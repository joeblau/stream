import AppKit
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import ScreenCaptureKit
import StreamCore
import UniformTypeIdentifiers

@main @MainActor struct ExternalDisplayProgramHarness {
    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw NSError(domain: "ExternalDisplayProgram", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func wait(_ message: String, until predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(6)
        while ContinuousClock.now < deadline { if predicate() { return }; try await Task.sleep(for: .milliseconds(10)) }
        try require(false, message)
    }
    static func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
        var value = [UInt8](repeating: 0, count: 4)
        value.withUnsafeMutableBytes { CIContext().render(CIImage(cgImage: image), toBitmap: $0.baseAddress!, rowBytes: 4,
            bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) }
        return value
    }
    static func capture(_ surface: NativeExternalDisplaySurface?, name: String, root: URL) throws -> CGImage {
        guard let surface, let layer = surface.window.contentView?.layer else { throw CocoaError(.fileReadUnknown) }
        surface.window.contentView?.layoutSubtreeIfNeeded()
        guard let context = CGContext(data: nil, width: 320, height: 180, bitsPerComponent: 8, bytesPerRow: 1280,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { throw CocoaError(.fileReadUnknown) }
        layer.render(in: context)
        guard let image = context.makeImage(), let writer = CGImageDestinationCreateWithURL(root.appendingPathComponent(name + ".png") as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(writer, image, nil); try require(CGImageDestinationFinalize(writer), "Could not retain actual own-surface pixels")
        return image
    }
    static func main() async throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        guard IsolatedVideoBudget.current.qualified else { print("UNQUALIFIED: measured clean-render Mac absent"); exit(77) }
        let target = ExternalDisplayDescriptor(id: 9001, name: "Owned offscreen surface", frame: .init(x: -24000, y: -24000, width: 320, height: 180), maximumFPS: 60, isBuiltIn: false, hostsStudio: false)
        var surface: NativeExternalDisplaySurface?
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let project = root.appendingPathComponent("Project"); try DesktopStorage.prepare(project)
        let layer = LayerNode(name: "Owned blue scene", payload: .shape(.init(fillColorHex: "#0000FF")), transform: .init(position: .init(x: 0, y: 0), size: .init(width: 0.5, height: 1), anchor: .topLeft))
        let scene = Scene(name: "Owned clean display", layers: [layer], secondaryCanvas: .init(size: .init(width: 1920, height: 1080)))
        let overlay = LayerNode(name: "Owned green overlay", payload: .shape(.init(fillColorHex: "#00FF00")), transform: .fullscreen)
        try JSONEncoder().encode(SceneDocument(sources: [], scenes: [scene], selectedID: scene.id, overlays: [overlay], defaultBackground: .solid(colorHex: "#A020D0"))).write(to: project.appendingPathComponent("stream.scenes.v2.json"))
        let secondary = StreamDestination(name: "Owned secondary budget refusal", transport: .rtmp, canvas: .secondary)
        try JSONEncoder().encode([secondary]).write(to: project.appendingPathComponent("destinations.json"))
        var settings = StreamSettings.default; settings.outputProfile = .init(canvasWidth: 3840, canvasHeight: 2160, frameRate: 30)
        settings.audioInputs = []; settings.micVolume = 0; settings.voicePolishEnabled = false
        DesktopSettingsStore().saveNonSecret(settings)
        let store = SceneStore(), preview = PreviewProgramModel(selected: store.selected)
        let controller = StreamController(sceneStore: store, previewProgram: preview, permissions: PermissionsManager(), externalDisplayScreens: { [target] }, externalDisplaySurface: { display in
            let value = NativeExternalDisplaySurface(display: display); surface = value; return value
        })
        try require(!controller.resilience.isLocked && !controller.resilience.requiresManualRestart,
            "Owned external-display workload must explicitly start unlocked without host lifecycle observation")
        print("Owned fixture lifecycle: explicit unlocked initial state; generated coordinator has no system observers")
        let output = controller.externalDisplayOutput; output.selectedDisplayID = target.id; output.feed = .clean
        defer { output.stop(); controller.stopPreview(); controller.stopStream() }
        let windows = NSApplication.shared.windows.count
        output.start(programProfile: controller.activeProfile)
        guard case .failed(let error) = output.state else { throw CocoaError(.coderInvalidValue) }
        try require(error.contains("compositor budget") && !controller.cleanReturnDemanded && !controller.outputSessionActive && NSApplication.shared.windows.count == windows,
            "Over-budget external Clean allocated a renderer/surface or hid the real preflight error")
        settings.outputProfile = .init(canvasWidth: 320, canvasHeight: 180, frameRate: 30); controller.applySavedSettings(settings)
        let stroke = AnnotationStroke(tool: .pen, colorHex: "#FF0000", width: 64, points: [.init(x: 0.1, y: 0.5), .init(x: 0.9, y: 0.5)])
        ProgramAnnotationStore.shared.publish(.init(strokes: [scene.id: [stroke]]))
        output.feed = .program; output.start(programProfile: controller.activeProfile)
        try await wait("Program display did not receive real compositor frames") { output.presentedImages >= 3 }
        let program = try capture(surface, name: "actual-program-overlay-annotation", root: root)
        try require(pixel(program, 80, 30)[1] > 200 && pixel(program, 160, 90)[0] > 200, "Actual Program omitted the public overlay/annotation controls")
        output.stop(); try await wait("Program teardown did not release demand") { !controller.outputSessionActive }
        output.feed = .clean; output.start(programProfile: controller.activeProfile)
        try await wait("Clean display did not receive actual clean compositor frames") { output.presentedImages >= 3 }
        let clean = try capture(surface, name: "actual-clean-scene-only", root: root)
        let left = pixel(clean, 80, 30), right = pixel(clean, 240, 30), center = pixel(clean, 160, 90)
        try require(left[2] > 200 && left[0] < 40 && left[1] < 60 && right[0] > 100 && right[1] < 80 && right[2] > 140 && center[1] < 80 && center[2] > 140,
            "External Clean substituted Program, global overlay, annotation or another canvas")
        try require(controller.cleanReturnDemanded, "Actual external clean renderer was absent from shared demand")
        output.stop(); try require(controller.cleanReturnDemanded, "Clean reservation released before actor unsubscribe acknowledgment")
        try await wait("Clean teardown did not release shared demand") { !controller.cleanReturnDemanded && !controller.outputSessionActive }
        settings.outputProfile = .init(canvasWidth: 1920, canvasHeight: 1080, frameRate: 60); controller.applySavedSettings(settings)
        output.feed = .clean; output.start(programProfile: controller.activeProfile)
        try require(output.isActive && controller.cleanReturnDemanded, "Exact shared 4K30 ceiling incorrectly rejected external Clean")
        let reservation = UUID()
        let refusal = controller.reserveRecordingEncoders(reservation, count: 1, canvas: .secondary)
        try require(refusal?.contains("compositor budget") == true && controller.reservedRecordingEncoderCount == 0, "Later secondary guest/recording reservation undercounted external clean work")
        controller.startDestination(secondary.id)
        try require(controller.errorMessage?.contains("compositor budget") == true && controller.activePublishingEncoderCount == 0, "Later secondary publisher bypassed external clean workload")
        let lease = GuestReceiveLease(slot: UUID(), peerID: UUID(), negotiation: UUID(), generation: 1)
        guard let guest = await controller.makeGuestMediaSink(lease, name: "Owned extra clean consumer") else { throw CocoaError(.coderInvalidValue) }
        try require(guest.selectReturnVideoSource(.clean), "Could not select shared guest clean consumer")
        let token = UUID(); try require(guest.claimReturnVideo(token), "Guest clean claim rejected")
        let installed = await guest.installReturnVideo(token: token) { _ in }
        try require(installed && controller.reservedRecordingEncoderCount == 1 && controller.cleanReturnDemanded, "Two consumers incorrectly counted two clean renderers")
        guest.removeReturnVideo(token: token)
        try await wait("Guest clean teardown failed") { controller.reservedRecordingEncoderCount == 0 }
        try require(output.isActive && controller.cleanReturnDemanded, "Guest removal stopped the independent external clean renderer")
        guest.close(); controller.removeGuestMedia(lease)
        controller.startPreview(); controller.setSecondaryMonitorsEnabled(true)
        try await wait("New secondary monitor demand did not revoke the over-budget external Clean") { !output.isActive && !controller.cleanReturnDemanded }
        guard case .failed(let monitorError) = output.state else { throw CocoaError(.coderInvalidValue) }
        try require(monitorError.contains("compositor budget"), "Monitor-priority revocation hid the actual budget cause")
        controller.setSecondaryMonitorsEnabled(false); controller.stopPreview()
        try await wait("Final external clean demand leaked") { !controller.cleanReturnDemanded && !controller.outputSessionActive }
        print("PASS: actual StreamController Program/Clean compositor → converter → display surface owned native offscreen layer pixels; overlay/annotation exclusion, qualified/pre-allocation 4K30 refusal, exact-ceiling admission, later secondary publisher+guest reservation refusal, shared guest/display clean renderer counted once, independent teardown acknowledgment; \(IsolatedVideoBudget.current.machineClass); \(ProcessInfo.processInfo.operatingSystemVersionString); \(root.path)")
    }
}
