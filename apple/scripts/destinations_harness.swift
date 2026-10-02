import Foundation
import AppKit
import CoreMedia
import CoreVideo
import StreamCore

// Shipping publishers import HaishinKit's identical conformance. The harness
// feeds immutable sample buffers across independent actor mailboxes.
extension CMSampleBuffer: @retroactive @unchecked Sendable {}

actor FakeDestinationPublisher: Publisher {
    nonisolated let events: AsyncStream<PublisherEvent>
    nonisolated let continuation: AsyncStream<PublisherEvent>.Continuation
    var held = false
    var entered = false
    var gate: CheckedContinuation<Void, Never>?
    var frames: [Int64] = []
    var stopped = false
    init() {
        (events, continuation) = AsyncStream.makeStream(of: PublisherEvent.self)
    }
    nonisolated func emit(_ event: PublisherEvent) { continuation.yield(event) }
    func start(_ settings: StreamSettings) async throws {}
    func stop() async { stopped = true; release() }
    func pause() async {}
    func resume() async {}
    func setOutputSize(_ size: CGSize, nativeShortEdge: Int) async {}
    func appendVideo(_ sb: CMSampleBuffer) async {
        entered = true
        if held { await withCheckedContinuation { gate = $0 } }
        frames.append(CMSampleBufferGetPresentationTimeStamp(sb).value)
    }
    func hold() { held = true }
    func release() { held = false; gate?.resume(); gate = nil }
    nonisolated func enqueueMic(_ sb: CMSampleBuffer) {}
    nonisolated func enqueueApp(_ sb: CMSampleBuffer) {}
    nonisolated func enqueueProgram(_ sb: CMSampleBuffer) {}
    func setMicVolume(_ volume: Double) async {}
    func setThermalCeiling(bitRateScale: Double, frameRateCap: Int) async {}
    func statsSnapshot() async -> LiveStats? { nil }
}

