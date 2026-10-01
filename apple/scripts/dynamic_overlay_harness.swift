import Foundation
import CoreImage
import CoreMedia
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
import StreamCore

/// Compiled with the app's actual sources, excluding only its @main entry.
@main struct DynamicOverlayHarness {
    static func main() throws {
        let preview = SceneRenderer(usesSoftwareRendering: true)
        let program = SceneRenderer(usesSoftwareRendering: true)
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var control = [UInt8](repeating: 0, count: 64)
        CIContext(options: [.useSoftwareRenderer: true]).render(CIImage(color: .red),
            toBitmap: &control, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 4, height: 4),
            format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        if !control.contains(where: { $0 != 0 }) {
            try rasterChecks(output: output)
            print("SKIP: CI frame comparisons; the red control image also renders zero bytes in this sandbox")
            return
        }
        var config = TimerOverlayConfiguration(durationSeconds: 2, format: .seconds)
        var layer = LayerNode(name: "Timer", payload: .text(TextSourcePayload(
            fontSize: 100, backgroundColorHex: "#204060", padding: 12, timer: config)), transform: .fullscreen)
        layer.transform = LayerTransform(position: GraphPoint(x: 0.125, y: 0.4),
            size: GraphSize(width: 0.75, height: 0.25), anchor: .topLeft)
        var scene = Scene(name: "Timers", layers: [layer])
        DynamicOverlayStore.shared.perform(.start, id: config.runtimeID, at: 100)
        let first = try render(scene, renderer: program, at: 100)
        let second = try render(scene, renderer: program, at: 101)
        check(bytes(first) != bytes(second), "Timer must advance on output")
        check(bytes(second) == bytes(try render(scene, renderer: preview, at: 101)),
                     "Preview and program must share timer state")
        DynamicOverlayStore.shared.perform(.pause, id: config.runtimeID, at: 101)
        check(bytes(second) == bytes(try render(scene, renderer: program, at: 500)), "Pause must freeze")
        var copy = layer
        copy.id = LayerID()
        let other = Scene(name: "Other", layers: [copy])
        check(bytes(second) == bytes(try render(other, renderer: preview, at: 500)),
                     "Copied scene layer must retain its shared playback")
        try save(first, to: output.appendingPathComponent("timer.png"))
        config.zeroBehavior = .hide
        scene.layers[0].payload = .text(TextSourcePayload(timer: config))
        DynamicOverlayStore.shared.perform(.start, id: config.runtimeID, at: 501)
        let hidden = try render(scene, renderer: program, at: 510)
        let empty = try render(Scene(name: "Empty", layers: []), renderer: preview, at: 510)
        check(bytes(hidden) == bytes(empty), "Hide-at-zero must paint nothing")

        let ticker = TickerOverlayConfiguration(speed: 120, gap: 120)
        layer.payload = .text(TextSourcePayload(text: "LIVE • Welcome 👋 — 日本語 مرحبا",
            fontSize: 100, backgroundColorHex: "#203050", padding: 12, ticker: ticker))
        scene.layers = [layer]
        DynamicOverlayStore.shared.perform(.start, id: ticker.runtimeID, at: 100)
        let tickerFirst = try render(scene, renderer: program, at: 100)
        let tickerNext = try render(scene, renderer: program, at: 102)
        check(bytes(tickerFirst) != bytes(tickerNext), "Ticker must move")
        check(bytes(tickerNext) == bytes(try render(scene, renderer: preview, at: 102)))
        DynamicOverlayStore.shared.perform(.pause, id: ticker.runtimeID, at: 102)
        check(bytes(tickerNext) == bytes(try render(scene, renderer: preview, at: 900)))
        try save(tickerNext, to: output.appendingPathComponent("ticker.png"))
        layer.payload = .text(TextSourcePayload(text: String(repeating: "語😀", count: 2048),
            fontSize: 100, ticker: ticker))
        scene.layers = [layer]
        let long = try render(scene, renderer: program, at: 900)
        check(bytes(long) != bytes(empty), "Long Unicode must still paint without a full-line bitmap")
        try save(long, to: output.appendingPathComponent("ticker-long.png"))

        DynamicOverlayStore.shared.perform(.start, id: ticker.runtimeID, at: 900)
        let parent = Scene(name: "Nested", layers: [LayerNode(name: "Nested", payload:
            .scene(SceneReferencePayload(sceneID: scene.id)), transform: .fullscreen)])
        let nested1 = try render(parent, renderer: program, at: 900, scenes: [scene.id: scene])
        let nested2 = try render(parent, renderer: program, at: 901, scenes: [scene.id: scene])
        check(bytes(nested1) != bytes(nested2), "Nested dynamic layers cannot freeze in the static cache")
        print("PASS: timer transport, shared scenes/renderers, zero-hide, ticker motion/pause, long Unicode, nested animation")
    }

    static func check(_ passed: Bool, _ message: String = "Assertion failed") {
        precondition(passed, message)
    }

