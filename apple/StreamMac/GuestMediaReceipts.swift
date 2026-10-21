import AVFoundation
import CoreMedia
import Foundation

/// Immutable, application-owned decoded media receipts. They do not register
/// a source or authorize routing. Playout selects frames due at original host PTS.
struct GuestReceiveLease: Sendable, Hashable {
    let slot: UUID
    let peerID: UUID
    let negotiation: UUID
    let generation: UInt64
}
enum GuestReceiveRole: Int32, Sendable { case camera = 0, screen = 1, audio = 2 }
enum GuestClockQuality: Sendable { case senderReportAligned }
struct GuestVideoFrame: @unchecked Sendable {
    let lease: GuestReceiveLease, role: GuestReceiveRole, pixels: CVPixelBuffer, pts: CMTime, duration: CMTime
    let mappingGeneration: UUID
    let clockQuality: GuestClockQuality
}
struct GuestAudioFrame: @unchecked Sendable {
    let lease: GuestReceiveLease, pcm: AVAudioPCMBuffer, pts: CMTime, duration: CMTime
    let mappingGeneration: UUID
    let clockQuality: GuestClockQuality
}

/// A recipient-specific public Program sum, excluding that full lease's own
/// channel before any bus clamp. Revision fences queued PCM across revocation.
struct GuestReturnAudioFrame: @unchecked Sendable {
    let lease: GuestReceiveLease
    let routingRevision: UInt64
    let sample: CMSampleBuffer
    var pts: CMTime { sample.presentationTimeStamp }
}

/// Ephemeral plain text carried only by the current authenticated media
/// channel. This type deliberately has no Codable or useful debug description.
enum GuestPrivateControlEnvelope: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    var description: String { "<private interview control>" }
    var debugDescription: String { description }
    case message(id: UUID, text: String)
    case acknowledgment(id: UUID)
    case availability(Bool)
    var isMessage: Bool { if case .message = self { return true }; return false }
    var byteCount: Int { if case .message(_, let text) = self { return text.utf8.count + 160 }; return 160 }
    static func validText(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.utf8.count <= 512
            && !text.unicodeScalars.contains { ($0.value < 32 && ![9, 10].contains($0.value)) || $0.value == 127 }
    }
    func wire(negotiation: UUID) -> String? {
        var value: [String: Any] = ["negotiation": negotiation.uuidString.lowercased()]
        switch self {
        case .message(let id, let text):
            guard Self.validText(text) else { return nil }
            value["type"] = "private-message"; value["id"] = id.uuidString.lowercased(); value["text"] = text
        case .acknowledgment(let id): value["type"] = "private-message-ack"; value["id"] = id.uuidString.lowercased()
        case .availability(let enabled): value["type"] = "private-message-capability"; value["enabled"] = enabled
        }
        guard let data = try? JSONSerialization.data(withJSONObject: value), data.count <= 1024 else { return nil }
        return String(data: data, encoding: .utf8)
    }
    private static func id(_ value: Any?) -> UUID? {
        guard let text = value as? String, text.count == 36, text == text.lowercased(),
              let value = UUID(uuidString: text), value.uuidString.lowercased() == text else { return nil }
        return value
    }
    static func parse(_ text: String, negotiation: UUID) -> Self? {
        guard let data = text.data(using: .utf8), data.count <= 1024, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              id(object["negotiation"]) == negotiation else { return nil }
        if object["type"] as? String == "private-message-capability", object.count == 3,
           let enabled = object["enabled"] as? NSNumber, CFGetTypeID(enabled) == CFBooleanGetTypeID() {
            return .availability(enabled.boolValue)
        }
        guard let id = id(object["id"]) else { return nil }
        if object["type"] as? String == "private-message", object.count == 4,
           let body = object["text"] as? String, validText(body) { return .message(id: id, text: body) }
        if object["type"] as? String == "private-message-ack", object.count == 3 { return .acknowledgment(id: id) }
        return nil
    }
}
