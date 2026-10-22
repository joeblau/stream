import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import IOSurface
import StreamCore

extension CMSampleBuffer: @retroactive @unchecked Sendable {}

/// Intentionally opaque/misbehaving raw endpoint: append can return while it
/// keeps every private buffer forever. The healthy sibling retains only values.
actor PrivateIngressPublisher: Publisher {
    nonisolated let supportsSharedH264AAC: Bool
    nonisolated let events: AsyncStream<PublisherEvent>
    private nonisolated let eventsContinuation: AsyncStream<PublisherEvent>.Continuation
    private let retainsPixels: Bool
    private var retained: [CMSampleBuffer] = []
    private var times: [Int64] = []
    private var presentationSeconds: [Double] = []
    private var surfaces: [UInt32] = []
    private(set) var starts = 0
    init(retainsPixels: Bool = false, shared: Bool = false) {
        self.retainsPixels = retainsPixels; supportsSharedH264AAC = shared
        (events, eventsContinuation) = AsyncStream.makeStream(of: PublisherEvent.self)
    }
    func start(_ settings: StreamSettings) async throws { starts += 1; eventsContinuation.yield(.published) }
    func stop() async { /* deliberately retain previously escaped buffers */ }
    func pause() async {}
    func resume() async {}
    func configureEncodedInput() async -> Bool { supportsSharedH264AAC }
    func setOutputSize(_ size: CGSize, nativeShortEdge: Int) async {}
    func appendVideo(_ sample: CMSampleBuffer) async {
        times.append(sample.presentationTimeStamp.value)
        presentationSeconds.append(sample.presentationTimeStamp.seconds)
        if let image = sample.imageBuffer, let surface = CVPixelBufferGetIOSurface(image)?.takeUnretainedValue() {
            surfaces.append(IOSurfaceGetID(surface))
        }
        if retainsPixels { retained.append(sample) }
    }
    func snapshot() -> (times: [Int64], surfaces: [UInt32], presentationSeconds: [Double], retainedTags: [UInt8]) {
        (times, surfaces, presentationSeconds, retained.compactMap { sample in
            guard let image = sample.imageBuffer, CVPixelBufferLockBaseAddress(image, .readOnly) == kCVReturnSuccess else { return nil }
            defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
            return CVPixelBufferGetBaseAddress(image)?.load(as: UInt8.self)
        })
    }
    nonisolated func enqueueMic(_ sample: CMSampleBuffer) {}
    nonisolated func enqueueApp(_ sample: CMSampleBuffer) {}
    nonisolated func enqueueProgram(_ sample: CMSampleBuffer) {}
    func setMicVolume(_ volume: Double) async {}
    func setThermalCeiling(bitRateScale: Double, frameRateCap: Int) async {}
    func statsSnapshot() async -> LiveStats? { nil }
}

