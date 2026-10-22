import CoreMedia
import CoreVideo
import Foundation
import StreamCore

/// Continuations, not time, decide when the actual clock may proceed. These
/// latches deliberately resume canceled tasks: cancellation is what we test.
final class ClockLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if signaled { lock.unlock(); continuation.resume() }
            else { waiters.append(continuation); lock.unlock() }
        }
    }
    func signal() {
        lock.lock(); signaled = true
        let pending = waiters; waiters.removeAll(); lock.unlock()
        for waiter in pending { waiter.resume() }
    }
}
final class ClockGate: Sendable {
    let entered = ClockLatch()
    private let released = ClockLatch()
    func suspend() async { entered.signal(); await released.wait() }
    func release() { released.signal() }
}
final class OwnedClockSource: @unchecked Sendable {
    private let lock = NSLock()
    private let pixels: CVPixelBuffer
    private var pulls = 0
    private var overridePulls = 0
    private var keys: [String] = []
    private var skipped = 0
    private var dimensions: [Int] = []
    private var duration = 0.0
    let delivered = ClockLatch()
    init() {
        var buffer: CVPixelBuffer?
        precondition(CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess)
        pixels = buffer!
        CVPixelBufferLockBaseAddress(pixels, [])
        memset(CVPixelBufferGetBaseAddress(pixels), 127, CVPixelBufferGetDataSize(pixels))
        CVPixelBufferUnlockBaseAddress(pixels, [])
    }
    func pull(_ key: CaptureSourceKey) -> CVPixelBuffer {
        lock.lock(); pulls += 1; keys.append(String(describing: key)); lock.unlock()
        return pixels
    }
    func override() -> Scene? { lock.lock(); overridePulls += 1; lock.unlock(); return nil }
    func noteSkipped(_ count: Int) { lock.lock(); skipped = count; lock.unlock() }
    func receive(_ frame: CompositedFrame) {
        lock.lock()
        dimensions = [CVPixelBufferGetWidth(frame.pixelBuffer!), CVPixelBufferGetHeight(frame.pixelBuffer!)]
        duration = frame.frameDuration.seconds
        lock.unlock(); delivered.signal()
    }
    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(pulls: pulls, overridePulls: overridePulls, keys: keys,
                        skipped: skipped, dimensions: dimensions, duration: duration)
    }
    struct Snapshot: Equatable, Codable {
        var pulls: Int
        var overridePulls: Int
        var keys: [String]
        var skipped: Int
        var dimensions: [Int]
        var duration: Double
    }
}

