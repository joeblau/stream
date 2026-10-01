import CoreImage
import CoreMedia
import CoreText
import CoreVideo
import Metal

/// Composites one scene graph onto the output-profile canvas using a single
/// reused Metal-backed `CIContext` and a `CVPixelBufferPool` sized to the
/// canvas. Runs entirely inside the `CompositionEngine` actor (never on the
/// main actor); not thread-confined beyond that.
///
/// Layer model (S01): `scene.layers` is back-to-front; only `isVisible` layers
/// paint. Transforms are normalized 0…1 canvas coordinates with an anchor, so
/// the graph renders identically at any canvas size.
///
/// S07 (issue #74) compositing order, back to front: the explicit background
/// (`scene.background`, else the project default from `overlayContext`, else
/// the documented implicit black canvas) → the scene's visible layers → the
/// project-wide overlays from `overlayContext`, minus the scene's
/// `hiddenOverlayIDs` per-scene overrides. Overlays are shared branding —
/// stored once at document level, painted above every scene.
///
/// Source fallback (documented contract): a visible layer whose source has no
/// current pixels — screen capture not started, camera stalled past
/// `LatestCameraFrame`'s freshness window, or a payload kind with no renderer
/// yet (image/media/web/guest/…) — paints NOTHING, so the background shows
/// through. The tick is never gated on a source: the composition always
/// renders at the output fps from the latest sample each source produced.
///
/// Generated content (S07): solid-color shape and text layers have no
/// external source — the renderer rasterizes them itself (Core Graphics /
/// Core Text, off-main on the engine actor) at the layer's transform rect and
/// caches the raster by content + pixel size, so a static overlay costs
/// nothing per frame after its first paint.
///
/// Visual parity with the legacy `FacecamCompositor` path: camera layers are
/// mirrored (macOS cameras behave as `.front`); a camera layer narrower than
/// the canvas renders as the classic PIP — aspect-FILL cropped to a rounded
/// box (`size.width` is the classic 0.10…0.40 scale, height derived from the
/// source aspect, 24 px canvas-edge inset); fullscreen layers aspect-FIT
/// centered into their rect. `.opacity` and `.cornerRadius` effects are
/// honored; other effects are ignored per the LayerGraph contract.
final class SceneRenderer {

    private let ciContext: CIContext
    private let workingColorSpace = CGColorSpaceCreateDeviceRGB()
    private var pool: CVPixelBufferPool?
    private var poolWidth = 0
    private var poolHeight = 0
    private var formatDescription: CMVideoFormatDescription?

    /// Reused corner-rounding mask generator + cache (same rationale as
    /// FacecamCompositor: filter allocation at output fps is pure churn, and
    /// the PIP mask only changes when the box geometry does).
    private let roundedRectangleGenerator = CIFilter(name: "CIRoundedRectangleGenerator")
    private var cachedMask: CIImage?
    private var cachedMaskRect: CGRect = .null
    private var cachedMaskRadius: CGFloat = -1

    /// Reused gradient generator for gradient backgrounds (S07): same
    /// per-frame filter-allocation churn rationale as the PIP mask above.
    private let linearGradientGenerator = CIFilter(name: "CILinearGradient")

    /// S07 raster cache for generated content (shape/text layers): keyed by
    /// the full content + pixel-size descriptor, so a static overlay draws
    /// once and is composited from cache every frame after. Bounded — a
    /// resize drag churns sizes, so the cache clears itself past the cap.
    private struct GeneratedKey: Hashable {
        let descriptor: String
        let width: Int
        let height: Int
    }
    private var generatedCache: [GeneratedKey: CIImage] = [:]
    private let generatedCacheLimit = 64

    init() {
        let options: [CIContextOption: Any] = [
            .workingColorSpace: NSNull(),
            .cacheIntermediates: false
        ]
        if let device = MTLCreateSystemDefaultDevice() {
            ciContext = CIContext(mtlDevice: device, options: options)
        } else {
            ciContext = CIContext(options: options)
        }
    }

