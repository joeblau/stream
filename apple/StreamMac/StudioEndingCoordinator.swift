import Combine
import Foundation
import StreamCore

struct StudioEndingTarget: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let session: UUID?
    let binding: ProviderDestinationBinding?
    func matches(_ other: Self) -> Bool { id == other.id && session == other.session && binding == other.binding }
}
struct StudioEndingReport {
    enum Local: String { case untouched = "Not requested", pending = "Stopping", stopped = "Stopped", superseded = "Session changed", unconfirmed = "Stop unconfirmed", inactive = "No active local session" }
    let target: StudioEndingTarget
    var local = Local.untouched
    var localReceivedAt: Date?
    var remote: ProviderCompletionReceipt?
    var remotePending = false
    var note: String?
}
struct StudioOutroChoice: Identifiable { let id: UUID; let name: String }
struct StudioOutroReceipt: Equatable { let sceneID: UUID; let revision: UUID }
struct StudioEndingSceneHooks {
    let choices: () -> [StudioOutroChoice]
    let take: (UUID) throws -> StudioOutroReceipt
    let matches: (StudioOutroReceipt) -> Bool
    let transitionComplete: () -> Bool
}

/// A deliberate ending plan, scoped to the runtime and exact publishing
/// sessions confirmed by the operator. No plans or mutations are persisted.
@MainActor final class StudioEndingCoordinator: ObservableObject {
    enum Mode { case local, remote, both, review }
    enum LocalResult { case stopped, superseded, unconfirmed }
    typealias Sleep = @Sendable (Double) async throws -> Void
    struct Boundary {
        let targets: () -> [StudioEndingTarget]
        let stopLocal: (StudioEndingTarget) async -> LocalResult
        let localReceipt: (StudioEndingTarget) -> LocalResult
        let remote: (ProviderDestinationBinding, Bool) async -> ProviderCompletionReceipt
        let canEndRemote: (ProviderDestinationBinding) -> Bool
    }
    @Published private(set) var reports: [UUID: StudioEndingReport] = [:]
    @Published private(set) var isWorking = false
    @Published private(set) var countdown: Int?
    @Published private(set) var notice: String?
    @Published private(set) var isBound = false
    @Published private(set) var availabilityRevision = UUID()
    private var bindingObservations: [AnyCancellable] = []
    func retainBindings(_ observations: [AnyCancellable]) { bindingObservations = observations }
    func refreshAvailability() { availabilityRevision = UUID() }
    private var boundary: Boundary?
    private var sceneHooks: StudioEndingSceneHooks?
    private var epoch = UUID()
    private var plan: Task<Void, Never>?
    private var workers: [UUID: Task<Void, Never>] = [:]
    private var remoteWork: [String: RemoteWork] = [:]
    private let sleep: Sleep
    private let clock: @Sendable () -> Double
    private let remoteTimeout: Double
    private var reportOrder: [UUID] = []
    private final class RemoteWork {
        var result: ProviderCompletionReceipt?
        var task: Task<Void, Never>?
        let deadline: Double
        init(deadline: Double) { self.deadline = deadline }
    }
    init(sleep: @escaping Sleep = { try await Task.sleep(for: .seconds($0)) },
         clock: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }, remoteTimeout: Double = 30) {
        self.sleep = sleep; self.clock = clock; self.remoteTimeout = max(0.01, min(60, remoteTimeout))
    }
    func bind(_ boundary: Boundary, sceneHooks: StudioEndingSceneHooks? = nil) {
        shutdown(); self.boundary = boundary; self.sceneHooks = sceneHooks; isBound = true; notice = nil
    }
    var targets: [StudioEndingTarget] { boundary?.targets() ?? [] }
    var activeTargets: [StudioEndingTarget] { targets.filter { $0.session != nil } }
    var outroChoices: [StudioOutroChoice] { sceneHooks?.choices() ?? [] }
    var canUseOutro: Bool { sceneHooks != nil && !activeTargets.isEmpty }
    func canEndRemote(_ target: StudioEndingTarget) -> Bool { target.binding.map { boundary?.canEndRemote($0) == true } ?? false }
    func reviewLocal(_ id: UUID) {
        guard let boundary, let report = reports[id], report.target.session != nil else { return }
        switch boundary.localReceipt(report.target) {
        case .stopped: reports[id]?.local = .stopped
        case .superseded: reports[id]?.local = .superseded
        case .unconfirmed: reports[id]?.local = .unconfirmed
        }
        reports[id]?.localReceivedAt = Date()
    }
    private func current(_ captured: UUID) -> Bool { epoch == captured && !Task.isCancelled }
    private func unchanged(_ target: StudioEndingTarget) -> Bool { targets.first { $0.id == target.id }.map(target.matches) == true }
    func cancelPending() {
        let hadPendingPlan = isWorking
        epoch = UUID(); plan?.cancel(); plan = nil
        for worker in workers.values { worker.cancel() }; workers = [:]
        for work in remoteWork.values { work.task?.cancel() }; remoteWork = [:]
        for id in reports.keys {
            guard reports[id]?.local == .pending || reports[id]?.remotePending == true else { continue }
            if reports[id]?.local == .pending { reports[id]?.local = .unconfirmed }
            if reports[id]?.remotePending == true { reports[id]?.remote = .init(.unconfirmed); reports[id]?.remotePending = false }
            reports[id]?.note = "Pending work cancelled locally. A sent provider request cannot be undone; review uncertain remote state."
        }
        if hadPendingPlan { notice = "Pending ending cancelled. Review uncertain receipts before an explicit retry." }
        countdown = nil; isWorking = false
    }
    func shutdown() { cancelPending(); boundary = nil; sceneHooks = nil; bindingObservations = []; isBound = false; reports = [:]; reportOrder = [] }
    /// The caller must confirm the exact targets/mode. A running plan cannot
    /// be replaced or retried implicitly, even if only one target failed.
    func request(_ selected: [StudioEndingTarget], mode: Mode, outroScene: UUID? = nil, duration: Double = 0) {
        guard !isWorking, let boundary, !selected.isEmpty, selected.count <= 128 else { return }
        let selected = Array(Dictionary(selected.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values)
        guard selected.allSatisfy(unchanged) else { notice = "A destination session or routing binding changed. Review and confirm again."; return }
        guard duration.isFinite, (0...120).contains(duration), outroScene == nil || (mode == .both && sceneHooks != nil && selected.allSatisfy { $0.session != nil }) else {
            notice = "Timed outro requires an active captured session and the shared scene command hooks."; return
        }
        epoch = UUID(); let captured = epoch; isWorking = true; notice = nil
        remoteWork = [:]
        for target in selected {
            if reports[target.id]?.target.binding != target.binding || reports[target.id]?.target.session != target.session { reports[target.id] = nil }
            if reports[target.id] == nil {
                reports[target.id] = .init(target: target); reportOrder.removeAll { $0 == target.id }; reportOrder.append(target.id)
            }
            reports[target.id]?.note = nil
        }
        while reportOrder.count > 128 { reports[reportOrder.removeFirst()] = nil }
        plan = Task { [weak self] in
            guard let self else { return }
            if let sceneID = outroScene {
                guard let hooks = sceneHooks else { finish(captured); return }
                do {
                    let receipt = try hooks.take(sceneID)
                    let transitionDeadline = clock() + 30
                    while !hooks.transitionComplete() {
                        guard current(captured), hooks.matches(receipt), selected.allSatisfy(unchanged), clock() < transitionDeadline else {
                            abortOutro(captured); return
                        }
                        try await sleep(0.05)
                    }
                    let deadline = clock() + duration
                    while clock() < deadline {
                        guard current(captured), hooks.matches(receipt), selected.allSatisfy(unchanged) else { abortOutro(captured); return }
                        countdown = Int(ceil(deadline - clock())); try await sleep(min(0.1, max(0.01, deadline - clock())))
                    }
                    guard current(captured), hooks.matches(receipt), selected.allSatisfy(unchanged) else { abortOutro(captured); return }
                    countdown = nil
                } catch {
                    guard current(captured) else { return }; notice = "The shared scene command could not publish the outro. Outputs remain running."; finish(captured); return
                }
            }
            guard current(captured) else { return }
            for target in selected {
                workers[target.id] = Task { [weak self] in
                    guard let self else { return }
                    guard current(captured), unchanged(target) else { reports[target.id]?.note = "Session changed; no ending action was sent."; return }
                    if mode != .local {
                        reports[target.id]?.remotePending = true
                        if let binding = target.binding {
                            let result = await remote(binding, review: mode == .review, boundary: boundary, epoch: captured)
                            guard current(captured) else { return }
                            reports[target.id]?.remote = result
                        } else { reports[target.id]?.remote = .init(.unsupported) }
                        reports[target.id]?.remotePending = false
                    }
                    guard current(captured) else { return }
                    if mode == .local || mode == .both {
                        guard let _ = target.session else { reports[target.id]?.local = .inactive; return }
                        guard unchanged(target) else { reports[target.id]?.local = .superseded; return }
                        reports[target.id]?.local = .pending
                        let result = await boundary.stopLocal(target)
                        guard current(captured) else { return }
                        switch result {
                        case .stopped: reports[target.id]?.local = .stopped
                        case .superseded: reports[target.id]?.local = .superseded
                        case .unconfirmed: reports[target.id]?.local = .unconfirmed
                        }
                        reports[target.id]?.localReceivedAt = Date()
                    }
                }
            }
            for target in selected { await workers[target.id]?.value }
            finish(captured)
        }
    }
    private func remote(_ binding: ProviderDestinationBinding, review: Bool, boundary: Boundary, epoch captured: UUID) async -> ProviderCompletionReceipt {
        guard binding.provider == .youtube, binding.eventID != nil else { return .init(.unsupported) }
        guard review || boundary.canEndRemote(binding) else { return .init(.blocked, failure: .init(.permission)) }
        let key = "\(review):\(binding.provider.rawValue):\(binding.channelID):\(binding.eventID!)"
        let work: RemoteWork
        if let existing = remoteWork[key] { work = existing }
        else {
            work = RemoteWork(deadline: clock() + remoteTimeout); remoteWork[key] = work
            work.task = Task { [weak self, weak work] in
                let result = await boundary.remote(binding, review)
                guard let self, let work, self.current(captured), work.result == nil else { return }
                work.result = result
            }
        }
        while current(captured) {
            if let result = work.result { return result }
            if clock() >= work.deadline {
                work.result = .init(.unconfirmed, failure: .init(.unavailable)); work.task?.cancel()
                return work.result!
            }
            do { try await sleep(0.05) } catch { return .init(.unconfirmed) }
        }
        return .init(.unconfirmed)
    }
    private func abortOutro(_ captured: UUID) {
        guard current(captured) else { return }
        notice = "Outro ending cancelled because Program, a publishing session, or the transition changed. Review before ending again."
        finish(captured)
    }
    private func finish(_ captured: UUID) {
        guard current(captured) else { return }; isWorking = false; countdown = nil; workers = [:]; plan = nil; remoteWork = [:]
    }
}
