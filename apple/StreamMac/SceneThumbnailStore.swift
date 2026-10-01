import AppKit
import CoreImage
import SwiftUI

/// S02 (issue #70): cached scene thumbnails for the scene browser.
///
/// Rendering is OFFLINE and off the main actor: `SceneThumbnailRenderer`
/// composites a small CIImage per scene — the current monitor frame when the
/// scene is staged in PREVIEW or on PROGRAM and a composited frame is
/// cheaply available, otherwise a stylized placeholder per layer kind (a
/// colored rounded block at each visible layer's canvas position, using the
/// same normalized-transform math as `SceneRenderer`). Results are cached by
/// scene-content fingerprint, so a refresh only re-renders scenes that
/// actually changed (a Take, an edit, a rename, a reorder of layers);
/// `forceLive` refreshes just the monitor-backed scenes on the browser's
/// slow timer so staged/program thumbnails track the live picture.
@MainActor
final class SceneThumbnailStore: ObservableObject {
    @Published private(set) var images: [SceneID: NSImage] = [:]

    private var fingerprints: [SceneID: Int] = [:]
    private var inFlight: Set<SceneID> = []
    private let size = CGSize(width: 256, height: 144)

    /// Re-renders every stale scene. `liveImage` returns the latest
    /// composited monitor frame for a scene staged in preview or on program,
    /// nil for every other scene (those render placeholders). With
    /// `forceLive`, monitor-backed scenes re-render even when their scene
    /// content is unchanged — the live picture moves while the graph doesn't.
    func refresh(scenes: [Scene],
                 liveImage: (Scene) -> CGImage?,
                 forceLive: Bool = false) {
        let sceneIDs = Set(scenes.map(\.id))
        images = images.filter { sceneIDs.contains($0.key) }
        fingerprints = fingerprints.filter { sceneIDs.contains($0.key) }
        for scene in scenes {
            let live = liveImage(scene)
            let fingerprint = Self.fingerprint(of: scene, hasLiveFrame: live != nil)
            let isStale = fingerprints[scene.id] != fingerprint
            let liveRefresh = forceLive && live != nil
            guard isStale || liveRefresh, !inFlight.contains(scene.id) else { continue }
            fingerprints[scene.id] = fingerprint
            inFlight.insert(scene.id)
            let size = self.size
            Task.detached(priority: .utility) { [weak self] in
                let cgImage = SceneThumbnailRenderer.render(scene: scene, live: live, size: size)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.inFlight.remove(scene.id)
                    if let cgImage {
                        self.images[scene.id] = NSImage(cgImage: cgImage, size: size)
                    } else {
                        // Render failed: forget the fingerprint so the next
                        // refresh retries instead of caching a blank.
                        self.fingerprints.removeValue(forKey: scene.id)
                    }
                }
            }
        }
    }

    private static func fingerprint(of scene: Scene, hasLiveFrame: Bool) -> Int {
        var hasher = Hasher()
        hasher.combine(scene)
        hasher.combine(hasLiveFrame)
        return hasher.finalize()
    }
}

/// The off-main renderer. Sends nothing: takes a value-type scene plus an
/// optional live frame and returns a CGImage. Non-renderer payload kinds
/// (image/text/media/web/guest/…) get the same "no pixels" treatment the
/// engine documents — here they paint a placeholder block instead of black,
/// so the thumbnail still communicates the scene's layout.
enum SceneThumbnailRenderer {
    /// One shared context is safe: `CIContext` is documented thread-safe for
    /// rendering, and thumbnails render at thumbnail size on a utility queue.
    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    static func render(scene: Scene, live: CGImage?, size: CGSize) -> CGImage? {
        let canvas = CGRect(origin: .zero, size: size)
        guard canvas.width > 1, canvas.height > 1 else { return nil }

        var output = CIImage(color: CIColor(red: 0.07, green: 0.07, blue: 0.09))
            .cropped(to: canvas)
        if let live {
            output = fit(CIImage(cgImage: live), into: canvas).composited(over: output)
        } else {
            for layer in scene.layers where layer.isVisible {
                let rect = rectInCanvas(for: layer.transform, canvas: canvas)
                guard rect.width > 1, rect.height > 1 else { continue }
                output = roundedBlock(rect: rect, color: color(for: layer.payload))
                    .composited(over: output)
            }
        }
        return ciContext.createCGImage(output, from: canvas)
    }

