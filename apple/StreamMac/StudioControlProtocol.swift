import Foundation

/// Versioned JSON-lines local IPC. Authentication starts a fresh session;
/// every subsequent request must carry that session and a unique request ID.
struct StudioControlRequest: Codable, Sendable {
    enum Operation: String, Codable, Sendable { case authenticate, capabilities, snapshot, subscribe, command, ping }
    var version = 1
    var type: Operation
    var id: UUID
    var clientID: UUID?
    var token: String?
    var sessionID: UUID?
    var commandID: String?
    /// Absolute/relative normalized numeric input. Exactly one may be set.
    var value: Double?
    var delta: Double?
    var page: Int?
    var text: String?
    var cursor: Int?
    /// Negotiate bounded response framing in the authentication handshake.
    var responseChunks: Bool?
    var authority: String?
}
struct StudioControlProtocolError: Codable, Equatable, Error, Sendable {
    var code: String
    var message: String
}
struct StudioControlCapability: Codable, Equatable, Sendable {
    var id: String
    var title: String
    var category: String
    var available: Bool
    var unavailableReason: String?
    var kind: String? = nil
    var argument: String? = nil
    var sourceKind: String? = nil
    var sourceAvailable: Bool? = nil
    var requiresConfirmation: Bool? = nil
    var target: StudioControlTarget? = nil
    var authority: String? = nil
    var scope: String? = nil
    var bindingIntent: String? = nil
}
struct StudioControlSnapshot: Codable, Equatable, Sendable {
    var projectID: String
    var revision: UInt64 = 0
    var stream: String
    var recording: String
    var preview: String
    var stagedSceneID: UUID?
    var programSceneID: UUID?
    var pendingStagedEdits: Bool
    var layerVisibility: [String: Bool]
    var macroProgress: ShowMacroProgress
    var values: [String: Double]? = nil
    var mutes: [String: Bool]? = nil
    var playback: [String: String]? = nil
    var programLayerVisibility: [String: Bool]? = nil
    var groupVisibility: [String: Bool]? = nil
    var overlayVisibility: [String: Bool]? = nil
    var directLiveEditing: Bool? = nil
    var chat: StudioControlChatState? = nil
    var interview: StudioControlInterviewState? = nil
    var recordingCountdown: Int? = nil
    var transport: StudioControlTransportState? = nil
    var visuals: [String: StudioControlVisualState]? = nil
    var guestSlots: [StudioControlGuestSlotState]? = nil
    var audience: StudioControlAudienceState? = nil
    var showProfiles: StudioControlShowProfileState? = nil
}
/// Resource-scoped visual intent receipts. Visibility reports the actual
/// staged/taken compositions, independently of whether its command is enabled.
struct StudioControlVisualState: Codable, Equatable, Sendable {
    var previewVisible: Bool? = nil
    var programVisible: Bool? = nil
    var bypassed: Bool? = nil
    var programBypassed: Bool? = nil
    var sourceID: UUID? = nil
    var programSourceID: UUID? = nil
}
struct StudioControlGuestSlotState: Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var peerID: UUID?
    var membership: String?
    var media: String?
    var muted: Bool?
    var solo: Bool?
}
struct StudioControlShowProfileState: Codable, Equatable, Sendable {
    var projectID: UUID
    var profileID: UUID
    var canSelect: Bool
    var requestedProjectID: UUID? = nil
    var requestedProfileID: UUID? = nil
}
struct StudioControlAudienceState: Codable, Equatable, Sendable {
    struct Reading: Codable, Equatable, Sendable {
        var destinationID: UUID
        var name: String
        var count: Int?
        var readAt: TimeInterval?
        var freshness: String
    }
    var observedAt: TimeInterval
    var liveSeconds: Int?
    var health: String
    var readings: [Reading]
    var presetDelivery: [String: String]
}
struct StudioControlInterviewState: Codable, Equatable, Sendable {
    struct Member: Codable, Equatable, Sendable {
        var id: UUID
        var name: String
        var membership: String
        var media: String
        var slot: UUID?
        var programAllowed: Bool
        var monitorAllowed: Bool
        var screenApproved: Bool
        var screenSharing: Bool
    }
    var phase: String
    var room: UUID?
    var locked: Bool
    var members: [Member]
}
struct StudioControlChatState: Codable, Equatable, Sendable {
    var queuedCount: Int
    var selectedID: String?
    var featuredID: String?
    var ready: Bool
    var stagedVisible: Bool
    var programVisible: Bool
}
struct StudioControlCommandResult: Codable, Sendable {
    var commandID: String
    var succeeded: Bool
    var error: StudioControlProtocolError?
}
struct StudioControlResponse: Codable, Sendable {
    var version = 1
    var type: String
    var id: UUID?
    var sessionID: UUID?
    var error: StudioControlProtocolError?
    var snapshot: StudioControlSnapshot?
    var commands: [StudioControlCapability]?
    var nextCursor: Int?
    var totalCommands: Int?
    var result: StudioControlCommandResult?
    var responseChunk: StudioControlResponseChunk?
}
struct StudioControlSession {
    private(set) var clientID: UUID?
    private(set) var sessionID: UUID?
    private var requests: Set<UUID> = []
    static let maxRequests = 2048
    mutating func authorize(_ request: StudioControlRequest, tokenForClient: (UUID) -> String?) -> StudioControlProtocolError? {
        guard request.version == 1 else { return .init(code: "versionMismatch", message: "Stream local IPC supports protocol version 1.") }
        guard request.type == .authenticate, clientID == nil, let client = request.clientID,
              let received = request.token, received.utf8.count == 64,
              let expected = tokenForClient(client), Self.constantTimeEqual(received, expected) else {
            return .init(code: "unauthorized", message: "Pair this client in Stream Settings before connecting.")
        }
        clientID = client; sessionID = UUID(); requests = [request.id]
        return nil
    }
    mutating func validate(_ request: StudioControlRequest, clientStillPaired: (UUID) -> Bool) -> StudioControlProtocolError? {
        guard request.version == 1 else { return .init(code: "versionMismatch", message: "Stream local IPC supports protocol version 1.") }
        guard let clientID, clientStillPaired(clientID), let sessionID, request.sessionID == sessionID else {
            return .init(code: "unauthorized", message: "This connection needs a fresh authenticated session.")
        }
        guard request.type != .authenticate, request.token == nil, request.responseChunks == nil else {
            return .init(code: "invalidRequest", message: "Authenticate only once per connection; tokens belong only in the handshake.")
        }
        guard !requests.contains(request.id) else { return .init(code: "duplicateRequest", message: "This request ID was already handled. It will not execute again.") }
        guard requests.count < Self.maxRequests else { return .init(code: "sessionLimit", message: "Reconnect and authenticate for a fresh session; do not replay old commands.") }
        if let authority = request.authority, request.type != .command || authority.utf8.count > 128 || authority.isEmpty {
            return .init(code: "invalidRequest", message: "Authority belongs only to a bounded current command.")
        }
        if request.type == .command {
            guard let id = request.commandID, !id.isEmpty, id.utf8.count <= 512 else { return .init(code: "invalidRequest", message: "A command needs a stable command ID of at most 512 bytes.") }
            let arguments = [request.value != nil, request.delta != nil, request.page != nil, request.text != nil]
            guard arguments.filter({ $0 }).count <= 1 else { return .init(code: "invalidValue", message: "Choose at most one typed command argument.") }
            if let value = request.value, !value.isFinite || value < 0 || value > 1 { return .init(code: "invalidValue", message: "A normalized value must be finite and between 0 and 1.") }
            if let delta = request.delta, !delta.isFinite || delta < -1 || delta > 1 { return .init(code: "invalidValue", message: "A normalized delta must be finite and between -1 and 1.") }
            if let page = request.page, page < 0 || page > 100_000 { return .init(code: "invalidValue", message: "A PDF page must be a zero-based integer from 0 to 100000.") }
            if let text = request.text, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.utf8.count > 512 { return .init(code: "invalidValue", message: "Marker text needs 1–512 UTF-8 bytes.") }
        } else if request.value != nil || request.delta != nil || request.page != nil || request.text != nil {
            return .init(code: "invalidRequest", message: "Typed arguments belong only to commands.")
        }
        if let cursor = request.cursor, cursor < 0 { return .init(code: "invalidRequest", message: "Capability cursors must be nonnegative.") }
        requests.insert(request.id)
        return nil
    }
    static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for index in a.indices { difference |= a[index] ^ b[index] }
        return difference == 0
    }
}
struct StudioControlFrameBuffer {
    static let maximumFrameBytes = 65_536
    private var buffer = Data()
    mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var frames: [Data] = []
        while let newline = buffer.firstIndex(of: 10) {
            let frame = buffer.prefix(upTo: newline)
            guard !frame.isEmpty, frame.count <= Self.maximumFrameBytes else { throw StudioControlProtocolError(code: "messageSize", message: "Each JSON message must contain 1–65536 bytes.") }
            frames.append(Data(frame))
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        guard buffer.count <= Self.maximumFrameBytes else { throw StudioControlProtocolError(code: "messageSize", message: "A JSON message exceeded 65536 bytes.") }
        return frames
    }
}

