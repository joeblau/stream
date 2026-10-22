import CoreMedia
import CoreVideo
import Foundation
import StreamCore

/// Only owned serial sink queues block; continuations decide every boundary.
/// No elapsed-time polling or sleep decides whether a frame may proceed.
final class MailboxBlockedSink: @unchecked Sendable {
    let entered = ClockLatch()
    private let released = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var sequences: [Int64] = []
    func receive(_ frame: CompositedFrame) {
        lock.lock(); sequences.append(frame.sequence); let first = sequences.count == 1; lock.unlock()
        if first { entered.signal(); released.wait() }
        // Force the actual source pixel buffer to remain owned throughout wait.
        withExtendedLifetime(frame) {}
    }
    func release() { released.signal() }
    func snapshot() -> [Int64] { lock.lock(); defer { lock.unlock() }; return sequences }
}
final class MailboxHealthySink: @unchecked Sendable {
    private let lock = NSLock()
    private var sequences: [Int64] = []
    private var dimensions: [[Int]] = []
    func receive(_ frame: CompositedFrame) {
        lock.lock(); defer { lock.unlock() }
        sequences.append(frame.sequence)
        dimensions.append([CVPixelBufferGetWidth(frame.pixelBuffer!), CVPixelBufferGetHeight(frame.pixelBuffer!)])
    }
    func snapshot() -> [Int64] { lock.lock(); defer { lock.unlock() }; return sequences }
    func validDimensions() -> Bool { lock.lock(); defer { lock.unlock() }; return dimensions.allSatisfy { $0 == [16, 16] } }
}

