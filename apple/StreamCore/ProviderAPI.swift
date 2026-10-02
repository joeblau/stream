import Foundation

/// Adapters issue real documented requests. Authorization lives in an injected
/// machine credential boundary; tests replace that boundary, never app statuses.
public struct ProviderAPI: Sendable {
    public typealias Request = @Sendable (ManagedProvider, URLRequest) async throws -> Data
    private let send: Request
    public init(send: @escaping Request) { self.send = send }
    public func channels(_ provider: ManagedProvider) async throws -> [ProviderChannel] {
        let path: String, query: [String: String]
        switch provider {
        case .youtube: path = "/youtube/v3/channels"; query = ["part": "snippet", "mine": "true", "maxResults": "50"]
        case .twitch: path = "/helix/users"; query = [:]
        case .restream: path = "/v2/user/channels"; query = [:]
        default: throw ProviderFailure(.unavailable)
        }
        let key = provider == .youtube ? "items" : (provider == .twitch ? "data" : "channels")
        let rows: [[String: Any]]
        if provider == .youtube { rows = try await youtubeRows(path: path, query: query) }
        else {
            let object = try await object(provider, path: path, query: query)
            guard let values = object[key] as? [[String: Any]], values.count <= 2_000 else { throw ProviderFailure(.invalidResponse) }
            rows = values
        }
        var channels: [String: ProviderChannel] = [:]
        for row in rows {
            let id = (row["id"] as? String) ?? (row["id"] as? NSNumber)?.stringValue ?? ""
            guard ProviderChannel.validID(id) else { throw ProviderFailure(.invalidResponse) }
            let title: String, url: URL?
            switch provider {
            case .youtube:
                title = (row["snippet"] as? [String: Any])?["title"] as? String ?? id
                url = URL(string: "https://www.youtube.com/channel/\(id)")
            case .twitch:
                title = row["display_name"] as? String ?? id
                let login = row["login"] as? String ?? ""
                url = ProviderChannel.validID(login) ? URL(string: "https://www.twitch.tv/\(login)") : nil
            default:
                title = row["displayName"] as? String ?? id
                url = (row["channelUrl"] as? String).flatMap(URL.init(string:))
            }
            channels[id] = .init(id: id, provider: provider, title: title, publicURL: url)
        }
        return channels.values.sorted { $0.id < $1.id }
    }
    /// Refresh reads existing IDs only. It cannot create, replay or start events.
    public func upcoming(_ provider: ManagedProvider) async throws -> [ProviderEvent] {
        if provider == .youtube {
            let rows = try await youtubeRows(path: "/youtube/v3/liveBroadcasts", query: ["part": "snippet,status", "broadcastStatus": "upcoming", "maxResults": "50"])
            return try unique(rows.map(Self.youtubeEvent))
        }
        if provider == .restream {
            let data = try await send(provider, request(provider, path: "/v2/user/events/upcoming", query: ["source": "2"]))
            guard data.count <= 2_097_152, let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]], rows.count <= 2_000 else { throw ProviderFailure(.invalidResponse) }
            return try unique(rows.map { row in
                guard let id = row["id"] as? String, ProviderChannel.validID(id) else { throw ProviderFailure(.invalidResponse) }
                return ProviderEvent(id: id, provider: .restream, title: row["title"] as? String ?? id,
                    description: row["description"] as? String ?? "",
                    scheduledAt: (row["scheduledFor"] as? Double).flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0) : nil },
                    state: row["status"] as? String == "upcoming" ? .upcoming : .unknown)
            })
        }
        // Twitch channel schedule segments are not discrete live-event grants.
        throw ProviderFailure(.unavailable)
    }
    public func youtubeEvent(id: String) async throws -> ProviderEvent {
        guard ProviderChannel.validID(id) else { throw ProviderFailure(.invalidRequest) }
        let object = try await object(.youtube, path: "/youtube/v3/liveBroadcasts", query: ["part": "snippet,status", "id": id])
        guard let rows = object["items"] as? [[String: Any]], let row = rows.first, rows.count == 1, row["id"] as? String == id else { throw ProviderFailure(.invalidResponse) }
        return try Self.youtubeEvent(row)
    }
    public func twitchViewers(channelID: String) async throws -> Int? {
        guard ProviderChannel.validID(channelID) else { throw ProviderFailure(.invalidRequest) }
        let object = try await object(.twitch, path: "/helix/streams", query: ["user_id": channelID])
        guard let rows = object["data"] as? [[String: Any]] else { throw ProviderFailure(.invalidResponse) }
        // Empty means no visible active stream; no fabricated zero or event end.
        guard let value = rows.first?["viewer_count"] as? Int, value >= 0 else { return nil }
        return value
    }
    public func youtubeViewers(eventID: String) async throws -> Int? {
        guard ProviderChannel.validID(eventID) else { throw ProviderFailure(.invalidRequest) }
        let object = try await object(.youtube, path: "/youtube/v3/videos", query: ["part": "liveStreamingDetails", "id": eventID])
        guard let rows = object["items"] as? [[String: Any]] else { throw ProviderFailure(.invalidResponse) }
        let raw = (rows.first?["liveStreamingDetails"] as? [String: Any])?["concurrentViewers"] as? String
        return raw.flatMap(Int.init).flatMap { $0 >= 0 ? $0 : nil }
    }
    public func twitchStreamKey(channelID: String) async throws -> String {
        guard ProviderChannel.validID(channelID) else { throw ProviderFailure(.invalidRequest) }
        let object = try await object(.twitch, path: "/helix/streams/key", query: ["broadcaster_id": channelID])
        guard let rows = object["data"] as? [[String: Any]], let key = rows.first?["stream_key"] as? String,
              !key.isEmpty, key.utf8.count <= 16_384 else { throw ProviderFailure(.invalidResponse) }
        return key // In-memory -> destination Keychain; never ProviderChannel.
    }
    private func youtubeRows(path: String, query: [String: String]) async throws -> [[String: Any]] {
        var query = query, rows: [[String: Any]] = [], seen: Set<String> = []
        for _ in 0..<40 {
            let page = try await object(.youtube, path: path, query: query)
            guard let values = page["items"] as? [[String: Any]], rows.count + values.count <= 2_000 else { throw ProviderFailure(.invalidResponse) }
            rows += values
            guard let next = page["nextPageToken"] as? String, !next.isEmpty else { return rows }
            guard next.utf8.count <= 2_048, seen.insert(next).inserted else { throw ProviderFailure(.invalidResponse) }
            query["pageToken"] = next
        }
        throw ProviderFailure(.invalidResponse) // Never present a truncated list as complete.
    }
    private static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let result = formatter.date(from: value) { return result }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: value)
    }
    private func object(_ provider: ManagedProvider, path: String, query: [String: String] = [:]) async throws -> [String: Any] {
        let data = try await send(provider, request(provider, path: path, query: query))
        guard data.count <= 2_097_152, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ProviderFailure(.invalidResponse) }
        return object
    }
    public static func request(_ provider: ManagedProvider, path: String, query: [String: String] = [:]) throws -> URLRequest {
        let host: String
        switch provider {
        case .youtube: host = "www.googleapis.com"
        case .twitch: host = "api.twitch.tv"
        case .restream: host = "api.restream.io"
        default: throw ProviderFailure(.unavailable)
        }
        guard path.first == "/", !path.contains(".."), !path.contains("?"), !path.contains("#") else { throw ProviderFailure(.invalidRequest) }
        var c = URLComponents(); c.scheme = "https"; c.host = host; c.path = path
        c.queryItems = query.isEmpty ? nil : query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: c.url!); request.timeoutInterval = 30
        return request
    }
    private func request(_ provider: ManagedProvider, path: String, query: [String: String] = [:]) throws -> URLRequest {
        try Self.request(provider, path: path, query: query)
    }
    private static func youtubeEvent(_ row: [String: Any]) throws -> ProviderEvent {
        guard let id = row["id"] as? String, ProviderChannel.validID(id) else { throw ProviderFailure(.invalidResponse) }
        let snippet = row["snippet"] as? [String: Any] ?? [:], status = row["status"] as? [String: Any] ?? [:]
        let state: ProviderEvent.State
        switch status["lifeCycleStatus"] as? String {
        case "created", "ready": state = .upcoming
        case "live": state = .live
        case "complete", "revoked": state = .ended
        default: state = .unknown
        }
        return ProviderEvent(id: id, provider: .youtube, channelID: snippet["channelId"] as? String,
            title: snippet["title"] as? String ?? id, description: snippet["description"] as? String ?? "",
            privacy: status["privacyStatus"] as? String,
            scheduledAt: (snippet["scheduledStartTime"] as? String).flatMap { Self.date($0) },
            state: state, publicURL: URL(string: "https://www.youtube.com/watch?v=\(id)"))
    }
    private func unique(_ events: [ProviderEvent]) throws -> [ProviderEvent] {
        guard events.count <= 2_000 else { throw ProviderFailure(.invalidResponse) }
        return Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { _, newest in newest }).values.sorted { $0.id < $1.id }
    }
}

