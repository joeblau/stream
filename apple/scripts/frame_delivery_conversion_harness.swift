import CoreGraphics
import CoreMedia
import CoreMediaIO
import CoreVideo
import Foundation
import IOSurface
import StreamCore

private final class Counts: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Int] = [:]
    func add(_ key: String) { lock.lock(); values[key, default: 0] += 1; lock.unlock() }
    func get(_ key: String) -> Int { lock.lock(); defer { lock.unlock() }; return values[key, default: 0] }
}

private final class ProducerHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: VirtualCameraProducer?
    func set(_ producer: VirtualCameraProducer?) { lock.lock(); value = producer; lock.unlock() }
    func get() -> VirtualCameraProducer? { lock.lock(); defer { lock.unlock() }; return value }
}

private final class HeldConsumer: @unchecked Sendable {
    private let lock = NSLock()
    let release = DispatchSemaphore(value: 0)
    private var held: CMSampleBuffer?
    private var entered = false
    func receive(_ frame: CompositedFrame) {
        lock.lock()
        guard !entered else { lock.unlock(); return }
        entered = true; held = frame.sampleBuffer
        lock.unlock()
        release.wait()
    }
    var hasEntered: Bool { lock.lock(); defer { lock.unlock() }; return entered }
}

@MainActor private final class InstallGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

@main @MainActor struct FrameDeliveryConversionHarness {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func check(_ ok: Bool, _ message: String) throws { if !ok { throw Failure(description: message) } }

