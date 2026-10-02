import AppKit
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import StreamCore

@MainActor private final class FakeDisplaySurface: ExternalDisplaySurface {
    var moves: [ExternalDisplayDescriptor] = []
    var images: [CGImage] = []
    var framing: [ExternalDisplayScaling] = []
    var closed = false
    func move(to display: ExternalDisplayDescriptor) { moves.append(display) }
    func present(_ image: CGImage, scaling: ExternalDisplayScaling) { images.append(image); framing.append(scaling) }
    func close() { closed = true }
}
@MainActor private final class InjectedScreens {
    var values: [ExternalDisplayDescriptor]
    init(_ values: [ExternalDisplayDescriptor]) { self.values = values }
}
@main struct ExternalDisplayHarness {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let builtIn = ExternalDisplayDescriptor(id: 1, name: "Built-in", frame: CGRect(x: 0, y: 0, width: 1440, height: 900), maximumFPS: 120, isBuiltIn: true, hostsStudio: true)
        var external = ExternalDisplayDescriptor(id: 2, name: "Injected AirPlay Display", frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080), maximumFPS: 60, isBuiltIn: false, hostsStudio: false)
        let screens = InjectedScreens([builtIn, external])
        var surfaces: [FakeDisplaySurface] = [], subscriptions = 0, cancellations = 0
        var consumer: (@Sendable (CGImage) -> Void)?
        var requestedProfile: OutputProfile?
        let output = ExternalDisplayOutputController(screensProvider: { screens.values }, surfaceFactory: { _ in
            let surface = FakeDisplaySurface(); surfaces.append(surface); return surface
        }, observeSystem: false, subscribe: { profile, sink in
            requestedProfile = profile; consumer = sink; subscriptions += 1
            return { cancellations += 1 }
        })
        output.selectedDisplayID = 1
        output.start(programProfile: .default)
        precondition(!output.isActive && subscriptions == 0)
        output.selectedDisplayID = 2
        output.start(programProfile: .default)
        precondition(output.isActive && subscriptions == 1 && requestedProfile == nil)
        let image = try makeImage()
        let sample = try sampleBuffer()
        let frame = CompositedFrame(sampleBuffer: sample, presentationTime: CMTime(value: 42, timescale: 30), frameDuration: CMTime(value: 1, timescale: 30), sequence: 1)
        let raw = ExternalProgramImageConverter(profile: nil).image(frame)!
        precondition(raw.width == 16 && raw.height == 10 && raw.colorSpace?.name == CGColorSpace.sRGB)
        let converted = ExternalProgramImageConverter(profile: .init(canvasWidth: 10, canvasHeight: 20, frameRate: 30)).image(frame)!
        precondition(converted.width == 10 && converted.height == 20 && converted.colorSpace?.name == CGColorSpace.sRGB)
        let corner = pixel(converted, x: 0, y: 0), center = pixel(converted, x: 5, y: 10)
        precondition(corner[0] == 0 && corner[1] == 0 && corner[2] == 0 && corner[3] == 255, "Selected canvas needs opaque black letterboxing")
        precondition(abs(Int(center[0]) - 64) <= 2 && abs(Int(center[1]) - 128) <= 2 && abs(Int(center[2]) - 192) <= 2)
        precondition(CMSampleBufferGetPresentationTimeStamp(sample) == CMTime(value: 42, timescale: 30))
        for _ in 0..<100 { consumer?(image) }
        precondition(output.droppedImages == 99 && output.presentedImages == 0)
        output.presentLatest()
        precondition(output.presentedImages == 1 && surfaces[0].images.count == 1)
        output.scaling = .fill; consumer?(image); output.presentLatest()
        precondition(surfaces[0].framing == [.fit, .fill])
        external.frame = CGRect(x: -1920, y: -300, width: 2560, height: 1440)
        screens.values = [builtIn, external]; output.refreshDisplays()
        precondition(output.isActive && surfaces[0].moves.last?.frame == external.frame && cancellations == 0)
        screens.values = [builtIn]; output.refreshDisplays()
        precondition(!output.isActive && cancellations == 1 && surfaces[0].closed)
        // Old callbacks after disconnect cannot populate a new display session.
        consumer?(image); output.presentLatest(); precondition(output.presentedImages == 2)
        screens.values = [builtIn, external]; output.refreshDisplays()
        precondition(!output.isActive && subscriptions == 1)
        output.feed = .selectedCanvas
        output.start(programProfile: .default)
        precondition(!output.isActive && subscriptions == 1)
        let portrait = OutputProfile(canvasWidth: 1080, canvasHeight: 1920, frameRate: 30)
        output.start(programProfile: .default, selectedProfile: portrait)
        precondition(output.isActive && requestedProfile == portrait && subscriptions == 2)
        consumer?(image)
        let presentationDeadline = Date().addingTimeInterval(0.08)
        while Date() < presentationDeadline { _ = RunLoop.main.run(mode: .default, before: presentationDeadline) }
        precondition(output.presentedImages == 1, "Native pacing must present a new image once and skip empty ticks")
        external.hostsStudio = true; screens.values = [builtIn, external]; output.refreshDisplays()
        precondition(!output.isActive && cancellations == 2)
        external.hostsStudio = false; screens.values = [builtIn, external]; output.refreshDisplays()
        output.start(programProfile: .default, selectedProfile: .init(canvasWidth: 8192, canvasHeight: 8192, frameRate: 60))
        precondition(!output.isActive && subscriptions == 2)
        let allocationFailure = ExternalDisplayOutputController(screensProvider: { screens.values }, surfaceFactory: { _ in nil }, observeSystem: false, subscribe: { _, _ in fatalError("A failed surface must allocate no subscription") })
        allocationFailure.selectedDisplayID = 2; allocationFailure.start(programProfile: .default)
        precondition(!allocationFailure.isActive)
        let subscriptionFailureSurface = FakeDisplaySurface()
        let subscriptionFailure = ExternalDisplayOutputController(screensProvider: { screens.values }, surfaceFactory: { _ in subscriptionFailureSurface }, observeSystem: false, subscribe: { _, _ in nil })
        subscriptionFailure.selectedDisplayID = 2; subscriptionFailure.start(programProfile: .default)
        precondition(!subscriptionFailure.isActive && subscriptionFailureSurface.closed)
        let offscreen = ExternalDisplayDescriptor(id: 9, name: "Native offscreen", frame: CGRect(x: -20000, y: -20000, width: 640, height: 360), maximumFPS: 60, isBuiltIn: false, hostsStudio: false)
        let native = NativeExternalDisplaySurface(display: offscreen)!
        precondition(native.window.styleMask == .borderless && !native.window.canBecomeKey && !native.window.canBecomeMain && native.window.ignoresMouseEvents)
        precondition(native.window.contentView?.subviews.isEmpty == true)
        native.present(image, scaling: .fit)
        precondition(native.window.contentView?.layer?.contentsGravity == .resizeAspect)
        native.present(image, scaling: .fill)
        precondition(native.window.contentView?.layer?.contentsGravity == .resizeAspectFill)
        native.close()
        print("PASS: shipping native external-display controller/surface; injected AirPlay-style topology, independent start/stop, one-image bounded presentation and late callback rejection, fit/fill, rearrangement without resubscription, unplug/manual reconnect, studio-display exclusion, selected portrait canvas, size/resource failure cleanup, sRGB/letterbox conversion and unchanged PTS, native run-loop pacing, borderless video-only non-key surface; \(ProcessInfo.processInfo.operatingSystemVersionString)")
    }
    static func sampleBuffer() throws -> CMSampleBuffer {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, 16, 10, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess, let buffer else { throw NSError(domain: "DisplayHarness", code: 2) }
        CVPixelBufferLockBaseAddress(buffer, [])
        let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<10 { for x in 0..<16 {
            let offset = y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
            bytes[offset] = 192; bytes[offset + 1] = 128; bytes[offset + 2] = 64; bytes[offset + 3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format) == noErr, let format else { throw NSError(domain: "DisplayHarness", code: 3) }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: CMTime(value: 42, timescale: 30), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else { throw NSError(domain: "DisplayHarness", code: 4) }
        return sample
    }
    static func pixel(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = CIContext()
        bytes.withUnsafeMutableBytes { pointer in
            context.render(CIImage(cgImage: image), toBitmap: pointer.baseAddress!, rowBytes: 4,
                           bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        }
        return bytes
    }
    static func makeImage() throws -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: 16, height: 9, bitsPerComponent: 8, bytesPerRow: 64, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw NSError(domain: "DisplayHarness", code: 1) }
        context.setFillColor(CGColor(red: 0.25, green: 0.5, blue: 0.75, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 16, height: 9))
        return context.makeImage()!
    }
}
