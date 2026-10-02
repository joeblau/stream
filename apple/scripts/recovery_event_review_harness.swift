import Foundation
import CoreMedia
import StreamCore

extension CMSampleBuffer: @retroactive @unchecked Sendable {}

private actor ReviewPublisher: Publisher {
    nonisolated let events: AsyncStream<PublisherEvent>
    init() { events = AsyncStream { _ in } }
    func start(_ settings: StreamSettings) async throws {}
    func stop() async {}
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
private final class ReviewClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_000)
    func now() -> Date { lock.withLock { date } }
    func advance(_ seconds: Double) { lock.withLock { date = date.addingTimeInterval(seconds) } }
}
private actor ReviewHTTP {
    var requests: [URLRequest] = []
    var owner = "owner"
    var eventOwner = "owner"
    var state = "live"
    var absent = false
    var failure: ProviderFailure?
    var gates: [CheckedContinuation<Void, Never>] = []
    var hold = false
    var entered = false
    func configure(owner: String = "owner", eventOwner: String = "owner", state: String = "live", absent: Bool = false,
                   failure: ProviderFailure? = nil, hold: Bool = false) {
        self.owner = owner; self.eventOwner = eventOwner; self.state = state; self.absent = absent
        self.failure = failure; self.hold = hold; entered = false
    }
    func release() { hold = false; let pending = gates; gates.removeAll(); for gate in pending { gate.resume() } }
    func count() -> Int { requests.count }
    func send(_ provider: ManagedProvider, _ request: URLRequest) async throws -> Data {
        precondition(provider == .youtube && request.httpMethod == "GET" && request.httpBody == nil)
        precondition(request.cachePolicy == .reloadIgnoringLocalCacheData)
        requests.append(request)
        if let failure { throw failure }
        if request.url!.path == "/youtube/v3/channels" {
            return Data("{\"items\":[{\"id\":\"\(owner)\",\"snippet\":{\"title\":\"Fixture\"}}]}".utf8)
        }
        precondition(request.url!.path == "/youtube/v3/liveBroadcasts")
        if hold { entered = true; await withCheckedContinuation { gates.append($0) } }
        return Data(absent ? "{\"items\":[]}".utf8 : "{\"items\":[{\"id\":\"event_a\",\"snippet\":{\"channelId\":\"\(eventOwner)\"},\"status\":{\"lifeCycleStatus\":\"\(state)\"}}]}".utf8)
    }
}

