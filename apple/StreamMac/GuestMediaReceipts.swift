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

/// Separate one-way public chat frames. No provider route, token, avatar or
/// private transcript enters this protocol. It shares the existing 1 KiB cap.
struct GuestPublicChatSource: Sendable {
    let id: String, platform: String, state: String
}
struct GuestPublicChatEntry: Sendable {
    let id: String, source: String, platform: String, author: String, roles: [String]
    let text: String, timestamp: Double, receiptTime: Bool, kind: String, truncated: Bool
}
enum GuestPublicChatEnvelope: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    case state(feed: UUID, enabled: Bool, reset: UInt32, sequence: UInt32, dropped: UInt32,
               adapters: [String: String], sources: [GuestPublicChatSource], sourcesTruncated: Bool)
    case message(feed: UUID, reset: UInt32, sequence: UInt32, dropped: UInt32, entry: GuestPublicChatEntry)
    var description: String { "<guest public chat control>" }
    var debugDescription: String { description }

    static func prefix(_ value: String, bytes: Int) -> String {
        var count = 0, result = ""
        for character in value {
            let size = character.utf8.count
            guard count + size <= bytes else { break }
            result.append(character); count += size
        }
        return result
    }
    func wire(negotiation: UUID) -> String? {
        var value: [String: Any] = ["negotiation": negotiation.uuidString.lowercased()]
        switch self {
        case .state(let feed, let enabled, let reset, let sequence, let dropped, let adapters, let sources, let omitted):
            guard adapters.count <= 3, Set(adapters.keys).isSubset(of: ["restream", "youtube", "twitch"]),
                  adapters.values.allSatisfy({ ["connected", "connecting", "offline", "failed", "unavailable"].contains($0) }),
                  sources.count <= 4, sources.allSatisfy({ $0.id.utf8.count <= 16 && $0.platform.utf8.count <= 32 && $0.state.utf8.count <= 64 }) else { return nil }
            value.merge(["type": "public-chat-state", "feed": feed.uuidString.lowercased(), "enabled": enabled,
                "reset": reset, "seq": sequence, "dropped": dropped, "adapters": adapters,
                "sources": sources.map { ["id": $0.id, "platform": $0.platform, "state": $0.state] }, "sourcesTruncated": omitted]) { _, new in new }
            var retained = sources
            while Self.encoded(value) == nil, !retained.isEmpty {
                retained.removeLast(); value["sources"] = retained.map { ["id": $0.id, "platform": $0.platform, "state": $0.state] }
                value["sourcesTruncated"] = true
            }
        case .message(let feed, let reset, let sequence, let dropped, let entry):
            guard !entry.id.isEmpty, entry.id.utf8.count <= 128, entry.source.utf8.count <= 16,
                  entry.platform.utf8.count <= 32, entry.author.utf8.count <= 64,
                  entry.roles.count <= 6, entry.roles.allSatisfy({ ["Owner", "Moderator", "Member", "Verified", "VIP", "Bot"].contains($0) }),
                  entry.text.utf8.count <= 512, entry.kind.utf8.count <= 24,
                  entry.timestamp.isFinite, entry.timestamp > 0, entry.timestamp < 253_402_300_800 else { return nil }
            value.merge(["type": "public-chat-message", "feed": feed.uuidString.lowercased(), "reset": reset,
                "seq": sequence, "dropped": dropped, "id": entry.id, "source": entry.source, "platform": entry.platform,
                "author": entry.author, "roles": entry.roles, "text": entry.text, "timestamp": entry.timestamp,
                "receiptTime": entry.receiptTime, "kind": entry.kind, "truncated": entry.truncated]) { _, new in new }
            // Escaping can expand public text. At most ten attempts preserve
            // whole composed characters and explicitly disclose any clipping.
            var budget = 512
            while Self.encoded(value) == nil, budget > 0 {
                budget /= 2
                value["text"] = Self.prefix(entry.text, bytes: budget); value["truncated"] = true
            }
        }
        return Self.encoded(value)
    }
    private static func encoded(_ value: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: value), data.count <= 1024 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
