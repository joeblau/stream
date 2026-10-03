import Combine
import Foundation
import StreamCore

/// Disk operations are serialized on this actor, never on a media callback.
/// Two bounded documents retain prior-run review and the newest live checkpoint.
actor SessionRecoveryDiskStore {
    let directory: URL
    init(directory: URL) { self.directory = directory }
    static func read(_ url: URL) throws -> SessionRecoverySnapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let size = (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
        guard size <= 1_048_576 else { throw Failure.invalid }
        let snapshot = try JSONDecoder().decode(SessionRecoverySnapshot.self, from: Data(contentsOf: url))
        guard snapshot.validationError == nil else { throw Failure.invalid }
        return snapshot
    }
    enum Failure: Error { case invalid }
    func preserve(_ snapshot: SessionRecoverySnapshot) throws {
        let url = directory.appendingPathComponent("pending.v1.json")
        // An unresolved earlier interruption remains reviewable across another crash.
        if FileManager.default.fileExists(atPath: url.path) { _ = try Self.read(url); return }
        try write(snapshot, to: url)
    }
    func checkpoint(_ snapshot: SessionRecoverySnapshot) throws {
        let url = directory.appendingPathComponent("current.v1.json")
        if FileManager.default.fileExists(atPath: url.path) { _ = try Self.read(url) }
        try write(snapshot, to: url)
    }
    func dismissPending(id: UUID) throws {
        let currentURL = directory.appendingPathComponent("current.v1.json")
        if var value = try Self.read(currentURL), value.id == id {
            value.reviewDismissed = true
            try write(value, to: currentURL)
        }
        let url = directory.appendingPathComponent("pending.v1.json")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    private func write(_ snapshot: SessionRecoverySnapshot, to url: URL) throws {
        guard snapshot.validationError == nil else { throw Failure.invalid }
        let data = try JSONEncoder().encode(snapshot)
        guard data.count <= 1_048_576 else { throw Failure.invalid }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

@MainActor final class SessionRecoveryCoordinator: ObservableObject {
    @Published private(set) var pending: SessionRecoverySnapshot?
    @Published private(set) var error: String?
    @Published var showReview = false
    let remoteReview = RecoveryEventReviewCoordinator()
    let sessionID = UUID()
    var restoreLocalContext: (@MainActor (SessionRecoverySnapshot) async -> Void)?
    var contextLabel: ((UUID, UUID) -> String?)?
    var reviewRecordings: (() -> Void)?
    private let store: SessionRecoveryDiskStore
    private var current: SessionRecoverySnapshot?
    private var newest: SessionRecoverySnapshot?
    private var writer: Task<Void, Never>?
    private var preserveNeeded = false
    private var context: (UUID, UUID)?
    init(directory: URL) {
        store = SessionRecoveryDiskStore(directory: directory)
        do {
            let prior = try SessionRecoveryDiskStore.read(directory.appendingPathComponent("pending.v1.json"))
            let latest = try SessionRecoveryDiskStore.read(directory.appendingPathComponent("current.v1.json"))
            pending = prior ?? latest.flatMap { $0.needsReview ? $0 : nil }
            preserveNeeded = prior == nil && pending != nil
            showReview = pending != nil
        } catch { self.error = "Recovery metadata could not be read. Its original bytes are preserved; review project backups and recordings manually." }
        remoteReview.load(pending, context: nil)
    }
    func beginContext(projectID: UUID, profileID: UUID, generation: UUID = UUID()) {
        context = (projectID, profileID)
        remoteReview.load(pending, context: .init(projectID: projectID, profileID: profileID, generation: generation))
    }
    func reportError(_ message: String) { error = String(message.prefix(500)) }
    func checkpoint(_ snapshot: SessionRecoverySnapshot) {
        if let context, (snapshot.projectID != context.0 || snapshot.profileID != context.1) { return }
        guard snapshot.validationError == nil else { error = "Recovery metadata contains an invalid or oversized inventory."; return }
        var value = snapshot; value.id = sessionID; value.updatedAt = Date(); value.cleanExit = false; value.reviewDismissed = false
        current = value; newest = value
        if writer == nil { startWriter() }
    }
    private func startWriter() {
        writer = Task { [weak self] in
            guard let self else { return }
            do {
                if self.preserveNeeded, let prior = self.pending { try await self.store.preserve(prior); self.preserveNeeded = false }
                while let value = self.newest {
                    self.newest = nil
                    try await self.store.checkpoint(value)
                    // Burst edits replace one pending snapshot, not one queued write each.
                    try? await Task.sleep(for: .milliseconds(250))
                }
            } catch { self.error = "Recovery checkpoint could not be saved. Existing recovery documents remain available." }
            self.writer = nil
        }
    }
    func flush() async {
        if newest != nil && writer == nil { startWriter() }
        await writer?.value
    }
    func finishCurrentSession() async {
        await flush()
        guard var value = current else { return }
        // A stop still in flight is conservatively treated as interrupted.
        value.cleanExit = value.activeOutputIDs.isEmpty && !value.recordingWasActive && !value.recordings.contains { [.preparing, .recording, .paused, .finishing].contains($0.status) }
        do { try await store.checkpoint(value); current = value }
        catch { self.error = "Final recovery checkpoint could not be saved. The next launch will offer conservative recovery." }
    }
    func restore() async {
        guard let pending else { return }
        // No output-start, recording-start or command replay API exists here.
        await restoreLocalContext?(pending)
    }
    func dismiss() async {
        await flush()
        do {
            try await store.dismissPending(id: pending?.id ?? UUID()); pending = nil; showReview = false; preserveNeeded = false
            remoteReview.load(nil, context: nil)
        }
        catch { self.error = "The recovery review could not be dismissed." }
    }
}