    /// Composites the background, the scene's visible layers (back-to-front),
    /// and the project overlays onto a pooled canvas-sized buffer, then wraps
    /// it in a `CMSampleBuffer` timed on the engine's shared clock.
    func render(scene: Scene,
                overlayContext: OverlayContext,
                canvasSize: CGSize,
                screen: CVPixelBuffer?,
                camera: LatestCameraFrame.Frame?,
                presentationTime: CMTime,
                frameDuration: CMTime,
                sequence: Int64) -> CompositedFrame? {
        let outWidth = Int(canvasSize.width.rounded())
        let outHeight = Int(canvasSize.height.rounded())
        guard outWidth > 1, outHeight > 1 else { return nil }
        let canvas = CGRect(x: 0, y: 0, width: outWidth, height: outHeight)

        // S07 order: explicit background → scene layers → project overlays.
        var output = backgroundImage(overlayContext.background(for: scene), canvas: canvas)
        for layer in scene.layers where layer.isVisible {
            guard let layerImage = image(for: layer, canvas: canvas,
                                         screen: screen, camera: camera) else {
                continue    // documented fallback: missing source → background shows through
            }
            output = layerImage.composited(over: output)
        }
        for overlay in overlayContext.overlays(for: scene) {
            guard let overlayImage = image(for: overlay, canvas: canvas,
                                           screen: screen, camera: camera) else {
                continue    // same fallback as scene layers
            }
            output = overlayImage.composited(over: output)
        }

        guard let pool = ensurePool(width: outWidth, height: outHeight) else { return nil }
        // Same steady-state budget as the legacy compositor: one buffer rendering
        // here, one in a subscriber, one pinned by the publisher's frame-repeat,
        // one of slack — with drop-oldest mailboxes a slow consumer can no longer
        // pin more than its mailbox capacity.
        let allocationLimit = [
            kCVPixelBufferPoolAllocationThresholdKey as String: 4
        ] as CFDictionary
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            kCFAllocatorDefault, pool, allocationLimit, &out
        ) == kCVReturnSuccess, let outBuffer = out else { return nil }

        ciContext.render(output, to: outBuffer, bounds: canvas, colorSpace: workingColorSpace)