    static func sample(_ pixels: CVPixelBuffer, pts: CMTime = CMTime(value: 6000, timescale: 60),
                       duration: CMTime = CMTime(value: 1, timescale: 60), dts: CMTime = .invalid) throws -> CMSampleBuffer {
        var description: CMVideoFormatDescription?
        try check(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixels, formatDescriptionOut: &description) == noErr, "owned format")
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: pts, decodeTimeStamp: dts)
        var sample: CMSampleBuffer?
        try check(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixels,
            formatDescription: description!, sampleTiming: &timing, sampleBufferOut: &sample) == noErr, "owned sample")
        return sample!
    }

    static func paint(_ pixels: CVPixelBuffer) throws {
        try check(CVPixelBufferLockBaseAddress(pixels, []) == kCVReturnSuccess, "owned pixels writable")
        defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
        let bytes = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
        let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels), stride = CVPixelBufferGetBytesPerRow(pixels)
        memset(bytes, 0, stride * height)
        for y in 0..<height { for x in 0..<width {
            let offset = y * stride + x * 4
            bytes[offset + (x < width / 2 ? 2 : 1)] = 255
            bytes[offset + 3] = 255
        } }
    }

    static func rgb(_ sample: CMSampleBuffer, _ x: Int, _ y: Int) -> (Int, Int, Int) {
        let pixels = CMSampleBufferGetImageBuffer(sample)!
        CVPixelBufferLockBaseAddress(pixels, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        let bytes = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
        let offset = y * CVPixelBufferGetBytesPerRow(pixels) + x * 4
        return (Int(bytes[offset + 2]), Int(bytes[offset + 1]), Int(bytes[offset]))
    }

    static func bank(_ label: String, width: Int, height: Int, capacity: Int) throws -> RawVideoResourceBank {
        let domain = StableFrameDomainID(workspace: UUID(), kind: .validation, outputID: label, plane: .program)
        return try RawVideoResourceCoordinator.shared.reserveBatch([.init(domain: domain,
            descriptor: .init(width: width, height: height, capacity: capacity), sessionGeneration: UUID())]).banks[0]
    }

    @inline(never) static func offer(_ broker: FrameDeliveryBroker, source: RawVideoResourceBank, sequence: Int64) throws {
        let image = try source.allocatePixelBuffer(); try paint(image)
        let sample = try sample(image, pts: CMTime(value: 6000 + sequence, timescale: 60))
        broker.offer(.init(sampleBuffer: sample, presentationTime: sample.presentationTimeStamp,
            frameDuration: sample.duration, sequence: sequence))
    }

    static func wait(_ condition: @MainActor () -> Bool, _ label: String) async throws {
        for _ in 0..<1000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw Failure(description: "bounded wait: \(label)")
    }

    static func queue() throws -> CMSimpleQueue {
        var queue: CMSimpleQueue?
        try check(CMSimpleQueueCreate(allocator: nil, capacity: 2, queueOut: &queue) == noErr, "owned CMIO queue")
        return queue!
    }

    @inline(never) static func enqueueOwnedCamera(_ producer: VirtualCameraProducer, bank: RawVideoResourceBank) throws {
        let pixels = try bank.allocatePixelBuffer()
        producer.appendPrepared(try sample(pixels, duration: CMTime(value: 1, timescale: 30)))
    }

    static func main() async throws {
        let converter = FrameDeliveryConverter()
        let sourceBank = try bank("copy-source", width: 96, height: 48, capacity: 4)
        let source = try sourceBank.allocatePixelBuffer(); try paint(source)
        CVBufferSetAttachment(source, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        let original = try sample(source, dts: CMTime(value: 5999, timescale: 60))
        let metadata = RecordingChatPaint(slotID: "owned", messageID: "owned-message", fingerprint: String(repeating: "a", count: 64))
        RecordingChatPaint.attach([metadata], to: original)
        let copied = try FrameDeliveryConverter.copy(source: original, into: bank("copy-target", width: 96, height: 48, capacity: 4))
        try check(copied.presentationTimeStamp == original.presentationTimeStamp && copied.decodeTimeStamp == original.decodeTimeStamp && copied.duration == original.duration, "copy preserves exact PTS/DTS/duration")
        try check(rgb(copied, 20, 20).0 == 255 && rgb(copied, 70, 20).1 == 255, "copy preserves actual asymmetric pixels")
        try check(RecordingChatPaint.read(copied) == [metadata], "ShouldNotPropagate recorder paint retained as bounded values")
        let copiedPixels = copied.imageBuffer!
        try check(IOSurfaceGetID(CVPixelBufferGetIOSurface(source)!.takeUnretainedValue()) != IOSurfaceGetID(CVPixelBufferGetIOSurface(copiedPixels)!.takeUnretainedValue()), "copy owns a different actual IOSurface")
        do { _ = try converter.prepare(original, into: source, transfer: .copyBGRA); throw Failure(description: "alias accepted") }
        catch FrameDeliveryTransferError.aliasedStorage { }

        CVBufferSetAttachment(source, kCVImageBufferCGColorSpaceKey, CGColorSpaceCreateDeviceRGB(), .shouldPropagate)
        let deviceCopy = try FrameDeliveryConverter.copy(source: original, into: bank("device-rgb", width: 96, height: 48, capacity: 4))
        try check(CVBufferCopyAttachment(deviceCopy.imageBuffer!, kCVImageBufferCGColorSpaceKey, nil).map { CFEqual($0, CGColorSpaceCreateDeviceRGB()) } == true,
                  "generic copy retains the compositor's DeviceRGB contract")
        CVBufferSetAttachment(source, kCVImageBufferICCProfileKey, Data(repeating: 0, count: 16_385) as CFData, .shouldPropagate)
        do {
            _ = try converter.prepare(original, into: sourceBank.allocatePixelBuffer(), transfer: .copyBGRA)
            throw Failure(description: "oversize color metadata accepted")
        } catch FrameDeliveryTransferError.unsupportedFormat { }
        CVBufferRemoveAttachment(source, kCVImageBufferICCProfileKey)
        CVBufferSetAttachment(source, kCVImageBufferCGColorSpaceKey, "not-a-color-space" as CFString, .shouldPropagate)
        let malformedColor = CVBufferCopyAttachment(source, kCVImageBufferCGColorSpaceKey, nil)
        try check(malformedColor == nil || CFGetTypeID(malformedColor!) == CGColorSpace.typeID,
                  "Core Video refuses an ill-typed native color-space attachment")
        CVBufferSetAttachment(source, kCVImageBufferCGColorSpaceKey, CGColorSpaceCreateDeviceGray(), .shouldPropagate)
        let grayColor = CVBufferCopyAttachment(source, kCVImageBufferCGColorSpaceKey, nil)
        try check(grayColor != nil && CFGetTypeID(grayColor!) == CGColorSpace.typeID && unsafeDowncast(grayColor!, to: CGColorSpace.self).model == .monochrome,
                  "owned non-RGB color-space negative was actually installed")
        do {
            _ = try converter.prepare(original, into: sourceBank.allocatePixelBuffer(), transfer: .copyBGRA)
            throw Failure(description: "non-RGB color space accepted for BGRA copy")
        } catch FrameDeliveryTransferError.unsupportedFormat { }
        CVBufferSetAttachment(source, kCVImageBufferCGColorSpaceKey, CGColorSpaceCreateDeviceRGB(), .shouldPropagate)

        let fitBank = try bank("fit", width: 128, height: 128, capacity: 4)
        let fitted = try converter.prepare(original, into: fitBank.allocatePixelBuffer(), transfer: .aspectFitBGRA)
        try check(rgb(fitted, 64, 8) == (0, 0, 0) && rgb(fitted, 25, 64).0 > 245 && rgb(fitted, 100, 64).1 > 245, "actual shared/external aspect-fit black letterbox and sRGB pixels")
        try check(fitted.presentationTimeStamp == original.presentationTimeStamp && fitted.decodeTimeStamp == original.decodeTimeStamp, "fit keeps source clock")

        let cameraBank = try bank("camera", width: 1280, height: 720, capacity: 4), cameraCadence = FrameDeliveryCameraCadence()
        let camera = try converter.prepare(original, into: cameraBank.allocatePixelBuffer(),
            transfer: .virtualCameraBGRA(referenceCanvas: CGSize(width: 96, height: 96), cadence: cameraCadence))
        try check(rgb(camera, 640, 100) == (0, 0, 0) && rgb(camera, 400, 360).0 > 245 && rgb(camera, 880, 360).1 > 245, "camera preserves selected-canvas two-stage fit")
        try check(camera.presentationTimeStamp == original.presentationTimeStamp && camera.duration == CMTime(value: 1, timescale: 30) && !camera.decodeTimeStamp.isValid, "camera retains original PTS and negotiated 30fps timing")
        let q = try queue(), stops = Counts()
        let producer = try VirtualCameraProducer(validationQueue: q, format: .hd720, cadence: cameraCadence, stopStream: { stops.add("stop"); return noErr })
        producer.appendPrepared(camera)
        try check(CMSimpleQueueGetCount(q) == 1 && producer.statistics.sent == 1, "actual private camera sample enqueued")
        producer.appendPrepared(camera)
        try check(CMSimpleQueueGetCount(q) == 1, "camera duplicate/30fps pacing retained")
        let halfStep = try sample(source, pts: original.presentationTimeStamp + CMTime(value: 1, timescale: 60))
        do {
            _ = try converter.prepare(halfStep, into: cameraBank.allocatePixelBuffer(), transfer: .virtualCameraBGRA(referenceCanvas: nil, cadence: cameraCadence))
            throw Failure(description: "60fps duplicate converted before camera cadence gate")
        } catch FrameDeliveryTransferError.cadenceSkipped { }
        producer.appendPrepared(copied)
        try check(producer.statistics.dropped == 1, "camera refuses wrong prepared dimensions")
        let secondSource = try sample(source, pts: original.presentationTimeStamp + CMTime(value: 1, timescale: 30))
        let secondCamera = try converter.prepare(secondSource, into: cameraBank.allocatePixelBuffer(), transfer: .virtualCameraBGRA(referenceCanvas: nil, cadence: cameraCadence))
        producer.appendPrepared(secondCamera)
        let thirdSource = try sample(source, pts: original.presentationTimeStamp + CMTime(value: 2, timescale: 30))
        let thirdCamera = try converter.prepare(thirdSource, into: cameraBank.allocatePixelBuffer(), transfer: .virtualCameraBGRA(referenceCanvas: nil, cadence: cameraCadence))
        producer.appendPrepared(thirdCamera)
        try check(producer.statistics.sent == 2 && CMSimpleQueueGetCount(q) == 2 && cameraCadence.permits(thirdSource.presentationTimeStamp),
                  "failed full-queue enqueue does not advance the pre-conversion cadence")
        producer.stop(); producer.stop(); producer.appendPrepared(camera)
        try check(CMSimpleQueueGetCount(q) == 0 && stops.get("stop") == 1 && producer.statistics.sent == 2, "camera stop drains ownership and refuses late private frames")

        let failedQueue = try queue(), failedStops = Counts()
        let stopBank = try bank("stop-retained-bank4", width: 1280, height: 720, capacity: 4)
        let failedProducer = try VirtualCameraProducer(validationQueue: failedQueue, format: .hd720, stopStream: {
            failedStops.add("native-stop")
            return failedStops.get("allow-stop") == 0 ? -50 : noErr
        })
        failedProducer.bindRetirement(revoke: { failedStops.add("revoke") }, completion: { failedStops.add("cleanup") })
        try enqueueOwnedCamera(failedProducer, bank: stopBank)
        let occupied = try (0..<3).map { _ in try stopBank.allocatePixelBuffer() }
        try check(failedProducer.stop() == .unconfirmed(-50) && CMSimpleQueueGetCount(failedQueue) == 1,
                  "failed native stop leaves the actual queued sample pointer untouched")
        failedProducer.appendPrepared(camera)
        try check(failedProducer.stop() == .unconfirmed(-50) && failedStops.get("native-stop") == 1
                  && failedStops.get("revoke") == 1 && failedStops.get("cleanup") == 0 && CMSimpleQueueGetCount(failedQueue) == 1,
                  "failed stop revokes ingress, retains admission, and repeated default stop never retries")
        do { _ = try stopBank.allocatePixelBuffer(); throw Failure(description: "failed stop freed queued private storage") }
        catch RawVideoResourceFailure.capacityOccupied { }
        do { _ = try VirtualCameraProducer(validationQueue: queue(), format: .hd720); throw Failure(description: "fresh camera bypassed unconfirmed transport") }
        catch is VirtualCameraProducer.Failure { }
        failedStops.add("allow-stop")
        try check(failedProducer.stop(retry: true) == .confirmed && CMSimpleQueueGetCount(failedQueue) == 0
                  && failedStops.get("native-stop") == 2 && failedStops.get("cleanup") == 1,
                  "one explicit successful retry drains the old queue and completes its exact admission once")
        let reclaimed = try stopBank.allocatePixelBuffer()
        withExtendedLifetime((occupied, reclaimed)) {}

        let orphanQueue = try queue(), orphanStops = Counts()
        var orphan: VirtualCameraProducer? = try VirtualCameraProducer(validationQueue: orphanQueue, format: .hd720, stopStream: {
            orphanStops.add("native-stop"); return orphanStops.get("allow-stop") == 0 ? -51 : noErr
        })
        orphan!.bindRetirement(revoke: {}, completion: { orphanStops.add("cleanup") })
        orphan!.appendPrepared(camera)
        try check(orphan!.stop() == .unconfirmed(-51), "owned orphan enters failed retirement")
        orphan = nil
        try check(VirtualCameraProducer.hasUnconfirmedStop && orphanStops.get("native-stop") == 1
                  && orphanStops.get("cleanup") == 0 && CMSimpleQueueGetCount(orphanQueue) == 1,
                  "producer deinit preserves quarantined queue and admission without automatic retry")
        orphanStops.add("allow-stop")
        try check(VirtualCameraProducer.retryQuarantinedStop() == .confirmed && orphanStops.get("cleanup") == 1
                  && CMSimpleQueueGetCount(orphanQueue) == 0, "exact orphaned transport can be explicitly retired")

        let nativeGate = DispatchSemaphore(value: 0), heldStops = Counts(), holder = ProducerHolder()
        let heldProducer = try VirtualCameraProducer(validationQueue: queue(), format: .hd720, stopStream: {
            _ = holder.get()?.statistics // A synchronous callback can take the ingress lock.
            heldStops.add("entered")
            _ = nativeGate.wait(timeout: .now() + 2)
            return noErr
        })
        holder.set(heldProducer)
        let heldStop = Task.detached { heldProducer.stop() }
        try await wait({ heldStops.get("entered") == 1 }, "native stop reenters statistics without deadlock")
        try check(heldProducer.stop() == .inProgress, "overlapping stop does not create a second native call")
        do { _ = try VirtualCameraProducer(validationQueue: queue(), format: .hd720); throw Failure(description: "fresh camera bypassed held native stop") }
        catch is VirtualCameraProducer.Failure { }
        nativeGate.signal()
        try check(await heldStop.value == .confirmed, "held exact native stop confirms before replacement admission")
        holder.set(nil)
        let fourthSource = try sample(source, pts: original.presentationTimeStamp + CMTime(value: 3, timescale: 30))
        let cameraHeld = [camera, secondCamera, thirdCamera,
            try converter.prepare(fourthSource, into: cameraBank.allocatePixelBuffer(), transfer: .virtualCameraBGRA(referenceCanvas: nil))]
        do { _ = try cameraBank.allocatePixelBuffer(); throw Failure(description: "camera exceeded bank4") }
        catch RawVideoResourceFailure.capacityOccupied { }

        // Hold a real opaque-consumer callback while offering more source
        // frames. The source bank still admits its exact remaining two slots:
        // the callback can retain only private pixels, not a renderer borrow.
        let broker = FrameDeliveryBroker(), held = HeldConsumer()
        defer { held.release.signal() }
        let brokerSource = try bank("broker-source4", width: 96, height: 48, capacity: 4)
        let privateBank = try bank("broker-private4", width: 96, height: 48, capacity: 4)
        let request = privateBank.reservation.request, cancellation = FrameDeliveryCancellation()
        let lease = try broker.install(token: UUID(), domain: request.domain, generation: request.sessionGeneration,
            bank: privateBank, capacity: 1, cancellation: cancellation) { held.receive($0) }
        try offer(broker, source: brokerSource, sequence: 1)
        await broker.validationTransferBarrier()
        try await wait({ held.hasEntered }, "held private callback")
        for sequence: Int64 in 2...5 {
            try offer(broker, source: brokerSource, sequence: sequence)
            await broker.validationTransferBarrier()
        }
        let remainingOne = try brokerSource.allocatePixelBuffer(), remainingTwo = try brokerSource.allocatePixelBuffer()
        do { _ = try brokerSource.allocatePixelBuffer(); throw Failure(description: "source exceeded physical4") }
        catch RawVideoResourceFailure.capacityOccupied { }
        withExtendedLifetime((remainingOne, remainingTwo)) {}
        broker.remove(lease)
        held.release.signal()

        // Only selected native effects are inert: real controller admission,
        // prepared-bank checks, broker installation, queue lifecycle and late
        // completion fences all run. No device discovery or stream API runs.
        let failedFactories = Counts()
        let refused = VirtualCameraOutputController(observeSystem: false,
            deviceProbe: { fatalError("unexpected real device probe") }, producerFactory: { _, _ in
                failedFactories.add("factory"); throw Failure(description: "unreachable")
            }, prepare: { _, _ in throw FrameDeliveryFailure.invalidBank })
        refused.start(programAvailable: true)
        try check(failedFactories.get("factory") == 0 && !refused.isActive && !refused.isPreparing && refused.error != nil, "admission refusal precedes every native factory")

        let gate = InstallGate(), transport = Counts(), controllerBroker = FrameDeliveryBroker()
        let controllerSources = EngineSourceResources(), controllerWorkspace = UUID()
        var attempt = 0
        let controller = VirtualCameraOutputController(observeSystem: false,
            deviceProbe: { false }, producerFactory: { format, cadence in
                try check(transport.get("source-prepared") > transport.get("factory"), "source4 admitted before native factory")
                transport.add("factory")
                return try VirtualCameraProducer(validationQueue: queue(), format: format, cadence: cadence, stopStream: {
                    transport.add("stop"); return transport.get("allow-stop") == 0 ? -52 : noErr
                })
            }, prepare: { format, _ in
                attempt += 1; let isFirst = attempt == 1
                let size = CGSize(width: 96, height: 48)
                let sourceRequest = try controllerSources.request(size: size, canvas: .program, clean: false)
                let domain = StableFrameDomainID(workspace: controllerWorkspace, kind: .virtualCamera, outputID: "owned-camera", plane: .program)
                let request = RawVideoResourceRequest(domain: domain,
                    descriptor: .init(width: format.width, height: format.height, capacity: 4), sessionGeneration: UUID())
                let batch = try RawVideoResourceCoordinator.shared.reserveBatch([sourceRequest, request])
                let sourceBank = batch.bank(for: sourceRequest.domain)!, bank = batch.bank(for: domain)!
                let sourceReceipt = try batch.selecting(domain: sourceRequest.domain)
                let privateReceipt = try batch.selecting(domain: domain)
                transport.add("source-prepared")
                let ticket = FrameDeliveryCancellation(), token = UUID(), cadence = FrameDeliveryCameraCadence()
                let state = VirtualCameraFrameInstallState()
                return VirtualCameraFrameAdmission(bank: bank, cadence: cadence, install: { consume in
                    state.lease = try controllerBroker.install(token: token, domain: request.domain,
                        generation: request.sessionGeneration, bank: bank, transfer: .virtualCameraBGRA(referenceCanvas: nil, cadence: cadence),
                        capacity: 1, cancellation: ticket) { consume($0.sampleBuffer) }
                    try controllerSources.commit(sourceBank, receipt: sourceReceipt, size: size, canvas: .program, clean: false)
                    if isFirst { await gate.wait() }
                }, revoke: { ticket.cancel() }, cancel: {
                    ticket.cancel()
                    guard !state.cancelled else { return }; state.cancelled = true
                    transport.add("cancel")
                    if let lease = state.lease { controllerBroker.remove(lease) }
                    RawVideoResourceCoordinator.shared.rollback(sourceReceipt)
                    RawVideoResourceCoordinator.shared.rollback(privateReceipt)
                    RawVideoResourceCoordinator.shared.rollback(batch)
                })
            })
        controller.start(programAvailable: true)
        try await wait({ gate.entered }, "first installation ACK held")
        try check(controller.isPreparing && !controller.isActive, "camera remains preparing until actual install ACK")
        controller.stop(); controller.start(programAvailable: true)
        try check(controller.cleanupRequired && transport.get("factory") == 1 && transport.get("cancel") == 0,
                  "held-install stop failure retains admission and refuses fresh start before preparation")
        controller.refresh()
        try check(!controller.deviceAvailable && controller.cleanupRequired && transport.get("stop") == 1,
                  "discovery false is not a stop acknowledgement or an automatic retry")
        controller.removeExtension()
        try check(controller.activation == .unknown && controller.cleanupRequired && transport.get("stop") == 1,
                  "deactivation submission cannot bypass unconfirmed cleanup")
        transport.add("allow-stop"); controller.retryStop()
        try await wait({ transport.get("cancel") == 1 }, "confirmed old stop releases exact admission")
        controller.start(programAvailable: true)
        try await wait({ controller.isActive }, "fresh camera installation")
        gate.release()
        for _ in 0..<10 { await Task.yield() }
        try check(controller.isActive && !controller.isPreparing && transport.get("factory") == 2 && transport.get("stop") == 2, "late canceled ACK cannot stop or reactivate a replacement camera")
        controller.stop()
        try check(transport.get("stop") == 3, "replacement native lifetime closes once after old explicit retry")
        try await wait({ transport.get("cancel") == 2 }, "both exact controller admissions release")

        let installFailure = Counts()
        let rejected = VirtualCameraOutputController(observeSystem: false, deviceProbe: { false }, producerFactory: { format, cadence in
            try VirtualCameraProducer(validationQueue: queue(), format: format, cadence: cadence, stopStream: {
                installFailure.add("stop"); return installFailure.get("allow-stop") == 0 ? -53 : noErr
            })
        }, prepare: { format, _ in
            let resource = try bank("failed-install-bank", width: format.width, height: format.height, capacity: 4)
            return VirtualCameraFrameAdmission(bank: resource, cadence: FrameDeliveryCameraCadence(), install: { _ in
                throw Failure(description: "owned install rejection")
            }, revoke: { installFailure.add("revoke") }, cancel: { installFailure.add("cleanup") })
        })
        rejected.start(programAvailable: true)
        try await wait({ rejected.cleanupRequired }, "install rejection retains failed native stop")
        try check(!rejected.isActive && !rejected.isPreparing && installFailure.get("cleanup") == 0,
                  "install-failure catch does not release unconfirmed transport admission")
        rejected.shutdown()
        try check(installFailure.get("stop") == 1, "shutdown does not retry a previously failed stop")
        installFailure.add("allow-stop"); rejected.retryStop()
        try await wait({ installFailure.get("cleanup") == 1 }, "failed-install admission retires after explicit success")
        withExtendedLifetime(cameraHeld) {}
        print("PASS: actual admitted private BGRA/IOSurface copy, unchanged clocks and bounded recording metadata, completed fit/sRGB/camera conversion, camera bank4, real CMSimpleQueue pacing/drain, failed-stop pointer/private-storage/admission retention, explicit retry, orphaned transport, reentrant/held native stop, real broker source4 available during held callback, pre-factory refusal, failed install and stale ACK restart fences. Selected CMIO effects inert; no device/session/activation/capture/network APIs executed.")
    }
}
