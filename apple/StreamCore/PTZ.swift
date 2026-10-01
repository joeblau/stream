import Foundation

// MARK: - E06 PTZ camera control model + VISCA codec (issue #165)
//
// This file is the protocol-pinned, platform-agnostic core of the macOS PTZ
// feature: the target/preset/recall-link model, the VISCA packet codec, and
// the file-backed document store. The transport (Network framework UDP/TCP)
// and the UI live in the StreamMac target; everything here is pure Foundation
// so StreamCoreTests can pin the wire format and the document round-trip.
//
// ## Pinned protocol assumptions (VISCA over IP)
//
// - Framing: RAW serial-format VISCA frames (`8x ... FF`), one command per
//   datagram (UDP) or per TCP write. The Sony "VISCA over IP" 8-byte payload
//   header is NOT emitted — the common PTZ cameras below all accept raw
//   serial framing on their VISCA-over-IP listeners, which is also what their
//   own apps and companion software send.
// - Address: the header byte is `0x80 | cameraAddress` with address 1…7
//   (broadcast address 8 is not used; commands address one camera at a time).
// - No sequence numbers, no retries: VISCA over IP is best-effort. The
//   controller re-sends `stop` on focus loss/disconnect, and movement
//   commands are inherently idempotent (the last one wins).
// - Replies: ACK `90 4y FF`, completion `90 5y FF`, error `90 6y cc FF`
//   (y = socket 1…2). Movement commands are fire-and-forget; replies are
//   parsed for diagnostics only, never awaited on the control path.
//
// ## Protocol/device compatibility matrix
//
// | Device / family            | Protocol        | Default port | Pan/tilt | Zoom | Presets | Status |
// |----------------------------|-----------------|--------------|----------|------|---------|--------|
// | Sony SRG series (SRG-X120, | VISCA over IP   | UDP/TCP      | yes      | yes  | 0-5 via | Verified against Sony |
// |   SRG-300H, SRG-A40)       |  (raw serial)   | 52381        |          |      | CAM_Memory | protocol manual; hardware unconfirmed |
// | PTZOptics (12x/20x/30x,    | VISCA over IP   | UDP 1259,    | yes      | yes  | 0-89 via | Verified against PTZOptics |
// |   Move/Link series)        |  (raw serial)   | TCP 5678     |          |      | CAM_Memory | VISCA-over-IP command list; hardware unconfirmed |
// | BirdDog P100/P200, Eyes    | VISCA over IP   | UDP/TCP      | yes      | yes  | 0-5 via | Verified against BirdDog |
// |   (VISCA mode)             |  (raw serial)   | 52381        |          |      | CAM_Memory | API docs; hardware unconfirmed |
// | AViPAS AV-20xx series      | VISCA over IP   | UDP 1259,    | yes      | yes  | 0-9 via | Verified against AViPAS |
// |                            |  (raw serial)   | TCP 5678     |          |      | CAM_Memory | protocol docs; hardware unconfirmed |
// | SMTAV / generic OEM PTZ    | VISCA over IP   | UDP/TCP      | yes      | yes  | varies   | Assumed Sony-compatible |
// |                            |  (raw serial)   | 52381        |          |      |          | framing; hardware unconfirmed |
// | UVC webcams w/ PTZ (e.g.   | UVC terminal-   | n/a (USB)    | adapter  | adapter | none   | Adapter present but reports |
// |   OBSBOT, Aver)            | unit controls   |              | stub     | stub  | (no CAM_Memory) | unavailable: sandboxed app has no |
// |                            | via IOKit       |              |          |      |          | USB entitlement; see PTZTransport.swift |
//
// Speed ranges pinned here (clamped by the codec): pan 1…24 (0x18), tilt
// 1…20 (0x14) — the intersection every camera above documents; zoom speed
// 0…7 (encoded in the low nibble). Preset numbers 0…89 (0x00-0x59): cameras
// with fewer slots reject the command, which surfaces as a VISCA error
// reply, never a crash.

/// How the controller reaches a network PTZ camera.
public enum PTZProtocolKind: String, Codable, CaseIterable, Sendable {
    /// Raw serial-format VISCA frames, one command per UDP datagram
    /// (default port 52381 — Sony/BirdDog; PTZOptics/AViPAS listen on 1259).
    case viscaOverUDP
    /// Raw serial-format VISCA frames over a persistent TCP stream
    /// (default port 52381 — Sony/BirdDog; PTZOptics/AViPAS listen on 5678).
    case viscaOverTCP

