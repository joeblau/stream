import CoreMedia
import CoreVideo
import Foundation
import IOSurface
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

final class FractionalPixelReceipt: @unchecked Sendable {
    private let lock = NSLock()
    private var sizes: [[Int]] = []
    func receive(_ frame: CompositedFrame) {
        lock.lock(); sizes.append([CVPixelBufferGetWidth(frame.pixelBuffer!), CVPixelBufferGetHeight(frame.pixelBuffer!)]); lock.unlock()
    }
    func valid() -> Bool { lock.lock(); defer { lock.unlock() }; return sizes == Array(repeating: [17, 18], count: 3) }
}

final class TransferRestartGate: @unchecked Sendable {
    let entered = ClockLatch()
    private let lock = NSLock()
    private var first = true
    private let release = DispatchSemaphore(value: 0)
    func pauseFirst() {
        lock.lock(); let pause = first; first = false; lock.unlock()
        if pause { entered.signal(); release.wait() }
    }
    func resume() { release.signal() }
}
final class RestartPixelReceipt: @unchecked Sendable {
    private let lock = NSLock()
    private var times: [Double] = [], sequences: [Int64] = [], pixels: [UInt8] = []
    func receive(_ frame: CompositedFrame) {
        let image = frame.pixelBuffer!
        CVPixelBufferLockBaseAddress(image, .readOnly)
        let red = CVPixelBufferGetBaseAddress(image)!.load(fromByteOffset: 2, as: UInt8.self)
        CVPixelBufferUnlockBaseAddress(image, .readOnly)
        lock.lock(); times.append(frame.presentationTime.seconds); sequences.append(frame.sequence); pixels.append(red); lock.unlock()
    }
    func valid() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return times.count == 2 && abs(times[0] - 1.0 / 30) < 0.000001 && abs(times[1] - 100.0 / 30) < 0.000001
            && sequences == [1, 1] && pixels.count == 2 && pixels[0] != pixels[1]
    }
}

final class EscapedPrivatePixels: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers: [CVPixelBuffer] = []
    private var surfaces: [IOSurfaceRef] = []
    private var originals: [Data] = []
    var count: Int { lock.lock(); defer { lock.unlock() }; return buffers.count }
    func receive(_ frame: CompositedFrame) {
        let image = frame.pixelBuffer!
        CMRemoveAllAttachments(frame.sampleBuffer)
        CVBufferRemoveAllAttachments(image)
        lock.lock(); defer { lock.unlock() }
        buffers.append(image)
        if let surface = CVPixelBufferGetIOSurface(image)?.takeUnretainedValue() { surfaces.append(surface) }
        originals.append(Self.bytes(image))
    }
    func unchanged() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return zip(buffers, originals).allSatisfy { Self.bytes($0.0) == $0.1 }
    }
    func aliases(_ other: CVPixelBuffer) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let surface = CVPixelBufferGetIOSurface(other)?.takeUnretainedValue() else { return false }
        return surfaces.contains { IOSurfaceGetID($0) == IOSurfaceGetID(surface) }
    }
    private static func bytes(_ image: CVPixelBuffer) -> Data {
        CVPixelBufferLockBaseAddress(image, .readOnly); defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        return Data(bytes: CVPixelBufferGetBaseAddress(image)!, count: CVPixelBufferGetBytesPerRow(image) * CVPixelBufferGetHeight(image))
    }
}

