import Foundation

/// Value-only contracts cross an authenticated process boundary. No manifest
/// embeds executable paths or hands code to the compositor/audio callbacks.
struct StudioAdapterManifest: Codable, Equatable, Sendable {
    enum Role: String, Codable, Sendable { case source, output, control }
    var schemaVersion = 1
    var id: String
    var name: String
    var vendor: String
    var adapterVersion: String
    var minimumHostProtocol = 1
    var roles: [Role]
    var resources: [StudioAdapterResource]
    var source: StudioAdapterSourceContract?
    var output: StudioAdapterOutputContract?
    var control: StudioAdapterControlContract?

    var validationError: String? {
        guard schemaVersion == 1, minimumHostProtocol == 1 else { return "This host supports adapter manifest and control protocol version 1." }
        guard id.utf8.count <= 200, id.range(of: "^[a-z0-9]+(?:[.-][a-z0-9]+)+$", options: .regularExpression) != nil else { return "Use a stable reverse-domain adapter identifier." }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 200,
              !vendor.isEmpty, vendor.utf8.count <= 200, !adapterVersion.isEmpty, adapterVersion.utf8.count <= 100 else { return "Name, vendor, and adapter version must be bounded, nonempty labels." }
        guard !roles.isEmpty, Set(roles).count == roles.count else { return "Declare each adapter role once." }
        guard roles.contains(.source) == (source != nil), roles.contains(.output) == (output != nil), roles.contains(.control) == (control != nil) else { return "Each declared role needs exactly one matching versioned contract." }
        guard resources.count <= 1000, Set(resources.map(\.id)).count == resources.count,
              resources.allSatisfy({ !$0.name.isEmpty && $0.name.utf8.count <= 200 && StudioAutomationRequest.validProfileID($0.profileID) }) else { return "Resource descriptors need unique UUIDs, explicit profile scope, and bounded names." }
        if let source, source.validationError != nil { return source.validationError }
        if let output, output.validationError != nil { return output.validationError }
        if let control, control.validationError != nil { return control.validationError }
        return nil
    }
    var hostCompatibilityError: String? {
        if let validationError { return validationError }
        guard roles == [.control] else { return "This host currently loads external control adapters only. Source/output surface and encoded-packet transports are defined but unavailable." }
        return nil
    }
}
struct StudioAdapterResource: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case scene, layer, source, output, audioChannel }
    var id: UUID
    var profileID: String
    var kind: Kind
    var name: String
    var parentID: UUID?
}
struct StudioAdapterControlContract: Codable, Equatable, Sendable {
    var version = 1
    var transport = "studio-ipc-jsonl"
    /// Explicit grants. An empty list permits state inspection only.
    var allowedCommandIDs: [String]
    var validationError: String? {
        guard version == 1, transport == "studio-ipc-jsonl", allowedCommandIDs.count <= 1000,
              Set(allowedCommandIDs).count == allowedCommandIDs.count,
              allowedCommandIDs.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 512 && !$0.hasPrefix("unavailable.") }) else { return "Control adapters need protocol version 1 and a bounded, explicit list of stable command IDs." }
        return nil
    }
}
struct StudioAdapterSourceContract: Codable, Equatable, Sendable {
    /// Reserved media boundary. Source IDs address the engine registry; an
    /// IOSurface descriptor carries data/clock metadata, never executable code.
    var version = 1
    var transport = "authenticated-surface-xpc"
    var sourceID: UUID
    var pixelFormat = "bgra8"
    var width: Int
    var height: Int
    var maximumFramesPerSecond: Int
    var maximumQueuedFrames = 3
    var clock = "host-monotonic-nanoseconds"
    var validationError: String? {
        guard version == 1, transport == "authenticated-surface-xpc", pixelFormat == "bgra8", clock == "host-monotonic-nanoseconds",
              (1...8192).contains(width), (1...8192).contains(height), (1...120).contains(maximumFramesPerSecond),
              (1...3).contains(maximumQueuedFrames) else { return "Source contracts require version 1 BGRA surfaces, monotonic timestamps, and bounded dimensions/rate/queues." }
        return nil
    }
}
struct StudioAdapterOutputContract: Codable, Equatable, Sendable {
    /// Reserved packet boundary after engine encoding. Output adapters own
    /// their network/provider session and cannot run in the encoder callback.
    var version = 1
    var transport = "authenticated-packet-xpc"
    var outputID: UUID
    var videoCodec = "h264"
    var audioCodec = "aac"
    var maximumPacketBytes = 4_194_304
    var maximumQueuedPackets = 30
    var clock = "host-monotonic-nanoseconds"
    var validationError: String? {
        guard version == 1, transport == "authenticated-packet-xpc", videoCodec == "h264", audioCodec == "aac", clock == "host-monotonic-nanoseconds",
              (1...4_194_304).contains(maximumPacketBytes), (1...30).contains(maximumQueuedPackets) else { return "Output contracts require version 1 H.264/AAC packets with bounded packet sizes/queues and monotonic timestamps." }
        return nil
    }
}
struct StudioAdapterRegistration: Codable, Equatable, Identifiable, Sendable {
    var id: String { manifest.id }
    var manifest: StudioAdapterManifest
    var clientID: UUID
    var enabled: Bool
}
struct StudioAdapterDocument: Codable, Equatable, Sendable {
    var version = 1
    var adapters: [StudioAdapterRegistration] = []
    var validationError: String? {
        guard version == 1 else { return "This adapter document was created by an unsupported version." }
        guard adapters.count <= 16, Set(adapters.map(\.id)).count == adapters.count,
              Set(adapters.map(\.clientID)).count == adapters.count else { return "Register at most 16 adapters, each with its own stable ID and paired client." }
        return adapters.compactMap { $0.manifest.hostCompatibilityError }.first
    }
    func authorizationError(clientID: UUID, commandID: String?) -> StudioControlProtocolError? {
        guard let adapter = adapters.first(where: { $0.clientID == clientID }) else { return nil }
        guard adapter.manifest.hostCompatibilityError == nil, let control = adapter.manifest.control else {
            return .init(code: "adapterIncompatible", message: "This adapter contract is incompatible with the host.")
        }
        guard adapter.enabled else { return .init(code: "adapterDisabled", message: "Enable this adapter in the studio before connecting.") }
        if let commandID, !control.allowedCommandIDs.contains(commandID) {
            return .init(code: "adapterCapabilityDenied", message: "This stable command is outside the adapter's approved capabilities.")
        }
        return nil
    }
}