struct StudioControlTarget: Codable, Equatable, Sendable {
    var kind: String
    var id: String
    var name: String
    var eventID: String? = nil
    var provider: String? = nil
    var channelID: String? = nil
}
struct StudioControlTransportState: Codable, Equatable, Sendable {
    struct Destination: Codable, Equatable, Sendable {
        var id: UUID
        var name: String
        var state: String
        var eventKey: String?
        var managedStart: String?
        var localStop: String?
        var remoteEnd: String?
        var endingPending: Bool
        var confirmationPending: Bool
    }
    var destinations: [Destination]
    var confirmationPending: Bool
    var endingPending: Bool
    var endingCountdown: Int?
}

/// A negotiated framing extension: reconstruct the complete original response
/// before interpreting any state. Resource maps/arrays are never truncated.
struct StudioControlResponseChunk: Codable, Sendable {
    var transferID: UUID
    var index: Int
    var count: Int
    var totalBytes: Int
    var responseType: String
    var snapshotRevision: UInt64?
    var body: Data
}
enum StudioControlResponseFramer {
    static let chunkBytes = 24 * 1024
    static let maximumResponseBytes = 16 * 1024 * 1024
    static func frames(_ response: StudioControlResponse, chunking: Bool) throws -> [Data] {
        let encoder = JSONEncoder(), data = try JSONEncoder().encode(response)
        guard data.count <= maximumResponseBytes else {
            throw StudioControlProtocolError(code: "responseLimit", message: "This response exceeds the 16 MiB local control response limit. Reduce the project's resource data before reconnecting.")
        }
        if data.count <= StudioControlFrameBuffer.maximumFrameBytes { return [data] }
        guard chunking else {
            throw StudioControlProtocolError(code: "responseChunksRequired", message: "This project needs a controller that supports negotiated bounded response chunks. Update the controller and reconnect.")
        }
        let transfer = UUID(), count = (data.count + chunkBytes - 1) / chunkBytes
        return try (0..<count).map { index in
            let lower = index * chunkBytes, upper = min(data.count, lower + chunkBytes)
            let chunk = StudioControlResponseChunk(transferID: transfer, index: index, count: count, totalBytes: data.count,
                responseType: response.type, snapshotRevision: response.snapshot?.revision, body: data.subdata(in: lower..<upper))
            let frame = try encoder.encode(StudioControlResponse(type: "responseChunk", id: response.id, sessionID: response.sessionID, responseChunk: chunk))
            guard frame.count <= StudioControlFrameBuffer.maximumFrameBytes else {
                throw StudioControlProtocolError(code: "messageSize", message: "The response chunk exceeded the local frame limit.")
            }
            return frame
        }
    }
}