    static func rasterChecks(output: URL) throws {
        let renderer = SceneRenderer(usesSoftwareRendering: true)
        let timer = TimerOverlayConfiguration(durationSeconds: 2, format: .seconds)
        var layer = LayerNode(name: "Timer", payload: .text(TextSourcePayload(fontSize: 100, timer: timer)),
                              transform: .fullscreen)
        var scene = Scene(name: "Raster", layers: [layer])
        DynamicOverlayStore.shared.perform(.start, id: timer.runtimeID, at: 100)
        _ = try render(scene, renderer: renderer, at: 100)
        let first = try requireRaster(renderer.debugGeneratedRasters().first)
        _ = try render(scene, renderer: renderer, at: 101)
        let rasters = renderer.debugGeneratedRasters()
        check(rasters.count == 2, "Timer strings must produce two cached rasters")
        check(rasters[0].dataProvider!.data! as Data != rasters[1].dataProvider!.data! as Data)
        try saveRaster(first, to: output.appendingPathComponent("timer-raster.png"))
        DynamicOverlayStore.shared.perform(.pause, id: timer.runtimeID, at: 101)
        _ = try render(scene, renderer: renderer, at: 900)
        check(renderer.debugGeneratedRasters().count == 2, "Pause cannot change the raster")
        let ticker = TickerOverlayConfiguration()
        layer.payload = .text(TextSourcePayload(text: String(repeating: "語😀", count: 2048),
            fontSize: 100, ticker: ticker))
        scene.layers = [layer]
        DynamicOverlayStore.shared.perform(.start, id: ticker.runtimeID, at: 100)
        _ = try render(scene, renderer: renderer, at: 100)
        check(renderer.debugGeneratedRasters().count > 2, "Long text must rasterize visible tiles")
        let tiled = renderer.debugGeneratedRasters()
        try saveRaster(tiled.last!, to: output.appendingPathComponent("ticker-tile.png"))
        _ = try render(scene, renderer: renderer, at: 150)
        check(renderer.debugGeneratedRasters().count > tiled.count, "Motion must reach different text tiles")
        check(renderer.debugGeneratedRasters().count <= 64, "Raster cache must stay bounded")
        let parent = Scene(name: "Nested", layers: [LayerNode(name: "Nested", payload:
            .scene(SceneReferencePayload(sceneID: scene.id)), transform: .fullscreen)])
        _ = try render(parent, renderer: renderer, at: 150, scenes: [scene.id: scene])
        check(renderer.debugNestedCacheCount == 0, "Nested ticker cannot be cached as static content")
        print("PASS: actual Core Text timer rasters, pause, long Unicode tiling/motion/cache bounds, dynamic nested cache")
    }

    static func requireRaster(_ value: CGImage?) throws -> CGImage {
        guard let value else { throw CocoaError(.coderInvalidValue) }
        return value
    }

    static func saveRaster(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }

    static func render(_ scene: Scene, renderer: SceneRenderer, at seconds: Double,
                       scenes: [SceneID: Scene] = [:]) throws -> CVPixelBuffer {
        guard let frame = renderer.render(scene: scene, overlayContext: .empty,
            canvasSize: CGSize(width: 640, height: 360),
            frames: SourceFrameLookup(camera: { _ in nil }, screen: { _ in nil }),
            sourcePayloads: [:], scenes: scenes,
            presentationTime: CMTime(seconds: seconds, preferredTimescale: 60_000),
            frameDuration: CMTime(value: 1, timescale: 30), sequence: 1),
              let pixels = frame.pixelBuffer else { throw CocoaError(.coderInvalidValue) }
        // Retaining more than four pooled frames would exhaust the production
        // mailbox budget. Keep independent CPU snapshots for comparisons.
        var copy: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, 640, 360, kCVPixelFormatType_32BGRA, nil, &copy) == kCVReturnSuccess,
              let copy else { throw CocoaError(.coderInvalidValue) }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        CVPixelBufferLockBaseAddress(copy, [])
        for y in 0..<360 {
            memcpy(CVPixelBufferGetBaseAddress(copy)!.advanced(by: y * CVPixelBufferGetBytesPerRow(copy)),
                   CVPixelBufferGetBaseAddress(pixels)!.advanced(by: y * CVPixelBufferGetBytesPerRow(pixels)), 640 * 4)
        }
        CVPixelBufferUnlockBaseAddress(copy, [])
        CVPixelBufferUnlockBaseAddress(pixels, .readOnly)
        return copy
    }

    static func bytes(_ buffer: CVPixelBuffer) -> Data {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        return Data(bytes: CVPixelBufferGetBaseAddress(buffer)!,
                    count: CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer))
    }

    static func save(_ buffer: CVPixelBuffer, to url: URL) throws {
        guard let provider = CGDataProvider(data: bytes(buffer) as CFData),
              let cg = CGImage(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer),
                bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
                    .union(.byteOrder32Little), provider: provider, decode: nil,
                shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }
}