@main struct DestinationsHarness {
    @MainActor static func main() async throws {
        let slow = FakeDestinationPublisher(), healthy = FakeDestinationPublisher(), retry = FakeDestinationPublisher()
        var pending: [FakeDestinationPublisher] = [slow, healthy, retry]
        let outputs = DestinationOutputController(factory: { _ in pending.removeFirst() })
        let a = StreamDestination(name: "Slow"), b = StreamDestination(name: "Healthy")
        outputs.isPublishingAllowed = false
        outputs.start(a, settings: .default)
        precondition(pending.count == 3 && outputs.states.isEmpty,
                     "Local rehearsal must prevent publisher allocation at the output boundary")
        outputs.isPublishingAllowed = true
        outputs.start(a, settings: .default)
        outputs.start(b, settings: .default)
        precondition(outputs.states[a.id] == .connecting && outputs.states[b.id] == .connecting)
        slow.emit(.published); healthy.emit(.published)
        await settle { outputs.liveCount == 2 }
        precondition(outputs.aggregateState == .live)
        let acknowledgedStart = outputs.acknowledgedStarts[a.id]
        precondition(acknowledgedStart != nil)

        // A transport waiting forever on one frame cannot block the healthy sink.
        await slow.hold()
        outputs.fanout.enqueueVideo(try sample(0))
        await settleAsync { await slow.entered }
        await settleAsync { await healthy.frames.count >= 1 }
        for value in 1...100 { outputs.fanout.enqueueVideo(try sample(Int64(value))) }
        await settleAsync { await healthy.frames.last == 100 }
        let diagnostics = await outputs.diagnosticsSnapshot()
        precondition(diagnostics.allSatisfy { $0.videoQueueDepth <= 2 })
        precondition(diagnostics.first { $0.id == a.id.uuidString }!.videoMailboxDrops >= 98)
        await slow.release()
        await settleAsync { await slow.frames.count == 3 }
        let slowFrames = await slow.frames
        precondition(slowFrames == [0, 99, 100], "Slow sink must retain only two newest queued frames")

        slow.emit(.reconnecting(reason: "temporary"))
        await settle { if case .reconnecting = outputs.states[a.id] { return true }; return false }
        precondition(outputs.states[b.id] == .live && outputs.aggregateState == .live)
        precondition(outputs.acknowledgedStarts[a.id] == acknowledgedStart, "Reconnect reset elapsed timer")
        slow.emit(.failed(message: "rtmps://secret.invalid/key"))
        await settle { if case .failed = outputs.states[a.id] { return true }; return false }
        precondition(outputs.states[b.id] == .live && outputs.partialSuccess)
        if case .failed(let message) = outputs.states[a.id] { precondition(!message.contains("secret")) }
        outputs.start(a, settings: .default)
        slow.emit(.published) // Obsolete session must never acknowledge this retry.
        await Task.yield()
        precondition(outputs.states[a.id] == .connecting)
        retry.emit(.published)
        await settle { outputs.states[a.id] == .live }
        precondition(outputs.liveCount == 2)
        outputs.stop(a.id)
        retry.emit(.published) // A late acknowledgment cannot reanimate Stop.
        await settle { outputs.states[a.id] == .idle }
        precondition(outputs.states[b.id] == .live)
        outputs.stopAll()
        await settle { outputs.activeCount == 0 }
        precondition(outputs.aggregateState == .idle)
        var allocations = 0
        let capacity = DestinationOutputController(factory: { _ in
            allocations += 1
            return FakeDestinationPublisher()
        })
        for number in 0..<11 { capacity.start(.init(name: "Output \(number)"), settings: .default) }
        precondition(allocations == 10 && capacity.activeCount == 10)
        precondition(capacity.states.values.filter { if case .failed = $0 { return true }; return false }.count == 1)
        capacity.stopAll()
        await settle { capacity.activeCount == 0 }
        // Exercise the shipping native lifecycle coordinator against actual
        // multi-output sessions. No lifecycle event allocates a publisher.
        let first = FakeDestinationPublisher(), second = FakeDestinationPublisher()
        var lifecyclePending = [first, second]
        var allocationsAfterStart = 0, recorderStops = 0, slateRequests = 0, previewStarts = 0, refreshes = 0
        let lifecycleOutputs = DestinationOutputController(factory: { _ in
            allocationsAfterStart += 1
            return lifecyclePending.removeFirst()
        })
        let one = StreamDestination(name: "One"), two = StreamDestination(name: "Two")
        lifecycleOutputs.start(one, settings: .default); lifecycleOutputs.start(two, settings: .default)
        first.emit(.published); second.emit(.published)
        await settle { lifecycleOutputs.liveCount == 2 }
        var health = SourceFailureTracker<String>()
        let frameCache = SourceFailoverCache<String, Int>()
        let videoSources: Set<String> = ["camera", "screen"]
        frameCache.configure(active: videoSources, modes: ["camera": .freeze], failed: [])
        _ = frameCache.frame(for: "camera", live: { 1 }, standby: { nil }, offline: { 0 })
        let lost = health.update(active: videoSources, unavailable: [], reportedFailures: ["camera"],
                                now: 1, graceSeconds: 2, automaticallyRestore: false)
        frameCache.configure(active: videoSources, modes: ["camera": .freeze], failed: lost)
        precondition(frameCache.frame(for: "camera", live: { 2 }, standby: { nil }, offline: { 0 }) == 1)
        precondition(frameCache.frame(for: "screen", live: { 3 }, standby: { nil }, offline: { 0 }) == 3)
        precondition(lifecycleOutputs.liveCount == 2 && frameCache.retainedCount == 2)
        let coordinator = DesktopResilienceCoordinator(observeSystem: false)
        coordinator.stopOutputs = { lifecycleOutputs.stopAll(); recorderStops += 1 }
        coordinator.showOfflineSlate = { slateRequests += 1 }
        coordinator.startPreview = { previewStarts += 1 }
        coordinator.refreshSources = { refreshes += 1 }
        coordinator.policy.lockAction = .continueWithOfflineSlate
        coordinator.handle(.locked); coordinator.handle(.locked)
        precondition(slateRequests == 1 && lifecycleOutputs.liveCount == 2 && recorderStops == 0)
        coordinator.handle(.unlocked)
        precondition(lifecycleOutputs.liveCount == 2 && allocationsAfterStart == 2 && refreshes == 1)
        coordinator.handle(.sleep); coordinator.handle(.sleep)
        await settle { lifecycleOutputs.activeCount == 0 }
        precondition(recorderStops == 1 && coordinator.requiresManualRestart)
        coordinator.handle(.wake)
        precondition(previewStarts == 0 && lifecycleOutputs.activeCount == 0 && allocationsAfterStart == 2)
        coordinator.policy.previewAfterWake = true
        coordinator.handle(.wake)
        precondition(previewStarts == 1 && lifecycleOutputs.activeCount == 0 && allocationsAfterStart == 2)
        coordinator.policy.lockAction = .stopOutputs
        coordinator.handle(.locked); coordinator.handle(.unlocked)
        precondition(recorderStops == 2 && lifecycleOutputs.activeCount == 0 && allocationsAfterStart == 2)
        let observed = DesktopResilienceCoordinator(observeSystem: true)
        var observedStops = 0
        observed.stopOutputs = { observedStops += 1 }
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        await settle { observedStops == 1 }
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        await settle { observed.notice?.contains("Mac woke") == true }
        precondition(observedStops == 1 && allocationsAfterStart == 2)
        let policyURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let savedPolicy = DesktopResilienceCoordinator(url: policyURL, observeSystem: false)
        savedPolicy.policy.sourceRules = [.init(sourceID: one.id, mode: .freeze)]
        savedPolicy.save()
        precondition(DesktopResilienceCoordinator(url: policyURL, observeSystem: false).policy == savedPolicy.policy)
        let invalid = Data("broken policy".utf8)
        try invalid.write(to: policyURL)
        savedPolicy.save()
        let preservedPolicy = try Data(contentsOf: policyURL)
        precondition(preservedPolicy == invalid, "Corrupt project policy must not be replaced")
        try FileManager.default.removeItem(at: policyURL)
        print("PASS: native lifecycle coordinator, duplicate-event idempotence, silent-slate keeps both outputs live, sleep stops publishers/recorder once, wake/unlock never allocate publishers, opt-in preview only, persisted policy and corrupt-document protection; \(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("PASS: rehearsal prevents public publisher allocation; up-to-ten session boundary; actual destination controller, independent failure/reconnect/stop/retry, stable ID, stale event rejection, secret-safe failures, bounded slow queue and healthy fanout")
    }

    @MainActor static func settle(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition() && ContinuousClock.now < deadline { await Task.yield() }
        precondition(condition(), "Lifecycle event did not settle")
    }
    @MainActor static func settleAsync(_ condition: () async -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await condition()) && ContinuousClock.now < deadline { await Task.yield() }
        let settled = await condition()
        precondition(settled, "Media event did not settle")
    }
    static func sample(_ value: Int64) throws -> CMSampleBuffer {
        var pixel: CVPixelBuffer?
        precondition(CVPixelBufferCreate(nil, 2, 2, kCVPixelFormatType_32BGRA, nil, &pixel) == kCVReturnSuccess)
        var format: CMVideoFormatDescription?
        precondition(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixel!, formatDescriptionOut: &format) == noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                       presentationTimeStamp: CMTime(value: value, timescale: 30), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        precondition(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixel!, formatDescription: format!, sampleTiming: &timing, sampleBufferOut: &sample) == noErr)
        return sample!
    }
}
