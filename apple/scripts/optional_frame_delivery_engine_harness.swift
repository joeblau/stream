import CoreGraphics
import CoreMedia
import Foundation
import StreamCore

/// The only retained media are private CGImage providers and owned bitmap bytes.
/// No studio, window, display, capture, audio graph, or network is constructed.
final class OwnedOptionalImages: @unchecked Sendable {
    private let lock = NSLock()
    private let converter = PreviewImageConverter()
    private var images: [CGImage] = []
    private var pixels: [[UInt8]] = []
    private var times: [Double] = []
    func receive(_ frame: CompositedFrame) {
        guard let image = converter.makeImage(frame), let pixel = Self.pixel(image) else {
            preconditionFailure("Actual private CGImage conversion failed")
        }
        lock.lock(); defer { lock.unlock() }
        images.append(image); pixels.append(pixel); times.append(frame.presentationTime.seconds)
    }
    struct Snapshot: Codable {
        var count: Int
        var pixels: [[UInt8]]
        var times: [Double]
        var unchanged: Bool
    }
    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return .init(count: images.count, pixels: pixels, times: times,
                     unchanged: zip(images, pixels).allSatisfy { Self.pixel($0.0) == $0.1 })
    }
    private static func pixel(_ image: CGImage) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = bytes.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(data: storage.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        let offset = ((image.height / 2) * image.width + image.width / 2) * 4
        return drawn ? Array(bytes[offset..<(offset + 4)]) : nil
    }
}

