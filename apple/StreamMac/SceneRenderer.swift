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
/// Nested scenes (S06, issue #96): a `.scene` layer renders the referenced
/// scene's own layer stack recursively, rasterized at the layer rect's pixel
/// size and styled through the same anchor/rotation/effects path as generated
/// content. The reference resolves LIVE against the scene registry passed
/// into each render — never a copy — so a Taken edit to the referenced scene
/// updates every nesting site on the next tick. Background policy (documented
/// choice): the nested scene's EXPLICIT `Scene.background` is honored, but
/// there is no fallback to the project default or black — a nested scene
/// without its own background composites TRANSPARENT so the parent scene
/// shows through (the overlay-friendly default), and project overlays never
/// paint inside a nested scene (they are output-scope branding above the
/// top-level composition). Missing/dangling references and reference loops
/// paint nothing (the documented fallback); recursion is additionally capped
/// at `SceneGraph.maxNestingDepth` beyond the edit-time cycle check. A nested
/// scene whose entire (transitive) content is generated — text/shape only —
/// is STATIC: its raster is cached by transitive content fingerprint + pixel
/// size and baked through the CIContext, so it costs one texture draw per
/// frame after its first paint. A nested scene containing camera/screen
/// layers re-composites every frame, like any live source.
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

    /// S06 raster cache for STATIC nested scenes (transitively text/shape
    /// only): keyed by the transitive content fingerprint + pixel size, with
    /// rasters baked through the CIContext so a hit is one texture draw.
    /// Shares the generated cache's bound and clear-on-cap policy.
    private var nestedCache: [GeneratedKey: CIImage] = [:]

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
    /// it in a `CMSampleBuffer` timed on the engine's shared clock. `scenes`
    /// is the live scene-registry snapshot S06 nested-scene references
    /// resolve against. `frames` is the C01 per-source read path: each
    /// camera/screen layer resolves its capture identity (registry payload
    /// winning over inline, via `sourcePayloads`) and pulls THAT source's
    /// latest frame, so two camera layers paint two different cameras.
    func render(scene: Scene,
                overlayContext: OverlayContext,
                canvasSize: CGSize,
                frames: SourceFrameLookup,
                sourcePayloads: [SourceDefinitionID: LayerPayload],
                scenes: [SceneID: Scene],
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
                                         frames: frames, sourcePayloads: sourcePayloads,
                                         scenes: scenes, depth: 0, visited: [scene.id]) else {
                continue    // documented fallback: missing source → background shows through
            }
            output = layerImage.composited(over: output)
        }
        for overlay in overlayContext.overlays(for: scene) {
            guard let overlayImage = image(for: overlay, canvas: canvas,
                                           frames: frames, sourcePayloads: sourcePayloads,
                                           scenes: scenes, depth: 0, visited: [scene.id]) else {
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
    /// `depth`/`visited` are the S06 nested-scene recursion guards: how many
    /// reference hops deep this layer sits, and the scene IDs on its path.
    private func image(for layer: LayerNode,
                       canvas: CGRect,
                       frames: SourceFrameLookup,
                       sourcePayloads: [SourceDefinitionID: LayerPayload],
                       scenes: [SceneID: Scene],
                       depth: Int,
                       visited: Set<SceneID>) -> CIImage? {
        switch layer.payload {
        case .screen:
            guard let key = captureKey(for: layer, sourcePayloads: sourcePayloads),
                  let screen = frames.screen(key) else { return nil }
            return place(source: CIImage(cvPixelBuffer: screen),
                         layer: layer, canvas: canvas, isCamera: false)
        case .camera:
            guard let key = captureKey(for: layer, sourcePayloads: sourcePayloads),
                  let camera = frames.camera(key) else { return nil }
            // Mirror like the legacy path: every macOS camera is `.front`.
            let orientation: CGImagePropertyOrientation =
                camera.position == .front ? .upMirrored : .up
            return place(source: CIImage(cvPixelBuffer: camera.buffer).oriented(orientation),
                         layer: layer, canvas: canvas, isCamera: true)
        case .shape, .text:
            return placeGenerated(payload: layer.payload, layer: layer, canvas: canvas)
        case .scene(let reference):
            return placeNested(reference: reference, layer: layer, canvas: canvas,
                               frames: frames, sourcePayloads: sourcePayloads,
                               scenes: scenes, depth: depth, visited: visited)
        default:
            // Payload kinds without a renderer yet (image, media, pdf, web,
            // guest): documented fallback is the background showing through;
            // later waves add renderers behind this switch.
            return nil
        }
    }

    /// C01 (issue #76): the layer's capture identity — the registry source's
    /// payload when bound (the registry is the identity authority), else the
    /// inline payload. This is the SAME resolution the capture pool's demand
    /// uses, so the key always names the capture the pool actually runs.
    private func captureKey(for layer: LayerNode,
                            sourcePayloads: [SourceDefinitionID: LayerPayload]) -> CaptureSourceKey? {
        let payload = layer.sourceID.flatMap { sourcePayloads[$0] } ?? layer.payload
        switch payload {
        case .camera(let camera): return .camera(camera)
        case .screen(let screen): return .screen(screen)
        default: return nil
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
        guard let image = content else { return nil }
        return stylePlaced(content: image, layer: layer, canvas: canvas,
                           pixelWidth: pixelWidth, pixelHeight: pixelHeight)
    }

    /// The shared placement/styling tail for rasterized-content layers
    /// (generated shape/text and nested scenes): translate the raster into
    /// the transform's anchor-resolved canvas rect, round corners at
    /// placement time, rotate around the rect, then apply opacity-style
    /// effects — the same treatment sourced layers get.
    private func stylePlaced(content: CIImage, layer: LayerNode, canvas: CGRect,
                             pixelWidth: Int, pixelHeight: Int) -> CIImage {
        var image = content
        let rect = rectInCanvas(for: layer.transform, canvas: canvas,
                                width: CGFloat(pixelWidth), height: CGFloat(pixelHeight))
        image = image.transformed(by: CGAffineTransform(
            translationX: rect.minX - image.extent.minX,
            y: rect.minY - image.extent.minY))
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

    // MARK: - Nested scenes (S06, issue #96)

    /// The placed, styled image for a nested-scene layer: the referenced
    /// scene's layer stack composited at the layer rect's pixel size (cached
    /// when transitively static), then styled exactly like generated content.
    /// Nil — paint nothing — for a missing/dangling reference, a reference
    /// loop (the path-local `visited` guard), or recursion past
    /// `SceneGraph.maxNestingDepth` (defense beyond the edit-time check).
    private func placeNested(reference: SceneReferencePayload,
                             layer: LayerNode,
                             canvas: CGRect,
                             frames: SourceFrameLookup,
                             sourcePayloads: [SourceDefinitionID: LayerPayload],
                             scenes: [SceneID: Scene],
                             depth: Int,
                             visited: Set<SceneID>) -> CIImage? {
        guard depth < SceneGraph.maxNestingDepth,
              !visited.contains(reference.sceneID),
              let nested = scenes[reference.sceneID] else { return nil }
        let pixelWidth = Int((layer.transform.size.width * canvas.width).rounded())
        let pixelHeight = Int((layer.transform.size.height * canvas.height).rounded())
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }

        let path = visited.union([reference.sceneID])
        let content: CIImage?
        if isStaticContent(nested, scenes: scenes, visited: path) {
            // Static nested scene: one baked raster per content+size, then a
            // texture draw per frame — a static nested scene costs ~nothing.
            let fingerprint = nestedFingerprint(nested, scenes: scenes, visited: path)
            let key = GeneratedKey(descriptor: "nested|\(nested.id)|\(fingerprint)",
                                   width: pixelWidth, height: pixelHeight)
            content = cachedNested(key: key) {
                nestedContent(nested, pixelWidth: pixelWidth, pixelHeight: pixelHeight,
                              frames: frames, sourcePayloads: sourcePayloads,
                              scenes: scenes, depth: depth + 1, visited: path)
            }
        } else {
            content = nestedContent(nested, pixelWidth: pixelWidth, pixelHeight: pixelHeight,
                                    frames: frames, sourcePayloads: sourcePayloads,
                                    scenes: scenes, depth: depth + 1, visited: path)
        }
        guard let image = content else { return nil }
        return stylePlaced(content: image, layer: layer, canvas: canvas,
                           pixelWidth: pixelWidth, pixelHeight: pixelHeight)
    }

    /// The nested scene's layer stack composited over its OWN canvas rect
    /// (origin 0,0 at the layer rect's pixel size): its explicit background
    /// (else transparent — see the header's background policy), then its
    /// visible layers back-to-front. Project overlays stay outside: they are
    /// output-scope branding above the top-level composition only.
    private func nestedContent(_ scene: Scene,
                               pixelWidth: Int,
                               pixelHeight: Int,
                               frames: SourceFrameLookup,
                               sourcePayloads: [SourceDefinitionID: LayerPayload],
                               scenes: [SceneID: Scene],
                               depth: Int,
                               visited: Set<SceneID>) -> CIImage? {
        let canvas = CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight)
        var output = scene.background.map { backgroundImage($0, canvas: canvas) }
        for layer in scene.layers where layer.isVisible {
            guard let layerImage = image(for: layer, canvas: canvas,
                                         frames: frames, sourcePayloads: sourcePayloads,
                                         scenes: scenes, depth: depth, visited: visited) else {
                continue    // same documented fallback as top-level layers
            }
            output = output.map { layerImage.composited(over: $0) } ?? layerImage
        }
        return output
    }

    /// True when every visible layer of the scene (transitively, through
    /// nested references) paints without a live source — text/shape and
    /// unpainted model-only kinds only. Camera/screen layers make the scene
    /// dynamic: its content changes per frame and must not be cached.
    private func isStaticContent(_ scene: Scene,
                                 scenes: [SceneID: Scene],
                                 visited: Set<SceneID>) -> Bool {
        for layer in scene.layers where layer.isVisible {
            switch layer.payload {
            case .camera, .screen:
                return false
            case .scene(let reference):
                guard !visited.contains(reference.sceneID),
                      let child = scenes[reference.sceneID] else { continue }
                if !isStaticContent(child, scenes: scenes,
                                    visited: visited.union([reference.sceneID])) {
                    return false
                }
            default:
                continue
            }
        }
        return true
    }

    /// The cache fingerprint for a static nested scene: its full value hash
    /// PLUS the transitive fingerprints of every scene it references — a
    /// reference stores only the target's ID, so without the recursion an
    /// edit to a grandchild scene would leave the parent's raster stale.
    private func nestedFingerprint(_ scene: Scene,
                                   scenes: [SceneID: Scene],
                                   visited: Set<SceneID>) -> Int {
        var hasher = Hasher()
        hasher.combine(scene)
        for layer in scene.layers {
            guard case .scene(let reference) = layer.payload,
                  !visited.contains(reference.sceneID),
                  let child = scenes[reference.sceneID] else { continue }
            hasher.combine(nestedFingerprint(child, scenes: scenes,
                                             visited: visited.union([reference.sceneID])))
        }
        return hasher.finalize()
    }

    /// Returns the cached baked raster for a static nested scene, or renders,
    /// bakes (through the CIContext, so the cached value is a texture rather
    /// than a lazy filter graph that would re-evaluate per frame), and
    /// caches it. Shares the generated cache's clear-on-cap bound.
    private func cachedNested(key: GeneratedKey, render: () -> CIImage?) -> CIImage? {
        if let cached = nestedCache[key] { return cached }
        if nestedCache.count >= generatedCacheLimit {
            nestedCache.removeAll()
        }
        guard let rendered = render() else { return nil }
        let extent = rendered.extent
        guard !extent.isEmpty, !extent.isInfinite,
              let cgImage = ciContext.createCGImage(rendered, from: extent) else { return nil }
        let baked = CIImage(cgImage: cgImage)
        nestedCache[key] = baked
        return baked
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
