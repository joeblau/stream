import Combine
import Foundation
import StreamCore

/// Explicit read-only recovery review. This type has no publisher, command,
/// recording or provider mutation boundary, so neither load nor verify can
/// start/end an output or replay an interrupted command.
@MainActor
final class RecoveryEventReviewCoordinator: ObservableObject {
    struct Context: Equatable {
        let projectID: UUID
        let profileID: UUID
        let generation: UUID
    }
    typealias Authorization = @MainActor (ManagedProvider) async -> UUID?
    typealias Verify = @Sendable (RecoveryEventIdentity) async throws -> RecoveryEventVerification
    @Published private(set) var events: [SessionRecoveryRemoteEvent] = []
    @Published private(set) var reviews: [UUID: RecoveryEventReview] = [:]
    @Published private(set) var verifying: Set<UUID> = []
    private var snapshot: SessionRecoverySnapshot?
    private var context: Context?
    private var fence = UUID()
    private var closed = false
    private var authorize: Authorization?
    private var read: Verify?
    private var jobs: [UUID: Task<Void, Never>] = [:]
    private var deadlines: [UUID: Task<Void, Never>] = [:]
    private var jobOutputIDs: [UUID: UUID] = [:]
    private var expiredJobs: Set<UUID> = []
    private let now: @Sendable () -> Date
    private let timeout: Duration
    init(now: @escaping @Sendable () -> Date = { Date() }, timeout: Duration = .seconds(30)) {
        self.now = now; self.timeout = timeout
    }
    func bind(authorization: @escaping Authorization, verify: @escaping Verify) {
        invalidate(); authorize = authorization; read = verify
    }
    func load(_ snapshot: SessionRecoverySnapshot?, context: Context?) {
        invalidate(); self.context = context
        self.snapshot = snapshot?.validationError == nil ? snapshot : nil
        events = self.snapshot?.remoteEvents ?? []
        resetReviews()
    }
    /// Account or workspace changes invalidate all receipts, including ended
    /// receipts. There is no automatic reread after this fence changes.
    func invalidate() {
        fence = UUID()
        for task in jobs.values { task.cancel() }
        for task in deadlines.values { task.cancel() }
        deadlines.removeAll(); verifying.removeAll()
        // Keep occupied slots until an uncooperative injected/HTTP request
        // actually returns. Repeated context switches cannot spawn unbounded
        // canceled requests. Late replies are ignored by the captured fence.
        resetReviews()
    }
    func shutdown() { closed = true; invalidate(); authorize = nil; read = nil }
    private var contextMatches: Bool {
        guard let context, let snapshot else { return false }
        return context.projectID == snapshot.projectID && context.profileID == snapshot.profileID
    }
    private func initialReview(_ event: SessionRecoveryRemoteEvent) -> RecoveryEventReview {
        guard contextMatches else { return .init(reason: .contextMismatch) }
        guard let identity = event.reviewIdentity else { return .init(reason: .missingIdentity) }
        guard identity.provider == .youtube else { return .init(reason: .unsupportedProvider) }
        return .init() // Saved/cached states are never proof after restart.
    }
    private func resetReviews() { reviews = Dictionary(uniqueKeysWithValues: events.map { ($0.outputID, initialReview($0)) }) }
    func review(_ outputID: UUID) -> RecoveryEventReview {
        (reviews[outputID] ?? .init()).current(at: now())
    }
    func canVerify(_ outputID: UUID) -> Bool {
        !closed && contextMatches && authorize != nil && read != nil && jobs.count < 2
            && !verifying.contains(outputID)
            && events.first(where: { $0.outputID == outputID })?.reviewIdentity?.provider == .youtube
    }
    func verify(_ outputID: UUID) {
        guard canVerify(outputID), let identity = events.first(where: { $0.outputID == outputID })?.reviewIdentity,
              let authorize, let read else { return }
        let token = UUID(), capturedFence = fence, requested = now()
        verifying.insert(outputID); reviews[outputID] = .init()
        jobOutputIDs[token] = outputID
        jobs[token] = Task { [weak self] in
            guard let self else { return }
            let epoch = await authorize(identity.provider)
            guard !Task.isCancelled, self.fence == capturedFence, let epoch else {
                self.finish(token, fence: capturedFence, review: .init(reason: .authorizationNeeded)); return
            }
            let result: RecoveryEventReview
            do {
                let receipt = try await read(identity)
                let currentEpoch = await authorize(identity.provider)
                result = currentEpoch == epoch
                    ? .classify(receipt, identity: identity, requestedAt: requested, now: self.now())
                    : .init(reason: .accountChanged)
            } catch {
                let currentEpoch = await authorize(identity.provider)
                result = currentEpoch == epoch ? .failure(error) : .init(reason: .accountChanged)
            }
            self.finish(token, fence: capturedFence, review: result)
        }
        let deadline = timeout
        deadlines[token] = Task { [weak self] in
            do { try await Task.sleep(for: deadline) } catch { return }
            guard let self, self.fence == capturedFence, self.jobs[token] != nil else { return }
            self.expiredJobs.insert(token); self.jobs[token]?.cancel()
            self.verifying.remove(outputID); self.reviews[outputID] = .init(reason: .timedOut)
        }
    }
    private func finish(_ token: UUID, fence capturedFence: UUID, review: RecoveryEventReview) {
        jobs[token] = nil; deadlines.removeValue(forKey: token)?.cancel()
        let outputID = jobOutputIDs.removeValue(forKey: token)
        let expired = expiredJobs.remove(token) != nil
        guard !closed, fence == capturedFence, !expired, let outputID else { return }
        verifying.remove(outputID); reviews[outputID] = review
    }
}
