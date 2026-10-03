import Foundation
import CoreMedia
import CoreVideo
import StreamCore

extension CMSampleBuffer: @retroactive @unchecked Sendable {}
private actor EndingPublisher: Publisher {
    nonisolated let events: AsyncStream<PublisherEvent>
    nonisolated let continuation: AsyncStream<PublisherEvent>.Continuation
    var held = false
    var waiting: CheckedContinuation<Void, Never>?
    var stopCalls = 0
    init(held: Bool = false) { self.held = held; (events, continuation) = AsyncStream.makeStream(of: PublisherEvent.self) }
    func start(_ settings: StreamSettings) async throws { continuation.yield(.published) }
    func stop() async { stopCalls += 1; if held { await withCheckedContinuation { waiting = $0 } }; continuation.yield(.stopped) }
    func release() { held = false; waiting?.resume(); waiting = nil }
    func pause() async {}
    func resume() async {}
    func setOutputSize(_ size: CGSize, nativeShortEdge: Int) async {}
    func appendVideo(_ sample: CMSampleBuffer) async {}
    nonisolated func enqueueMic(_ sample: CMSampleBuffer) {}
    nonisolated func enqueueApp(_ sample: CMSampleBuffer) {}
    nonisolated func enqueueProgram(_ sample: CMSampleBuffer) {}
    func setMicVolume(_ volume: Double) async {}
    func setThermalCeiling(bitRateScale: Double, frameRateCap: Int) async {}
    func statsSnapshot() async -> LiveStats? { nil }
}
private actor EndingHTTP {
    var requests: [URLRequest] = []
    var failedEvents: Set<String> = []
    var holdPost = false
    var gate: CheckedContinuation<Data, Error>?
    func send(_ provider: ManagedProvider, _ call: URLRequest) async throws -> Data {
        precondition(provider == .youtube)
        requests.append(call)
        let id = URLComponents(url: call.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "id" }!.value!
        if call.httpMethod == "POST" {
            if holdPost { return try await withCheckedThrowingContinuation { gate = $0 } }
            if failedEvents.contains(id) { throw ProviderFailure(.unavailable) }
            return result(id)
        }
        return try JSONSerialization.data(withJSONObject: ["items": [["id": id, "snippet": ["channelId": "owner"], "status": ["lifeCycleStatus": "live"]]]])
    }
    nonisolated var api: ProviderAPI { ProviderAPI { try await self.send($0, $1) } }
    func result(_ id: String) -> Data { try! JSONSerialization.data(withJSONObject: ["id": id, "snippet": ["channelId": "owner"], "status": ["lifeCycleStatus": "complete"]]) }
    func fail(_ id: String) { failedEvents.insert(id) }
    func hold() { holdPost = true }
    func release(_ id: String) { gate?.resume(returning: result(id)); gate = nil }
    var postCount: Int { requests.filter { $0.httpMethod == "POST" }.count }
    var isHeld: Bool { gate != nil }
}
private final class EndingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds = 0.0
    func now() -> Double { lock.withLock { seconds } }
    func advance(_ amount: Double) { lock.withLock { seconds += amount } }
}
@MainActor private final class SceneBoundary {
    var revision = UUID()
    let id = UUID()
    var takeCalls = 0
    var transitionDone = true
    var failTake = false
    func take(_ scene: UUID) throws -> StudioOutroReceipt {
        guard !failTake, scene == id else { throw ProviderFailure(.invalidRequest) }
        takeCalls += 1; revision = UUID(); return .init(sceneID: id, revision: revision)
    }
    var hooks: StudioEndingSceneHooks { .init(choices: { [.init(id: self.id, name: "Saved Outro")] }, take: take,
        matches: { $0.revision == self.revision && $0.sceneID == self.id }, transitionComplete: { self.transitionDone }) }
}
@MainActor private final class EndingScenario {
    var targets: [StudioEndingTarget]
    var changeProgram = true
    var replaceSession = true
    init(_ targets: [StudioEndingTarget]) { self.targets = targets }
}
@main struct StudioEndingHarness {
    @MainActor static func until(line: Int = #line, _ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<600 { if condition() { return }; try? await Task.sleep(for: .milliseconds(5)) }
        precondition(condition(), "Ending fixture deadline at line \(line)")
    }
    @MainActor static func main() async throws {
        let aPublisher = EndingPublisher(), bPublisher = EndingPublisher(), replacement = EndingPublisher()
        var pool = [aPublisher, bPublisher, replacement]
        let outputs = DestinationOutputController(factory: { _ in pool.removeFirst() })
        let binding = ProviderDestinationBinding(provider: .youtube, channelID: "owner", eventID: "event-a")
        var a = StreamDestination(name: "YouTube", providerBinding: binding)
        let b = StreamDestination(name: "Twitch", providerBinding: .init(provider: .twitch, channelID: "owner"))
        outputs.start(a, settings: StreamSettings()); outputs.start(b, settings: StreamSettings())
        await until { outputs.liveCount == 2 }
        let firstToken = outputs.sessionToken(a.id)!
        // Editing a future start cannot rewrite the active event routing.
        a.providerBinding = .init(provider: .youtube, channelID: "owner", eventID: "future-event")
        precondition(outputs.endingSessions.first { $0.destination.id == a.id }?.destination.providerBinding == binding)
        let http = EndingHTTP(), coordinator = StudioEndingCoordinator()
        var localCalls = 0
        coordinator.bind(.init(targets: {
            outputs.endingSessions.map { .init(id: $0.destination.id, name: $0.destination.name, session: $0.token, binding: $0.destination.providerBinding) }
        }, stopLocal: { target in
            localCalls += 1
            switch await outputs.stopIfCurrent(target.id, token: target.session!) {
            case .stopped: return .stopped; case .superseded: return .superseded; case .unconfirmed: return .unconfirmed
            }
        }, localReceipt: { target in
            switch outputs.stopReceipt(target.id, token: target.session!) {
            case .stopped: return .stopped; case .superseded: return .superseded; case .unconfirmed: return .unconfirmed
            }
        }, remote: { route, review in
            if review { return await http.api.reviewYouTubeEnd(id: route.eventID!, expectedChannelID: route.channelID) }
            return await http.api.endYouTubeEvent(id: route.eventID!, expectedChannelID: route.channelID)
        }, canEndRemote: { $0.provider == .youtube }))
        let first = coordinator.targets.first { $0.id == a.id }!
        coordinator.request([first], mode: .local)
        await until { !coordinator.isWorking }
        precondition(coordinator.reports[a.id]?.local == .stopped && outputs.states[b.id] == .live)
        let noRemoteCalls = await http.postCount; precondition(noRemoteCalls == 0)
        // A stale command against the old stable ID cannot stop its new session.
        a.providerBinding = binding; outputs.start(a, settings: StreamSettings())
        await until { outputs.liveCount == 2 }
        precondition(outputs.sessionToken(a.id) != firstToken)
        coordinator.request([first], mode: .both)
        precondition(!coordinator.isWorking && outputs.states[a.id] == .live)
        let fresh = coordinator.targets.first { $0.id == a.id }!
        coordinator.request([fresh], mode: .remote)
        await until { !coordinator.isWorking }
        precondition(coordinator.reports[a.id]?.remote?.confirmsEnd == true && outputs.liveCount == 2 && localCalls == 1)
        let beforeBoth = await http.postCount
        coordinator.request(coordinator.activeTargets, mode: .both)
        await until { !coordinator.isWorking }
        precondition(outputs.activeCount == 0 && coordinator.reports[b.id]?.remote?.disposition == .unsupported)
        precondition(coordinator.reports[a.id]?.local == .stopped && coordinator.reports[b.id]?.local == .stopped)
        let afterBoth = await http.postCount; precondition(afterBoth == beforeBoth + 1)
        // Shared event targets mutate once; different event failures produce
        // independent receipts while every captured local stop still completes.
        let targets = [StudioEndingTarget(id: UUID(), name: "First", session: UUID(), binding: binding),
                       StudioEndingTarget(id: UUID(), name: "Alias", session: UUID(), binding: binding),
                       StudioEndingTarget(id: UUID(), name: "Fails", session: UUID(), binding: .init(provider: .youtube, channelID: "owner", eventID: "event-fail"))]
        await http.fail("event-fail")
        var stopped: Set<UUID> = []
        let partial = StudioEndingCoordinator()
        partial.bind(.init(targets: { targets }, stopLocal: { target in stopped.insert(target.id); return .stopped },
            localReceipt: { _ in .stopped }, remote: { route, _ in await http.api.endYouTubeEvent(id: route.eventID!, expectedChannelID: route.channelID) }, canEndRemote: { _ in true }))
        let beforePartial = await http.postCount
        partial.request(targets, mode: .both); await until { !partial.isWorking }
        let afterPartial = await http.postCount
        precondition(afterPartial == beforePartial + 2 && stopped.count == 3)
        precondition(partial.reports[targets[0].id]?.remote?.confirmsEnd == true && partial.reports[targets[1].id]?.remote?.confirmsEnd == true)
        precondition(partial.reports[targets[2].id]?.remote?.disposition == .unconfirmed)
        // Actual output teardown can time out without a fabricated idle state.
        let heldPublisher = EndingPublisher(held: true), heldOutputs = DestinationOutputController(factory: { _ in heldPublisher })
        let held = StreamDestination(name: "Held")
        heldOutputs.start(held, settings: StreamSettings()); await until { heldOutputs.liveCount == 1 }
        let heldToken = heldOutputs.sessionToken(held.id)!
        let unconfirmed = await heldOutputs.stopIfCurrent(held.id, token: heldToken, timeout: 0.01)
        precondition(unconfirmed == .unconfirmed && heldOutputs.states[held.id] == .stopping)
        heldOutputs.stop(held.id); precondition(heldOutputs.states[held.id] == .stopping)
        await heldPublisher.release(); await until { heldOutputs.states[held.id] == .idle }
        precondition(heldOutputs.stopReceipt(held.id, token: heldToken) == .stopped)
        let heldStopCalls = await heldPublisher.stopCalls; precondition(heldStopCalls == 1)
        // Late, noncooperative mutation replies cannot revive a shutdown plan.
        let lateHTTP = EndingHTTP(); await lateHTTP.hold()
        let late = StudioEndingCoordinator()
        late.bind(.init(targets: { targets }, stopLocal: { _ in .stopped }, localReceipt: { _ in .stopped },
            remote: { route, _ in await lateHTTP.api.endYouTubeEvent(id: route.eventID!, expectedChannelID: route.channelID) }, canEndRemote: { _ in true }))
        late.request([targets[0]], mode: .remote)
        for _ in 0..<200 { if await lateHTTP.isHeld { break }; try? await Task.sleep(for: .milliseconds(5)) }
        let mutationWasHeld = await lateHTTP.isHeld; precondition(mutationWasHeld)
        late.shutdown(); await lateHTTP.release("event-a"); try? await Task.sleep(for: .milliseconds(30))
        precondition(late.reports.isEmpty && !late.isBound && !late.isWorking)
        // The injected scene command receipt must remain current throughout
        // transition and hold; changing away and back still changes revision.
        let scene = SceneBoundary(), timerClock = EndingClock()
        var timedStops = 0, timedRemotes = 0
        let scenario = EndingScenario(targets)
        let timed = StudioEndingCoordinator(sleep: { seconds in
            timerClock.advance(seconds)
            await MainActor.run { if scenario.changeProgram && timerClock.now() >= 0.2 { scene.revision = UUID(); scenario.changeProgram = false } }
            await Task.yield()
        }, clock: timerClock.now)
        timed.bind(.init(targets: { targets }, stopLocal: { _ in timedStops += 1; return .stopped }, localReceipt: { _ in .stopped },
            remote: { _, _ in timedRemotes += 1; return .init(.ended) }, canEndRemote: { _ in true }), sceneHooks: scene.hooks)
        timed.request([targets[0]], mode: .both, outroScene: scene.id, duration: 1)
        await until { !timed.isWorking }
        precondition(scene.takeCalls == 1 && timedStops == 0 && timedRemotes == 0 && timed.notice != nil)
        timed.request([targets[0]], mode: .both, outroScene: scene.id, duration: 0.3)
        await until { !timed.isWorking }
        precondition(scene.takeCalls == 2 && timedStops == 1 && timedRemotes == 1)
        // Replacing an output during the hold also aborts before remote ending.
        let sessionClock = EndingClock(), replacementScene = SceneBoundary()
        let changing = StudioEndingCoordinator(sleep: { seconds in
            sessionClock.advance(seconds)
            await MainActor.run { if scenario.replaceSession { scenario.targets[0] = .init(id: scenario.targets[0].id, name: "New", session: UUID(), binding: binding); scenario.replaceSession = false } }
            await Task.yield()
        }, clock: sessionClock.now)
        let stopsBeforeReplacement = timedStops
        changing.bind(.init(targets: { scenario.targets }, stopLocal: { _ in timedStops += 1; return .stopped }, localReceipt: { _ in .stopped },
            remote: { _, _ in timedRemotes += 1; return .init(.ended) }, canEndRemote: { _ in true }), sceneHooks: replacementScene.hooks)
        changing.request([scenario.targets[0]], mode: .both, outroScene: replacementScene.id, duration: 0.3)
        await until { !changing.isWorking }
        precondition(timedStops == stopsBeforeReplacement && changing.notice != nil)
        print("PASS: actual output session/stop receipts; explicit local/remote separation; fresh owned YouTube completion; shared event dedup; independent partial results; bounded local stop/late receipts; shutdown late mutation rejection; timed scene receipt/revision and publishing-session cancellation")
    }
}