    public var displayName: String {
        switch self {
        case .viscaOverUDP: return "VISCA over UDP"
        case .viscaOverTCP: return "VISCA over TCP"
        }
    }

    /// The Sony/BirdDog default; PTZOptics/AViPAS targets override the port
    /// when configured (1259 UDP / 5678 TCP).
    public var defaultPort: UInt16 { 52381 }
}

/// A configured network PTZ camera. `deviceUniqueID` optionally associates
/// the target with a local capture device (AVCaptureDevice.uniqueID) so the
/// UI can show which on-screen source a camera feeds; the association is
/// informational only — capture ownership stays with the capture pool.
public struct PTZTarget: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var name: String
    /// Hostname or IPv4/IPv6 address of the camera's VISCA-over-IP listener.
    public var host: String
    public var port: UInt16
    public var kind: PTZProtocolKind
    /// VISCA address nibble (1…7) — the `8x` header byte's low bits.
    public var cameraAddress: UInt8
    /// Optional association with a local capture device's uniqueID.
    public var deviceUniqueID: String?

    public init(id: UUID = UUID(),
                name: String,
                host: String,
                port: UInt16 = PTZProtocolKind.viscaOverUDP.defaultPort,
                kind: PTZProtocolKind = .viscaOverUDP,
                cameraAddress: UInt8 = 1,
                deviceUniqueID: String? = nil) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.kind = kind
        self.cameraAddress = cameraAddress
        self.deviceUniqueID = deviceUniqueID
    }

    /// Additive-wire decode: documents written before a later field was added
    /// keep loading with that field's default.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "PTZ Camera"
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? ""
        kind = try container.decodeIfPresent(PTZProtocolKind.self, forKey: .kind) ?? .viscaOverUDP
        port = try container.decodeIfPresent(UInt16.self, forKey: .port) ?? kind.defaultPort
        cameraAddress = try container.decodeIfPresent(UInt8.self, forKey: .cameraAddress) ?? 1
        deviceUniqueID = try container.decodeIfPresent(String.self, forKey: .deviceUniqueID)
    }
}

/// One recallable camera position. `number` is the VISCA CAM_Memory slot;
/// VISCA supports 0…89, most cameras expose a smaller range (Sony 0-5) — an
/// out-of-range slot surfaces as a VISCA error reply from the camera.
public struct PTZPreset: Identifiable, Hashable, Codable, Sendable {
    /// The VISCA memory slot (0…`VISCAPacket.maxPresetNumber`); identity
    /// within a target's preset list.
    public var number: UInt8
    public var name: String

    public var id: UInt8 { number }

    public init(number: UInt8, name: String) {
        self.number = number
        self.name = name
    }
}

/// An explicit, opt-in link between a scene and a camera preset: when the
/// scene becomes PROGRAM (the dispatcher's Take seam — previewing never
/// fires this), the target recalls the preset. `recallOnProgramEntry` is the
/// opt-in: a link with it false is inert configuration, kept so the user can
/// stage a mapping without arming it. `sceneID` is the scene's stable UUID
/// (StreamMac's `GraphID<SceneTag>.rawValue`, which encodes as a bare UUID).
public struct PTZSceneRecallLink: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var sceneID: UUID
    public var targetID: UUID
    public var presetNumber: UInt8
    /// Explicit opt-in: fire the recall when the scene enters program.
    public var recallOnProgramEntry: Bool

    public init(id: UUID = UUID(),
                sceneID: UUID,
                targetID: UUID,
                presetNumber: UInt8,
                recallOnProgramEntry: Bool = false) {
        self.id = id
        self.sceneID = sceneID
        self.targetID = targetID
        self.presetNumber = presetNumber
        self.recallOnProgramEntry = recallOnProgramEntry
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        sceneID = try container.decode(UUID.self, forKey: .sceneID)
        targetID = try container.decode(UUID.self, forKey: .targetID)
        presetNumber = try container.decodeIfPresent(UInt8.self, forKey: .presetNumber) ?? 0
        recallOnProgramEntry = try container.decodeIfPresent(Bool.self, forKey: .recallOnProgramEntry) ?? false
    }
}

