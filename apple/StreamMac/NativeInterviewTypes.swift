import Foundation

enum NativeInterviewError: String, Error, Sendable, CustomStringConvertible {
    case configuration, authorization, expired, capacity, busy, malformed, unavailable
    case rateLimited, transport, timeout, cancelled, changed, closed, uncertainMutation
    var description: String { "Interview \(rawValue)" }
}

/// Capabilities and operator credentials deliberately have no Codable support.
/// They live only inside a session or the explicitly injected credential provider.
struct NativeInterviewSecret: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    fileprivate let value: String
    init(_ value: String, maximumBytes: Int = 1_024) throws {
        guard (1...2_048).contains(maximumBytes), !value.isEmpty, value.utf8.count <= maximumBytes,
              !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw NativeInterviewError.authorization
        }
        self.value = value
    }
    var description: String { "<private interview credential>" }
    var debugDescription: String { description }
    func withCredentialValue<Result>(_ body: (String) throws -> Result) rethrows -> Result { try body(value) }
    var authorizationHeader: String { "Bearer \(value)" }
    var capabilityProtocol: String { "cap.\(value)" }
    var isCapability: Bool { value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) } }
}

struct NativeInterviewInvite: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let id: UUID
    let expires: Date
    let secret: NativeInterviewSecret
    var description: String { "<private expiring interview invite>" }
    var debugDescription: String { description }

    /// Sharing is an explicit operation. The capability is a fragment, never
    /// a request query or part of a published session snapshot.
    func guestURL(configuration: NativeInterviewConfiguration, room: UUID) throws -> URL {
        guard expires > Date(), secret.isCapability else { throw NativeInterviewError.expired }
        var components = URLComponents(url: configuration.serviceURL, resolvingAgainstBaseURL: false)!
        components.path = "/guest.html"
        components.queryItems = [.init(name: "room", value: room.uuidString.lowercased())]
        components.fragment = secret.value
        guard let url = components.url else { throw NativeInterviewError.configuration }
        return url
    }
}

struct NativeInterviewCreatedRoom: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let id: UUID
    let expires: Date
    let capacity: Int
    let host: NativeInterviewInvite
    let guest: NativeInterviewInvite
    var description: String { "<private interview room capabilities>" }
    var debugDescription: String { description }
}

struct NativeInterviewConfiguration: Sendable {
    let serviceURL: URL
    let allowedOrigin: String
    let requestTimeout: TimeInterval

    init(serviceURL: URL, allowedOrigin: URL, requestTimeout: TimeInterval = 10,
         allowLoopbackHTTPForValidation: Bool = false) throws {
        func valid(_ url: URL) -> Bool {
            guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
                  parts.query == nil, parts.fragment == nil,
                  parts.path.isEmpty || parts.path == "/",
                  parts.port.map({ (1...65_535).contains($0) }) ?? true else { return false }
            return parts.scheme == "https" || (allowLoopbackHTTPForValidation
                && parts.scheme == "http" && ["127.0.0.1", "::1"].contains(host))
        }
        guard valid(serviceURL), valid(allowedOrigin), requestTimeout.isFinite,
              (0.1...30).contains(requestTimeout) else { throw NativeInterviewError.configuration }
        var base = URLComponents(url: serviceURL, resolvingAgainstBaseURL: false)!
        base.path = ""; self.serviceURL = base.url!
        var origin = URLComponents(url: allowedOrigin, resolvingAgainstBaseURL: false)!
        origin.path = ""; self.allowedOrigin = origin.string!
        self.requestTimeout = requestTimeout
    }

    func endpoint(_ path: String, websocket: Bool = false) -> URL {
        var parts = URLComponents(url: serviceURL, resolvingAgainstBaseURL: false)!
        parts.path = path
        if websocket { parts.scheme = parts.scheme == "https" ? "wss" : "ws" }
        return parts.url!
    }
}

struct NativeInterviewRelayServer: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let urls: [String]
    let username: String?
    let credential: NativeInterviewSecret?
    var description: String { "<private interview relay configuration>" }
    var debugDescription: String { description }
}

struct NativeInterviewRelayConfiguration: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let servers: [NativeInterviewRelayServer]
    let expires: Date
    let refreshAt: Date
    var description: String { "<private expiring interview relay configuration>" }
    var debugDescription: String { description }
}

/// The service UUID generations and native full lease are both required.
/// A reconnect retains the invite/slot identity but replaces every authority.
struct NativeInterviewPeerLease: Sendable, Equatable {
    let room: UUID
    let hostGeneration: UUID
    let guestGeneration: UUID
    let receive: GuestReceiveLease
}

struct NativeInterviewMediaMIDs: Sendable, Equatable {
    let audio: String
    let camera: String
    let screen: String
    init(audio: String, camera: String, screen: String) throws {
        let values = [audio, camera, screen]
        guard Set(values).count == 3, values.allSatisfy({ value in
            !value.isEmpty && value.utf8.count <= 64
                && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        }) else { throw NativeInterviewError.malformed }
        self.audio = audio; self.camera = camera; self.screen = screen
    }
}

