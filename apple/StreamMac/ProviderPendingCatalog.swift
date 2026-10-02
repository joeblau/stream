import Combine
import Foundation
import StreamCore

struct ProviderPendingRecord: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case event, stream }
    var provider: ManagedProvider
    var kind: Kind
    var providerID: String
    var channelID: String
    var title: String
    var privacy: String?
    var scheduledAt: Date?
    var id: String { "\(provider.rawValue):\(kind.rawValue):\(providerID)" }
    var valid: Bool {
        provider == .youtube && ProviderChannel.validID(providerID) && ProviderChannel.validID(channelID) &&
        title.utf8.count <= 1024 && title.count <= 500 &&
        (privacy == nil || ["private", "public", "unlisted"].contains(privacy!)) &&
        (scheduledAt == nil || scheduledAt!.timeIntervalSince1970.isFinite)
    }
    init(_ event: ProviderEvent) {
        provider = event.provider; kind = .event; providerID = event.id; channelID = event.channelID ?? ""
        title = String(decoding: event.title.utf8.prefix(1000), as: UTF8.self)
        privacy = event.privacy.flatMap { ["private", "public", "unlisted"].contains($0) ? $0 : nil }
        scheduledAt = event.scheduledAt
    }
    init(_ stream: YouTubeLiveStream) {
        provider = .youtube; kind = .stream; providerID = stream.id; channelID = stream.channelID ?? ""
        title = String(decoding: stream.title.utf8.prefix(1000), as: UTF8.self)
    }
    var cachedEvent: ProviderEvent {
        .init(id: providerID, provider: provider, channelID: channelID, title: title, privacy: privacy,
              scheduledAt: scheduledAt, state: .unknown, verifiedAt: .distantPast)
    }
    var cachedStream: YouTubeLiveStream {
        .init(id: providerID, channelID: channelID, title: title, state: .unknown, verifiedAt: .distantPast)
    }
}
struct ProviderPendingDocument: Codable, Equatable {
    var version = 1
    var records: [ProviderPendingRecord] = []
    var valid: Bool { version == 1 && records.count <= 128 && Set(records.map(\.id)).count == records.count && records.allSatisfy(\.valid) }
}

/// A project-scoped repair catalog, never an instruction queue or credential
/// cache. No remote lifecycle, ingest endpoint, stream key or token is saved.
@MainActor final class ProviderPendingCatalog: ObservableObject {
    @Published private(set) var document = ProviderPendingDocument()
    @Published private(set) var error: String?
    private(set) var writable = true
    private let url: URL?
    init(directory: URL? = nil) {
        url = directory?.appendingPathComponent("provider-pending.json")
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
            let data = try file.read(upToCount: 524289) ?? Data()
            guard data.count <= 524288 else { throw CatalogError() }
            let decoded = try JSONDecoder().decode(ProviderPendingDocument.self, from: data)
            guard decoded.valid else { throw CatalogError() }
            document = decoded
        } catch {
            writable = false; self.error = "The pending provider catalog is unreadable or from an unsupported version. Its original file was preserved; creating resources is disabled."
        }
    }
    func canRetain(_ records: [ProviderPendingRecord]) -> Bool {
        guard writable, records.allSatisfy(\.valid) else { return false }
        return merged(records).valid
    }
    var canCreate: Bool { writable && document.records.count < 128 }
    /// Retain in memory before attempting the atomic disk write. A disk failure
    /// never erases an acknowledged ID; show it for repair and block new creates.
    @discardableResult func retain(_ records: [ProviderPendingRecord]) -> Bool {
        guard canRetain(records) else { error = "The pending catalog is full or unavailable. Remove reviewed local entries before creating or binding."; return false }
        return write(merged(records))
    }
    func remove(_ id: String) {
        guard writable else { return }
        var next = document; next.records.removeAll { $0.id == id }; _ = write(next)
    }
    private func merged(_ records: [ProviderPendingRecord]) -> ProviderPendingDocument {
        let replacing = Set(records.map(\.id))
        return .init(records: document.records.filter { !replacing.contains($0.id) } + records)
    }
    private func write(_ next: ProviderPendingDocument) -> Bool {
        guard next.valid else { return false }
        document = next
        do {
            if let url {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(next).write(to: url, options: .atomic)
            }
            error = nil; return true
        } catch {
            writable = false; self.error = "Repair IDs could not be saved to disk. Acknowledged creation IDs remain in memory; copy the needed displayed IDs before leaving this project. New creation is disabled."
            return false
        }
    }
    private struct CatalogError: Error {}
}

struct ProviderSchedulingReceipt {
    enum State: Equatable { case acknowledged, observed, blocked, unconfirmed }
    let action: String
    let resourceID: String
    let state: State
    let failure: ProviderFailure?
    let receivedAt = Date()
}
