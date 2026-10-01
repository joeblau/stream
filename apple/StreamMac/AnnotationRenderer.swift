import CoreGraphics
import CoreImage
import os.lock
import StreamCore

/// G11 (issue #117): the PROGRAM-side compositing of presentation
/// annotations — a pure function over the shared Core Image pipeline, so the
/// render seam is one call line inside `SceneRenderer.render`.
///
/// **Render hook (owned by the orchestrator; G02 owns SceneRenderer.swift).**
/// In `SceneRenderer.render(scene:overlayContext:…)`, immediately AFTER the
/// existing `output = applyingOverlays(…)` line (and BEFORE
/// `applyingStinger`), insert:
///
///     output = AnnotationRenderer.composite(strokes: annotations.strokes[scene.id] ?? [],
///                                           pointer: annotations.pointer?.sceneID == scene.id
///                                               ? annotations.pointer?.point : nil,
///                                           onto: output, canvas: canvas)
///
/// where `annotations` is a new `AnnotationRenderSnapshot` parameter on
/// `render` (default `.empty`), fed by a new `CompositionEngine` init
/// provider `annotationProvider: @Sendable () -> AnnotationRenderSnapshot`
/// defaulting to `{ ProgramAnnotationStore.shared.snapshot() }` — the exact
/// `overlayContextProvider` precedent. The PROGRAM engine uses the default;
/// the PREVIEW engine (StreamController.swift's `previewEngine`
/// construction) passes `annotationProvider: { .empty }`, because preview
/// shows annotations as SwiftUI chrome in `CanvasInteractionView` — painting
/// them into the preview image too would double-draw them.
///
/// **Why this ordering.** Annotations composite above the scene and the
/// project overlays (the presenter draws on TOP of branding) and below the
/// stinger video mask (a transition mask must cover the whole outgoing
/// frame, annotations included).
///
/// **Geometry.** Stroke points are normalized 0…1 top-left-origin canvas
/// coordinates (the `LayerTransform` space); widths are 1080p-reference
/// pixels scaled by render height (the renderer's `styleScale` precedent).
/// Rasterization draws y-down into a bitmap context, which displays upright
/// as a `CIImage` — the same convention `SceneRenderer.generated` uses.
enum AnnotationRenderer {
    /// Composites `strokes` (back-to-front, drawing order) and the laser
    /// pointer dot onto `output`. Pure: same inputs, same image. The caller
    /// applies the visibility/program gates (it passes only
    /// `SceneAnnotations.programStrokes`).
    static func composite(strokes: [AnnotationStroke],
                          pointer: AnnotationPoint? = nil,
                          onto output: CIImage,
                          canvas: CGRect) -> CIImage {
        guard canvas.width > 1, canvas.height > 1 else { return output }
        var result = output
        if !strokes.isEmpty,
           let raster = StrokeRasterCache.shared.raster(for: strokes, canvas: canvas) {
            result = raster.composited(over: result)
        }
        if let pointer,
           let dot = pointerRaster(at: pointer, canvas: canvas) {
            result = dot.composited(over: result)
        }
        return result
    }

    /// Reference-pixel scale: stroke geometry is authored against the 1080p
    /// canvas and scales with the render height (the text `fontSize` /
    /// G03 `styleScale` precedent), so a pen line renders identically at any
    /// encode resolution.
    private static func scale(for canvas: CGRect) -> CGFloat {
        canvas.height / 1080
    }

