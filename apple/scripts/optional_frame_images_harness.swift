import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import StreamCore

@MainActor private final class MemoryExternalSurface: ExternalDisplaySurface {
    var currentImage: CGImage?
    var closed = false
    func move(to display: ExternalDisplayDescriptor) {}
    func present(_ image: CGImage, scaling: ExternalDisplayScaling) { currentImage = image }
    func close() { currentImage = nil; closed = true }
}
@MainActor private final class HeldExternalSubscription {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { let pending = continuation; continuation = nil; pending?.resume() }
}
private enum OwnedImageFailure: Error { case image, sample, pixel, assertion(String) }

@main struct OptionalFrameImagesHarness {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw OwnedImageFailure.assertion(message) }
    }
    static func source(_ red: UInt8, width: Int = 16, height: Int = 8, sequence: Int64 = 1) throws -> CompositedFrame {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes, &buffer) == kCVReturnSuccess,
              let buffer else { throw OwnedImageFailure.pixel }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            for y in 0..<height { for x in 0..<width {
                let p = base.advanced(by: y * CVPixelBufferGetBytesPerRow(buffer) + x * 4).assumingMemoryBound(to: UInt8.self)
                p[0] = 192; p[1] = 128; p[2] = red; p[3] = 255
            } }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        var description: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer,
                formatDescriptionOut: &description) == noErr, let description else { throw OwnedImageFailure.sample }
        let pts = CMTime(value: sequence, timescale: 30), duration = CMTime(value: 1, timescale: 30)
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer,
                formatDescription: description, sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
              let sample else { throw OwnedImageFailure.sample }
        return .init(sampleBuffer: sample, presentationTime: pts, frameDuration: duration, sequence: sequence)
    }
    static func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { storage in
            guard let context = CGContext(data: storage.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw OwnedImageFailure.image
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        let offset = (y * image.width + x) * 4
        return Array(bytes[offset..<(offset + 4)])
    }
    static func request(_ name: String, width: Int, height: Int, capacity: Int = 5) -> RawVideoResourceRequest {
        .init(domain: .init(workspace: UUID(), kind: .validation, outputID: name, plane: .preview),
              descriptor: .init(width: width, height: height, capacity: capacity), sessionGeneration: UUID())
    }
    static func imageBankLifetime() throws -> [String: Any] {
        let request = request("owned-image-lifetime", width: 16, height: 8)
        let receipt = try RawVideoResourceCoordinator.shared.reserveBatch([request])
        defer { RawVideoResourceCoordinator.shared.rollback(receipt) }
        let bank = receipt.banks[0], converter = PreviewImageConverter()
        var images: [CGImage] = []
        for index in 0..<5 {
            try autoreleasepool {
                let original = try source(UInt8(32 + index * 16), sequence: Int64(index + 1))
                let copied = try FrameDeliveryConverter.copy(source: original.sampleBuffer, into: bank)
                let frame = CompositedFrame(sampleBuffer: copied,
                    presentationTime: original.presentationTime, frameDuration: original.frameDuration, sequence: original.sequence)
                guard let image = converter.makeImage(frame) else { throw OwnedImageFailure.image }
                let actual = try pixel(image, x: 8, y: 4)
                try require(abs(Int(actual[0]) - (32 + index * 16)) <= 2 && abs(Int(actual[1]) - 128) <= 2 && abs(Int(actual[2]) - 192) <= 2,
                            "Owned bitmap pixels must retain the private copied color")
                try require(CMSampleBufferGetPresentationTimeStamp(copied) == original.presentationTime,
                            "Private copy must preserve actual source PTS")
                images.append(image)
            }
        }
        var occupied = false
        do { _ = try bank.allocatePixelBuffer() }
        catch RawVideoResourceFailure.capacityOccupied { occupied = true }
        try require(occupied, "Five retained, rendered CGImages must still occupy their five private CV slots")
        images.removeAll()
        try autoreleasepool { _ = try bank.allocatePixelBuffer() }
        return ["retainedRenderedImages": 5, "sixthAllocationRefused": occupied,
                "releasedImagesAllowSameSessionReuse": true, "actualThreshold": bank.allocationThreshold]
    }
    static func externalLetterbox() throws -> CGImage {
        let request = request("owned-external-letterbox", width: 10, height: 20)
        let receipt = try RawVideoResourceCoordinator.shared.reserveBatch([request])
        defer { RawVideoResourceCoordinator.shared.rollback(receipt) }
        let input = try source(64), target = try receipt.banks[0].allocatePixelBuffer()
        let copied = try FrameDeliveryConverter().prepare(input.sampleBuffer, into: target, transfer: .aspectFitBGRA)
        let frame = CompositedFrame(sampleBuffer: copied, presentationTime: input.presentationTime,
                                    frameDuration: input.frameDuration, sequence: input.sequence)
        guard let image = ExternalProgramImageConverter().image(frame) else { throw OwnedImageFailure.image }
        let corner = try pixel(image, x: 0, y: 0), center = try pixel(image, x: 5, y: 10)
        try require(image.width == 10 && image.height == 20 && corner == [0, 0, 0, 255], "Selected canvas requires opaque black letterbox")
        try require(abs(Int(center[0]) - 64) <= 2 && abs(Int(center[1]) - 128) <= 2 && abs(Int(center[2]) - 192) <= 2,
                    "Selected canvas private pixels must retain source color")
        try require(CMSampleBufferGetPresentationTimeStamp(copied) == input.presentationTime, "External transfer must preserve source PTS")
        return image
    }
    @MainActor static func wait(_ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw OwnedImageFailure.assertion("Owned async boundary timed out") }
            await Task.yield()
        }
    }
    @MainActor static func handoff(_ image: CGImage) async throws -> [String: Any] {
        var received = 0
        let handoff = OptionalMonitorImageHandoff { _ in received += 1 }
        let completed = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            for _ in 0..<200 { handoff.enqueue(image) }
            completed.signal()
        }
        // Deliberately hold this owned MainActor phase; no nested event loop,
        // native input, or system UI is involved in the bounded stall.
        try require(completed.wait(timeout: .now() + 2) == .success, "Owned producer did not complete")
        let stalled = handoff.snapshot
        try require(stalled.pendingImages == 1 && stalled.queuedDrains == 1 && stalled.peakQueuedDrains == 1,
                    "Blocked MainActor must retain one latest image and one queued task")
        try await wait { received == 1 }
        handoff.enqueue(image); handoff.finish()
        for _ in 0..<20 { await Task.yield() }
        try require(received == 1 && handoff.snapshot.pendingImages == 0,
                    "A retired handoff cannot deliver its already queued image")
        return ["offeredDuringStall": 200, "pendingImages": stalled.pendingImages,
                "queuedMainActorDrains": stalled.queuedDrains, "peakQueuedDrains": stalled.peakQueuedDrains,
                "coalescedDeliveries": received, "retiredQueuedImageRefused": true]
    }
    @MainActor static func externalStartup(_ image: CGImage) async throws -> [String: Any] {
        let display = ExternalDisplayDescriptor(id: 99, name: "Owned memory descriptor", frame: CGRect(x: 0, y: 0, width: 32, height: 32),
            maximumFPS: 30, isBuiltIn: false, hostsStudio: false)
        let first = HeldExternalSubscription(), second = HeldExternalSubscription()
        var entered = 0, canceled = 0, factoryCalls = 0
        let surface = MemoryExternalSurface()
        var oldSink: (@Sendable (CGImage) -> Void)?
        let output = ExternalDisplayOutputController(screensProvider: { [display] }, surfaceFactory: { _ in
            factoryCalls += 1; return surface
        }, observeSystem: false, subscribe: { _, sink in
            entered += 1
            if entered == 1 { oldSink = sink; await first.wait() }
            else { await second.wait() }
            return { canceled += 1 }
        })
        let profile = OutputProfile(canvasWidth: 16, canvasHeight: 8, frameRate: 30)
        output.selectedDisplayID = display.id
        output.start(programProfile: profile)
        try await wait { first.entered }
        try require(output.isStarting && factoryCalls == 0, "No native surface before subscription ACK")
        output.stop()
        output.start(programProfile: profile)
        try await wait { second.entered }
        first.release()
        try await wait { canceled == 1 }
        try require(output.isStarting && factoryCalls == 0, "Late canceled ACK cannot allocate or activate")
        second.release()
        try await wait { output.isActive }
        try require(factoryCalls == 1, "Current ACK must allocate exactly one surface")
        oldSink?(image); output.presentLatest()
        try require(surface.currentImage == nil, "Old callback must not populate replacement session")
        output.stop()
        try require(canceled == 2 && surface.closed, "Stop must close exact current subscription and surface")
        var refusedFactories = 0
        let refused = ExternalDisplayOutputController(screensProvider: { [display] }, surfaceFactory: { _ in
            refusedFactories += 1; return MemoryExternalSurface()
        }, observeSystem: false, subscribe: { _, _ in throw RawVideoResourceFailure.budgetExceeded })
        refused.selectedDisplayID = display.id; refused.start(programProfile: profile)
        try await wait { !refused.isStarting }
        try require(refusedFactories == 0 && !refused.isActive, "Admission refusal must allocate no surface")
        var surfaceFailureCanceled = 0
        let unavailableSurface = ExternalDisplayOutputController(screensProvider: { [display] }, surfaceFactory: { _ in nil },
            observeSystem: false, subscribe: { _, _ in { surfaceFailureCanceled += 1 } })
        unavailableSurface.selectedDisplayID = display.id; unavailableSurface.start(programProfile: profile)
        try await wait { !unavailableSurface.isStarting }
        try require(surfaceFailureCanceled == 1 && !unavailableSurface.isActive, "Failed surface must cancel acknowledged subscription exactly once")
        return ["ackBeforeSurface": true, "lateCanceledAckRefused": true, "staleCallbackRefused": true,
                "factoryCalls": factoryCalls, "subscriptionCancellations": canceled,
                "admissionFailureFactories": refusedFactories, "failedSurfaceCancellations": surfaceFailureCanceled]
    }
    @MainActor static func main() async throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        let lifecycle = try imageBankLifetime()
        let image = try externalLetterbox()
        let coalescing = try await handoff(image)
        let startup = try await externalStartup(image)
        let report: [String: Any] = ["privateBankImageLifetime": lifecycle, "boundedMainActorHandoff": coalescing,
            "externalStartup": startup, "letterboxAndPTS": true,
            "scope": "Owned BGRA, actual CV banks/converters, owned bitmap and injected memory surface only; no window/display/device/capture/AX/keyboard/operator qualification"]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output)
        print("PASS owned private-bank CGImage lifetime, bounded MainActor handoff and external startup authority")
    }
}