    /// Aspect-FIT centered in the canvas (monitor frames already match the
    /// canvas aspect, so this is effectively a plain scale).
    private static func fit(_ image: CIImage, into canvas: CGRect) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        let scale = min(canvas.width / extent.width, canvas.height / extent.height)
        var fitted = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        fitted = fitted.transformed(by: CGAffineTransform(
            translationX: canvas.midX - fitted.extent.midX,
            y: canvas.midY - fitted.extent.midY))
        return fitted
    }

    /// Resolves a normalized transform into a canvas rect, mirroring
    /// `SceneRenderer.rectInCanvas`: graph coordinates are top-left-origin,
    /// CI is bottom-left-origin; sub-fullscreen boxes (camera PIPs) derive
    /// their height from a 16:9 source aspect like the compositor's fill-crop.
    private static func rectInCanvas(for transform: LayerTransform, canvas: CGRect) -> CGRect {
        let anchor = anchorFraction(transform.anchor)
        let width = transform.size.width * canvas.width
        let height = transform.size.width < 1
            ? width * (9.0 / 16.0)
            : transform.size.height * canvas.height
        let topLeftX = transform.position.x * canvas.width - anchor.x * width
        let topLeftY = transform.position.y * canvas.height - anchor.y * height
        return CGRect(x: canvas.minX + topLeftX,
                      y: canvas.maxY - topLeftY - height,
                      width: width,
                      height: height)
    }

    private static func anchorFraction(_ anchor: LayerAnchor) -> (x: CGFloat, y: CGFloat) {
        switch anchor {
        case .topLeft: return (0, 0)
        case .topRight: return (1, 0)
        case .bottomLeft: return (0, 1)
        case .bottomRight: return (1, 1)
        case .center: return (0.5, 0.5)
        }
    }

    /// A soft rounded block for one layer, inset slightly so stacked layers
    /// read as distinct cards.
    private static func roundedBlock(rect: CGRect, color: CIColor) -> CIImage {
        let inset = rect.insetBy(dx: 1, dy: 1)
        guard let filter = CIFilter(name: "CIRoundedRectangleGenerator") else {
            return CIImage(color: color).cropped(to: inset)
        }
        filter.setValue(CIVector(cgRect: inset), forKey: "inputExtent")
        filter.setValue(min(inset.width, inset.height) * 0.14, forKey: "inputRadius")
        filter.setValue(color, forKey: "inputColor")
        return (filter.outputImage ?? CIImage(color: color)).cropped(to: inset)
    }

    /// One hue per layer kind, so a scene's source mix reads at a glance.
    private static func color(for payload: LayerPayload) -> CIColor {
        switch payload {
        case .camera: return CIColor(red: 0.25, green: 0.47, blue: 0.95)
        case .screen: return CIColor(red: 0.12, green: 0.62, blue: 0.68)
        case .image: return CIColor(red: 0.62, green: 0.35, blue: 0.85)
        case .text: return CIColor(red: 0.55, green: 0.55, blue: 0.60)
        case .shape: return CIColor(red: 0.90, green: 0.55, blue: 0.20)
        case .media: return CIColor(red: 0.90, green: 0.35, blue: 0.55)
        case .pdf: return CIColor(red: 0.85, green: 0.30, blue: 0.30)
        case .web: return CIColor(red: 0.35, green: 0.40, blue: 0.85)
        case .guest: return CIColor(red: 0.25, green: 0.70, blue: 0.40)
        case .syphon: return CIColor(red: 0.60, green: 0.30, blue: 0.90)
        case .scene: return CIColor(red: 0.60, green: 0.45, blue: 0.35)
        }
    }
}