@main enum OptionalFrameDeliveryEngineHarness {
    struct Bank: Codable {
        var kind: String
        var output: String
        var state: String
        var capacity: Int
        var bytes: UInt64
    }
    struct Receipt: Codable {
        var scope: String
        var originalAttempts: Int
        var originalRendered: Int
        var originalFailed: Int
        var oldImages: OwnedOptionalImages.Snapshot
        var replacementImages: OwnedOptionalImages.Snapshot
        var healthyImages: OwnedOptionalImages.Snapshot
        var retiredCallbacksRefused: Bool
        var replacementBankIsFresh: Bool
        var sourceBankCapacity: Int
        var canceledPreparationRefunded: Bool
        var canceledRegistrationAbsent: Bool
        var concurrentStopBarrierCompleted: Bool
        var banks: [Bank]
    }
    static func require(_ condition: Bool, _ message: String) {
        precondition(condition, message)
    }
    static func entry(_ domain: StableFrameDomainID, _ generation: UUID) -> RawVideoResourceBudget.Entry? {
        RawVideoResourceCoordinator.shared.snapshot().banks.first {
            $0.reservation.request.domain == domain && $0.reservation.request.sessionGeneration == generation
        }
    }
    static func render(_ engine: CompositionEngine, _ sequence: Int64, probes: [CompositionMailboxValidationProbe]) async {
        await FrameDeliveryBrokerHarness.render(engine, sequence)
        for probe in probes { await probe.barrier() }
    }
    static func main() async throws {
        let engine = await FrameDeliveryBrokerHarness.engine()
        let workspace = UUID()
        let domain = StableFrameDomainID(workspace: workspace, kind: .monitor, outputID: "owned-monitor", plane: .program)
        let old = try OptionalFrameDelivery(engine: engine, domain: domain, width: 16, height: 16)
        let oldImages = OwnedOptionalImages()
        try await old.install { oldImages.receive($0) }
        let oldProbe = await FrameDeliveryBrokerHarness.probe(engine, token: old.token, plane: "program")
        let oldBank = entry(domain, old.generation)!
        require(try oldBank.reservation.request.descriptor.allocationThreshold(bytesPerBuffer: oldBank.reservation.bytesPerBuffer) == 5,
                "Monitor must admit exactly five private backing slots")
        for sequence in 1...12 { await render(engine, Int64(sequence), probes: [oldProbe]) }
        let before = await engine.metricsSnapshot()
        require(oldImages.snapshot().count == 5, "Retained deferred CGImages must exhaust only private bank5")
        require(before.attempts == 12 && before.rendered == 12 && before.failed == 0,
                "Private image retention must not pin original compositor source4")

        async let stopA: Void = old.finishAndWait()
        async let stopB: Void = old.finishAndWait()
        _ = await (stopA, stopB)
        require(oldProbe.snapshot().closed, "Both Stop callers must await exact broker removal")
        require(entry(domain, old.generation)?.state == .quarantined, "Exposed retired backing remains charged")

        let replacement = try OptionalFrameDelivery(engine: engine, domain: domain, width: 16, height: 16)
        let replacementImages = OwnedOptionalImages()
        try await replacement.install { replacementImages.receive($0) }
        let replacementProbe = await FrameDeliveryBrokerHarness.probe(engine, token: replacement.token, plane: "program")
        let replacementBank = entry(domain, replacement.generation)!
        let fresh = oldBank.reservation.bankGeneration != replacementBank.reservation.bankGeneration
        require(fresh, "New monitor session must not reuse exposed retired bank")
        await engine.updateScene(Scene(name: "Owned replacement", layers: [LayerNode(name: "Owned replacement pixels",
            payload: .shape(.init(fillColorHex: "#D02050")), transform: .fullscreen)]))
        for sequence in 13...15 { await render(engine, Int64(sequence), probes: [oldProbe, replacementProbe]) }
        require(replacementImages.snapshot().count == 3, "Exact new session must receive fresh frames")
        require(oldImages.snapshot().count == 5 && oldImages.snapshot().unchanged,
                "Retirement must reject old callbacks and preserve held old pixels")
        require(oldImages.snapshot().pixels.first != replacementImages.snapshot().pixels.first,
                "Replacement must carry actual changed Program pixels")
        require(oldImages.snapshot().times == (1...5).map { Double($0) / 30 }, "Original source PTS changed")
        require(replacementImages.snapshot().times == (13...15).map { Double($0) / 30 }, "Replacement source PTS changed")

        let healthyDomain = StableFrameDomainID(workspace: workspace, kind: .monitor, outputID: "owned-healthy", plane: .program)
        let healthy = try OptionalFrameDelivery(engine: engine, domain: healthyDomain, width: 16, height: 16)
        let healthyImages = OwnedOptionalImages()
        try await healthy.install { healthyImages.receive($0) }
        let healthyProbe = await FrameDeliveryBrokerHarness.probe(engine, token: healthy.token, plane: "program")
        let canceledDomain = StableFrameDomainID(workspace: workspace, kind: .monitor, outputID: "owned-canceled", plane: .program)
        let canceled = try OptionalFrameDelivery(engine: engine, domain: canceledDomain, width: 16, height: 16)
        let gate = ClockGate()
        let pending = Task {
            await gate.suspend()
            try await canceled.install { _ in preconditionFailure("Canceled preparation delivered") }
        }
        await gate.entered.wait(); pending.cancel(); gate.release()
        do { try await pending.value; preconditionFailure("Canceled install must fail") }
        catch is CancellationError {} catch { throw error }
        await canceled.finishAndWait()
        let refunded = entry(canceledDomain, canceled.generation) == nil
        let absent = await engine.validationMailboxProbe(token: canceled.token) == nil
        require(refunded && absent, "Canceled preparation must release unexposed bank and leave no registration")
        for sequence in 16...18 { await render(engine, Int64(sequence), probes: [replacementProbe, healthyProbe]) }
        require(healthyImages.snapshot().count == 3, "Canceled optional startup must not stop healthy endpoint")
        require(replacementImages.snapshot().count == 5, "Replacement remains bounded after its own five holders")
        let final = await engine.metricsSnapshot()
        require(final.attempts == 18 && final.rendered == 18 && final.failed == 0, "All original renders must complete")
        let source = RawVideoResourceCoordinator.shared.snapshot().banks.first {
            $0.reservation.request.domain.kind == .rendererSource && $0.state == .exposed
        }!
        let sourceCapacity = try source.reservation.request.descriptor.allocationThreshold(bytesPerBuffer: source.reservation.bytesPerBuffer)
        require(sourceCapacity == 4, "Original renderer source budget must remain four")
        await replacement.finishAndWait(); await healthy.finishAndWait(); await engine.stop()
        let banks = try RawVideoResourceCoordinator.shared.snapshot().banks.map { value in
            Bank(kind: value.reservation.request.domain.kind.rawValue, output: value.reservation.request.domain.outputID,
                 state: value.state.rawValue,
                 capacity: try value.reservation.request.descriptor.allocationThreshold(bytesPerBuffer: value.reservation.bytesPerBuffer),
                 bytes: value.reservation.reservedBytes)
        }.sorted { $0.output < $1.output }
        let receipt = Receipt(scope: "Actual OptionalFrameDelivery + synthetic CompositionEngine/SceneRenderer/broker/native CV/CGImage. Owned shape pixels and bitmap only; no StudioRuntime, window, display, capture, device, mixer, network, UI input, preference or performance qualification.",
            originalAttempts: final.attempts, originalRendered: final.rendered, originalFailed: final.failed,
            oldImages: oldImages.snapshot(), replacementImages: replacementImages.snapshot(), healthyImages: healthyImages.snapshot(),
            retiredCallbacksRefused: oldImages.snapshot().count == 5, replacementBankIsFresh: fresh,
            sourceBankCapacity: sourceCapacity, canceledPreparationRefunded: refunded, canceledRegistrationAbsent: absent,
            concurrentStopBarrierCompleted: oldProbe.snapshot().closed, banks: banks)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(receipt).write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
        print("PASS actual OptionalFrameDelivery: original18/18, private5, source4, fresh replacement, canceled startup, exact Stop")
    }
}