actor PrivateIngressInstallGate {
    private var first = true
    private(set) var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func waitOnce() async {
        guard first else { return }
        first = false; entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

@main struct PublisherPrivateIngressHarness {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            fatalError(message)
        }
    }
    @MainActor static func settle(_ condition: () async -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await condition()), ContinuousClock.now < deadline { await Task.yield() }
        let passed = await condition(); require(passed, "Owned publisher event did not settle")
    }
    static func sample(_ value: Int64, timescale: CMTimeScale = 30) throws -> CMSampleBuffer {
        var pixel: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        require(CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, attributes, &pixel) == kCVReturnSuccess, "Fixture allocation failed")
        guard let pixel else { throw CocoaError(.coderInvalidValue) }
        CVPixelBufferLockBaseAddress(pixel, [])
        memset(CVPixelBufferGetBaseAddress(pixel), Int32(value), CVPixelBufferGetDataSize(pixel))
        CVPixelBufferUnlockBaseAddress(pixel, [])
        var format: CMVideoFormatDescription?
        require(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixel, formatDescriptionOut: &format) == noErr, "Fixture format failed")
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: CMTime(value: value, timescale: timescale), decodeTimeStamp: .invalid)
        var result: CMSampleBuffer?
        require(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixel, formatDescription: format!, sampleTiming: &timing, sampleBufferOut: &result) == noErr, "Fixture sample failed")
        return result!
    }
    static var settings: StreamSettings {
        var settings = StreamSettings.default
        settings.outputProfile = OutputProfile(canvasWidth: 320, canvasHeight: 180, frameRate: 30)
        return settings
    }
    @MainActor static func retentionIsolation() async throws {
        let retained = PrivateIngressPublisher(retainsPixels: true), healthy = PrivateIngressPublisher(), replacement = PrivateIngressPublisher(retainsPixels: true)
        var publishers = [retained, healthy, replacement]
        let outputs = DestinationOutputController(factory: { _ in publishers.removeFirst() })
        let slow = StreamDestination(name: "Retaining endpoint"), fast = StreamDestination(name: "Healthy endpoint")
        require(outputs.start(slow, settings: settings, sourceSize: CGSize(width: 16, height: 16)), "Retaining endpoint not admitted")
        require(outputs.start(fast, settings: settings, sourceSize: CGSize(width: 16, height: 16)), "Healthy endpoint not admitted")
        await settle { outputs.liveCount == 2 }
        var sourceSurfaces: [Int64: UInt32] = [:]
        var sourceSamples: [CMSampleBuffer] = []
        for value in 1...20 {
            let source = try sample(Int64(value))
            sourceSamples.append(source)
            sourceSurfaces[Int64(value)] = IOSurfaceGetID(CVPixelBufferGetIOSurface(source.imageBuffer!)!.takeUnretainedValue())
            outputs.fanout.enqueueVideo(source)
            await settle { await healthy.snapshot().times.last == Int64(value) }
        }
        let old = await retained.snapshot(), good = await healthy.snapshot()
        require(old.times == [1, 2, 3, 4, 5, 6], "Retaining SDK escaped its six-buffer private bank")
        require(good.times == Array(1...20).map(Int64.init), "One full raw bank starved a healthy independent endpoint")
        require(old.surfaces.count == old.times.count && good.surfaces.count == good.times.count, "A private frame lost its IOSurface")
        // Compare corresponding simultaneously live frames. Numeric IOSurface
        // IDs from an already released healthy frame can be recycled later.
        for (time, surface) in zip(old.times, old.surfaces) {
            require(sourceSurfaces[time] != surface, "An original IOSurface escaped to retaining publisher")
            let peer = good.times.firstIndex(of: time)!
            require(good.surfaces[peer] != surface, "Independent publishers shared a private IOSurface")
        }
        for (time, surface) in zip(good.times, good.surfaces) {
            require(sourceSurfaces[time] != surface, "An original IOSurface escaped to healthy publisher")
        }
        withExtendedLifetime(sourceSamples) {}
        let diagnostics = await outputs.diagnosticsSnapshot()
        require((diagnostics.first { $0.id == slow.id.uuidString }?.privateVideoCapacityDrops ?? 0) >= 14, "Private-capacity drops were not attributed to retaining endpoint")
        require(diagnostics.first { $0.id == fast.id.uuidString }?.privateVideoCapacityDrops == 0, "Healthy endpoint was mislabeled capacity-limited")
        let firstBanks = RawVideoResourceCoordinator.shared.snapshot().banks.filter { $0.reservation.request.domain.workspace == outputs.rawVideoResourceWorkspaceID }
        let oldBank = firstBanks.first { $0.reservation.request.domain.outputID == slow.id.uuidString }!.reservation.bankGeneration
        outputs.stop(slow.id)
        await settle { outputs.states[slow.id] == .idle }
        require(outputs.start(slow, settings: settings, sourceSize: CGSize(width: 16, height: 16)), "Fresh raw generation not admitted")
        await settle { await replacement.starts == 1 }
        outputs.fanout.enqueueVideo(try sample(99))
        await settle { await replacement.snapshot().times.last == 99 }
        let new = await replacement.snapshot(), retainedAfterRestart = await retained.snapshot()
        require(retainedAfterRestart.retainedTags == old.retainedTags, "Restart overwrote a legally retained old IOSurface")
        require(Set(old.surfaces).isDisjoint(with: Set(new.surfaces)), "Restart reused an exposed old private bank")
        let banks = RawVideoResourceCoordinator.shared.snapshot().banks
        require(banks.first { $0.reservation.bankGeneration == oldBank }?.state == .quarantined, "Stopped exposed bank lost its charged quarantine")
        outputs.stopAll(); await settle { outputs.activeCount == 0 }
        print("PASS: actual controller/broker/private copy + opaque publisher retention isolates healthy raw sibling; per-endpoint capacity drops; old surfaces unchanged and charged across fresh-session restart")
    }
    @MainActor static func cancellationBeforeAcknowledgement() async {
        let old = PrivateIngressPublisher(), new = PrivateIngressPublisher()
        var publishers = [old, new]
        let outputs = DestinationOutputController(factory: { _ in publishers.removeFirst() })
        let base = outputs.frameDelivery, gate = PrivateIngressInstallGate()
        outputs.frameDelivery.install = { token, domain, generation, bank, sourceBank, sourceReceipt, transfer, canvas, cancellation, authorized, sink in
            await gate.waitOnce()
            return try await base.install(token, domain, generation, bank, sourceBank, sourceReceipt, transfer, canvas, cancellation, authorized, sink)
        }
        let destination = StreamDestination(name: "Delayed installation")
        require(outputs.start(destination, settings: settings, sourceSize: CGSize(width: 16, height: 16)), "First start not prepared")
        await settle { await gate.entered }
        let startsBeforeACK = await old.starts
        require(startsBeforeACK == 0, "Publisher started before broker installation ACK")
        outputs.stop(destination.id); await settle { outputs.states[destination.id] == .idle }
        require(outputs.start(destination, settings: settings, sourceSize: CGSize(width: 16, height: 16)), "Replacement not prepared")
        await settle { await new.starts == 1 }
        await gate.release()
        for _ in 0..<20 { await Task.yield() }
        let startsAfterRetiredACK = await old.starts
        require(startsAfterRetiredACK == 0, "Canceled late ACK started the retired publisher")
        require(outputs.states[destination.id] == .live, "Retired install cleanup removed replacement registration")
        outputs.stopAll(); await settle { outputs.activeCount == 0 }
        print("PASS: delayed installation cannot start before ACK; synchronous ticket cancellation and exact old lease cleanup preserve replacement session")
    }
    @MainActor static func distinctTimingRepresentations() async throws {
        let publisher = PrivateIngressPublisher()
        let outputs = DestinationOutputController(factory: { _ in publisher })
        let destination = StreamDestination(name: "Distinct media times")
        require(outputs.start(destination, settings: settings, sourceSize: CGSize(width: 16, height: 16)), "Timing endpoint not admitted")
        await settle { await publisher.starts == 1 }
        outputs.fanout.enqueueVideo(try sample(1, timescale: 30))
        await settle { await publisher.snapshot().times.count == 1 }
        outputs.fanout.enqueueVideo(try sample(1, timescale: 15))
        await settle { await publisher.snapshot().times.count == 2 }
        let values = await publisher.snapshot()
        require(values.presentationSeconds == [1.0 / 30, 1.0 / 15],
                "Equal CMTime value with different timescale selected an older source")
        outputs.stopAll(); await settle { outputs.activeCount == 0 }
        print("PASS: standalone frame identities are independent of equal CMTime integer values; both original timescales/PTS survive private transfer")
    }

    @MainActor static func atomicBatchAndCapability() async {
        var factories = 0
        let outputs = DestinationOutputController(factory: { _ in factories += 1; return PrivateIngressPublisher() })
        let first = StreamDestination(name: "Valid"), second = StreamDestination(name: "Invalid")
        var bodyRan = false
        let accepted = outputs.withPreparedVideoResources([
            .init(destination: first, settings: settings, sourceSize: CGSize(width: 16, height: 16)),
            .init(destination: second, settings: settings, sourceSize: CGSize(width: 5000, height: 16))
        ]) { bodyRan = true }
        require(!accepted && !bodyRan && factories == 0, "Batch admission failure crossed factory boundary")
        outputs.sharedEncodingEnabled = true; outputs.sharedSourceFrameRate = 30
        let count = RawVideoResourceCoordinator.shared.snapshot().banks.count
        require(!outputs.start(first, settings: settings, sourceSize: CGSize(width: 16, height: 16)), "Unsupported injected shared adapter silently used raw path")
        require(factories == 1, "Capability mismatch did not verify exact factory adapter")
        require(RawVideoResourceCoordinator.shared.snapshot().banks.count == count, "Never-exposed mismatch reservation was not refunded")
        print("PASS: whole manual resource batch fails before any factory; prospective shared capability mismatch fails locally and refunds only unexposed reservation")
    }
    @MainActor static func main() async throws {
        FileHandle.standardError.write(Data("BEGIN retentionIsolation\n".utf8))
        try await retentionIsolation()
        FileHandle.standardError.write(Data("BEGIN cancellationBeforeAcknowledgement\n".utf8))
        await cancellationBeforeAcknowledgement()
        FileHandle.standardError.write(Data("BEGIN distinctTimingRepresentations\n".utf8))
        try await distinctTimingRepresentations()
        FileHandle.standardError.write(Data("BEGIN atomicBatchAndCapability\n".utf8))
        await atomicBatchAndCapability()
        print("PASS: publisher private-ingress owned validation; no transport, provider, capture, system configuration or personal credentials")
    }
}
