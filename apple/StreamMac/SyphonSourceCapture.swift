import CoreImage
import CoreVideo
import Metal

#if canImport(Syphon)
import Syphon
#endif

/// C09 (issue #163): receives frames from ONE Syphon server — the per-key
/// capture runtime the pool drives for `.syphon` sources, mirroring
/// `ScreenSourceCapture`'s surface (`isCapturing` / `errorMessage` /
/// latest-frame holder) so the pool's C02/C10 wiring applies unchanged.
///
/// Frame path: `SyphonMetalClient.newFrameImage()` hands a live Metal
/// texture (IOSurface-backed on the server side, premultiplied alpha
/// preserved). Each frame renders through a Metal-backed `CIContext` into a
/// pooled BGRA `CVPixelBuffer` — the exact currency the composition engines
/// already spend — and lands in `frames`, which the pool publishes keyed by
/// source identity (C01 pattern; the renderer reads it through the existing
/// keyed screen-frame path). Metal textures are top-left origin and Core
/// Image is bottom-left, so the image is flipped on the way in.
///
/// ObjC bridge isolation: `SyphonMetalClient` and the server-description
/// dictionaries are non-Sendable Objective-C types; every touch happens on
/// the main actor here. The only cross-thread surface is `frames`
/// (lock-protected, like every other source holder). The client's
/// new-frame handler can fire on any thread, so it hops to the main actor
/// before touching the client.
///
/// When the Syphon package is absent (`canImport` fails) the whole runtime
/// compiles to a stub that reports the honest unavailable error, so the app
/// builds and every other source keeps working.
@MainActor
final class SyphonSourceCapture: ObservableObject {
    /// True while connected to a live server. Frames may still age out if
    /// the server stops publishing without retiring (the pool's discovery
    /// reconciliation owns the MISSING state for a genuinely gone server).
    @Published private(set) var isCapturing = false
    /// The last connection failure, surfaced as the source's error badge.
    @Published private(set) var errorMessage: String?

    /// The per-source latest-frame holder (non-destructive reads; the
    /// composition tick re-uses the newest frame exactly like screen
    /// captures, so a still Syphon feed keeps compositing).
    let frames = LatestScreenFrame()

    #if canImport(Syphon)
    private var client: SyphonMetalClient?
    private var ciContext: CIContext?
    private var pixelPool: CVPixelBufferPool?
    private var poolWidth = 0
    private var poolHeight = 0
    #endif

    /// Connects to the live server matching `payload`'s identity and starts
    /// receiving. Returns false when NO server matches — not an error: the
    /// pool moves the source to MISSING (C10) and the discovery
    /// reconciliation restarts capture when the same name+app reappears.
    @discardableResult
    func start(matching payload: SyphonSourcePayload) -> Bool {
        stop()
        errorMessage = nil
        #if canImport(Syphon)
        guard let description = Self.serverDescription(matching: payload) else {
            return false
        }
        guard let device = MTLCreateSystemDefaultDevice() else {
            errorMessage = "Syphon needs a Metal-capable GPU, which this Mac doesn't provide."
            return true
        }
        let client = SyphonMetalClient(
            serverDescription: description,
            device: device,
            options: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pullFrame()
            }
        }
        guard client.isValid else {
            errorMessage = "Could not connect to the Syphon server \"\(payload.displayTitle)\". It may have just quit — capture retries automatically."
            return true
        }
        ciContext = CIContext(mtlDevice: device, options: [
            .workingColorSpace: NSNull(),
            .cacheIntermediates: false,
        ])
        self.client = client
        isCapturing = true
        pullFrame()
        return true
        #else
        errorMessage = "This build doesn't include Syphon support."
        return true
        #endif
    }

    /// Disconnects and clears the frame holder, so a stopped source never
    /// serves stale pixels (the renderer's documented paint-nothing fallback).
    func stop() {
        #if canImport(Syphon)
        client?.stop()
        client = nil
        ciContext = nil
        #endif
        frames.clear()
        isCapturing = false
    }

    #if canImport(Syphon)
    /// Pulls the server's newest frame into the holder. Called (on the main
    /// actor) from the client's new-frame handler; a nil frame keeps the
    /// previous pixels, matching the screen captures' latest-frame semantics.
    private func pullFrame() {
        guard let client, let ciContext,
              let texture = client.newFrameImage() else { return }
        let width = texture.width
        let height = texture.height
        guard width > 1, height > 1,
              let buffer = pixelBuffer(width: width, height: height) else { return }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        guard let textureImage = CIImage(mtlTexture: texture,
                                         options: [.colorSpace: NSNull()]) else { return }
        let image = textureImage
            .transformed(by: CGAffineTransform(scaleX: 1, y: -1)
                .translatedBy(x: 0, y: -CGFloat(height)))
        ciContext.render(image, to: buffer, bounds: bounds,
                         colorSpace: CGColorSpaceCreateDeviceRGB())
        frames.store(buffer)
    }

    /// A pooled BGRA buffer of the frame's size (the pool is re-created when
    /// the server starts publishing a new size). IOSurface-backed and
    /// Metal-compatible, matching the compositor's buffers.
    private func pixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        if pixelPool == nil || poolWidth != width || poolHeight != height {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            var pool: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(
                kCFAllocatorDefault, nil, attributes as CFDictionary, &pool
            ) == kCVReturnSuccess else { return nil }
            pixelPool = pool
            poolWidth = width
            poolHeight = height
        }
        guard let pixelPool else { return nil }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(
            kCFAllocatorDefault, pixelPool, &buffer
        ) == kCVReturnSuccess else { return nil }
        return buffer
    }

    /// The raw server description for the live server answering to
    /// `payload`'s persisted identity (server name + app name; the volatile
    /// instance UUID deliberately ignored so app relaunches re-match).
    private static func serverDescription(
        matching payload: SyphonSourcePayload
    ) -> [String: any NSCoding]? {
        SyphonServerDirectory.shared().servers.first { description in
            let name = description[SyphonServerDescriptionNameKey] as? String ?? ""
            let app = description[SyphonServerDescriptionAppNameKey] as? String ?? ""
            return name == payload.serverName && app == payload.appName
        }
    }
    #endif
}