public struct YouTubeEventDraft: Equatable, Sendable {
    public enum Privacy: String, CaseIterable, Sendable { case `private`, unlisted, `public` }
    public var title: String
    public var description: String
    public var privacy: Privacy
    public var scheduledAt: Date
    public init(title: String = "", description: String = "", privacy: Privacy = .private, scheduledAt: Date = Date().addingTimeInterval(3_600)) {
        self.title = title; self.description = description; self.privacy = privacy; self.scheduledAt = scheduledAt
    }
    public func validate(now: Date = Date()) throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 100,
              description.count <= 5_000, scheduledAt > now else { throw ProviderFailure(.invalidRequest) }
    }
}

public extension ProviderAPI {
    /// Acknowledged provider ID is returned immediately. The caller retains it
    /// before any later refresh. No mutation is retried after an uncertain reply.
    func createYouTubeEvent(_ draft: YouTubeEventDraft) async throws -> ProviderEvent {
        try draft.validate()
        var request = try Self.request(.youtube, path: "/youtube/v3/liveBroadcasts", query: ["part": "snippet,status,contentDetails"])
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "snippet": ["title": draft.title, "description": draft.description,
                        "scheduledStartTime": ISO8601DateFormatter().string(from: draft.scheduledAt)],
            "status": ["privacyStatus": draft.privacy.rawValue],
            "contentDetails": ["enableAutoStart": false, "enableAutoStop": false]
        ])
        let data = try await send(.youtube, request)
        guard data.count <= 2_097_152, let row = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ProviderFailure(.invalidResponse) }
        return try Self.youtubeEvent(row)
    }
    /// Update only the snippet. Preserve all writable snippet fields from a
    /// fresh read and leave privacy/contentDetails untouched. Privacy changes
    /// require YouTube Studio until that broader mutation is implemented.
    func editYouTubeEvent(id: String, title: String, description: String, scheduledAt: Date) async throws -> ProviderEvent {
        try YouTubeEventDraft(title: title, description: description, scheduledAt: scheduledAt).validate()
        guard ProviderChannel.validID(id) else { throw ProviderFailure(.invalidRequest) }
        let object = try await object(.youtube, path: "/youtube/v3/liveBroadcasts", query: ["part": "snippet,status", "id": id])
        guard let rows = object["items"] as? [[String: Any]], rows.count == 1, let row = rows.first,
              row["id"] as? String == id, let old = row["snippet"] as? [String: Any],
              try Self.youtubeEvent(row).state == .upcoming else { throw ProviderFailure(.invalidRequest) }
        var snippet: [String: Any] = [:]
        for field in ["title", "description", "categoryId", "scheduledStartTime", "scheduledEndTime"] {
            snippet[field] = old[field]
        }
        if let end = old["scheduledEndTime"] as? String, let date = Self.date(end), date <= scheduledAt { throw ProviderFailure(.invalidRequest) }
        snippet["title"] = title; snippet["description"] = description
        snippet["scheduledStartTime"] = ISO8601DateFormatter().string(from: scheduledAt)
        var request = try Self.request(.youtube, path: "/youtube/v3/liveBroadcasts", query: ["part": "snippet"])
        request.httpMethod = "PUT"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let etag = row["etag"] as? String { request.setValue(etag, forHTTPHeaderField: "If-Match") }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["id": id, "snippet": snippet])
        let data = try await send(.youtube, request)
        guard data.count <= 2_097_152, let updated = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ProviderFailure(.invalidResponse) }
        // PUT with only snippet does not return status. Reuse the verified
        // pre-update privacy/state rather than inventing a changed lifecycle.
        var merged = updated; merged["status"] = row["status"]
        return try Self.youtubeEvent(merged)
    }
    func deleteYouTubeEvent(id: String) async throws {
        let event = try await youtubeEvent(id: id)
        guard event.state == .upcoming else { throw ProviderFailure(.invalidRequest) }
        var request = try Self.request(.youtube, path: "/youtube/v3/liveBroadcasts", query: ["id": id])
        request.httpMethod = "DELETE"
        _ = try await send(.youtube, request)
    }
    /// Completes the remote event. It does not stop any local publisher or
    /// recorder. An operator must choose this separately from Disconnect Ingest.
    func completeYouTubeEvent(id: String) async throws -> ProviderEvent {
        let event = try await youtubeEvent(id: id)
        guard event.state == .live else { throw ProviderFailure(.invalidRequest) }
        var request = try Self.request(.youtube, path: "/youtube/v3/liveBroadcasts/transition",
            query: ["part": "snippet,status", "id": id, "broadcastStatus": "complete"])
        request.httpMethod = "POST"
        let data = try await send(.youtube, request)
        guard data.count <= 2_097_152, let row = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ProviderFailure(.invalidResponse) }
        return try Self.youtubeEvent(row)
    }
    /// Only an existing, bound RTMP/RTMPS stream is importable. Stream does not
    /// guess an endpoint or create/bind a stream behind the operator's back.
    func youtubeIngest(eventID: String) async throws -> DestinationCredentials {
        guard ProviderChannel.validID(eventID) else { throw ProviderFailure(.invalidRequest) }
        let event = try await object(.youtube, path: "/youtube/v3/liveBroadcasts", query: ["part": "contentDetails", "id": eventID])
        guard let rows = event["items"] as? [[String: Any]], rows.count == 1,
              let details = rows.first?["contentDetails"] as? [String: Any],
              let streamID = details["boundStreamId"] as? String, ProviderChannel.validID(streamID) else { throw ProviderFailure(.unavailable) }
        let stream = try await object(.youtube, path: "/youtube/v3/liveStreams", query: ["part": "cdn", "id": streamID])
        guard let streams = stream["items"] as? [[String: Any]], streams.count == 1,
              let cdn = streams.first?["cdn"] as? [String: Any], cdn["ingestionType"] as? String == "rtmp",
              let ingest = cdn["ingestionInfo"] as? [String: Any],
              let endpoint = (ingest["rtmpsIngestionAddress"] as? String) ?? (ingest["ingestionAddress"] as? String),
              let url = URL(string: endpoint), ["rtmp", "rtmps"].contains(url.scheme ?? ""), url.host != nil,
              let key = ingest["streamName"] as? String, !key.isEmpty, key.utf8.count <= 16_384 else { throw ProviderFailure(.invalidResponse) }
        return .init(endpoint: endpoint, streamKey: key)
    }
    func setTwitchTitle(channelID: String, title: String) async throws {
        guard ProviderChannel.validID(channelID), !title.isEmpty, title.utf8.count <= 140 else { throw ProviderFailure(.invalidRequest) }
        var request = try Self.request(.twitch, path: "/helix/channels", query: ["broadcaster_id": channelID])
        request.httpMethod = "PATCH"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["title": title])
        _ = try await send(.twitch, request)
    }
}
