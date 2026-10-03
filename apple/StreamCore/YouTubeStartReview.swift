import Foundation
import CoreFoundation

/// Public metadata only. This review cannot carry an ingest URL, key or token.
public struct YouTubeStartReview: Equatable, Sendable {
    public let binding: ProviderDestinationBinding
    public let eventTitle: String
    public let privacy: String
    public let scheduledAt: Date
    public let lifecycle: String
    public let streamID: String
    public let streamState: String
    public let resolution: String
    public let frameRate: String
    public let autoStart: Bool
    public let autoStop: Bool
    public let latency: String?
    public let profile: YouTubeStartProfile
    public let verifiedAt: Date
    public var expiresAt: Date { verifiedAt.addingTimeInterval(60) }
    public func requiresEarlyStart(at date: Date) -> Bool { lifecycle != "live" && scheduledAt > date }
}

/// The effective encoder configuration, after selecting the actual canvas.
public struct YouTubeStartProfile: Equatable, Sendable {
    public let transport: StreamProtocol
    public let output: OutputProfile
    public let codec: VideoCodec
    public let videoBitrate: Int
    public let audioBitrate: Int
    public let keyframeSeconds: Double
    public init(destination: StreamDestination, program: OutputProfile) {
        transport = destination.transport; output = destination.effectiveProfile(program: program)
        codec = destination.videoCodec; videoBitrate = destination.videoBitrate
        audioBitrate = destination.audioBitrate; keyframeSeconds = destination.keyframeSeconds ?? 2
    }
    public func validate() throws {
        // This managed route qualifies H.264/AAC SDR only. The provider also
        // documents HEVC/AV1, but this does not qualify Stream's E-RTMP path.
        guard [.rtmp, .rtmps].contains(transport), codec == .h264,
              output.canvasWidth <= 3840, output.canvasHeight <= 3840,
              min(output.canvasWidth, output.canvasHeight) <= 2160,
              output.frameRate <= 60, (100_000...50_000_000).contains(videoBitrate),
              (16_000...128_000).contains(audioBitrate), keyframeSeconds.isFinite,
              (1...4).contains(keyframeSeconds), keyframeSeconds.rounded() == keyframeSeconds else {
            throw ProviderFailure(.invalidRequest)
        }
    }
}