@main enum FrameDeliveryBrokerHarness {
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
        await engine.validationFrameDeliveryBarrier()
        await engine.validationFrameDeliveryBarrier(canvas: .secondary)
        await engine.validationFrameDeliveryBarrier(clean: true)
    }
    static func add(_ engine: CompositionEngine, token: UUID, plane: String, sink: @escaping CompositionEngine.FrameSink) async {
        if plane == "clean" { await engine.addCleanSink(token: token, capacity: 2, sink: sink) }
        else { await engine.addSink(token: token, capacity: 2, canvas: plane == "secondary" ? .secondary : .program, canvasSize: size, sink: sink) }
    }
    static func probe(_ engine: CompositionEngine, token: UUID, plane: String) async -> CompositionMailboxValidationProbe {
        await engine.validationMailboxProbe(token: token, canvas: plane == "secondary" ? .secondary : .program, clean: plane == "clean")!
    }
    /// Consumers deliberately escape BOTH extracted native storage and its
    /// surface beyond callback return, after removing every attachment. Their
    /// private banks fill; the compositor must still render every next frame.
    static func rawEscapes() async throws {
        let engine = await engine(), healthy = MailboxHealthySink(), workspace = UUID(), generation = UUID()
        let held = (0..<4).map { _ in EscapedPrivatePixels() }
        let tokens = (0..<5).map { _ in UUID() }
        let domains = (0..<5).map { StableFrameDomainID(workspace: workspace, kind: .validation, outputID: "raw-holder-\($0)", plane: .program) }
        let sourceRequest = try engine.sourceFrameResourceRequest(canvasSize: size)
        let requests = domains.map { RawVideoResourceRequest(domain: $0, descriptor: .init(width: 16, height: 16, capacity: 4), sessionGeneration: generation) }
        let receipt = try RawVideoResourceCoordinator.shared.reserveBatch(requests + [sourceRequest])
        let sourceChild = try receipt.selecting(domain: sourceRequest.domain)
        var children: [RawVideoResourceReceipt] = [], leases: [FrameDeliveryLease] = []
        for index in 0..<5 {
            let child = try receipt.selecting(domain: domains[index]); children.append(child)
            let lease = try await engine.installFrameDelivery(token: tokens[index], domain: domains[index], generation: generation,
                bank: child.banks[0], sourceBank: index == 0 ? sourceChild.banks[0] : nil,
                sourceReceipt: index == 0 ? sourceChild : nil, sink: { frame in
                    if index == 4 { healthy.receive(frame) } else { held[index].receive(frame) }
                })
            leases.append(lease)
        }
        // Stale preparation owners must not close the engine's adopted source.
        RawVideoResourceCoordinator.shared.rollback(sourceChild)
        RawVideoResourceCoordinator.shared.rollback(receipt)
        var probes: [CompositionMailboxValidationProbe] = []
        for token in tokens { probes.append(await probe(engine, token: token, plane: "program")) }
        for sequence in 1...12 {
            await render(engine, Int64(sequence))
            for probe in probes { await probe.barrier() }
        }
        let metrics = await engine.metricsSnapshot()
        var recipientDrops: [Int] = []
        for lease in leases.prefix(4) { recipientDrops.append(await engine.frameDeliveryStatistics(lease).privateCapacityDrops) }
        let observation = RawObservation(attempts: metrics.attempts, rendered: metrics.rendered, failed: metrics.failed,
            healthy: healthy.snapshot(), heldCounts: held.map { $0.count }, privateCapacityDrops: recipientDrops,
            unchangedPrivatePixels: held.allSatisfy { $0.unchanged() })
        if let directory = ProcessInfo.processInfo.environment["FRAME_DELIVERY_RECEIPT_DIR"] {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(observation).write(to: URL(fileURLWithPath: directory).appendingPathComponent("raw-escapes.json"), options: .atomic)
        }
        precondition(metrics.attempts == 12 && metrics.rendered == 12 && metrics.failed == 0 && healthy.snapshot() == Array(1...12).map(Int64.init),
            "Escaped private raw holders must not exhaust the compositor source pool4 or lose healthy frames")
        precondition(held.allSatisfy { $0.count == 4 && $0.unchanged() } && recipientDrops.allSatisfy { $0 >= 8 },
            "Each opaque holder must exhaust only its own admitted bank, with truthful recipient drops and immutable held pixels")
        for (index, lease) in leases.enumerated() {
            let final = await engine.removeFrameDelivery(lease)
            let repeated = await engine.removeFrameDelivery(lease)
            precondition(final == repeated && lease.finalStatistics == final && final.depth == 0)
            if index < 4 { precondition(final.privateCapacityDrops >= 8 && final.allocationFailures == 0 && final.conversionFailures == 0) }
        }
        for child in children { RawVideoResourceCoordinator.shared.rollback(child) }
        // Retired exposed storage remains charged, while actual allocation is
        // revoked even though extracted pixels/surfaces are still held here.
        precondition(children.allSatisfy { !$0.banks[0].isOpen })
        let restart = try RawVideoResourceCoordinator.shared.reserveBatch([.init(domain: domains[0], descriptor: requests[0].descriptor, sessionGeneration: UUID())])
        precondition(restart.banks[0].id != children[0].banks[0].id)
        let fresh = try restart.banks[0].allocatePixelBuffer()
        precondition(held.allSatisfy { !$0.aliases(fresh) && $0.unchanged() }, "Restart must never recycle old exposed alias storage")
        RawVideoResourceCoordinator.shared.rollback(restart)
        print("PASS raw-escapes: four independent retained native/surface holders fill private banks, all12 source renders and healthy deliveries continue at cap4; retired/restart storage isolated")
    }
    struct RawObservation: Codable {
        let attempts: Int, rendered: Int, failed: Int
        let healthy: [Int64], heldCounts: [Int], privateCapacityDrops: [Int]
        let unchangedPrivatePixels: Bool
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
    static func fractionalGeometry() async throws {
        let requested = CGSize(width: 16.5, height: 17.5), received = FractionalPixelReceipt()
        let engine = CompositionEngine(screenProvider: { nil }, cameraProvider: { nil },
            sourcePayloadProvider: { [:] }, overlayContextProvider: { .empty }, sceneRegistryProvider: { [:] },
            transitionRequestProvider: { nil }, annotationProvider: { .empty }, canvasSize: requested, frameRate: 30)
        let exited = ClockLatch()
        await engine.setValidationClockHooks(.init(onExit: { exited.signal() }))
        let scene = Scene(name: "Fractional source geometry", layers: [LayerNode(name: "Owned shape", payload: .shape(.init(fillColorHex: "#4070C0")), transform: .fullscreen)])
        await engine.prepareValidation(scene: scene, canvasSize: requested, frameRate: 30, at: .zero)
        await exited.wait()
        let sourceRequest = try engine.sourceFrameResourceRequest(canvasSize: requested)
        precondition(sourceRequest.descriptor.width == 17 && sourceRequest.descriptor.height == 18,
            "Source admission must round geometry exactly as the actual renderer")
        let domain = StableFrameDomainID(workspace: UUID(), kind: .validation, outputID: "fractional", plane: .program), generation = UUID(), token = UUID()
        let batch = try RawVideoResourceCoordinator.shared.reserveBatch([sourceRequest, .init(domain: domain,
            descriptor: .init(width: 17, height: 18, capacity: 4), sessionGeneration: generation)])
        let sourceChild = try batch.selecting(domain: sourceRequest.domain), child = try batch.selecting(domain: domain)
        let lease = try await engine.installFrameDelivery(token: token, domain: domain, generation: generation,
            bank: child.banks[0], sourceBank: sourceChild.banks[0], sourceReceipt: sourceChild, sink: { received.receive($0) })
        RawVideoResourceCoordinator.shared.rollback(batch); RawVideoResourceCoordinator.shared.rollback(sourceChild)
        let probe = await probe(engine, token: token, plane: "program")
        let compatibility = FractionalPixelReceipt(), compatibilityToken = UUID()
        await engine.addSink(token: compatibilityToken, sink: { compatibility.receive($0) })
        let compatibilityProbe = await self.probe(engine, token: compatibilityToken, plane: "program")
        for frame in 1...3 { await engine.renderValidationFrame(at: CMTime(value: Int64(frame), timescale: 30)); await engine.validationFrameDeliveryBarrier(); await probe.barrier(); await compatibilityProbe.barrier() }
        let metrics = await engine.metricsSnapshot()
        precondition(metrics.attempts == 3 && metrics.rendered == 3 && metrics.failed == 0 && received.valid() && compatibility.valid(),
            "Fractional canvas must retain actual rounded renderer output and healthy delivery")
        let reusedRequest = try engine.sourceFrameResourceRequest(canvasSize: requested)
        precondition(reusedRequest == sourceRequest)
        await engine.removeFrameDelivery(lease); await engine.removeSink(compatibilityToken); RawVideoResourceCoordinator.shared.rollback(child)
        print("PASS fractional-geometry: actual16.5x17.5 canvas renders/delivers17x18 three times using one rounded admitted source generation")
    }
    static func restartPublicationIdentity() async {
        let engine = await engine(), gate = TransferRestartGate(), receipt = RestartPixelReceipt(), token = UUID()
        await engine.addSink(token: token, sink: { receipt.receive($0) })
        let probe = await probe(engine, token: token, plane: "program")
        await engine.validationBeforeFrameTransfer { gate.pauseFirst() }
        // The first worker is paused before any source borrow. Restart keeps
        // the subscriber while resetting frame.sequence to1 at a new PTS.
        await engine.renderValidationFrame(at: CMTime(value: 1, timescale: 30))
        await gate.entered.wait()
        let exited = ClockLatch()
        await engine.setValidationClockHooks(.init(onExit: { exited.signal() }))
        let replacement = Scene(name: "Restart red", layers: [LayerNode(name: "Owned red", payload: .shape(.init(fillColorHex: "#F01020")), transform: .fullscreen)])
        await engine.prepareValidation(scene: replacement, canvasSize: size, frameRate: 30, at: .zero)
        await exited.wait()
        await engine.renderValidationFrame(at: CMTime(value: 100, timescale: 30))
        gate.resume()
        await engine.validationFrameDeliveryBarrier(); await probe.barrier()
        precondition(receipt.valid(), "Publication identity must preserve distinct old/new PTS and pixels when engine sequence resets")
        await engine.validationBeforeFrameTransfer(nil)
        await engine.removeSink(token)
        print("PASS restart-publication: two pending sequence1 frames retain their distinct PTS/pixels across actual Engine stop/restart")
    }
    static func replacementReceipt() async throws {
        let engine = await engine(), token = UUID(), workspace = UUID(), oldHolder = EscapedPrivatePixels(), healthy = MailboxHealthySink()
        let domain = StableFrameDomainID(workspace: workspace, kind: .validation, outputID: "replacement", plane: .program)
        let oldGeneration = UUID()
        let oldReceipt = try RawVideoResourceCoordinator.shared.reserveBatch([.init(domain: domain,
            descriptor: .init(width: 16, height: 16, capacity: 4), sessionGeneration: oldGeneration)])
        let old = try await engine.installFrameDelivery(token: token, domain: domain, generation: oldGeneration,
            bank: oldReceipt.banks[0], sink: { oldHolder.receive($0) })
        let oldProbe = await probe(engine, token: token, plane: "program")
        for sequence in 1...8 { await render(engine, Int64(sequence)); await oldProbe.barrier() }
        let before = await engine.frameDeliveryStatistics(old)
        precondition(before.privateCapacityDrops == 4)
        let generation = UUID()
        let receipt = try RawVideoResourceCoordinator.shared.reserveBatch([.init(domain: domain,
            descriptor: .init(width: 16, height: 16, capacity: 4), sessionGeneration: generation)])
        let next = try await engine.installFrameDelivery(token: token, domain: domain, generation: generation,
            bank: receipt.banks[0], sink: { healthy.receive($0) })
        let final = await engine.removeFrameDelivery(old)
        precondition(final.privateCapacityDrops == 4 && final == old.finalStatistics && oldProbe.snapshot().closed,
            "Same-token replacement must preserve the old lease's exact final drop receipt")
        let currentProbe = await probe(engine, token: token, plane: "program")
        await render(engine, 9); await currentProbe.barrier()
        precondition(healthy.snapshot() == [9] && !currentProbe.snapshot().closed && oldHolder.unchanged(),
            "Late old-lease removal must not close the replacement or recycle its predecessor's raw storage")
        let retained = await engine.frameDeliveryStatistics(old)
        precondition(retained == final)
        await engine.removeFrameDelivery(next)
        RawVideoResourceCoordinator.shared.rollback(oldReceipt); RawVideoResourceCoordinator.shared.rollback(receipt)
        print("PASS replacement-receipt: old lease keeps final exact private-drop receipt; late teardown leaves new same-token delivery active")
    }
    static func cancelledAdmission() async throws {
        let engine = await engine(), token = UUID(), ticket = FrameDeliveryCancellation()
        ticket.cancel()
        await engine.addSink(token: token, cancellation: ticket, sink: { _ in preconditionFailure("Canceled admission delivered") })
        let count = await engine.subscriberCount
        precondition(count == 0, "Canceled ticket must reject a late install without token history")
        print("PASS canceled-admission: explicit pending ticket rejects late registration without UUID history")
    }
    static func main() async throws {
        if CommandLine.arguments.contains("--fractional-geometry") { try await fractionalGeometry(); return }
        if CommandLine.arguments.contains("--sequence-negative-control") { await restartPublicationIdentity(); preconditionFailure("Sequence-only negative must fail") }
        try await rawEscapes()
        if CommandLine.arguments.contains("--negative-control") { preconditionFailure("Negative control must fail the unchanged raw-holder isolation assertion") }
        for plane in ["program", "secondary", "clean"] {
            try await lifecycle(plane: plane, replacement: false)
            try await lifecycle(plane: plane, replacement: true)
        }
        await crossCanvasToken()
        try await cancelledAdmission()
        try await replacementReceipt()
        await restartPublicationIdentity()
        // Retain all six actual clock-authority regressions in this same binary.
        await CompositionClockAuthorityHarness.stoppedTick()
        await CompositionClockAuthorityHarness.restartedTick(reconfigure: false)
        await CompositionClockAuthorityHarness.restartedTick(reconfigure: true)
        await CompositionClockAuthorityHarness.staleMissedDeadline(restart: false)
        await CompositionClockAuthorityHarness.staleMissedDeadline(restart: true)
        await CompositionClockAuthorityHarness.explicitValidation()
        print("PASS full raw-holder isolation, retired mailbox lifecycle, cancellation and six actual clock authority cases; no sustained capacity claim")
    }
}