enum NativeInterviewMediaEvent: Sendable {
    case offer(sdp: String, media: NativeInterviewMediaMIDs)
    case candidate(value: String, mid: String)
    case ready
    case screenSharing(Bool)
    case controlClosed
    case failed(NativeInterviewError)
    var byteCount: Int {
        switch self {
        case .offer(let sdp, _): sdp.utf8.count + 256
        case .candidate(let value, let mid): value.utf8.count + mid.utf8.count + 128
        default: 128
        }
    }
}

@MainActor protocol NativeInterviewMediaHost: AnyObject {
    func startHost() throws
    func acceptAnswer(_ sdp: String) throws
    func acceptCandidate(_ value: String, mid: String) throws
    func approveScreen(_ approved: Bool) -> Bool
    /// Closes the full-lease sink synchronously before native callback teardown.
    func retire()
}

@MainActor protocol NativeInterviewMediaHostFactory {
    func makeHost(context: NativeInterviewPeerLease, relay: NativeInterviewRelayConfiguration,
                  events: @escaping @Sendable (NativeInterviewMediaEvent) -> Bool) async throws
        -> any NativeInterviewMediaHost
}

enum NativeInterviewMembership: String, Sendable { case waiting, backstage, onair }
enum NativeInterviewMediaState: String, Sendable { case unavailable, preparing, negotiating, ready, failed }
struct NativeInterviewMember: Identifiable, Sendable, Equatable {
    let id: UUID
    let name: String
    var membership: NativeInterviewMembership
    var media: NativeInterviewMediaState = .unavailable
    var screenApproved = false
    var screenSharing = false
}
enum NativeInterviewPhase: String, Sendable {
    case idle, creating, connecting, connected, disconnected, ending, ended, expired, failed, closed
}
struct NativeInterviewSnapshot: Sendable, Equatable {
    var phase: NativeInterviewPhase = .idle
    var room: UUID?
    var expires: Date?
    var members: [NativeInterviewMember] = []
    var locked = false
    var program = false
    var recording = false
    var failure: NativeInterviewError?
}

struct NativeInterviewICECandidate: Sendable {
    let value: String
    let mid: String
    init(value: String, mid: String) throws {
        guard !value.isEmpty, value.utf8.count <= 4_096, !mid.isEmpty, mid.utf8.count <= 64,
              !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              mid.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            throw NativeInterviewError.malformed
        }
        self.value = value; self.mid = mid
    }
}

enum NativeInterviewSignal: Sendable {
    case answer(negotiation: UUID, sdp: String)
    case candidate(negotiation: UUID, candidate: NativeInterviewICECandidate)
    case reset
}

/// Decodes only bounded metadata and the exact browser signal envelope.
enum NativeInterviewWire {
    static func object(_ data: Data, limit: Int = 65_536) throws -> [String: Any] {
        guard data.count <= limit, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NativeInterviewError.malformed
        }
        return object
    }
    static func id(_ value: Any?) throws -> UUID {
        guard let text = value as? String, text.count == 36, text == text.lowercased(),
              let id = UUID(uuidString: text), id.uuidString.lowercased() == text else {
            throw NativeInterviewError.malformed
        }
        return id
    }
    static func number(_ value: Any?) throws -> Double {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { throw NativeInterviewError.malformed }
        return number.doubleValue
    }
    static func boolean(_ value: Any?) throws -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw NativeInterviewError.malformed
        }
        return number.boolValue
    }
    static func invite(_ value: Any?, now: Date) throws -> NativeInterviewInvite {
        guard let value = value as? [String: Any], let token = value["token"] as? String else {
            throw NativeInterviewError.malformed
        }
        let secret = try NativeInterviewSecret(token), expires = try number(value["expires"]) / 1_000
        guard secret.isCapability, expires > now.timeIntervalSince1970,
              expires <= now.timeIntervalSince1970 + 7_201 else { throw NativeInterviewError.malformed }
        return try .init(id: id(value["id"]), expires: Date(timeIntervalSince1970: expires), secret: secret)
    }
    static func signal(kind: String, payload: String, expectedNegotiation: UUID) throws -> NativeInterviewSignal? {
        if kind == "reset" { return .reset }
        guard let data = payload.data(using: .utf8), data.count <= 60_000 else { throw NativeInterviewError.malformed }
        let object = try self.object(data, limit: 60_000), negotiation = try id(object["negotiation"])
        // Old negotiations may carry an obsolete or malformed codec payload.
        // Discard that envelope before interpreting its SDP/ICE contents.
        guard negotiation == expectedNegotiation else { return nil }
        if kind == "answer", let description = object["description"] as? [String: String],
           description["type"] == "answer", let sdp = description["sdp"], validSDP(sdp) {
            return .answer(negotiation: negotiation, sdp: sdp)
        }
        if kind == "candidate", let candidate = object["candidate"] as? [String: Any],
           let value = candidate["candidate"] as? String, let mid = candidate["sdpMid"] as? String {
            return .candidate(negotiation: negotiation, candidate: try .init(value: value, mid: mid))
        }
        throw NativeInterviewError.malformed
    }
    static func validSDP(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 58_000 && !value.unicodeScalars.contains {
            ($0.value < 32 && ![9, 10, 13].contains($0.value)) || $0.value == 127
        }
    }
}