    /// A canvas-sized transparent bitmap with every stroke drawn in order.
    private static func drawStrokes(_ strokes: [AnnotationStroke], canvas: CGRect) -> CIImage? {
        let width = Int(canvas.width.rounded())
        let height = Int(canvas.height.rounded())
        guard let context = bitmapContext(width: width, height: height) else { return nil }
        let scale = self.scale(for: canvas)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for stroke in strokes {
            guard stroke.points.count >= 2 else { continue }
            let components = HexColor.components(stroke.colorHex)
            // The highlighter reads as a translucent marker; the pen is solid.
            let alpha = stroke.tool == .highlighter ? 0.45 : 1.0
            context.setStrokeColor(CGColor(red: components.red, green: components.green,
                                           blue: components.blue,
                                           alpha: components.alpha * alpha))
            context.setLineWidth(CGFloat(stroke.width) * scale)
            let path = CGMutablePath()
            path.move(to: pixel(stroke.points[0], canvas: canvas))
            for point in stroke.points.dropFirst() {
                path.addLine(to: pixel(point, canvas: canvas))
            }
            context.addPath(path)
            context.strokePath()
        }
        guard let image = context.makeImage() else { return nil }
        return CIImage(cgImage: image)
    }

    /// The laser pointer dot: a soft translucent halo around a solid core
    /// with a white rim, so it reads over bright and dark content alike.
    private static func pointerRaster(at point: AnnotationPoint, canvas: CGRect) -> CIImage? {
        let width = Int(canvas.width.rounded())
        let height = Int(canvas.height.rounded())
        guard let context = bitmapContext(width: width, height: height) else { return nil }
        let scale = self.scale(for: canvas)
        let center = pixel(point, canvas: canvas)
        let coreRadius = 5 * scale
        let haloRadius = 16 * scale
        context.setFillColor(CGColor(red: 1, green: 0.23, blue: 0.19, alpha: 0.30))
        context.fillEllipse(in: CGRect(x: center.x - haloRadius, y: center.y - haloRadius,
                                       width: haloRadius * 2, height: haloRadius * 2))
        context.setFillColor(CGColor(red: 1, green: 0.23, blue: 0.19, alpha: 0.95))
        context.fillEllipse(in: CGRect(x: center.x - coreRadius, y: center.y - coreRadius,
                                       width: coreRadius * 2, height: coreRadius * 2))
        context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.9))
        context.setLineWidth(max(1, 1.5 * scale))
        context.strokeEllipse(in: CGRect(x: center.x - coreRadius, y: center.y - coreRadius,
                                         width: coreRadius * 2, height: coreRadius * 2))
        guard let image = context.makeImage() else { return nil }
        return CIImage(cgImage: image)
    }

    /// Normalized top-left-origin point → bitmap pixel (drawing y-down
    /// displays upright as a CIImage).
    private static func pixel(_ point: AnnotationPoint, canvas: CGRect) -> CGPoint {
        CGPoint(x: CGFloat(point.x) * canvas.width,
                y: CGFloat(point.y) * canvas.height)
    }

    private static func bitmapContext(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// Strokes change only on commit (a drag's end), not per frame, so the
    /// raster caches by content + pixel size — a static annotation costs one
    /// texture draw per frame after its first paint (the renderer's
    /// generated-content cache precedent). The pointer is excluded: it moves
    /// at event rate and is a single cheap dot.
    private final class StrokeRasterCache: @unchecked Sendable {
        static let shared = StrokeRasterCache()

        private struct Key: Hashable {
            let fingerprint: Int
            let width: Int
            let height: Int
        }

        private var lock = os_unfair_lock_s()
        private var cache: [Key: CIImage] = [:]
        private let limit = 16

        func raster(for strokes: [AnnotationStroke], canvas: CGRect) -> CIImage? {
            let key = Key(fingerprint: strokes.hashValue,
                          width: Int(canvas.width.rounded()),
                          height: Int(canvas.height.rounded()))
            os_unfair_lock_lock(&lock)
            if let cached = cache[key] {
                os_unfair_lock_unlock(&lock)
                return cached
            }
            os_unfair_lock_unlock(&lock)
            guard let raster = drawStrokes(strokes, canvas: canvas) else { return nil }
            os_unfair_lock_lock(&lock)
            if cache.count >= limit { cache.removeAll() }
            cache[key] = raster
            os_unfair_lock_unlock(&lock)
            return raster
        }
    }
}
