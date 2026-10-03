import Combine
import Foundation
import StreamCore

/// Captures all destination/settings changes, including the chosen canvas.
/// Connection secrets are removed before the snapshot can reach the review UI.
struct ManagedYouTubeStartContext: Equatable, Sendable {
    let destination: StreamDestination
    let settings: StreamSettings
    let authorityRevision: UUID?
    var profile: YouTubeStartProfile { .init(destination: destination, program: settings.outputProfile) }
    init(destination: StreamDestination, settings: StreamSettings, authorityRevision: UUID? = nil) {
        self.destination = destination
        self.authorityRevision = authorityRevision
        var publicSettings = settings; publicSettings.rtmpURL = ""; publicSettings.streamKey = ""
        self.settings = publicSettings
    }
}

struct ManagedYouTubeStartEntry: Identifiable {
    enum Phase { case checking, review, preparing, blocked }
    let id: UUID
    let context: ManagedYouTubeStartContext
    var attempt: UUID
    var phase: Phase
    var review: YouTubeStartReview?
    var accountGeneration: UUID?
    var message: String?
}

struct ManagedYouTubeStartConsent {
    var reviewedPublicEffect = false
    var startBeforeScheduledTime = false
}

/// The host must route every managed start through request(), and revalidate its
/// encoder/canvas/lock/rehearsal budget synchronously in publish(). No publisher
/// is allocated by this coordinator, and it never stores returned credentials.
@MainActor
final class ManagedYouTubeStartCoordinator: ObservableObject {
    typealias Generation = @MainActor @Sendable () async throws -> UUID?
    typealias Read = @MainActor @Sendable (URLRequest, UUID) async throws -> Data
    @Published private(set) var entries: [ManagedYouTubeStartEntry] = []
    private let generation: Generation
    private let read: Read
    private let current: (UUID) -> ManagedYouTubeStartContext?
    private let publish: (ManagedYouTubeStartContext, DestinationCredentials) -> Bool
    private let now: @Sendable () -> Date
    private let operationTimeout: Duration
    private var jobs: [UUID: Task<Void, Never>] = [:]
    private var deadlines: [UUID: Task<Void, Never>] = [:]
    private var closed = false
    init(generation: @escaping Generation, read: @escaping Read,
         current: @escaping (UUID) -> ManagedYouTubeStartContext?,
         publish: @escaping (ManagedYouTubeStartContext, DestinationCredentials) -> Bool,
         now: @escaping @Sendable () -> Date = { Date() }, operationTimeout: Duration = .seconds(30)) {
        self.generation = generation; self.read = read; self.current = current
        self.publish = publish; self.now = now; self.operationTimeout = operationTimeout
    }
    /// Returns false only for a manual destination, whose existing route the
    /// host owns. Unsupported managed providers remain visibly blocked.
    @discardableResult
    func request(_ context: ManagedYouTubeStartContext) -> Bool {
        guard context.destination.providerBinding != nil else { return false }
        guard !closed else { return true }
        let id = context.destination.id
        if let entry = entries.first(where: { $0.id == id }), entry.phase == .checking || entry.phase == .preparing { return true }
        if entries.count >= 10 && !entries.contains(where: { $0.id == id }) { return true }
        cancel(id)
        let token = UUID()
        var entry = ManagedYouTubeStartEntry(id: id, context: context, attempt: token, phase: .checking)
        guard context.destination.providerBinding?.provider == .youtube else {
            entry.phase = .blocked
            entry.message = "Managed start review is available for YouTube only. Review this provider in its external controls and deliberately use a manual destination."
            entries.append(entry); return true
        }
        entries.append(entry)
        jobs[id] = Task { [weak self] in
            guard let self else { return }
            do {
                guard let account = try await generation(), valid(id, token), let binding = context.destination.providerBinding else { throw CancellationError() }
                let reader = reader(account: account)
                let review = try await reader.review(binding: binding, profile: context.profile)
                guard valid(id, token), try await generation() == account, valid(id, token) else { throw CancellationError() }
                guard let index = entries.firstIndex(where: { $0.id == id && $0.attempt == token }) else { return }
                entries[index].phase = .review; entries[index].review = review; entries[index].accountGeneration = account
                finishJob(id)
            } catch { fail(id, token: token, error: error) }
        }
        startDeadline(id, token: token)
        return true
    }
    func confirm(_ id: UUID, consent: ManagedYouTubeStartConsent) {
        guard !closed, let index = entries.firstIndex(where: { $0.id == id }),
              entries[index].phase == .review, let review = entries[index].review,
              let account = entries[index].accountGeneration else { return }
        let context = entries[index].context
        guard consent.reviewedPublicEffect,
              !review.requiresEarlyStart(at: now()) || consent.startBeforeScheduledTime else { return }
        let token = UUID(); entries[index].attempt = token
        entries[index].phase = .preparing; entries[index].message = nil
        jobs[id] = Task { [weak self] in
            guard let self else { return }
            do {
                guard valid(id, token), try await generation() == account, valid(id, token) else { throw CancellationError() }
                let credentials = try await reader(account: account).reviewedIngest(review)
                guard valid(id, token), try await generation() == account, valid(id, token),
                      now() >= review.verifiedAt, now() < review.expiresAt else { throw CancellationError() }
                // No suspension from the final identity/settings check through
                // one-use handoff. The host must not cache credentials/review.
                guard publish(context, credentials) else { throw ProviderFailure(.invalidRequest) }
                cancel(id)
            } catch { fail(id, token: token, error: error) }
        }
        startDeadline(id, token: token)
    }
    func reviewAgain(_ id: UUID) {
        guard let context = current(id) else { cancel(id); return }
        _ = request(context)
    }
    func cancel(_ id: UUID) {
        jobs.removeValue(forKey: id)?.cancel(); deadlines.removeValue(forKey: id)?.cancel()
        entries.removeAll(where: { $0.id == id })
    }
    func cancelAll() {
        for id in Array(jobs.keys) { cancel(id) }
        entries.removeAll()
    }
    func shutdown() {
        closed = true
        for task in jobs.values { task.cancel() }; for task in deadlines.values { task.cancel() }
        jobs.removeAll(); deadlines.removeAll(); entries.removeAll()
    }
    private func reader(account: UUID) -> YouTubeStartReader {
        let read = read, generation = generation
        return .init(send: { provider, request in
            guard provider == .youtube, !Task.isCancelled, try await generation() == account else { throw CancellationError() }
            var request = request; request.timeoutInterval = 10; request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            let data = try await read(request, account)
            guard !Task.isCancelled, try await generation() == account else { throw CancellationError() }
            return data
        }, now: now)
    }
    private func valid(_ id: UUID, _ token: UUID) -> Bool {
        let context = current(id)
        return !closed && !Task.isCancelled && entries.contains(where: { $0.id == id && $0.attempt == token && context == $0.context })
    }
    private func startDeadline(_ id: UUID, token: UUID) {
        let timeout = operationTimeout
        deadlines[id] = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard let self, let index = entries.firstIndex(where: { $0.id == id && $0.attempt == token }) else { return }
            jobs.removeValue(forKey: id)?.cancel(); deadlines[id] = nil
            entries[index].attempt = UUID(); entries[index].phase = .blocked; entries[index].review = nil
            entries[index].message = "Provider review timed out. Nothing was started. Review again explicitly when the account is available."
        }
    }
    private func finishJob(_ id: UUID) {
        jobs[id] = nil; deadlines.removeValue(forKey: id)?.cancel()
    }
    private func fail(_ id: UUID, token: UUID, error: Error) {
        guard !closed, let index = entries.firstIndex(where: { $0.id == id && $0.attempt == token }) else { return }
        entries[index].phase = .blocked; entries[index].review = nil; entries[index].accountGeneration = nil
        entries[index].message = error is CancellationError
            ? "The account, destination, settings or review changed. Nothing was started. Review again explicitly."
            : (error as? ProviderFailure)?.localizedDescription ?? "The provider could not be freshly verified. Nothing was started."
        finishJob(id)
    }
}
