import AppKit
import Darwin
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers
import ScreenCaptureKit
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
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let actualDisplays = ExternalDisplayOutputController.systemDisplays()
        precondition(actualDisplays.allSatisfy(\.hostsStudio), "Unattached studio identity must not guess from the key window")
        let shellFrame = CGRect(x: -24000, y: -24000, width: 400, height: 300)
        let shell = NSWindow(contentRect: shellFrame, styleMask: .titled, backing: .buffered, defer: false)
        shell.isReleasedWhenClosed = false
        defer { shell.close() }
        ExternalDisplayOutputController.attachStudioWindow(shell)
        precondition(ExternalDisplayOutputController.hostsStudio(shell.frame))
        let adjacent = CGRect(x: shell.frame.maxX - 1, y: shell.frame.minY, width: 400, height: 300)
        precondition(ExternalDisplayOutputController.hostsStudio(adjacent), "Protect every display intersected by studio controls")
        let settings = NSWindow(contentRect: CGRect(x: -18000, y: -18000, width: 200, height: 200), styleMask: .titled, backing: .buffered, defer: false)
        settings.isReleasedWhenClosed = false
        defer { settings.close() }
        settings.makeKey()
        precondition(!ExternalDisplayOutputController.hostsStudio(settings.frame), "A settings key window cannot retarget studio display ownership")
        let builtIn = ExternalDisplayDescriptor(id: 1, name: "Built-in", frame: CGRect(x: 0, y: 0, width: 1440, height: 900), maximumFPS: 120, isBuiltIn: true, hostsStudio: true)
        var external = ExternalDisplayDescriptor(id: 2, name: "Injected external descriptor", frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080), maximumFPS: 60, isBuiltIn: false, hostsStudio: false)
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
        let ceiling = OutputProfile(canvasWidth: 1920, canvasHeight: 1080, frameRate: 60)
        precondition(CompositorWorkloadBudget.cleanStartError(program: ceiling, secondary: nil, qualified: true) == nil)
        precondition(CompositorWorkloadBudget.cleanStartError(program: ceiling, secondary: nil, qualified: false) != nil)
        precondition(CompositorWorkloadBudget.cleanStartError(program: ceiling, secondary: .init(canvasWidth: 2, canvasHeight: 2, frameRate: 1), qualified: true) != nil)
        precondition(CompositorWorkloadBudget.secondaryStartError(program: ceiling, secondary: ceiling, cleanDemanded: false) == nil)
        precondition(CompositorWorkloadBudget.secondaryStartError(program: ceiling, secondary: ceiling, cleanDemanded: true) != nil)
        let denied = ExternalDisplayOutputController(screensProvider: { screens.values }, surfaceFactory: { _ in fatalError("Budget rejection allocated a surface") }, observeSystem: false, startError: { _ in "Measured compositor budget refusal" }, subscribe: { _, _ in fatalError("Budget rejection subscribed") })
        denied.selectedDisplayID = 2; denied.feed = .clean; denied.start(programProfile: .default)
        precondition(denied.state == .failed("Measured compositor budget refusal"))
        let permit = ExternalCleanRenderPermit(); precondition(permit.isActive); permit.finish(); precondition(!permit.isActive)
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
        let movesBeforeUnchanged = surfaces[0].moves.count
        for _ in 0..<10 { output.refreshDisplays() }
        precondition(surfaces[0].moves.count == movesBeforeUnchanged, "Unchanged display notifications must not move the surface or restart presentation cadence")
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
        try await Task.sleep(for: .milliseconds(80))
        precondition(output.presentedImages == 1, "Native pacing must present a new image once and skip empty ticks")
        external.hostsStudio = true; screens.values = [builtIn, external]; output.refreshDisplays()
        precondition(!output.isActive && cancellations == 2)
        external.hostsStudio = false; screens.values = [builtIn, external]; output.refreshDisplays()
        output.feed = .clean
        output.start(programProfile: .default)
        precondition(output.isActive && requestedProfile == nil && subscriptions == 3, "Clean Program must retain the taken Program geometry")
        output.stop()
        output.feed = .selectedCanvas
        output.start(programProfile: .default, selectedProfile: .init(canvasWidth: 8192, canvasHeight: 8192, frameRate: 60))
        precondition(!output.isActive && subscriptions == 3)
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

        // Exercise the actual controller → newest-image mailbox → AppKit layer
        // with fixture-owned offscreen windows. No physical topology is changed.
        var ownedDisplay = offscreen
        ownedDisplay.frame.size = CGSize(width: 160, height: 160)
        let nativeScreens = InjectedScreens([ownedDisplay])
        var nativeSurface: NativeExternalDisplaySurface?
        var nativeConsumer: (@Sendable (CGImage) -> Void)?
        var nativeCancellations = 0
        let nativeOutput = ExternalDisplayOutputController(screensProvider: { nativeScreens.values }, surfaceFactory: { display in
            let value = NativeExternalDisplaySurface(display: display); nativeSurface = value; return value
        }, subscribe: { _, sink in nativeConsumer = sink; return { nativeCancellations += 1 } })
        nativeOutput.selectedDisplayID = ownedDisplay.id
        nativeOutput.start(programProfile: .init(canvasWidth: 160, canvasHeight: 100, frameRate: 30))
        let pattern = try patternImage()
        expectPixel(pattern, x: 20, y: 50, rgb: [255, 0, 0])
        expectPixel(pattern, x: 80, y: 50, rgb: [0, 255, 0])
        expectPixel(pattern, x: 140, y: 50, rgb: [0, 0, 255])
        nativeConsumer?(pattern); nativeOutput.presentLatest()
        let fitPixels = try renderedSurface(nativeSurface!)
        expectPixel(fitPixels, x: 20, y: 10, rgb: [0, 0, 0])
        expectPixel(fitPixels, x: 20, y: 80, rgb: [255, 0, 0])
        expectPixel(fitPixels, x: 80, y: 80, rgb: [0, 255, 0])
        expectPixel(fitPixels, x: 140, y: 80, rgb: [0, 0, 255])
        nativeOutput.scaling = .fill; nativeConsumer?(pattern); nativeOutput.presentLatest()
        let fillPixels = try renderedSurface(nativeSurface!)
        expectPixel(fillPixels, x: 20, y: 10, rgb: [0, 255, 0])
        expectPixel(fillPixels, x: 80, y: 80, rgb: [0, 255, 0])
        ownedDisplay.frame = CGRect(x: -16000, y: -16000, width: 80, height: 160)
        nativeScreens.values = [ownedDisplay]
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        for _ in 0..<5 { await Task.yield() }
        precondition(nativeSurface!.window.frame == ownedDisplay.frame, "Actual display notification did not resize/reposition the owned surface")
        nativeConsumer?(pattern); nativeOutput.presentLatest()
        let resizedPixels = try renderedSurface(nativeSurface!)
        precondition(resizedPixels.width == 80 && resizedPixels.height == 160)
        expectPixel(resizedPixels, x: 10, y: 10, rgb: [0, 255, 0])
        precondition(nativeSurface!.window.colorSpace == .sRGB)
        let presentationsBefore = nativeOutput.presentedImages, paceStart = ProcessInfo.processInfo.systemUptime
        for _ in 0..<40 {
            nativeConsumer?(pattern)
            NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
            try await Task.sleep(for: .milliseconds(8))
        }
        let paceSeconds = ProcessInfo.processInfo.systemUptime - paceStart
        let pacedImages = nativeOutput.presentedImages - presentationsBefore
        precondition(pacedImages >= 3 && Double(pacedImages) <= ceil(paceSeconds * 30) + 2, "Unchanged topology notifications starved or exceeded actual 30fps presentation cadence")
        nativeScreens.values = []
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        for _ in 0..<5 { await Task.yield() }
        precondition(!nativeOutput.isActive && nativeCancellations == 1 && !nativeSurface!.window.isVisible)
        nativeConsumer?(pattern)
        nativeScreens.values = [ownedDisplay]
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        for _ in 0..<5 { await Task.yield() }
        precondition(!nativeOutput.isActive, "Returning display availability must require deliberate restart")
        let artifacts = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? NSTemporaryDirectory() + "stream-external-display-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        for (name, bitmap) in [("fit", fitPixels), ("fill", fillPixels), ("resized-fill", resizedPixels)] {
            guard let destination = CGImageDestinationCreateWithURL(artifacts.appendingPathComponent(name + ".png") as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw NSError(domain: "DisplayHarness", code: 11) }
            CGImageDestinationAddImage(destination, bitmap, nil)
            precondition(CGImageDestinationFinalize(destination))
        }
        let systemSurface = try await observeSystemSurface(shell: shell, pattern: pattern, artifacts: artifacts)
        let report: [String: Any] = ["system": ProcessInfo.processInfo.operatingSystemVersionString,
            "hardwareModel": machineModel(), "processors": ProcessInfo.processInfo.processorCount,
            "systemDisplayCount": actualDisplays.count, "systemExternalSurface": systemSurface,
            "presentationCount": pacedImages, "presentationSeconds": paceSeconds, "presentationTargetFPS": 30,
            "ownedSurfaceSize": [80, 160], "surfaceColorSpace": "sRGB", "videoOnly": true,
            "unchangedTopologyNotifications": 40, "notificationDisconnectStopped": true,
            "physicalAirPlayOrHotplugExercised": false]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: artifacts.appendingPathComponent("report.json"))
        print("Native owned surface pixels: fit/fill/portrait resize PASS; \(pacedImages) presentations in \(paceSeconds)s at target30fps during40unchanged topology notifications; systemdisplays \(actualDisplays.count); artifacts \(artifacts.path)")
        print("PASS: shipping native external-display controller/surface; injected display availability/topology, independent start/stop, one-image bounded presentation and late callback rejection, fit/fill, rearrangement without resubscription, unplug/manual reconnect, studio-display exclusion, selected portrait canvas, size/resource failure cleanup, sRGB/letterbox conversion and unchanged PTS, native run-loop pacing, borderless video-only non-key surface; \(ProcessInfo.processInfo.operatingSystemVersionString)")
    }
    static func machineModel() -> String {
        var bytes = [CChar](repeating: 0, count: 128), size = 128
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return "unknown" }
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
    @MainActor static func observeSystemSurface(shell: NSWindow, pattern: CGImage, artifacts: URL) async throws -> [String: Any] {
        guard CGPreflightScreenCaptureAccess() else { return ["qualified": false, "reason": "Existing screen-observation grant unavailable; no permission requested."] }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard content.displays.count >= 2, let primary = NSScreen.screens.first else { return ["qualified": false, "reason": "Fewer than two observable system displays."] }
        shell.setFrame(CGRect(x: primary.frame.minX + 16, y: primary.frame.minY + 16, width: 80, height: 60), display: false)
        let displays = ExternalDisplayOutputController.systemDisplays()
        guard let target = displays.first(where: { candidate in candidate.canShowCleanOutput && content.displays.contains(where: { $0.displayID == candidate.id }) }) else { return ["qualified": false, "reason": "No separate system-visible external display."] }
        var surface: NativeExternalDisplaySurface?
        var sink: (@Sendable (CGImage) -> Void)?
        let output = ExternalDisplayOutputController(surfaceFactory: { display in
            let value = NativeExternalDisplaySurface(display: display); surface = value; return value
        }, subscribe: { _, consumer in sink = consumer; return {} })
        defer { output.stop() }
        output.selectedDisplayID = target.id
        output.start(programProfile: .init(canvasWidth: 160, canvasHeight: 100, frameRate: 30))
        guard output.isActive, let surface else { throw NSError(domain: "DisplayHarness", code: 20) }
        precondition(surface.window.frame == target.frame && !surface.window.canBecomeKey && surface.window.ignoresMouseEvents)
        sink?(pattern)
        try await Task.sleep(for: .milliseconds(120))
        let available = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let window = available.windows.first(where: { $0.windowID == CGWindowID(surface.window.windowNumber) && $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier }) else { throw NSError(domain: "DisplayHarness", code: 21) }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        configuration.width = 320; configuration.height = 180; configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        let fit = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        print("SCK own-window image color space: \(fit.colorSpace?.name.map { $0 as String } ?? "unknown"); RGB \(pixel(fit, x: 40, y: 90))/\(pixel(fit, x: 160, y: 90))/\(pixel(fit, x: 280, y: 90)); black \(pixel(fit, x: 2, y: 90))")
        // The positive colors and negative letterbox control must both survive
        // actual WindowServer/SCK observation before any qualification claim.
        expectPixel(fit, x: 2, y: 90, rgb: [0, 0, 0])
        expectPixel(fit, x: 40, y: 90, rgb: [255, 0, 0])
        expectPixel(fit, x: 160, y: 90, rgb: [0, 255, 0])
        expectPixel(fit, x: 280, y: 90, rgb: [0, 0, 255])
        output.scaling = .fill; sink?(pattern)
        try await Task.sleep(for: .milliseconds(80))
        let fill = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        expectPixel(fill, x: 2, y: 90, rgb: [255, 0, 0])
        expectPixel(fill, x: 160, y: 90, rgb: [0, 255, 0])
        expectPixel(fill, x: 318, y: 90, rgb: [0, 0, 255])
        for (name, image) in [("system-display-fit", fit), ("system-display-fill", fill)] {
            guard let destination = CGImageDestinationCreateWithURL(artifacts.appendingPathComponent(name + ".png") as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw NSError(domain: "DisplayHarness", code: 22) }
            CGImageDestinationAddImage(destination, image, nil); precondition(CGImageDestinationFinalize(destination))
        }
        let presented = output.presentedImages
        output.stop()
        precondition(!surface.window.isVisible && !output.isActive)
        print("PASS: actual system external display \(target.id), frame \(target.frame), own-window ScreenCaptureKit readback320x180 verifies positive RGB+negative letterbox, fit/fill, non-key video-only surface and stop; \(presented) timer presentations")
        return ["qualified": true, "displayID": target.id, "frame": NSStringFromRect(target.frame), "readbackSize": [fit.width, fit.height], "presentedImages": presented, "captureBoundary": "own-window ScreenCaptureKit screenshot", "physicalAirPlayOrCableHotplug": false]
    }
    @MainActor static func renderedSurface(_ surface: NativeExternalDisplaySurface) throws -> CGImage {
        guard let layer = surface.window.contentView?.layer else { throw NSError(domain: "DisplayHarness", code: 6) }
        surface.window.contentView?.layoutSubtreeIfNeeded()
        let bounds = layer.bounds
        guard let context = CGContext(data: nil, width: Int(bounds.width), height: Int(bounds.height), bitsPerComponent: 8, bytesPerRow: Int(bounds.width) * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { throw NSError(domain: "DisplayHarness", code: 7) }
        layer.render(in: context)
        return context.makeImage()!
    }
    static func expectPixel(_ image: CGImage, x: Int, y: Int, rgb: [Int]) {
        let value = pixel(image, x: x, y: y)
        precondition(zip(value.prefix(3), rgb).allSatisfy { abs(Int($0) - $1) <= 3 } && value[3] == 255, "Native surface pixel at \(x),\(y) expected \(rgb), got \(value)")
    }
    static func patternImage() throws -> CGImage {
        guard let context = CGContext(data: nil, width: 160, height: 100, bitsPerComponent: 8, bytesPerRow: 640, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw NSError(domain: "DisplayHarness", code: 8) }
        context.setFillColor(CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [0, 1, 0, 1])!); context.fill(CGRect(x: 0, y: 0, width: 160, height: 100))
        context.setFillColor(CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [1, 0, 0, 1])!); context.fill(CGRect(x: 0, y: 0, width: 40, height: 100))
        context.setFillColor(CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [0, 0, 1, 1])!); context.fill(CGRect(x: 120, y: 0, width: 40, height: 100))
        return context.makeImage()!
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