        guard let sample = makeSampleBuffer(from: outBuffer,
                                            presentationTime: presentationTime,
                                            frameDuration: frameDuration) else { return nil }
        return CompositedFrame(sampleBuffer: sample,
                               presentationTime: presentationTime,
                               frameDuration: frameDuration,
                               sequence: sequence)
    }

    // MARK: - Layer rendering

    /// The placed, styled image for one layer, or nil when its source has no
    /// pixels (or no renderer yet) — the caller treats nil as "paint nothing".
    private func image(for layer: LayerNode,
                       canvas: CGRect,
                       screen: CVPixelBuffer?,
                       camera: LatestCameraFrame.Frame?) -> CIImage? {
        switch layer.payload {
        case .screen:
            guard let screen else { return nil }
            return place(source: CIImage(cvPixelBuffer: screen),
                         layer: layer, canvas: canvas, isCamera: false)
        case .camera:
            guard let camera else { return nil }
            // Mirror like the legacy path: every macOS camera is `.front`.
            let orientation: CGImagePropertyOrientation =
                camera.position == .front ? .upMirrored : .up
            return place(source: CIImage(cvPixelBuffer: camera.buffer).oriented(orientation),
                         layer: layer, canvas: canvas, isCamera: true)
        case .shape, .text:
            return placeGenerated(payload: layer.payload, layer: layer, canvas: canvas)
        default:
            // Payload kinds without a renderer yet (image, media, pdf, web,
            // guest, nested scene): documented fallback is the background
            // showing through; later waves add renderers behind this switch.
            return nil
        }
    }

    // MARK: - Backgrounds (S07)

    /// The canvas-sized background image. Nil background = the documented
    /// implicit black canvas; an image background has no render path yet (no
    /// asset store), so it paints the same black fallback.
    private func backgroundImage(_ background: SceneBackground?, canvas: CGRect) -> CIImage {
        switch background {
        case .solid(let colorHex):
            return CIImage(color: ciColor(colorHex)).cropped(to: canvas)
        case .gradient(let topColorHex, let bottomColorHex):
            // CI coordinates are bottom-left-origin: the "top" color anchors
            // at the canvas's maximum Y.
            guard let filter = linearGradientGenerator else {
                return CIImage(color: ciColor(topColorHex)).cropped(to: canvas)
            }
            filter.setValue(CIVector(x: canvas.midX, y: canvas.maxY), forKey: "inputPoint0")
            filter.setValue(ciColor(topColorHex), forKey: "inputColor0")
            filter.setValue(CIVector(x: canvas.midX, y: canvas.minY), forKey: "inputPoint1")
            filter.setValue(ciColor(bottomColorHex), forKey: "inputColor1")
            return (filter.outputImage ?? CIImage(color: ciColor(topColorHex))).cropped(to: canvas)
        case .image, nil:
            return CIImage(color: .black).cropped(to: canvas)
        }
    }

    // MARK: - Generated content (S07: shapes and text)

    /// The placed, styled image for a generated-content layer (shape/text):
    /// rasterized at the transform rect's pixel size (cached), translated
    /// into canvas position, then rotated and effect-styled like any layer.
    private func placeGenerated(payload: LayerPayload, layer: LayerNode, canvas: CGRect) -> CIImage? {
        let pixelWidth = Int((layer.transform.size.width * canvas.width).rounded())
        let pixelHeight = Int((layer.transform.size.height * canvas.height).rounded())
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }

        let content: CIImage?
        switch payload {
        case .shape(let shape):
            let descriptor = "shape|\(shape.shape.rawValue)|\(shape.fillColorHex)"
            content = generated(key: GeneratedKey(descriptor: descriptor,
                                                  width: pixelWidth, height: pixelHeight)) { context, rect in
                context.setFillColor(cgColor(shape.fillColorHex))
                switch shape.shape {
                case .rectangle:
                    context.fill(rect)
                case .roundedRectangle:
                    let radius = min(rect.width, rect.height) * 0.15
                    context.addPath(CGPath(roundedRect: rect, cornerWidth: radius,
                                           cornerHeight: radius, transform: nil))
                    context.fillPath()
                case .ellipse:
                    context.fillEllipse(in: rect)
                }
            }
        case .text(let text):
            guard !text.text.isEmpty else { return nil }
            // `fontSize` is points on the 1080p reference canvas; scale with
            // the actual output height so text tracks the render resolution.
            let scaledFontSize = text.fontSize * (canvas.height / 1080)
            let descriptor = "text|\(text.text)|\(text.fontName ?? "")|\(scaledFontSize)|\(text.colorHex)"
            content = generated(key: GeneratedKey(descriptor: descriptor,
                                                  width: pixelWidth, height: pixelHeight)) { context, rect in
                drawText(text.text, fontName: text.fontName, fontSize: scaledFontSize,
                         colorHex: text.colorHex, in: rect, context: context)
            }
        default:
            return nil
        }
        guard var image = content else { return nil }

        let rect = rectInCanvas(for: layer.transform, canvas: canvas,
                                width: CGFloat(pixelWidth), height: CGFloat(pixelHeight))
        image = image.transformed(by: CGAffineTransform(
            translationX: rect.minX - image.extent.minX,
            y: rect.minY - image.extent.minY))
        // Same placement-time corner rounding sourced layers get.
        let cornerRadius = layer.effects.compactMap { effect -> CGFloat? in
            if case .cornerRadius(let value) = effect { return CGFloat(value) }
            return nil
        }.first
        if let cornerRadius, cornerRadius > 0 {
            image = applyRoundedCorners(image, radius: cornerRadius, rect: rect)
        }
        image = rotated(image, degrees: layer.transform.rotationDegrees, around: rect)
        return applyEffects(image, layer: layer)
    }

    /// Returns the cached raster for `key`, or draws it into a fresh
    /// RGBA bitmap context and caches the result. The cache clears itself
    /// past the cap so a resize drag (a new size per frame) can't grow it
    /// without bound.
    private func generated(key: GeneratedKey,
                           draw: (CGContext, CGRect) -> Void) -> CIImage? {
        if let cached = generatedCache[key] { return cached }
        if generatedCache.count >= generatedCacheLimit {
            generatedCache.removeAll()
        }
        let rect = CGRect(x: 0, y: 0, width: key.width, height: key.height)
        guard let context = CGContext(data: nil,
                                      width: key.width,
                                      height: key.height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        draw(context, rect)
        guard let cgImage = context.makeImage() else { return nil }
        let image = CIImage(cgImage: cgImage)
        generatedCache[key] = image
        return image
    }

    /// Rasterizes text into the (already canvas-upright) bitmap context using
    /// Core Text — thread-safe off-main, unlike AppKit string drawing. The
    /// text is frame-set into the layer rect, clipped, and vertically
    /// centered within the frame it measures to.
    private func drawText(_ string: String,
                          fontName: String?,
                          fontSize: Double,
                          colorHex: String,
                          in rect: CGRect,
                          context: CGContext) {
        let font = CTFontCreateWithName((fontName ?? "Helvetica") as CFString,
                                        max(1, CGFloat(fontSize)), nil)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: cgColor(colorHex)
        ]
        guard let attributed = CFAttributedStringCreate(nil, string as CFString,
                                                        attributes as CFDictionary)
        else { return }
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        // Vertically center the measured text block inside the layer rect.
        let measured = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0), nil,
            CGSize(width: rect.width, height: .greatestFiniteMagnitude), nil)
        let textRect = CGRect(x: rect.minX,
                              y: rect.minY + (rect.height - min(measured.height, rect.height)) / 2,
                              width: rect.width,
                              height: min(measured.height, rect.height))
        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: 0, y: rect.height)
        context.scaleBy(x: 1, y: -1)
        let path = CGPath(rect: CGRect(x: textRect.minX,
                                       y: rect.height - textRect.maxY,
                                       width: textRect.width,
                                       height: textRect.height),
                          transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        CTFrameDraw(frame, context)
        context.restoreGState()
    }

    // MARK: - Colors

    private func ciColor(_ hex: String) -> CIColor {
        let components = HexColor.components(hex)
        return CIColor(red: components.red, green: components.green,
                       blue: components.blue, alpha: components.alpha)
    }

    private func cgColor(_ hex: String) -> CGColor {
        let components = HexColor.components(hex)
        return CGColor(red: components.red, green: components.green,
                       blue: components.blue, alpha: components.alpha)
    }

    /// Places a source image according to the layer's normalized transform.
    /// Camera layers narrower than the canvas take the classic PIP treatment
    /// (fill-crop, rounded corners, edge inset); everything else aspect-fits
    /// centered into its anchor-resolved rect.
    private func place(source: CIImage,
                       layer: LayerNode,
                       canvas: CGRect,
                       isCamera: Bool) -> CIImage? {
        let extent = source.extent
        guard extent.width > 0, extent.height > 0 else { return nil }

        let cornerRadius = layer.effects.compactMap { effect -> CGFloat? in
            if case .cornerRadius(let value) = effect { return CGFloat(value) }
            return nil
        }.first

        let placed: CIImage
        if isCamera, layer.transform.size.width < 1 {
            placed = placePIP(source: source, layer: layer, canvas: canvas,
                              cornerRadius: cornerRadius ?? 16)
        } else {
            placed = placeFit(source: source, layer: layer, canvas: canvas,
                              cornerRadius: cornerRadius)
        }

        return applyEffects(placed, layer: layer)
    }

    /// Aspect-FIT centered in the transform's rect. The rect comes from the
    /// normalized position/size/anchor (top-left-origin graph coordinates
    /// mapped into CI's bottom-left-origin canvas space).
    private func placeFit(source: CIImage,
                          layer: LayerNode,
                          canvas: CGRect,
                          cornerRadius: CGFloat?) -> CIImage {
        let rect = rectInCanvas(for: layer.transform, canvas: canvas,
                                width: layer.transform.size.width * canvas.width,
                                height: layer.transform.size.height * canvas.height)
        let extent = source.extent
        let fit = min(rect.width / extent.width, rect.height / extent.height)
        var image = source.transformed(by: CGAffineTransform(scaleX: fit, y: fit))
        image = image.transformed(by: CGAffineTransform(
            translationX: rect.midX - image.extent.midX,
            y: rect.midY - image.extent.midY))
        if let cornerRadius, cornerRadius > 0 {
            image = applyRoundedCorners(image, radius: cornerRadius, rect: rect)
        }
        return rotated(image, degrees: layer.transform.rotationDegrees, around: rect)
    }

    /// The classic camera PIP: box width = `size.width` (clamped 0.10…0.40) ×
    /// canvas width, height from the source aspect, positioned by the anchor's
    /// canvas corner with a 24 px inset, aspect-FILL cropped, rounded corners.
    private func placePIP(source: CIImage,
                          layer: LayerNode,
                          canvas: CGRect,
                          cornerRadius: CGFloat) -> CIImage {
        let extent = source.extent
        let clampedScale = max(0.10, min(0.40, layer.transform.size.width))
        let boxW = canvas.width * clampedScale
        let boxH = boxW * (extent.height / extent.width)
        let inset: CGFloat = 24

        var rect = rectInCanvas(for: layer.transform, canvas: canvas,
                                width: boxW, height: boxH)
        // The transform positions the box flush with its anchor corner; the
        // inset pushes it off the canvas edge(s) it is anchored to.
        let anchor = anchorFraction(layer.transform.anchor)
        if anchor.x == 0 { rect.origin.x += inset }
        if anchor.x == 1 { rect.origin.x -= inset }
        if anchor.y == 0 { rect.origin.y += inset }
        if anchor.y == 1 { rect.origin.y -= inset }

        let fill = max(boxW / extent.width, boxH / extent.height)
        var image = source.transformed(by: CGAffineTransform(scaleX: fill, y: fill))
        image = image.transformed(by: CGAffineTransform(
            translationX: rect.minX - image.extent.minX,
            y: rect.minY - image.extent.minY))
        image = image.cropped(to: rect)
        image = applyRoundedCorners(image, radius: cornerRadius, rect: rect)
        return rotated(image, degrees: layer.transform.rotationDegrees, around: rect)
    }

    /// Resolves a normalized transform into a canvas rect (CI coordinates).
    /// `position` refers to the layer's anchor point; graph coordinates are
    /// top-left-origin, CI is bottom-left-origin.
    private func rectInCanvas(for transform: LayerTransform,
                              canvas: CGRect,
                              width: CGFloat,
                              height: CGFloat) -> CGRect {
        let anchor = anchorFraction(transform.anchor)
        let topLeftX = transform.position.x * canvas.width - anchor.x * width
        let topLeftY = transform.position.y * canvas.height - anchor.y * height
        return CGRect(x: canvas.minX + topLeftX,
                      y: canvas.maxY - topLeftY - height,
                      width: width, height: height)
    }

    /// The layer point `position` refers to, as a 0…1 fraction in
    /// top-left-origin layer space.
    private func anchorFraction(_ anchor: LayerAnchor) -> (x: CGFloat, y: CGFloat) {
        switch anchor {
        case .topLeft: return (0, 0)
        case .topRight: return (1, 0)
        case .bottomLeft: return (0, 1)
        case .bottomRight: return (1, 1)
        case .center: return (0.5, 0.5)
        }
    }

    private func applyEffects(_ image: CIImage, layer: LayerNode) -> CIImage {
        var image = image
        for effect in layer.effects {
            switch effect {
            case .opacity(let value):
                image = image.applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(value))
                ])
            case .cornerRadius:
                break   // applied during placement, where the rect is known
            case .border, .chromaKey:
                break   // ignored per the LayerGraph renderer contract
            }
        }
        return image
    }

    private func rotated(_ image: CIImage, degrees: Double, around rect: CGRect) -> CIImage {
        guard degrees != 0 else { return image }
        let radians = -CGFloat(degrees) * .pi / 180   // clockwise in top-left semantics
        let center = CGPoint(x: rect.midX, y: rect.midY)
        return image.transformed(by: CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: radians)
            .translatedBy(x: -center.x, y: -center.y))
    }

    // MARK: - Output buffer + timing

    private func makeSampleBuffer(from pixelBuffer: CVPixelBuffer,
                                  presentationTime: CMTime,
                                  frameDuration: CMTime) -> CMSampleBuffer? {
        let format: CMVideoFormatDescription
        if let formatDescription {
            format = formatDescription
        } else {
            var created: CMVideoFormatDescription?
            guard CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &created) == noErr,
                  let created else { return nil }
            formatDescription = created
            format = created
        }

        var timing = CMSampleTimingInfo(duration: frameDuration,
                                        presentationTimeStamp: presentationTime,
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }

    private func ensurePool(width: Int, height: Int) -> CVPixelBufferPool? {
        if let pool, width == poolWidth, height == poolHeight {
            return pool
        }
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ]
        var newPool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil,
                                      attrs as CFDictionary, &newPool) == kCVReturnSuccess else {
            return nil
        }
        pool = newPool
        poolWidth = width
        poolHeight = height
        formatDescription = nil
        return newPool
    }

    private func applyRoundedCorners(_ image: CIImage,
                                     radius: CGFloat,
                                     rect: CGRect) -> CIImage {
        guard let mask = roundedCornerMask(radius: radius, rect: rect) else { return image }
        return image.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(),
            kCIInputMaskImageKey: mask
        ])
    }

    private func roundedCornerMask(radius: CGFloat, rect: CGRect) -> CIImage? {
        if let cachedMask, cachedMaskRect == rect, cachedMaskRadius == radius {
            return cachedMask
        }
        guard let generator = roundedRectangleGenerator else { return nil }
        generator.setValue(CIVector(cgRect: rect), forKey: "inputExtent")
        generator.setValue(radius, forKey: "inputRadius")
        generator.setValue(CIColor.white, forKey: "inputColor")
        guard let mask = generator.outputImage else { return nil }
        cachedMask = mask
        cachedMaskRect = rect
        cachedMaskRadius = radius
        return mask
    }
}