/// The persisted PTZ document: configured targets, per-target presets, and
/// scene recall links. Additive-wire Codable like the other Stream documents.
public struct PTZDocument: Codable, Sendable, Equatable {
    public var version: Int
    public var targets: [PTZTarget]
    /// Presets keyed by target ID (VISCA slots are per-camera state).
    public var presets: [UUID: [PTZPreset]]
    public var recallLinks: [PTZSceneRecallLink]

    public init(version: Int = 1,
                targets: [PTZTarget] = [],
                presets: [UUID: [PTZPreset]] = [:],
                recallLinks: [PTZSceneRecallLink] = []) {
        self.version = version
        self.targets = targets
        self.presets = presets
        self.recallLinks = recallLinks
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        targets = try container.decodeIfPresent([PTZTarget].self, forKey: .targets) ?? []
        presets = try container.decodeIfPresent([UUID: [PTZPreset]].self, forKey: .presets) ?? [:]
        recallLinks = try container.decodeIfPresent([PTZSceneRecallLink].self, forKey: .recallLinks) ?? []
    }
}

/// File IO for the PTZ document, mirroring the established document pattern
/// (atomic writes, corrupt-file quarantine, never overwrite unreadable
/// data). The URL is injectable so tests round-trip through a temp file.
public struct PTZDocumentStore: Sendable {
    public static let fileName = "stream.ptz.v1.json"

    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// The production location: the shared App Group container, beside the
    /// scene and soundboard documents. Nil when the container is unavailable.
    public static func `default`() -> PTZDocumentStore? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier)
            .map { PTZDocumentStore(fileURL: $0.appendingPathComponent(fileName)) }
    }

    /// Loads the document; nil when the file is absent or unreadable. A
    /// present-but-undecodable file is quarantined aside (never overwritten).
    public func load() -> PTZDocument? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        guard let document = try? JSONDecoder().decode(PTZDocument.self, from: data) else {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            try? FileManager.default.moveItem(
                at: fileURL,
                to: fileURL.appendingPathExtension("corrupt.\(formatter.string(from: Date())).bak"))
            return nil
        }
        return document
    }

    public func save(_ document: PTZDocument) {
        guard let data = try? JSONEncoder().encode(document) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

// MARK: - VISCA codec

/// Pan/tilt drive direction (the diagonal cases combine both axes).
public enum PTZMoveDirection: String, Codable, CaseIterable, Sendable {
    case up, down, left, right, upLeft, upRight, downLeft, downRight

    /// VISCA pan-direction byte (0x01 left, 0x02 right, 0x03 stationary).
    var panByte: UInt8 {
        switch self {
        case .left, .upLeft, .downLeft: return 0x01
        case .right, .upRight, .downRight: return 0x02
        case .up, .down: return 0x03
        }
    }

    /// VISCA tilt-direction byte (0x01 up, 0x02 down, 0x03 stationary).
    var tiltByte: UInt8 {
        switch self {
        case .up, .upLeft, .upRight: return 0x01
        case .down, .downLeft, .downRight: return 0x02
        case .left, .right: return 0x03
        }
    }

    public var displayName: String {
        switch self {
        case .up: return "Up"
        case .down: return "Down"
        case .left: return "Left"
        case .right: return "Right"
        case .upLeft: return "Up-Left"
        case .upRight: return "Up-Right"
        case .downLeft: return "Down-Left"
        case .downRight: return "Down-Right"
        }
    }
}

public enum PTZZoomDirection: String, Codable, Sendable {
    case tele, wide

    public var displayName: String {
        switch self {
        case .tele: return "Zoom In"
        case .wide: return "Zoom Out"
        }
    }
}

/// VISCA packet encoders. All frames are the raw serial format
/// (`8x ... FF`) documented at the top of this file; speeds and preset
/// numbers are clamped to the pinned compatibility ranges so a malformed UI
/// or automation value can never emit an out-of-spec packet.
public enum VISCAPacket {
    /// Widest-documented ranges across the compatibility matrix.
    public static let maxPanSpeed = 0x18   // 24
    public static let maxTiltSpeed = 0x14  // 20
    public static let maxZoomSpeed = 7
    public static let maxPresetNumber: UInt8 = 89

    /// Pan-tilt drive: `8x 01 06 01 VV WW PP TT FF`.
    public static func panTiltDrive(address: UInt8 = 1,
                                    direction: PTZMoveDirection,
                                    panSpeed: Int,
                                    tiltSpeed: Int) -> Data {
        Data([header(address), 0x01, 0x06, 0x01,
              UInt8(clamped(panSpeed, max: maxPanSpeed)),
              UInt8(clamped(tiltSpeed, max: maxTiltSpeed)),
              direction.panByte, direction.tiltByte, 0xFF])
    }

    /// Pan-tilt stop: drive with both direction bytes 0x03 (speeds ignored
    /// by the camera; the minimum speeds are emitted for spec conformance).
    public static func panTiltStop(address: UInt8 = 1) -> Data {
        Data([header(address), 0x01, 0x06, 0x01, 0x01, 0x01, 0x03, 0x03, 0xFF])
    }

    /// Zoom tele/wide with variable speed: `8x 01 04 07 2p/3p FF`
    /// (p = speed 0…7 in the low nibble).
    public static func zoom(address: UInt8 = 1,
                            direction: PTZZoomDirection,
                            speed: Int) -> Data {
        let nibble = UInt8(clamped(speed, min: 0, max: maxZoomSpeed))
        let opcode: UInt8 = direction == .tele ? 0x20 | nibble : 0x30 | nibble
        return Data([header(address), 0x01, 0x04, 0x07, opcode, 0xFF])
    }

    public static func zoomStop(address: UInt8 = 1) -> Data {
        Data([header(address), 0x01, 0x04, 0x07, 0x00, 0xFF])
    }

    /// CAM_Memory set (store current position into a slot):
    /// `8x 01 04 3F 01 0p FF`.
    public static func memorySet(address: UInt8 = 1, preset: UInt8) -> Data {
        Data([header(address), 0x01, 0x04, 0x3F, 0x01,
              min(preset, maxPresetNumber), 0xFF])
    }

    /// CAM_Memory recall: `8x 01 04 3F 02 0p FF`.
    public static func memoryRecall(address: UInt8 = 1, preset: UInt8) -> Data {
        Data([header(address), 0x01, 0x04, 0x3F, 0x02,
              min(preset, maxPresetNumber), 0xFF])
    }

    /// The `8x` header byte: 0x80 OR the camera address, clamped to 1…7.
    static func header(_ address: UInt8) -> UInt8 {
        0x80 | min(max(address, 1), 7)
    }

    private static func clamped(_ speed: Int, min: Int = 1, max: Int) -> Int {
        Swift.max(min, Swift.min(speed, max))
    }
}

/// A parsed VISCA reply. Replies are diagnostics on the control path (the
/// controller never blocks a command on one), surfaced for connection
/// health reporting.
public enum VISCAResponse: Equatable, Sendable {
    /// `90 4y FF` — the command was accepted into socket y (1…2).
    case ack(socket: Int)
    /// `90 5y FF` — the command finished on socket y.
    case completion(socket: Int)
    /// `90 6y cc FF` — the camera rejected the command.
    case error(socket: Int, code: UInt8)

    /// Parses one raw reply frame; nil for malformed/short data.
    public static func parse(_ data: Data) -> VISCAResponse? {
        let bytes = [UInt8](data)
        guard bytes.count >= 3, bytes[0] == 0x90, bytes.last == 0xFF else { return nil }
        let socket = Int(bytes[1] & 0x0F)
        switch bytes[1] & 0xF0 {
        case 0x40:
            return bytes.count == 3 ? .ack(socket: socket) : nil
        case 0x50:
            return .completion(socket: socket)
        case 0x60:
            guard bytes.count == 4 else { return nil }
            return .error(socket: socket, code: bytes[2])
        default:
            return nil
        }
    }

    /// Plain-language description of a parsed error code (VISCA standard).
    public var errorDescription: String? {
        guard case .error(_, let code) = self else { return nil }
        switch code {
        case 0x01: return "Reply length error"
        case 0x02: return "Syntax error"
        case 0x03: return "Command buffer full"
        case 0x04: return "Command cancelled"
        case 0x05: return "No socket"
        case 0x41: return "Command not executable"
        default: return "Unknown VISCA error \(code)"
        }
    }
}
