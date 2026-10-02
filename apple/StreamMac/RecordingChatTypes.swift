import CoreMedia
import CryptoKit
import Foundation

struct RecordingChatPreferences: Codable, Equatable, Sendable {
    var enabled = false
    var includeAuthors = true
    /// Zero keeps archives until the operator removes them.
    var retentionDays = 0
}

/// A deliberately smaller public-message schema. Neither provider envelopes,
/// connection credentials, avatar URLs nor backstage messages enter this type.
struct RecordingChatMessage: Codable, Equatable, Sendable {
    let id: String
    let platform: String
    var author: String?
    let text: String
    let providerTimestamp: Date
    let timestampIsReceiptTime: Bool
    let kind: String
    var isValid: Bool {
        !id.isEmpty && id.utf8.count <= 128 && platform.utf8.count <= 128
            && (author?.utf8.count ?? 0) <= 512 && text.utf8.count <= 16_384
            && ["Text", "Super Chat", "Super Sticker", "Milestone", "Membership", "Gift"].contains(kind)
            && providerTimestamp.timeIntervalSince1970.isFinite
    }
}

struct RecordingChatPaint: Codable, Hashable, Sendable {
    let slotID: String
    let messageID: String
    let fingerprint: String
    static func fingerprint(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    var isValid: Bool { slotID.utf8.count <= 64 && !slotID.isEmpty && messageID.utf8.count <= 128 && !messageID.isEmpty && fingerprint.count == 64 }
    private static var key: CFString { "com.joeblau.Stream.recording.publicChatPaint.v1" as CFString }
    static func attach(_ value: [Self], to sample: CMSampleBuffer) {
        guard let data = try? JSONEncoder().encode(Array(value.filter(\.isValid).prefix(32))), !value.isEmpty else { return }
        CMSetAttachment(sample, key: key, value: data as CFData, attachmentMode: kCMAttachmentMode_ShouldNotPropagate)
    }
    static func read(_ sample: CMSampleBuffer) -> [Self] {
        guard let data = CMGetAttachment(sample, key: key, attachmentModeOut: nil) as? Data,
              data.count <= 16_384, let values = try? JSONDecoder().decode([Self].self, from: data), values.count <= 32 else { return [] }
        return values.filter(\.isValid)
    }
}

struct RecordingChatBinding: Sendable {
    let paint: RecordingChatPaint
    let message: RecordingChatMessage
}

struct RecordingChatFrame: Sendable {
    let seconds: Double
    let endSeconds: Double
    let painted: [RecordingChatPaint]
}

/// Avoid alpha-mask work when no opted-in recorder needs it. Segments overlap
/// during finalization, so demand is counted rather than a process-wide toggle.
final class RecordingChatPaintDemand: @unchecked Sendable {
    static let shared = RecordingChatPaintDemand()
    private let lock = NSLock()
    private var count = 0
    var isRequested: Bool { lock.lock(); defer { lock.unlock() }; return count > 0 }
    func acquire() { lock.lock(); count += 1; lock.unlock() }
    func release() { lock.lock(); count = max(0, count - 1); lock.unlock() }
}

enum RecordingChatFormat: String, CaseIterable, Sendable {
    case json, csv, vtt, srt
    var title: String { rawValue.uppercased() }
}

struct RecordingChatHeader: Codable, Sendable {
    var type = "header"
    var version = 1
    let sessionID: String
    let segmentIndex: Int
    let programFile: String
    let context: RecordingContext
    let createdAt: Date
    let includesAuthors: Bool
    var sourceStartSeconds: Double?
}

struct RecordingChatRecord: Codable, Sendable {
    var type: String
    var seconds: Double
    var message: RecordingChatMessage?
    var slotID: String?
    var messageID: String?
    var whilePaused: Bool?
    var title: String?
    var isValid: Bool {
        seconds.isFinite && seconds >= 0 && seconds < 31_536_000
            && ["message", "show", "hide", "marker"].contains(type)
            && (message == nil || message!.isValid)
            && (slotID?.utf8.count ?? 0) <= 64 && (messageID?.utf8.count ?? 0) <= 128
            && (title?.utf8.count ?? 0) <= 4_096
            && (type != "message" || message != nil)
            && (type != "show" || (message != nil && slotID?.isEmpty == false && messageID == message?.id))
            && (type != "hide" || (messageID?.isEmpty == false && slotID?.isEmpty == false))
    }
}

struct RecordingChatSummary: Codable, Sendable {
    var version = 1
    var header: RecordingChatHeader
    var status = "recording"
    var records = 0
    var droppedEvents = 0
    var durationSeconds = 0.0
    var bytes: Int64 = 0
    var warning: String?
    var completedAt: Date?
}

/// Bounded typed memory survives a reconnect and a file split, so a comment
/// already on Program can be identified in the next segment. It stores no
/// messages on disk until an explicitly enabled archive is installed.
final class RecordingChatFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var bindings: [RecordingChatPaint: RecordingChatMessage] = [:]
    private var bindingOrder: [RecordingChatPaint] = []
    private var archive: RecordingChatArchive?
    func bind(_ binding: RecordingChatBinding) {
        guard binding.paint.isValid, binding.message.isValid, binding.paint.messageID == binding.message.id else { return }
        lock.lock(); defer { lock.unlock() }
        if bindings[binding.paint] == nil { bindingOrder.append(binding.paint) }
        bindings[binding.paint] = binding.message
        while bindingOrder.count > 128 { bindings.removeValue(forKey: bindingOrder.removeFirst()) }
    }
    func install(_ archive: RecordingChatArchive?) { lock.lock(); self.archive = archive; lock.unlock() }
    func receive(_ message: RecordingChatMessage, at sourceTime: CMTime = CMClockGetTime(CMClockGetHostTimeClock())) {
        guard message.isValid, sourceTime.isNumeric else { return }
        lock.lock(); let target = archive; lock.unlock()
        target?.receive(message, at: sourceTime)
    }
    func frame(_ frame: RecordingChatFrame, into target: RecordingChatArchive) {
        lock.lock()
        let bound = frame.painted.prefix(32).compactMap { paint in bindings[paint].map { RecordingChatBinding(paint: paint, message: $0) } }
        lock.unlock()
        target.frame(frame, bindings: bound)
    }
}