@main enum CompositionMailboxRetirementHarness {
    static let size = CGSize(width: 16, height: 16)
    struct Observation: Codable {
        var stage: String
        var metrics: CompositionMetrics
        var a: CompositionMailboxValidationProbe.Snapshot
        var b: CompositionMailboxValidationProbe.Snapshot
        var healthy: [Int64]
        var callbacksA: [Int64]
        var callbacksB: [Int64]
    }
    static func save(_ name: String, _ observations: [Observation]) throws {
        guard let directory = ProcessInfo.processInfo.environment["COMPOSITION_MAILBOX_RECEIPT_DIR"] else { return }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(observations).write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".json"), options: .atomic)
    }
    static func engine() async -> CompositionEngine {
        let engine = CompositionEngine(screenProvider: { nil }, cameraProvider: { nil },
            sourcePayloadProvider: { [:] }, overlayContextProvider: { .empty }, sceneRegistryProvider: { [:] },
            transitionRequestProvider: { nil }, annotationProvider: { .empty }, canvasSize: size, frameRate: 30)
        let exit = ClockLatch()
        await engine.setValidationClockHooks(.init(onExit: { exit.signal() }))
        let scene = Scene(name: "Owned mailbox retention", layers: [LayerNode(name: "Owned solid shape", payload: .shape(.init(fillColorHex: "#4070C0")), transform: .fullscreen)])
        await engine.prepareValidation(scene: scene, canvasSize: size, frameRate: 30, at: .zero)
        await exit.wait()
        return engine
    }
    static func render(_ engine: CompositionEngine, _ sequence: Int64) async {
        await engine.renderValidationFrame(at: CMTime(value: sequence, timescale: 30))
    }
    static func add(_ engine: CompositionEngine, token: UUID, plane: String, sink: @escaping CompositionEngine.FrameSink) async {
        if plane == "clean" { await engine.addCleanSink(token: token, capacity: 2, sink: sink) }
        else { await engine.addSink(token: token, capacity: 2, canvas: plane == "secondary" ? .secondary : .program, canvasSize: size, sink: sink) }
    }
    static func probe(_ engine: CompositionEngine, token: UUID, plane: String) async -> CompositionMailboxValidationProbe {
        await engine.validationMailboxProbe(token: token, canvas: plane == "secondary" ? .secondary : .program, clean: plane == "clean")!
    }
    static func pressureRecovery() async throws {
        let engine = await engine(), a = MailboxBlockedSink(), b = MailboxBlockedSink(), healthy = MailboxHealthySink()
        let tokenA = UUID(), tokenB = UUID(), tokenHealthy = UUID()
        await engine.addSink(token: tokenHealthy, sink: { healthy.receive($0) })
        let healthyProbe = await probe(engine, token: tokenHealthy, plane: "program")
        await engine.addSink(token: tokenA, sink: { a.receive($0) })
        let probeA = await probe(engine, token: tokenA, plane: "program")
        await render(engine, 1); await a.entered.wait(); await healthyProbe.barrier()
        // B must own a different active source buffer from A.
        await engine.addSink(token: tokenB, sink: { b.receive($0) })
        let probeB = await probe(engine, token: tokenB, plane: "program")
        await render(engine, 2); await b.entered.wait(); await healthyProbe.barrier()
        await render(engine, 3); await healthyProbe.barrier()
        await render(engine, 4); await healthyProbe.barrier()
        precondition(probeA.snapshot().pendingSequences == [3, 4] && probeB.snapshot().pendingSequences == [3, 4])
        await render(engine, 5); await healthyProbe.barrier()
        var rows: [Observation] = []
        func observe(_ name: String, _ metrics: CompositionMetrics) {
            rows.append(.init(stage: name, metrics: metrics, a: probeA.snapshot(), b: probeB.snapshot(), healthy: healthy.snapshot(), callbacksA: a.snapshot(), callbacksB: b.snapshot()))
        }
        let starved = await engine.metricsSnapshot(); observe("four-known-owned-surfaces", starved)
        precondition(starved.attempts == 5 && starved.rendered == 4 && starved.failed == 1, "Actual four-surface pool must demonstrate the controlled pressure failure")
        await engine.removeSink(tokenA)
        await render(engine, 6); await healthyProbe.barrier()
        let stillOwned = await engine.metricsSnapshot(); observe("one-retired-other-pending-still-owns", stillOwned)
        precondition(stillOwned.rendered == 4 && stillOwned.failed == 2, "Retired active plus live pending still own all four source surfaces")
        await engine.removeSink(tokenB)
        await render(engine, 7); await healthyProbe.barrier()
        let recovered = await engine.metricsSnapshot(); observe("both-retired-active-still-blocked", recovered)
        try save("pressure-recovery", rows)
        // Release blocked callbacks even in the negative control before failing.
        a.release(); b.release(); await probeA.barrier(); await probeB.barrier()
        precondition(recovered.attempts == 7 && recovered.rendered == 5 && recovered.failed == 2,
            "Retiring pending mailbox ownership must restore healthy rendering before active callbacks return")
        precondition(probeA.snapshot().closed && probeB.snapshot().closed && probeA.snapshot().pendingSequences.isEmpty && probeB.snapshot().pendingSequences.isEmpty)
        precondition(a.snapshot() == [1] && b.snapshot() == [2], "Retired backlogs must never deliver after the in-flight callbacks finish")
        precondition(healthy.snapshot() == [1, 2, 3, 4, 7] && healthy.validDimensions())
        let stableA = probeA.snapshot(), stableB = probeB.snapshot()
        probeA.close(); probeA.close(); probeB.close()
        precondition(probeA.snapshot() == stableA && probeB.snapshot() == stableB, "Mailbox close must be idempotent")
        await engine.removeSink(tokenHealthy)
        print("PASS pressure-recovery: actual pool4 fails with four known holders; retiring pending restores healthy output while both old callbacks remain blocked")
    }
    static func lifecycle(plane: String, replacement: Bool) async throws {
        let engine = await engine(), blocked = MailboxBlockedSink(), healthy = MailboxHealthySink(), token = UUID()
        await add(engine, token: token, plane: plane, sink: { blocked.receive($0) })
        let old = await probe(engine, token: token, plane: plane)
        await render(engine, 1); await blocked.entered.wait()
        await render(engine, 2)
        precondition(old.snapshot().pendingSequences == [2])
        if replacement { await add(engine, token: token, plane: plane, sink: { healthy.receive($0) }) }
        else { await engine.removeSink(token) }
        let retired = old.snapshot()
        precondition(retired.closed && retired.pendingSequences.isEmpty && retired.drops == 1,
            "Removal/replacement must retire this canvas mailbox pending ownership")
        if replacement {
            let current = await probe(engine, token: token, plane: plane)
            await render(engine, 3); await current.barrier()
            precondition(healthy.snapshot() == [3] && healthy.validDimensions() && !current.snapshot().closed)
            await engine.removeSink(token)
            precondition(current.snapshot().closed)
        }
        blocked.release(); await old.barrier()
        precondition(blocked.snapshot() == [1], "Retired mailbox delivered queued frame after active return")
        print("PASS \(plane)-\(replacement ? "replacement" : "removal"): pending released, in-flight allowed to finish, no retired callbacks")
    }
    static func crossCanvasToken() async {
        let engine = await engine(), token = UUID()
        let a = MailboxHealthySink(), b = MailboxHealthySink(), c = MailboxHealthySink(), replacement = MailboxHealthySink()
        await add(engine, token: token, plane: "program", sink: { a.receive($0) })
        await add(engine, token: token, plane: "secondary", sink: { b.receive($0) })
        await add(engine, token: token, plane: "clean", sink: { c.receive($0) })
        let p = await probe(engine, token: token, plane: "program"), s = await probe(engine, token: token, plane: "secondary"), clean = await probe(engine, token: token, plane: "clean")
        await add(engine, token: token, plane: "program", sink: { replacement.receive($0) })
        let current = await probe(engine, token: token, plane: "program")
        precondition(p.snapshot().closed && !s.snapshot().closed && !clean.snapshot().closed)
        await render(engine, 1); await current.barrier(); await s.barrier(); await clean.barrier()
        precondition(a.snapshot().isEmpty && replacement.snapshot() == [1] && b.snapshot() == [1] && c.snapshot() == [1])
        await engine.removeSink(token)
        precondition(current.snapshot().closed && s.snapshot().closed && clean.snapshot().closed)
        print("PASS cross-canvas-token: same-canvas replacement preserves other planes; removal closes every registered plane")
    }
    static func main() async throws {
        try await pressureRecovery()
        if CommandLine.arguments.contains("--negative-control") { preconditionFailure("Negative control must fail the unchanged pressure recovery assertion") }
        for plane in ["program", "secondary", "clean"] {
            try await lifecycle(plane: plane, replacement: false)
            try await lifecycle(plane: plane, replacement: true)
        }
        await crossCanvasToken()
        // Retain all six actual clock-authority regressions in this same binary.
        await CompositionClockAuthorityHarness.stoppedTick()
        await CompositionClockAuthorityHarness.restartedTick(reconfigure: false)
        await CompositionClockAuthorityHarness.restartedTick(reconfigure: true)
        await CompositionClockAuthorityHarness.staleMissedDeadline(restart: false)
        await CompositionClockAuthorityHarness.staleMissedDeadline(restart: true)
        await CompositionClockAuthorityHarness.explicitValidation()
        print("PASS mailbox retirement + six actual clock authority cases; no sustained capacity claim")
    }
}
