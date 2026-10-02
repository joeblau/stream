import Foundation

public enum ManagedProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case youtube, twitch, restream, facebookPages, linkedinLive
    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .youtube: return "YouTube"
        case .twitch: return "Twitch"
        case .restream: return "Restream"
        case .facebookPages: return "Facebook Pages"
        case .linkedinLive: return "LinkedIn Live"
        }
    }
    public var scopes: [String] {
        switch self {
        case .youtube: return ["https://www.googleapis.com/auth/youtube"]
        case .twitch: return ["channel:read:stream_key", "channel:manage:broadcast"]
        case .restream: return ["channels.read", "stream.read", "stream.write"]
        default: return []
        }
    }
    public var accountGate: String {
        switch self {
        case .youtube: return "Register a Google Desktop OAuth client, enable YouTube Data API v3, configure consent/test users and complete any required scope verification. The selected channel must separately enable live streaming."
        case .twitch: return "Register a public Twitch application for device authorization. Twitch public clients can refresh without a client secret; authorization must grant this channel's requested scopes."
        case .restream: return "Use your own registered Restream application and granted channels.read / stream.read / stream.write scopes. Its client secret stays in this Mac's Keychain; Stream embeds none."
        case .facebookPages: return "An approved Meta app, Live Video API feature, current Page permissions and a permitted Page role are required. Current approval/configuration is unavailable here; Page discovery and event APIs are disabled."
        case .linkedinLive: return "LinkedIn Live Events product approval, eligible broadcaster and member or organization live scopes are required. Member and organization scopes cannot be combined in one authorization request. No approved connector is configured here."
        }
    }
    public var repairURL: URL {
        switch self {
        case .youtube: return URL(string: "https://www.youtube.com/features")!
        case .twitch: return URL(string: "https://dev.twitch.tv/console/apps")!
        case .restream: return URL(string: "https://developers.restream.io/apps")!
        case .facebookPages: return URL(string: "https://www.facebook.com/live/producer")!
        case .linkedinLive: return URL(string: "https://www.linkedin.com/help/linkedin/answer/a568503")!
        }
    }
}

public struct ProviderChannel: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var provider: ManagedProvider
    public var title: String
    public var publicURL: URL?
    public init(id: String, provider: ManagedProvider, title: String, publicURL: URL? = nil) {
        self.id = id; self.provider = provider; self.title = String(title.prefix(500))
        self.publicURL = Self.publicLink(publicURL)
    }
    public static func publicLink(_ url: URL?) -> URL? {
        guard let url, url.absoluteString.utf8.count <= 2_048,
              let c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.scheme == "https", c.host != nil,
              c.user == nil, c.password == nil,
              (c.queryItems ?? []).allSatisfy({ ["v", "t"].contains($0.name) }) else { return nil }
        return url
    }
    public static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 256 && id.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "_-".unicodeScalars.contains($0)
        }
    }
}

public struct ProviderEvent: Codable, Equatable, Identifiable, Sendable {
    public enum State: String, Codable, Sendable { case unknown, upcoming, live, ended }
    public var id: String
    public var provider: ManagedProvider
    public var channelID: String?
    public var title: String
    public var description: String
    public var privacy: String?
    public var scheduledAt: Date?
    public var state: State
    public var publicURL: URL?
    public var verifiedAt: Date
    public init(id: String, provider: ManagedProvider, channelID: String? = nil, title: String,
                description: String = "", privacy: String? = nil, scheduledAt: Date? = nil,
                state: State = .unknown, publicURL: URL? = nil, verifiedAt: Date = Date()) {
        self.id = id; self.provider = provider; self.channelID = channelID; self.title = String(title.prefix(500))
        self.description = String(description.prefix(5_000)); self.privacy = privacy; self.scheduledAt = scheduledAt
        self.state = state; self.publicURL = ProviderChannel.publicLink(publicURL); self.verifiedAt = verifiedAt
    }
}

/// Portable routing identity only. A restored project must reauthorize and
/// refresh before showing remote state. No OAuth token, ingest URL or key here.
public struct ProviderDestinationBinding: Codable, Equatable, Sendable {
    public var provider: ManagedProvider
    public var channelID: String
    public var eventID: String?
    public init(provider: ManagedProvider, channelID: String, eventID: String? = nil) {
        self.provider = provider; self.channelID = channelID; self.eventID = eventID
    }
}

public struct ProviderFailure: Error, Equatable, Sendable, LocalizedError {
    public enum Kind: String, Sendable { case authorization, permission, rateLimited, unavailable, invalidResponse, invalidRequest }
    public var kind: Kind
    public var retryAfter: Double?
    public init(_ kind: Kind, retryAfter: Double? = nil) { self.kind = kind; self.retryAfter = retryAfter }
    public var errorDescription: String? {
        switch kind {
        case .authorization: return "Provider authorization expired or was revoked. Reconnect the account."
        case .permission: return "The provider denied this API or scope. Check app approval, account eligibility and permissions, then reconnect."
        case .rateLimited: return "The provider rate/quota limit was reached. Wait before refreshing; do not recreate the event."
        case .unavailable: return "The provider API is unavailable. Use its external controls or a manual destination."
        case .invalidResponse: return "The provider returned an unsupported or oversized response. No remote state was inferred."
        case .invalidRequest: return "Review the selected account, event and supported fields before retrying."
        }
    }
    public static func check(data: Data, response: HTTPURLResponse) throws {
        guard data.count <= 2_097_152 else { throw Self(.invalidResponse) }
        guard (200..<300).contains(response.statusCode) else {
            let status = response.statusCode
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let error = object?["error"] as? [String: Any]
            let reasons = (error?["errors"] as? [[String: Any]])?.compactMap { $0["reason"] as? String } ?? []
            if status == 429 || reasons.contains(where: { ["quotaExceeded", "rateLimitExceeded", "userRateLimitExceeded"].contains($0) }) {
                let delay = response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init).flatMap { $0.isFinite ? min(86_400, max(0, $0)) : nil }
                throw Self(.rateLimited, retryAfter: delay)
            }
            throw Self(status == 401 ? .authorization : (status == 403 ? .permission : (status >= 500 ? .unavailable : .invalidRequest)))
        }
    }
}
