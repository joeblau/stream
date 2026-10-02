import Combine
import Foundation
import StreamCore

/// A reviewed target captures the actual authorized reader generation. A
/// confirmation cannot silently retarget a replacement account or broadcast.
struct DirectChatWriteTarget: Hashable, Sendable {
    let provider: ManagedProvider
    let channelID: String
    let chatID: String
    let broadcastID: String
    let generation: UUID
    var label: String { "\(provider.name) · \(broadcastID)" }
}

enum DirectChatWriteKind: String, Sendable {
    case post, reply, delete, timeout, ban
    var label: String {
        switch self {
        case .post: "Post"
        case .reply: "Reply"
        case .delete: "Delete message"
        case .timeout: "Timeout 10 minutes"
        case .ban: "Ban author"
        }
    }
}

enum DirectChatWriteState: Equatable, Sendable {
    case sending, acknowledged, notSent(String), rejected(String), unconfirmed(String), stopped
    var isPending: Bool { self == .sending }
    var label: String {
        switch self {
        case .sending: "Waiting for provider"
        case .acknowledged: "Provider acknowledged"
        case .notSent(let reason): "Not sent · \(reason)"
        case .rejected(let reason): "Provider refused · \(reason)"
        case .unconfirmed(let reason): "Unconfirmed · \(reason)"
        case .stopped: "Stopped locally · provider outcome unknown"
        }
    }
}

/// Receipts and submitted text stay in memory; they never become project,
/// recovery, telemetry or diagnostic data. Acknowledgement is not a local echo.
struct DirectChatWriteReceipt: Identifiable, Sendable {
    let id: UUID
    let batchID: UUID
    let provider: ManagedProvider
    let target: String
    let kind: DirectChatWriteKind
    let summary: String
    let createdAt: Date
    var state: DirectChatWriteState
}

struct DirectChatPreset: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var name: String
    var text: String
}
struct DirectChatPresetDocument: Codable, Equatable, Sendable {
    var version = 1
    var presets: [DirectChatPreset] = []
    var valid: Bool {
        version == 1 && presets.count <= 32 && Set(presets.map(\.id)).count == presets.count &&
        presets.allSatisfy { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            $0.name.count <= 64 && $0.name.utf8.count <= 512 &&
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            $0.text.count <= 500 && $0.text.utf8.count <= 4096 }
    }
}

/// Only producer-authored preset text persists. Provider targets, credentials,
/// incoming messages, receipts and automatic-send instructions do not.
@MainActor final class StudioChatPresetStore: ObservableObject {
    @Published private(set) var document = DirectChatPresetDocument()
    @Published private(set) var error: String?
    private(set) var writable = true
    private let url: URL?
    init(directory: URL? = nil) {
        url = directory?.appendingPathComponent("chat-presets.json")
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 262145) ?? Data()
            guard data.count <= 262144 else { throw PresetFailure() }
            let decoded = try JSONDecoder().decode(DirectChatPresetDocument.self, from: data)
            guard decoded.valid else { throw PresetFailure() }
            document = decoded
        } catch { writable = false; self.error = "Chat presets are unreadable or from an unsupported version. The original file was preserved." }
    }
    @discardableResult func save(name: String, text: String, replacing id: UUID? = nil) -> Bool {
        var next = document
        let preset = DirectChatPreset(id: id ?? UUID(), name: name, text: text)
        if let id {
            guard let index = next.presets.firstIndex(where: { $0.id == id }) else { error = "This preset no longer exists."; return false }
            next.presets[index] = preset
        } else { next.presets.append(preset) }
        return write(next)
    }
    func remove(_ id: UUID) { var next = document; next.presets.removeAll { $0.id == id }; _ = write(next) }
    private func write(_ next: DirectChatPresetDocument) -> Bool {
        guard writable else { return false }
        guard next.valid else { error = "Use at most 32 presets, names up to 64 characters and text up to 500 characters (4096 UTF-8 bytes)."; return false }
        do {
            if let url {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(next).write(to: url, options: .atomic)
            }
            document = next; error = nil; return true
        } catch { self.error = "Chat presets could not be saved."; return false }
    }
    private struct PresetFailure: Error {}
}