@main enum CompositionClockAuthorityHarness {
    static let size = CGSize(width: 16, height: 16)
    static func scene(_ name: String) -> Scene {
        Scene(name: name, layers: [LayerNode(name: "Owned pixels", payload: .screen(.init(targetIdentifier: name)), transform: .fullscreen)])
    }
    static func engine(_ source: OwnedClockSource) -> CompositionEngine {
        CompositionEngine(screenProvider: { nil }, cameraProvider: { nil },
            frameLookup: SourceFrameLookup(camera: { _ in nil }, screen: { source.pull($0) }),
            sourcePayloadProvider: { [:] }, overlayContextProvider: { .empty }, sceneRegistryProvider: { [:] },
            transitionRequestProvider: { nil }, stingerProvider: { .inactive }, annotationProvider: { .empty },
            canvasSize: size, frameRate: 30, frameOverrideProvider: { source.override() })
    }
    struct Observation: Codable {
        var before: CompositionMetrics
        var after: CompositionMetrics
        var sourceBefore: OwnedClockSource.Snapshot
        var sourceAfter: OwnedClockSource.Snapshot
    }
    static func observe(_ name: String, before: CompositionMetrics, after: CompositionMetrics,
                        sourceBefore: OwnedClockSource.Snapshot, sourceAfter: OwnedClockSource.Snapshot) {
        guard let directory = ProcessInfo.processInfo.environment["COMPOSITION_CLOCK_RECEIPT_DIR"] else { return }
        let url = URL(fileURLWithPath: directory).appendingPathComponent(name + ".json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try! encoder.encode(Observation(before: before, after: after,
            sourceBefore: sourceBefore, sourceAfter: sourceAfter)).write(to: url, options: .atomic)
    }
    static func equal(_ before: CompositionMetrics, _ after: CompositionMetrics, _ message: String) {
        precondition(before.attempts == after.attempts && before.rendered == after.rendered
            && before.failed == after.failed && before.missedDeadlines == after.missedDeadlines
            && before.totalRenderMilliseconds == after.totalRenderMilliseconds
            && before.maxRenderMilliseconds == after.maxRenderMilliseconds
            && before.lastPresentationSeconds == after.lastPresentationSeconds, message)
    }
    static func stoppedTick() async {
        let source = OwnedClockSource(), gate = ClockGate(), exited = ClockLatch()
        let engine = engine(source)
        await engine.setValidationClockHooks(.init(beforeTick: { await gate.suspend() }, onExit: { exited.signal() }))
        await engine.run(scene: scene("owned-stop"), canvasSize: size, frameRate: 30)
        await gate.entered.wait()
        await engine.stop()
        let metrics = await engine.metricsSnapshot(), pulls = source.snapshot()
        gate.release(); await exited.wait()
        let after = await engine.metricsSnapshot()
        observe("stopped-tick", before: metrics, after: after, sourceBefore: pulls, sourceAfter: source.snapshot())
        equal(metrics, after, "Stopped clock changed metrics after cancellation")
        precondition(source.snapshot() == pulls, "Stopped clock pulled a source after cancellation")
        print("PASS stopped-tick: real canceled clock entered after stop; no metric/provider mutation")
    }
    static func restartedTick(reconfigure: Bool) async {
        let source = OwnedClockSource(), old = ClockGate(), oldExit = ClockLatch()
        let current = ClockGate(), currentDone = ClockGate(), currentExit = ClockLatch()
        let engine = engine(source)
        await engine.setValidationClockHooks(.init(beforeTick: { await old.suspend() }, onExit: { oldExit.signal() }))
        await engine.run(scene: scene("owned-old"), canvasSize: size, frameRate: 30)
        await old.entered.wait()
        await engine.setValidationClockHooks(.init(beforeTick: { await current.suspend() }, afterIteration: { await currentDone.suspend() }, onExit: { currentExit.signal() }))
        let outputSize = reconfigure ? CGSize(width: 32, height: 32) : size
        if reconfigure { await engine.setOutput(canvasSize: outputSize, frameRate: 60) }
        else { await engine.run(scene: scene("owned-current"), canvasSize: outputSize, frameRate: 30) }
        await current.entered.wait()
        let metrics = await engine.metricsSnapshot(), pulls = source.snapshot()
        old.release(); await oldExit.wait()
        let after = await engine.metricsSnapshot()
        observe(reconfigure ? "reconfigure" : "restarted-tick", before: metrics, after: after,
                sourceBefore: pulls, sourceAfter: source.snapshot())
        equal(metrics, after, "Retired clock changed replacement metrics")
        precondition(source.snapshot() == pulls, "Retired clock pulled replacement source")
        let sink = UUID()
        await engine.addSink(token: sink, sink: { source.receive($0) })
        current.release(); await currentDone.entered.wait(); await source.delivered.wait()
        let active = await engine.metricsSnapshot(), activeSource = source.snapshot()
        precondition(active.attempts == metrics.attempts + 1 && active.rendered == metrics.rendered + 1,
                     "Current clock must render exactly one actual frame")
        precondition(activeSource.pulls == pulls.pulls + 1 && activeSource.overridePulls == pulls.overridePulls + 1)
        precondition(activeSource.dimensions == [Int(outputSize.width), Int(outputSize.height)])
        precondition(abs(activeSource.duration - 1.0 / (reconfigure ? 60 : 30)) < 1e-9)
        if !reconfigure { precondition(activeSource.keys.last!.contains("owned-current"), "Current run must resolve its own scene") }
        await engine.stop(); currentDone.release(); await currentExit.wait()
        await engine.removeSink(sink)
        print("PASS \(reconfigure ? "reconfigure" : "restarted-tick"): old real task rejected; current frame keeps actual source/geometry/duration")
    }
    static func staleMissedDeadline(restart: Bool) async {
        let source = OwnedClockSource(), old = ClockGate(), oldExit = ClockLatch()
        let current = ClockGate(), currentDone = ClockGate(), currentExit = ClockLatch()
        let engine = engine(source)
        await engine.setValidationClockHooks(.init(initialDeadlineOffset: .seconds(-1),
            beforeMissedDeadlines: { count in source.noteSkipped(count); await old.suspend() }, onExit: { oldExit.signal() }))
        await engine.run(scene: scene("owned-missed-old"), canvasSize: size, frameRate: 30)
        await old.entered.wait()
        precondition(source.snapshot().skipped > 0, "Actual production schedule must produce a positive skip count")
        let first = await engine.metricsSnapshot()
        precondition(first.attempts == 1 && first.rendered == 1 && first.missedDeadlines == 0)
        if restart {
            await engine.setValidationClockHooks(.init(beforeTick: { await current.suspend() }, afterIteration: { await currentDone.suspend() }, onExit: { currentExit.signal() }))
            await engine.run(scene: scene("owned-missed-current"), canvasSize: size, frameRate: 30)
            await current.entered.wait()
        } else { await engine.stop() }
        let metrics = await engine.metricsSnapshot(), pulls = source.snapshot()
        old.release(); await oldExit.wait()
        let after = await engine.metricsSnapshot()
        observe(restart ? "restarted-missed" : "stopped-missed", before: metrics, after: after,
                sourceBefore: pulls, sourceAfter: source.snapshot())
        equal(metrics, after, "Retired clock changed missed-deadline metrics")
        precondition(source.snapshot() == pulls, "Retired deadline operation pulled a source")
        if restart {
            current.release(); await currentDone.entered.wait()
            let active = await engine.metricsSnapshot()
            precondition(active.attempts == 1 && active.rendered == 1)
            await engine.stop(); currentDone.release(); await currentExit.wait()
        }
        print("PASS \(restart ? "restarted" : "stopped")-missed: positive real schedule result cannot mutate retired/new metrics")
    }
    static func explicitValidation() async {
        let source = OwnedClockSource(), exited = ClockLatch(), engine = engine(source)
        await engine.setValidationClockHooks(.init(onExit: { exited.signal() }))
        await engine.prepareValidation(scene: scene("owned-explicit"), canvasSize: size, frameRate: 30, at: CMTime(seconds: 10, preferredTimescale: 30))
        await exited.wait()
        await engine.renderValidationFrame(at: CMTime(seconds: 11, preferredTimescale: 30))
        let gate = ClockGate()
        let canceled = Task {
            await gate.suspend()
            await engine.renderValidationFrame(at: CMTime(seconds: 12, preferredTimescale: 30))
        }
        await gate.entered.wait(); canceled.cancel(); gate.release(); await canceled.value
        let metrics = await engine.metricsSnapshot()
        precondition(metrics.attempts == 2 && metrics.rendered == 2 && source.snapshot().pulls == 2)
        precondition(metrics.lastPresentationSeconds == 12, "Explicit validation must retain its requested timestamp")
        print("PASS explicit-validation: synchronous rendering remains available after clock stop and from canceled fixture caller")
    }
    static func main() async {
        let requested = CommandLine.arguments.dropFirst().first
        switch requested {
        case "stopped-tick": await stoppedTick()
        case "restarted-tick": await restartedTick(reconfigure: false)
        case "reconfigure": await restartedTick(reconfigure: true)
        case "stopped-missed": await staleMissedDeadline(restart: false)
        case "restarted-missed": await staleMissedDeadline(restart: true)
        case nil:
            await stoppedTick(); await restartedTick(reconfigure: false)
            await restartedTick(reconfigure: true)
            await staleMissedDeadline(restart: false); await staleMissedDeadline(restart: true)
            await explicitValidation()
        default: preconditionFailure("Unknown clock-authority case")
        }
    }
}