/// A GET-only reader. Its injected request must fence the expected account
/// generation before and after every network call. No creation, transition,
/// binding, retries or persisted credentials exist in this API.
public struct YouTubeStartReader: Sendable {
    private let send: ProviderAPI.Request
    private let now: @Sendable () -> Date
    public init(send: @escaping ProviderAPI.Request, now: @escaping @Sendable () -> Date = { Date() }) {
        self.send = send; self.now = now
    }
    public func review(binding: ProviderDestinationBinding, profile: YouTubeStartProfile) async throws -> YouTubeStartReview {
        try validate(binding); try profile.validate()
        try await verifyOwner(binding.channelID)
        let event = try await readEvent(binding)
        let stream = try await readStream(id: event.streamID, channelID: binding.channelID, profile: profile)
        guard !(event.latency == "ultraLow" && min(profile.output.canvasWidth, profile.output.canvasHeight) > 1080) else {
            throw ProviderFailure(.invalidRequest)
        }
        // The event could have been rebound while its stream was fetched.
        let after = try await readEvent(binding)
        guard after == event else { throw ProviderFailure(.invalidRequest) }
        return YouTubeStartReview(binding: binding, eventTitle: event.title, privacy: event.privacy,
            scheduledAt: event.scheduledAt, lifecycle: event.lifecycle, streamID: event.streamID,
            streamState: stream.state, resolution: stream.resolution, frameRate: stream.rate,
            autoStart: event.autoStart, autoStop: event.autoStop, latency: event.latency,
            profile: profile, verifiedAt: now())
    }
    /// Credentials live only in the returned value and the synchronous native
    /// handoff. Exact IDs/owner/profile/flags are rechecked around their read.
    public func reviewedIngest(_ review: YouTubeStartReview) async throws -> DestinationCredentials {
        try validate(review.binding); try review.profile.validate(); try fresh(review)
        try await verifyOwner(review.binding.channelID)
        let event = try await readEvent(review.binding)
        guard matches(event, review) else { throw ProviderFailure(.invalidRequest) }
        let row = try await single(path: "/youtube/v3/liveStreams", id: review.streamID, part: "snippet,cdn,status")
        let stream = try parseStream(row, id: review.streamID, channelID: review.binding.channelID, profile: review.profile)
        guard stream.resolution == review.resolution, stream.rate == review.frameRate else { throw ProviderFailure(.invalidRequest) }
        let cdn = row["cdn"] as? [String: Any] ?? [:]
        guard let ingest = cdn["ingestionInfo"] as? [String: Any],
              let endpoint = ingest[review.profile.transport == .rtmps ? "rtmpsIngestionAddress" : "ingestionAddress"] as? String,
              endpoint.utf8.count <= 2048,
              let url = URLComponents(string: endpoint), url.scheme == review.profile.transport.rawValue,
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              let key = ingest["streamName"] as? String, !key.isEmpty, key.utf8.count <= 16_384,
              !key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ProviderFailure(.invalidResponse)
        }
        let after = try await readEvent(review.binding)
        guard after == event, matches(after, review) else { throw ProviderFailure(.invalidRequest) }
        try fresh(review); try Task.checkCancellation()
        return .init(endpoint: endpoint, streamKey: key)
    }
    private struct Event: Equatable {
        var title: String; var privacy: String; var scheduledAt: Date; var lifecycle: String
        var streamID: String; var autoStart: Bool; var autoStop: Bool; var latency: String?
    }
    private struct Stream { var state: String; var resolution: String; var rate: String }
    private func validate(_ binding: ProviderDestinationBinding) throws {
        guard binding.provider == .youtube, ProviderChannel.validID(binding.channelID),
              let id = binding.eventID, ProviderChannel.validID(id) else { throw ProviderFailure(.invalidRequest) }
    }
    private func fresh(_ review: YouTubeStartReview) throws {
        let age = now().timeIntervalSince(review.verifiedAt)
        guard age >= 0, age < 60 else { throw ProviderFailure(.invalidRequest) }
    }
    private func verifyOwner(_ id: String) async throws {
        let channels = try await ProviderAPI(send: send).channels(.youtube)
        try Task.checkCancellation()
        guard channels.contains(where: { $0.id == id }) else { throw ProviderFailure(.permission) }
    }
    private func single(path: String, id: String, part: String) async throws -> [String: Any] {
        try Task.checkCancellation()
        var request = try ProviderAPI.request(.youtube, path: path, query: ["part": part, "id": id])
        request.timeoutInterval = 10
        let data = try await send(.youtube, request)
        try Task.checkCancellation()
        guard data.count <= 2_097_152,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["items"] as? [[String: Any]], rows.count == 1,
              rows[0]["id"] as? String == id else { throw ProviderFailure(.invalidResponse) }
        return rows[0]
    }
    private func readEvent(_ binding: ProviderDestinationBinding) async throws -> Event {
        guard let id = binding.eventID else { throw ProviderFailure(.invalidRequest) }
        let row = try await single(path: "/youtube/v3/liveBroadcasts", id: id, part: "snippet,status,contentDetails")
        guard let snippet = row["snippet"] as? [String: Any], snippet["channelId"] as? String == binding.channelID,
              let title = snippet["title"] as? String, !title.isEmpty, title.utf8.count <= 2048,
              let dateString = snippet["scheduledStartTime"] as? String,
              let scheduled = Self.date(dateString),
              let status = row["status"] as? [String: Any],
              let lifecycle = status["lifeCycleStatus"] as? String, ["ready", "live"].contains(lifecycle),
              let privacy = status["privacyStatus"] as? String, ["private", "unlisted", "public"].contains(privacy),
              let details = row["contentDetails"] as? [String: Any],
              let streamID = details["boundStreamId"] as? String, ProviderChannel.validID(streamID),
              let autoStart = Self.boolean(details["enableAutoStart"]),
              let autoStop = Self.boolean(details["enableAutoStop"]) else { throw ProviderFailure(.invalidRequest) }
        let latency = details["latencyPreference"] as? String
        if details["latencyPreference"] != nil && latency == nil { throw ProviderFailure(.invalidResponse) }
        if let latency, !["normal", "low", "ultraLow"].contains(latency) { throw ProviderFailure(.invalidRequest) }
        return .init(title: title, privacy: privacy, scheduledAt: scheduled, lifecycle: lifecycle,
            streamID: streamID, autoStart: autoStart, autoStop: autoStop, latency: latency)
    }
    private func readStream(id: String, channelID: String, profile: YouTubeStartProfile) async throws -> Stream {
        try parseStream(await single(path: "/youtube/v3/liveStreams", id: id, part: "snippet,cdn,status"), id: id, channelID: channelID, profile: profile)
    }
    private func parseStream(_ row: [String: Any], id: String, channelID: String, profile: YouTubeStartProfile) throws -> Stream {
        guard row["id"] as? String == id, (row["snippet"] as? [String: Any])?["channelId"] as? String == channelID,
              let status = row["status"] as? [String: Any], let state = status["streamStatus"] as? String,
              ["ready", "inactive"].contains(state),
              let cdn = row["cdn"] as? [String: Any], cdn["ingestionType"] as? String == "rtmp",
              let resolution = cdn["resolution"] as? String, let rate = cdn["frameRate"] as? String,
              let res = YouTubeStreamDraft.Resolution(rawValue: resolution), let fps = YouTubeStreamDraft.FrameRate(rawValue: rate),
              (res == .variable) == (fps == .variable) else { throw ProviderFailure(.invalidRequest) }
        if let health = status["healthStatus"] as? [String: Any] {
            guard health["status"] as? String != "bad" else { throw ProviderFailure(.invalidRequest) }
            if let issues = health["configurationIssues"] {
                guard let rows = issues as? [[String: Any]], rows.count <= 128,
                      !rows.contains(where: { $0["severity"] as? String == "error" }) else { throw ProviderFailure(.invalidRequest) }
            }
        }
        if res != .variable {
            let expectedHeight = ["240p": 240, "360p": 360, "480p": 480, "720p": 720, "1080p": 1080, "1440p": 1440, "2160p": 2160][resolution]!
            // Fixed provider profiles describe landscape height; use variable
            // profiles for portrait/square/custom layouts instead of guessing.
            guard profile.output.canvasHeight == expectedHeight,
                  profile.output.canvasWidth == (expectedHeight * 16 / 9) / 2 * 2,
                  profile.output.frameRate == (fps == .fps30 ? 30 : 60) else { throw ProviderFailure(.invalidRequest) }
        }
        return .init(state: state, resolution: resolution, rate: rate)
    }
    private func matches(_ event: Event, _ review: YouTubeStartReview) -> Bool {
        event.streamID == review.streamID && event.title == review.eventTitle && event.privacy == review.privacy &&
        event.scheduledAt == review.scheduledAt && event.lifecycle == review.lifecycle && event.autoStart == review.autoStart &&
        event.autoStop == review.autoStop && event.latency == review.latency &&
        !(event.latency == "ultraLow" && min(review.profile.output.canvasWidth, review.profile.output.canvasHeight) > 1080)
    }
    private static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds); return formatter.date(from: value)
    }
    private static func boolean(_ value: Any?) -> Bool? {
        // JSON numbers must not bridge to Bool and masquerade as reviewed flags.
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
}