@main struct RecoveryEventReviewHarness {
    @MainActor static func check(_ value: Bool, _ message: String = "Recovery assertion failed") { precondition(value, message) }
    @MainActor static func until(_ predicate: () async -> Bool) async {
        for _ in 0..<1_000 { if await predicate() { return }; try? await Task.sleep(for: .milliseconds(2)) }
        preconditionFailure("Recovery event fixture did not settle")
    }
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("stream-event-review-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var allocations = 0
        let outputs = DestinationOutputController { _ in allocations += 1; return ReviewPublisher() }
        var destination = StreamDestination(name: "Started", providerBinding: .init(provider: .youtube, channelID: "owner", eventID: "event_a"))
        outputs.start(destination, settings: .default)
        let captured = outputs.recoveryRemoteEvents[0]
        precondition(captured.reviewIdentity != nil && captured.publisherSessionID == outputs.sessionToken(destination.id))
        destination.providerBinding?.eventID = "edited_event_b"
        destination.providerBinding?.channelID = "edited_channel"
        precondition(outputs.recoveryRemoteEvents == [captured], "Mutable settings replaced the started event")
        outputs.stopAll()
        await until { outputs.activeCount == 0 }
        precondition(outputs.recoveryRemoteEvents == [captured], "Local stop discarded remote identity")
        let stoppedAllocations = allocations
        var checkpoint = SessionRecoverySnapshot(projectID: UUID(), profileID: UUID())
        checkpoint.remoteEvents = outputs.recoveryRemoteEvents
        let writer = SessionRecoveryCoordinator(directory: directory)
        writer.beginContext(projectID: checkpoint.projectID, profileID: checkpoint.profileID)
        writer.checkpoint(checkpoint); await writer.flush()
        let restarted = SessionRecoveryCoordinator(directory: directory)
        precondition(restarted.pending?.remoteEvents == [captured] && restarted.pending?.activeOutputIDs.isEmpty == true)
        precondition(allocations == stoppedAllocations)
        let clock = ReviewClock(), http = ReviewHTTP()
        let review = restarted.remoteReview
        // For deterministic freshness use a separate shipping coordinator; the
        // reopened real journal still supplies its exact interrupted identity.
        let deterministic = RecoveryEventReviewCoordinator(now: { clock.now() })
        let context = RecoveryEventReviewCoordinator.Context(projectID: checkpoint.projectID, profileID: checkpoint.profileID, generation: UUID())
        var epoch: UUID? = UUID()
        let reader = RecoveryEventReader(send: { p, r in try await http.send(p, r) }, now: { clock.now() })
        deterministic.bind(authorization: { _ in epoch }, verify: { try await reader.verify($0) })
        deterministic.load(restarted.pending, context: context)
        check(await http.count() == 0 && deterministic.review(destination.id).state == .unknown)
        precondition(review.review(destination.id).state == .unknown)
        deterministic.verify(destination.id)
        await until { !deterministic.verifying.contains(destination.id) }
        precondition(deterministic.review(destination.id).state == .reconnectable)
        clock.advance(61)
        precondition(deterministic.review(destination.id).reason == .stale)
        await http.configure(state: "complete")
        deterministic.verify(destination.id); await until { !deterministic.verifying.contains(destination.id) }
        precondition(deterministic.review(destination.id).state == .ended)
        for state in ["ready", "created", "testing", "testStarting", "liveStarting"] {
            await http.configure(state: state)
            deterministic.verify(destination.id); await until { !deterministic.verifying.contains(destination.id) }
            precondition(deterministic.review(destination.id).state == .unknown)
        }
        await http.configure(owner: "foreign")
        let beforeForeign = await http.count()
        deterministic.verify(destination.id); await until { !deterministic.verifying.contains(destination.id) }
        precondition(deterministic.review(destination.id).reason == .foreignOwnership)
        check(await http.count() == beforeForeign + 1, "Foreign current account looked up the event")
        await http.configure(eventOwner: "foreign")
        deterministic.verify(destination.id); await until { !deterministic.verifying.contains(destination.id) }
        precondition(deterministic.review(destination.id).reason == .foreignOwnership)
        await http.configure(absent: true)
        deterministic.verify(destination.id); await until { !deterministic.verifying.contains(destination.id) }
        precondition(deterministic.review(destination.id).reason == .invalidResponse)
        for (failure, reason) in [(ProviderFailure.Kind.permission, RecoveryEventReview.Reason.permissionDenied), (.authorization, .authorizationNeeded), (.rateLimited, .rateLimited), (.unavailable, .unavailable)] {
            await http.configure(failure: .init(failure))
            deterministic.verify(destination.id); await until { !deterministic.verifying.contains(destination.id) }
            precondition(deterministic.review(destination.id).reason == reason)
        }
        await http.configure(hold: true)
        deterministic.verify(destination.id); await until { await http.entered }
        epoch = UUID(); await http.release()
        await until { !deterministic.verifying.contains(destination.id) }
        precondition(deterministic.review(destination.id).reason == .accountChanged)
        await http.configure(hold: true)
        deterministic.verify(destination.id); await until { await http.entered }
        deterministic.load(restarted.pending, context: .init(projectID: context.projectID, profileID: UUID(), generation: UUID()))
        await http.release(); try? await Task.sleep(for: .milliseconds(20))
        precondition(deterministic.review(destination.id).reason == .contextMismatch)
        let readsBeforeMismatch = await http.count()
        deterministic.verify(destination.id)
        check(await http.count() == readsBeforeMismatch)
        var legacy = checkpoint
        legacy.remoteEvents = [.init(outputID: destination.id, eventID: "event_a", state: .ended)]
        deterministic.load(legacy, context: context)
        precondition(deterministic.review(destination.id).reason == .missingIdentity && !deterministic.canVerify(destination.id))
        var unsupported = checkpoint; unsupported.remoteEvents[0].provider = .twitch
        deterministic.load(unsupported, context: context)
        precondition(deterministic.review(destination.id).reason == .unsupportedProvider && !deterministic.canVerify(destination.id))
        let timeoutHTTP = ReviewHTTP(), timeoutReview = RecoveryEventReviewCoordinator(now: { clock.now() }, timeout: .milliseconds(20))
        let timeoutReader = RecoveryEventReader(send: { p, r in try await timeoutHTTP.send(p, r) }, now: { clock.now() })
        timeoutReview.bind(authorization: { _ in epoch }, verify: { try await timeoutReader.verify($0) })
        timeoutReview.load(checkpoint, context: context)
        await timeoutHTTP.configure(hold: true)
        timeoutReview.verify(destination.id); await until { await timeoutHTTP.entered }
        await until { timeoutReview.review(destination.id).reason == .timedOut }
        await timeoutHTTP.release(); try? await Task.sleep(for: .milliseconds(20))
        precondition(timeoutReview.review(destination.id).reason == .timedOut, "Late live reply replaced timeout")
        // A request that ignores cancellation still occupies one of two slots.
        // Profile switching and timeout/retry cannot accumulate HTTP jobs.
        let boundedHTTP = ReviewHTTP(), bounded = RecoveryEventReviewCoordinator(now: { clock.now() }, timeout: .milliseconds(20))
        let boundedReader = RecoveryEventReader(send: { p, r in try await boundedHTTP.send(p, r) }, now: { clock.now() })
        bounded.bind(authorization: { _ in epoch }, verify: { try await boundedReader.verify($0) })
        var several = checkpoint
        for _ in 0..<2 {
            var item = captured; item.outputID = UUID(); item.publisherSessionID = UUID(); several.remoteEvents.append(item)
        }
        bounded.load(several, context: context); await boundedHTTP.configure(hold: true)
        let ids = several.remoteEvents.map(\.outputID)
        bounded.verify(ids[0]); bounded.verify(ids[1]); bounded.verify(ids[2])
        await until { await boundedHTTP.gates.count == 2 }
        await until { bounded.review(ids[0]).reason == .timedOut && bounded.review(ids[1]).reason == .timedOut }
        precondition(!bounded.canVerify(ids[2]))
        bounded.load(several, context: .init(projectID: context.projectID, profileID: context.profileID, generation: UUID()))
        precondition(!bounded.canVerify(ids[2]))
        check(await boundedHTTP.count() == 4, "Canceled requests exceeded the two-job bound")
        await boundedHTTP.release(); await until { bounded.canVerify(ids[2]) }
        bounded.shutdown()
        timeoutReview.shutdown(); deterministic.shutdown(); review.shutdown()
        precondition(allocations == stoppedAllocations, "Recovery replayed an output start")
        outputs.start(destination, settings: .default)
        precondition(outputs.recoveryRemoteEvents[0].eventID == "edited_event_b" && outputs.recoveryRemoteEvents[0].publisherSessionID != captured.publisherSessionID)
        outputs.stopAll(); await until { outputs.activeCount == 0 }
        print("PASS: native immutable started event binding survives destination edits/local stop; real atomic checkpoint/restart retains session identity, no auto GET or publisher allocation")
        print("PASS: explicit fresh owned live/ended, transitional/absent/foreign/permission/offline/rate unknown; cached legacy/unsupported unknown; receipt expiry; account/profile fences; timeout and late-response rejection; no mutation boundary")
        print("Environment: \(ProcessInfo.processInfo.operatingSystemVersionString)")
    }
}
