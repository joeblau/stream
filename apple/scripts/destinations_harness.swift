import Foundation
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

        // A transport waiting forever on one frame cannot block the healthy sink.
        await slow.hold()
        outputs.fanout.enqueueVideo(try sample(0))
        await settleAsync { await slow.entered }
        await settleAsync { await healthy.frames.count >= 1 }
        for value in 1...100 { outputs.fanout.enqueueVideo(try sample(Int64(value))) }
        await settleAsync { await healthy.frames.last == 100 }
        await slow.release()
        await settleAsync { await slow.frames.count == 3 }
        let slowFrames = await slow.frames
        precondition(slowFrames == [0, 99, 100], "Slow sink must retain only two newest queued frames")

        slow.emit(.reconnecting(reason: "temporary"))
        await settle { if case .reconnecting = outputs.states[a.id] { return true }; return false }
        precondition(outputs.states[b.id] == .live && outputs.aggregateState == .live)
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
