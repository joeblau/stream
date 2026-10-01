import CoreImage
import CoreMedia
import CoreText
import CoreVideo
import Metal
import StreamCore

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
/// `LatestCameraFrame`'s freshness window, media playout loading/errored/
/// stopped (A02), or a payload kind with no renderer yet (image/pdf/guest/…)
/// — paints NOTHING, so the background shows
/// through. The tick is never gated on a source: the composition always
/// renders at the output fps from the latest sample each source produced.
///
/// Media layers (A02, issue #97) take the standard transform path: the pulled
/// frame aspect-FITS centered into the layer's anchor-resolved rect, exactly
/// like screen layers — a fullscreen media layer letterboxes a mismatched
/// file aspect rather than cropping it (fill-crop remains the camera PIP
/// behavior only). Pause and the HOLD end action keep painting the last
/// pulled frame; the STOP end action and missing/unlinked sources clear it.
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
/// G03 (issue #106) layer styling (`LayerNode.style`) is a non-destructive,
/// alpha-preserving pass over the placed layer image, identical for sourced,
/// generated, and nested layers: shape MASK (rectangle/circle/custom —
/// custom assets are the P03 seam and render unmasked until resolvable) and
/// BORDER before rotation, PERSPECTIVE tilt (corner projection through
/// `CIPerspectiveTransform`) around the layer center, then the S04 rotation,
/// then OPACITY (the style's resting opacity multiplies any legacy
/// `.opacity` effect) and the drop SHADOW (the styled silhouette, tinted,
/// blurred, offset, composited underneath). All pixel measurements are
/// 1080p-reference pixels scaled by the render height. The shadow is
/// decorative and excluded from the canvas selection bounds; the perspective
/// quad IS the selection bounds (see CanvasInteractionView).
///
/// Visual parity with the legacy `FacecamCompositor` path: camera layers are
/// mirrored (macOS cameras behave as `.front`); a camera layer narrower than
/// the canvas renders as the classic PIP — aspect-FILL cropped to a rounded
/// box (`size.width` is the classic 0.10…0.40 scale, height derived from the
/// source aspect, 24 px canvas-edge inset); fullscreen layers aspect-FIT
/// centered into their rect. `.opacity` and `.cornerRadius` effects are
/// honored; other effects are ignored per the LayerGraph contract. E01 (issue
/// #101) source effects are a separate model (`LayerNode.effectOverrides` /
/// `SourceDefinition.effectDefaults`): framing reframes the source before
/// placement, picture adjustments recolor it after, and a bypassed stack is a
/// render no-op. E03 (issue #164) extends that model with a person-
/// segmentation background effect on camera layers: the mask is produced off
/// the render tick (`PersonSegmentationCoordinator`), blended here when
/// fresh, and falls back to the unmodified source whenever it isn't.
///
/// G02 (issue #110) text layers: the full `TextSourcePayload` style surface
/// (alignment, background bar, padding, auto-sized vs fixed box, wrapping,
/// overflow) rasterizes through the generated-content path — cached by
/// content + pixel size like shapes — and inherits G03 `LayerStyle` styling
/// unchanged through `stylePlaced`. `{token}` host/guest names resolve per
/// tick against `tokenProvider` and are part of the cache descriptor, so a
/// published name change re-rasterizes exactly once. Fonts resolve through
/// the pinned `TitleFontFallback` chain, so an exported/reopened document
/// renders deterministically on a machine missing the requested font, and
/// Unicode/emoji ride the same pinned per-glyph cascade. Timed/fly-in
/// visibility is RENDERER-SIDE and timestamp-parametrized (the documented
/// preference over an engine change): the model carries only durations, the
/// renderer anchors elapsed time to the first tick the layer paints after
/// being absent (a hide → show replays the animation), and applies the
/// fly-in/fade-out as a translate+alpha pass over the placed image — the
/// cached raster is never animation-keyed, and S09's
/// `layerOpacity`/`exitingLayers` fades stay the edit-driven visibility
/// seam.
///
/// S09 (issue #100): the per-frame parameters of a scene blend transition
/// (everything except stingers, which are a base-scene swap under a video
/// mask and ride the normal `render` path's `stinger:` parameter).
struct SceneBlend: Sendable {
    var style: SceneTransitionStyle
    /// 0...1 — 0 paints the outgoing scene, 1 the incoming one.
    var progress: Double
    var direction: TransitionDirection
    var dipColorHex: String
}

/// S09 (issue #100): `renderTransition` cross-fades/wipes/slides/dips
/// between two FULL scene composites per tick (project overlays stable above
/// the blend); stingers ride the normal `render` path's `stinger:` parameter
/// (the video mask composites above everything and the scene swaps under
/// it); per-layer show/hide fades ride `layerOpacity:`/`exitingLayers:`.
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

    /// E01 (issue #101): where the renderer snapshots the source registry's
    /// effect-defaults index — the lookup a bound layer WITHOUT its own
    /// `effectOverrides` inherits its framing/picture adjustments through.
    /// Defaults to the shared `SourceEffectsStore` (fed by `SceneStore`), so
    /// existing call sites need no new argument; tests can inject a fixed map.
    private let sourceEffectsProvider: () -> [SourceDefinitionID: SourceEffects]

    /// E03 (issue #164): the person-segmentation coordinator camera layers
    /// with a background effect submit to (non-blocking) and pull the latest
    /// mask from. Defaults to the process-wide shared instance, so the
    /// preview and program engines share one segmentation per camera instead
    /// of paying for it twice.
    private let segmentation: PersonSegmentationCoordinator

    /// G02 (issue #110): where the renderer snapshots the live title-token
    /// values (`{host}`/`{guest}` display names) each text layer resolves
    /// against. Defaults to the shared `TitleTokenStore`; tests can inject a
    /// fixed map.
    private let tokenProvider: () -> [String: String]

    /// E03: the current tick's frame interval in milliseconds, set by
    /// `render`/`renderTransition` before any layer work so the segmentation
    /// governor budgets against the real cadence. Renderer state is
    /// engine-actor-confined, so a per-tick property is safe.
    private var currentFrameIntervalMs = 33.3

    /// G02 (issue #110): the current tick's clock seconds, set by
    /// `render`/`renderTransition` before any layer work — the timestamp the
    /// timed/fly-in title visibility samples against.
    private var currentPresentationSeconds = 0.0
    /// G02: per-layer timed-visibility anchors — the clock seconds at which
    /// each timed text layer FIRST painted after being absent. A layer absent
    /// from a tick is pruned (`textTimingSeen` is rebuilt per render call),
    /// so a hide → show replays the fly-in. Engine-actor-confined state,
    /// same rule as `currentFrameIntervalMs`.
    private var textTimingStart: [LayerID: Double] = [:]
    private var textTimingSeen: Set<LayerID> = []

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

    init(sourceEffectsProvider: @escaping () -> [SourceDefinitionID: SourceEffects] =
            { SourceEffectsStore.shared.snapshot() },
         segmentation: PersonSegmentationCoordinator = .shared,
         tokenProvider: @escaping () -> [String: String] =
            { TitleTokenStore.shared.snapshot() }) {
        self.sourceEffectsProvider = sourceEffectsProvider
        self.segmentation = segmentation
        self.tokenProvider = tokenProvider
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
    ///
    /// S09 (issue #100) additions:
    /// - `layerOpacity`: per-layer alpha multipliers for in-flight
    ///   show/hide fades (1 = normal; absent = normal).
    /// - `exitingLayers`: layers mid fade-OUT after a hide/remove — their
    ///   old content composites ABOVE the scene's new stack (back-to-front
    ///   among themselves) until the fade completes.
    /// - `stinger`: the stinger transition's current video frame, composited
    ///   fullscreen (aspect-fill, alpha preserved) ABOVE everything — the
    ///   scene swap happens under it.
    func render(scene: Scene,
                overlayContext: OverlayContext,
                canvasSize: CGSize,
                frames: SourceFrameLookup,
                sourcePayloads: [SourceDefinitionID: LayerPayload],
                scenes: [SceneID: Scene],
                presentationTime: CMTime,
                frameDuration: CMTime,
                sequence: Int64,
                layerOpacity: [LayerID: Double] = [:],
                exitingLayers: [LayerNode] = [],
                stinger: CVPixelBuffer? = nil,
                annotations: AnnotationRenderSnapshot = .empty) -> CompositedFrame? {
        let outWidth = Int(canvasSize.width.rounded())
        let outHeight = Int(canvasSize.height.rounded())
        guard outWidth > 1, outHeight > 1 else { return nil }
        let canvas = CGRect(x: 0, y: 0, width: outWidth, height: outHeight)
        currentFrameIntervalMs = max(1, CMTimeGetSeconds(frameDuration) * 1000)
        // G02: timed/fly-in titles sample against the engine clock; the seen
        // set rebuilds each call so an absent layer's anchor prunes (and its
        // next appearance replays the timing).
        currentPresentationSeconds = CMTimeGetSeconds(presentationTime)
        textTimingSeen.removeAll()

        var output = sceneComposite(scene, overlayContext: overlayContext, canvas: canvas,
                                    frames: frames, sourcePayloads: sourcePayloads,
                                    scenes: scenes, layerOpacity: layerOpacity,
                                    exitingLayers: exitingLayers)
        output = applyingOverlays(output, overlayContext: overlayContext, scene: scene,
                                  canvas: canvas, frames: frames,
                                  sourcePayloads: sourcePayloads, scenes: scenes)
        // G11 (issue #117): program annotations composite above the scene and
        // project overlays, below the stinger mask.
        output = AnnotationRenderer.composite(strokes: annotations.strokes[scene.id] ?? [],
                                              pointer: annotations.pointer?.sceneID == scene.id
                                                  ? annotations.pointer?.point : nil,
                                              onto: output, canvas: canvas)
        output = applyingStinger(output, stinger: stinger, canvas: canvas)
        pruneTextTimingAnchors()
        return finish(output, canvas: canvas, width: outWidth, height: outHeight,
                      presentationTime: presentationTime, frameDuration: frameDuration,
                      sequence: sequence)
    }

    /// S09 (issue #100): one frame of a scene blend transition — the
    /// outgoing and incoming scenes are BOTH composited this tick (shared
    /// sources keep pulling their latest frames, so neither side ever shows
    /// a missing frame) and blended at `blend.progress`. Project overlays
    /// composite ABOVE the blend (stable across the transition), under the
    /// INCOMING scene's per-scene visibility overrides from the first frame.
    func renderTransition(from: Scene,
                          to: Scene,
                          blend: SceneBlend,
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
        currentFrameIntervalMs = max(1, CMTimeGetSeconds(frameDuration) * 1000)
        currentPresentationSeconds = CMTimeGetSeconds(presentationTime)
        textTimingSeen.removeAll()

        let fromImage = sceneComposite(from, overlayContext: overlayContext, canvas: canvas,
                                       frames: frames, sourcePayloads: sourcePayloads,
                                       scenes: scenes, layerOpacity: [:], exitingLayers: [])
        let toImage = sceneComposite(to, overlayContext: overlayContext, canvas: canvas,
                                     frames: frames, sourcePayloads: sourcePayloads,
                                     scenes: scenes, layerOpacity: [:], exitingLayers: [])
        var output = blended(from: fromImage, to: toImage, blend: blend, canvas: canvas)
        output = applyingOverlays(output, overlayContext: overlayContext, scene: to,
                                  canvas: canvas, frames: frames,
                                  sourcePayloads: sourcePayloads, scenes: scenes)
        pruneTextTimingAnchors()
        return finish(output, canvas: canvas, width: outWidth, height: outHeight,
                      presentationTime: presentationTime, frameDuration: frameDuration,
                      sequence: sequence)
    }

    // MARK: - S09 blend math

    /// The per-frame blend of the two scene composites (no overlays — those
    /// stay stable above the blend). All styles keep both scenes' pixels
    /// live for the whole window, so a shared source never flickers out.
    private func blended(from: CIImage, to: CIImage, blend: SceneBlend, canvas: CGRect) -> CIImage {
        let progress = min(1, max(0, blend.progress))
        switch blend.style {
        case .dissolve, .stinger:
            // (Stingers never reach this path — the engine renders them as
            // a base swap under the video mask — but a dissolve is the
            // honest fallback if one ever did.)
            return to.applyingFilter("CIDissolveTransition", parameters: [
                "inputImage": from,
                "inputTargetImage": to,
                "inputTime": progress
            ])
        case .dipToColor:
            // Two-phase dissolve: out to the dip color over the first half,
            // the color in to the new scene over the second.
            let dip = CIImage(color: ciColor(blend.dipColorHex)).cropped(to: canvas)
            if progress < 0.5 {
                return dip.applyingFilter("CIDissolveTransition", parameters: [
                    "inputImage": from,
                    "inputTargetImage": dip,
                    "inputTime": progress * 2
                ])
            }
            return to.applyingFilter("CIDissolveTransition", parameters: [
                "inputImage": dip,
                "inputTargetImage": to,
                "inputTime": (progress - 0.5) * 2
            ])
        case .wipe:
            // Hard-edge wipe: the incoming scene is revealed by a rect
            // growing in the travel direction (CI is bottom-left-origin).
            let rect: CGRect
            switch blend.direction {
            case .right: rect = CGRect(x: 0, y: 0, width: canvas.width * progress, height: canvas.height)
            case .left:  rect = CGRect(x: canvas.width * (1 - progress), y: 0,
                                       width: canvas.width * progress, height: canvas.height)
            case .up:    rect = CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height * progress)
            case .down:  rect = CGRect(x: 0, y: canvas.height * (1 - progress),
                                       width: canvas.width, height: canvas.height * progress)
            }
            guard progress > 0 else { return from }
            return to.cropped(to: rect).composited(over: from)
        case .slide:
            // The incoming scene slides in over the outgoing one (which
            // stays put) — a push-over slide.
            let translation: CGVector
            switch blend.direction {
            case .right: translation = CGVector(dx: -canvas.width * (1 - progress), dy: 0)
            case .left:  translation = CGVector(dx: canvas.width * (1 - progress), dy: 0)
            case .up:    translation = CGVector(dx: 0, dy: -canvas.height * (1 - progress))
            case .down:  translation = CGVector(dx: 0, dy: canvas.height * (1 - progress))
            }
            guard progress < 1 else { return to }
            return to.transformed(by: CGAffineTransform(translationX: translation.dx,
                                                        y: translation.dy))
                .composited(over: from)
        case .cut:
            return to
        }
    }

    /// Alpha-multiplies a layer image for an in-flight visibility fade.
    private func applyingAlpha(_ image: CIImage, _ alpha: Double) -> CIImage {
        guard alpha < 0.999 else { return image }
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(max(0, alpha)))
        ])
    }

    /// Background + the scene's visible layers (back-to-front), with S09
    /// fade alpha applied per layer and exiting (fading-out) layers
    /// composited above the new stack in their old relative order.
    private func sceneComposite(_ scene: Scene,
                                overlayContext: OverlayContext,
                                canvas: CGRect,
                                frames: SourceFrameLookup,
                                sourcePayloads: [SourceDefinitionID: LayerPayload],
                                scenes: [SceneID: Scene],
                                layerOpacity: [LayerID: Double],
                                exitingLayers: [LayerNode]) -> CIImage {
        var output = backgroundImage(overlayContext.background(for: scene), canvas: canvas)
        for layer in scene.layers where layer.isVisible {
            guard let layerImage = image(for: layer, canvas: canvas,
                                         frames: frames, sourcePayloads: sourcePayloads,
                                         scenes: scenes, depth: 0, visited: [scene.id]) else {
                continue    // documented fallback: missing source → background shows through
            }
            output = applyingAlpha(layerImage, layerOpacity[layer.id] ?? 1)
                .composited(over: output)
        }
        for layer in exitingLayers {
            guard let layerImage = image(for: layer, canvas: canvas,
                                         frames: frames, sourcePayloads: sourcePayloads,
                                         scenes: scenes, depth: 0, visited: [scene.id]) else {
                continue    // same documented fallback
            }
            output = applyingAlpha(layerImage, layerOpacity[layer.id] ?? 1)
                .composited(over: output)
        }
        return output
    }

    /// The project overlays composited above a base image (S07 order), minus
    /// `scene`'s per-scene visibility overrides.
    private func applyingOverlays(_ output: CIImage,
                                  overlayContext: OverlayContext,
                                  scene: Scene,
                                  canvas: CGRect,
                                  frames: SourceFrameLookup,
                                  sourcePayloads: [SourceDefinitionID: LayerPayload],
                                  scenes: [SceneID: Scene]) -> CIImage {
        var output = output
        for overlay in overlayContext.overlays(for: scene) {
            guard let overlayImage = image(for: overlay, canvas: canvas,
                                           frames: frames, sourcePayloads: sourcePayloads,
                                           scenes: scenes, depth: 0, visited: [scene.id]) else {
                continue    // same fallback as scene layers
            }
            output = overlayImage.composited(over: output)
        }
        return output
    }

    /// S09: the stinger video frame composited fullscreen above everything —
    /// aspect-FILL (a mask covers the whole canvas; a mismatched aspect
    /// crops rather than letterboxes), alpha preserved for the wipe reveal.
    private func applyingStinger(_ output: CIImage, stinger: CVPixelBuffer?, canvas: CGRect) -> CIImage {
        guard let stinger else { return output }
        var image = CIImage(cvPixelBuffer: stinger)
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return output }
        let fill = max(canvas.width / extent.width, canvas.height / extent.height)
        image = image.transformed(by: CGAffineTransform(scaleX: fill, y: fill))
        image = image.transformed(by: CGAffineTransform(
            translationX: canvas.midX - image.extent.midX,
            y: canvas.midY - image.extent.midY))
        return image.composited(over: output)
    }

    /// Renders the finished composite into a pooled canvas-sized buffer and
    /// wraps it in a `CMSampleBuffer` timed on the engine's shared clock.
    private func finish(_ output: CIImage,
                        canvas: CGRect,
                        width outWidth: Int,
                        height outHeight: Int,
                        presentationTime: CMTime,
                        frameDuration: CMTime,
                        sequence: Int64) -> CompositedFrame? {
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
        case .syphon:
            // C09 (issue #163): syphon frames ride the keyed screen-frame
            // map the pool publishes (the C01 read path needs no syphon
            //-specific branch); premultiplied alpha composites through
            // `place` like any source.
            guard let key = captureKey(for: layer, sourcePayloads: sourcePayloads),
                  let syphon = frames.screen(key) else { return nil }
            return place(source: CIImage(cvPixelBuffer: syphon),
                         layer: layer, canvas: canvas, isCamera: false)
        case .camera:
            guard let key = captureKey(for: layer, sourcePayloads: sourcePayloads),
                  let camera = frames.camera(key) else { return nil }
            // Mirror like the legacy path: every macOS camera is `.front`.
            let orientation: CGImagePropertyOrientation =
                camera.position == .front ? .upMirrored : .up
            var source = CIImage(cvPixelBuffer: camera.buffer).oriented(orientation)
            // E03 (issue #164): the person-segmentation background effect
            // reframes nothing — it recomposites the raw source BEFORE E01
            // framing/placement, so the mask stays aligned with the pixels.
            if let effects = layer.effectiveSourceEffects(defaults: sourceEffectsProvider()),
               !effects.isBypassed, effects.hasBackgroundEffect {
                source = applyingBackgroundEffect(effects.background, to: source,
                                                  buffer: camera.buffer, key: key,
                                                  orientation: orientation)
            }
            return place(source: source, layer: layer, canvas: canvas, isCamera: true)
        case .media:
            // A02 (issue #97): media frames are PULLED per tick from the
            // pool's playback engine (the render tick is the cadence — no
            // second clock). A loading/errored/stopped source yields nil —
            // the documented paint-nothing fallback — while pause and the
            // HOLD end action keep serving the last pulled frame.
            guard let key = captureKey(for: layer, sourcePayloads: sourcePayloads),
                  let buffer = frames.media?(key) else { return nil }
            return place(source: CIImage(cvPixelBuffer: buffer),
                         layer: layer, canvas: canvas, isCamera: false)
        case .shape:
            return placeGenerated(payload: layer.payload, layer: layer, canvas: canvas)
        case .text(let text):
            // G02 (issue #110): the full title path — style surface, token
            // resolution, auto/fixed box, timed visibility.
            return placeText(text, layer: layer, canvas: canvas)
        case .scene(let reference):
            return placeNested(reference: reference, layer: layer, canvas: canvas,
                               frames: frames, sourcePayloads: sourcePayloads,
                               scenes: scenes, depth: depth, visited: visited)
        case .web(let web):
            // G07 (issue #114) prototype seam: with the explicit prototype
            // flag on, pull the widget's latest snapshot frame (published by
            // BrowserOverlayPrototype on its own clock, latest-wins like the
            // pool's screen-frame holders). Flag off — the shipping state —
            // or no fresh frame paints the documented nothing fallback.
            guard BrowserOverlayPrototypeFlag.isEnabled,
                  let key = web.url?.absoluteString,
                  let buffer = BrowserOverlayFrameStore.shared.latest(for: key) else { return nil }
            return place(source: CIImage(cvPixelBuffer: buffer),
                         layer: layer, canvas: canvas, isCamera: false)
        default:
            // Payload kinds without a renderer yet (image, pdf,
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
        case .syphon(let syphon): return .syphon(syphon)
        case .media:
            // A02: media keys are the registry source ID (playout/audio are
            // keyed by source, not payload — the payload can be edited
            // without restarting playback). Unbound media layers have no
            // key and paint the documented fallback.
            return layer.sourceID.map { .media($0) }
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

    // MARK: - Generated content (S07: shapes)

    /// The placed, styled image for a generated-content shape layer:
    /// rasterized at the transform rect's pixel size (cached), translated
    /// into canvas position, then rotated and effect-styled like any layer.
    /// (Text layers take the G02 `placeText` path.)
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
        default:
            return nil
        }
        guard let image = content else { return nil }
        return stylePlaced(content: image, layer: layer, canvas: canvas,
                           pixelWidth: pixelWidth, pixelHeight: pixelHeight)
    }

    // MARK: - G02 text layers (issue #110)

    /// The placed, styled image for a text layer: resolves `{token}` names,
    /// sizes the raster (auto-sized to the measured text, or the transform's
    /// fixed box with the overflow policy applied), draws through CoreText
    /// with the pinned font fallback, styles like any generated layer, then
    /// applies the renderer-side timed/fly-in visibility pass. Nil — paint
    /// nothing — for an empty string or an expired timed title.
    private func placeText(_ text: TextSourcePayload, layer: LayerNode, canvas: CGRect) -> CIImage? {
        let resolvedText = TitleTemplate.resolve(text.text, with: tokenProvider())
        guard !resolvedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        // Reference-canvas scale: fontSize/padding are 1080p reference units
        // (the standing text/style precedent).
        let scale = styleScale(canvas)
        let scaledFontSize = max(1, CGFloat(text.fontSize) * scale)
        let scaledPadding = max(0, CGFloat(text.padding) * scale)
        let transformWidth = max(1, layer.transform.size.width * canvas.width)
        let transformHeight = max(1, layer.transform.size.height * canvas.height)

        var font = TitleFontFallback.makeFont(requested: text.fontName, size: scaledFontSize)
        var effectiveFontSize = scaledFontSize
        let contentWidth: CGFloat
        let contentHeight: CGFloat
        switch text.boxSizing {
        case .auto:
            // Hug the measured text: width up to the transform's width when
            // wrapping (unbounded single line when not), height to the lines.
            let maxTextWidth = text.wraps
                ? max(1, transformWidth - scaledPadding * 2)
                : CGFloat.greatestFiniteMagnitude
            let measured = TextMeasurement.measuredSize(text: resolvedText, font: font,
                                                        maxWidth: maxTextWidth,
                                                        alignment: text.alignment,
                                                        wraps: text.wraps)
            contentWidth = max(1, measured.width)
            contentHeight = max(1, measured.height)
        case .fixed:
            // The transform rect is authoritative; scale-down shrinks the
            // font until the text fits (floor 25%), clip/ellipsis draw into
            // the box as-is.
            let boxWidth = max(1, transformWidth - scaledPadding * 2)
            let boxHeight = max(1, transformHeight - scaledPadding * 2)
            if text.overflow == .scaleDown {
                let measured = TextMeasurement.measuredSize(text: resolvedText, font: font,
                                                            maxWidth: boxWidth,
                                                            alignment: text.alignment,
                                                            wraps: text.wraps)
                let factor = CGFloat(TextMeasurement.scaleDownFactor(
                    measured: measured, box: CGSize(width: boxWidth, height: boxHeight)))
                if factor < 1 {
                    effectiveFontSize = max(1, scaledFontSize * factor)
                    font = TitleFontFallback.makeFont(requested: text.fontName,
                                                      size: effectiveFontSize)
                }
            }
            contentWidth = boxWidth
            contentHeight = boxHeight
        }

        // Cap the raster: a pathological unwrapped line must not allocate an
        // unbounded bitmap (the generated cache would churn it away anyway).
        let pixelWidth = Int((contentWidth + scaledPadding * 2).rounded(.up))
        let pixelHeight = Int((contentHeight + scaledPadding * 2).rounded(.up))
        guard pixelWidth > 0, pixelHeight > 0,
              pixelWidth <= 16384, pixelHeight <= 16384 else { return nil }

        // The cache descriptor covers everything the raster depends on —
        // resolved text (tokens included), the RESOLVED font, colors,
        // geometry — but never the timing, which animates the placed image.
        let fontPostScriptName = CTFontCopyPostScriptName(font) as String
        let descriptor = [
            "text2", resolvedText, fontPostScriptName, String(Double(effectiveFontSize)),
            text.colorHex, text.backgroundColorHex ?? "-", String(Double(scaledPadding)),
            text.alignment.rawValue, text.verticalAlignment.rawValue,
            text.boxSizing.rawValue, String(text.wraps), text.overflow.rawValue
        ].joined(separator: "|")
        let content = generated(key: GeneratedKey(descriptor: descriptor,
                                                  width: pixelWidth,
                                                  height: pixelHeight)) { context, rect in
            drawText(resolvedText, font: font,
                     colorHex: text.colorHex,
                     backgroundColorHex: text.backgroundColorHex,
                     alignment: text.alignment,
                     verticalAlignment: text.verticalAlignment,
                     padding: scaledPadding,
                     wraps: text.wraps,
                     overflow: text.overflow,
                     in: rect, context: context)
        }
        guard let content else { return nil }
        var image = stylePlaced(content: content, layer: layer, canvas: canvas,
                                pixelWidth: pixelWidth, pixelHeight: pixelHeight)

        // Timed/fly-in visibility: anchored to the first tick this layer
        // painted after being absent, sampled against the engine clock.
        if let timing = text.timing, timing.isActive {
            textTimingSeen.insert(layer.id)
            let start: Double
            if let anchored = textTimingStart[layer.id] {
                start = anchored
            } else {
                start = currentPresentationSeconds
                textTimingStart[layer.id] = start
            }
            let state = timing.state(atElapsed: currentPresentationSeconds - start)
            if state.isExpired { return nil }
            if state.travel > 0.001 {
                let offset = flyInOffset(direction: timing.flyInDirection,
                                         travel: state.travel,
                                         width: CGFloat(pixelWidth),
                                         height: CGFloat(pixelHeight))
                image = image.transformed(by: CGAffineTransform(translationX: offset.dx,
                                                                y: offset.dy))
            }
            if state.opacity < 0.999 {
                image = applyingAlpha(image, state.opacity)
            }
        }
        return image
    }

    /// The fly-in displacement for a travel fraction (1 = fully offset,
    /// 0 = at rest), in CI's bottom-left-origin space: "from bottom" starts
    /// the title BELOW its resting position (negative y).
    private func flyInOffset(direction: TitleFlyInDirection,
                             travel: Double,
                             width: CGFloat,
                             height: CGFloat) -> CGVector {
        let t = CGFloat(travel)
        switch direction {
        case .none: return CGVector(dx: 0, dy: 0)
        case .left: return CGVector(dx: -width * t, dy: 0)
        case .right: return CGVector(dx: width * t, dy: 0)
        case .top: return CGVector(dx: 0, dy: height * t)
        case .bottom: return CGVector(dx: 0, dy: -height * t)
        }
    }

    /// Drops the timing anchors of layers that didn't paint this render call
    /// (hidden, removed, or off the transitioned-away scene), so their next
    /// appearance re-anchors and replays the fly-in.
    private func pruneTextTimingAnchors() {
        guard !textTimingStart.isEmpty else { return }
        textTimingStart = textTimingStart.filter { textTimingSeen.contains($0.key) }
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
        image = applyingShapeStyle(layer.style, to: image, rect: rect, canvas: canvas)
        image = rotated(image, degrees: layer.transform.rotationDegrees, around: rect)
        return applyEffects(image, layer: layer, canvas: canvas)
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

    /// Rasterizes a G02 text layer into the (already canvas-upright) bitmap
    /// context using Core Text — thread-safe off-main, unlike AppKit string
    /// drawing. Order: the background bar fills the whole raster (padding
    /// included), then the text frame-sets into the padded inset with the
    /// horizontal/vertical alignment and the wrap/overflow line-break mode.
    /// The font arrives already resolved through the pinned fallback chain,
    /// so Unicode/emoji cascade deterministically.
    private func drawText(_ string: String,
                          font: CTFont,
                          colorHex: String,
                          backgroundColorHex: String?,
                          alignment: TextHorizontalAlignment,
                          verticalAlignment: TextVerticalAlignment,
                          padding: CGFloat,
                          wraps: Bool,
                          overflow: TextOverflow,
                          in rect: CGRect,
                          context: CGContext) {
        if let backgroundColorHex {
            context.setFillColor(cgColor(backgroundColorHex))
            context.fill(rect)
        }
        let inset = rect.insetBy(dx: padding, dy: padding)
        guard inset.width > 0, inset.height > 0 else { return }
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: cgColor(colorHex),
            kCTParagraphStyleAttributeName: TextMeasurement.paragraphStyle(
                alignment: alignment, wraps: wraps, overflow: overflow)
        ]
        guard let attributed = CFAttributedStringCreate(nil, string as CFString,
                                                        attributes as CFDictionary)
        else { return }
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        // Vertically place the measured text block inside the padded box.
        let measured = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0), nil,
            CGSize(width: inset.width, height: .greatestFiniteMagnitude), nil)
        let blockHeight = min(measured.height, inset.height)
        let blockMinY: CGFloat
        switch verticalAlignment {
        case .top: blockMinY = inset.maxY - blockHeight
        case .center: blockMinY = inset.minY + (inset.height - blockHeight) / 2
        case .bottom: blockMinY = inset.minY
        }
        let textRect = CGRect(x: inset.minX, y: blockMinY,
                              width: inset.width, height: blockHeight)
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
    /// unpainted model-only kinds only. Camera/screen/syphon/media layers
    /// make the scene dynamic: its content changes per frame and must not
    /// be cached.
    private func isStaticContent(_ scene: Scene,
                                 scenes: [SceneID: Scene],
                                 visited: Set<SceneID>) -> Bool {
        for layer in scene.layers where layer.isVisible {
            switch layer.payload {
            case .camera, .screen, .syphon, .media:
                return false
            case .text(let text):
                // G02 (issue #110): a timed/fly-in title animates per tick —
                // it must never bake into the static nested-scene cache.
                if text.timing?.isActive == true { return false }
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
    /// centered into its anchor-resolved rect. E01 (issue #101): the layer's
    /// effective source effects (its override, else the bound source's
    /// defaults) reframe the source BEFORE placement (zoom/pan crop, mirror,
    /// rotation) and adjust its picture AFTER (brightness/contrast/saturation/
    /// temperature/tint/gamma) — a bypassed or identity set is a render no-op.
    private func place(source: CIImage,
                       layer: LayerNode,
                       canvas: CGRect,
                       isCamera: Bool) -> CIImage? {
        let sourceEffects = layer.effectiveSourceEffects(defaults: sourceEffectsProvider())
        let framed = sourceEffects.map { applyingFraming($0, to: source) } ?? source
        let extent = framed.extent
        guard extent.width > 0, extent.height > 0 else { return nil }

        let cornerRadius = layer.effects.compactMap { effect -> CGFloat? in
            if case .cornerRadius(let value) = effect { return CGFloat(value) }
            return nil
        }.first

        let placed: CIImage
        if isCamera, layer.transform.size.width < 1 {
            placed = placePIP(source: framed, layer: layer, canvas: canvas,
                              cornerRadius: cornerRadius ?? 16)
        } else {
            placed = placeFit(source: framed, layer: layer, canvas: canvas,
                              cornerRadius: cornerRadius)
        }

        let adjusted = sourceEffects.map { applyingPictureAdjustments($0, to: placed) } ?? placed
        return applyEffects(adjusted, layer: layer, canvas: canvas)
    }

    // MARK: - E01 source effects (issue #101)

    /// The framing half of a source effect stack, applied to the raw source
    /// image BEFORE placement: mirror (horizontal flip about the extent),
    /// rotation (about the extent center — the rotated extent is what
    /// placement fits into the layer rect, so a 90° turn re-points a sideways
    /// camera instead of cropping it), then the zoom/pan crop (the extent
    /// shrunk by `zoom`, panned within the available slack, so the crop never
    /// leaves the source). All geometry-only — no color work here.
    private func applyingFraming(_ effects: SourceEffects, to source: CIImage) -> CIImage {
        guard !effects.isBypassed, effects.hasFraming else { return source }
        var image = source
        if effects.isMirrored {
            image = image.oriented(.upMirrored)
        }
        if effects.rotationDegrees != 0 {
            let extent = image.extent
            let center = CGPoint(x: extent.midX, y: extent.midY)
            let radians = -CGFloat(effects.rotationDegrees) * .pi / 180
            image = image.transformed(by: CGAffineTransform(translationX: center.x, y: center.y)
                .rotated(by: radians)
                .translatedBy(x: -center.x, y: -center.y))
        }
        let zoom = max(1, effects.zoom)
        if zoom > 1 {
            let extent = image.extent
            let cropWidth = extent.width / zoom
            let cropHeight = extent.height / zoom
            // Pan is a -1...1 fraction of the available slack, so every value
            // keeps the crop inside the source (±1 pins it to that edge).
            let maxDX = (extent.width - cropWidth) / 2
            let maxDY = (extent.height - cropHeight) / 2
            let centerX = extent.midX + CGFloat(effects.panX) * maxDX
            let centerY = extent.midY + CGFloat(effects.panY) * maxDY
            image = image.cropped(to: CGRect(x: centerX - cropWidth / 2,
                                             y: centerY - cropHeight / 2,
                                             width: cropWidth,
                                             height: cropHeight))
        }
        return image
    }

    /// The picture-adjustment half of a source effect stack, applied to the
    /// PLACED layer image (color-only, extent-preserving) through the shared
    /// Core Image pipeline: brightness/contrast/saturation via
    /// CIColorControls, white balance via CITemperatureAndTint (neutral
    /// 6500 K / tint 0 → target), gamma via CIGammaAdjust.
    private func applyingPictureAdjustments(_ effects: SourceEffects, to image: CIImage) -> CIImage {        guard !effects.isBypassed, effects.hasPictureAdjustments else { return image }
        var output = image
        if effects.brightness != 0 || effects.contrast != 1 || effects.saturation != 1 {
            output = output.applyingFilter("CIColorControls", parameters: [
                "inputBrightness": effects.brightness,
                "inputContrast": effects.contrast,
                "inputSaturation": effects.saturation
            ])
        }
        if effects.temperature != SourceEffects.neutralTemperature || effects.tint != 0 {
            output = output.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: CGFloat(SourceEffects.neutralTemperature), y: 0),
                "inputTargetNeutral": CIVector(x: CGFloat(effects.temperature),
                                               y: CGFloat(effects.tint))
            ])
        }
        if effects.gamma != 1 {
            output = output.applyingFilter("CIGammaAdjust", parameters: [
                "inputPower": effects.gamma
            ])
        }
        return output
    }

    // MARK: - E03 background effects (issue #164)

    /// The blur radius (source-resolution pixels) `strength` = 1 maps to.
    private static let maxBackgroundBlurRadius: CGFloat = 48
    /// The mask edge-feather ceiling (pixels) for replacement mode.
    private static let maxMaskFeatherRadius: CGFloat = 8

    /// Recomposites a camera source for its configured background effect:
    /// the segmented person over a blurred copy (blur) or a solid-color
    /// backdrop (replacement). The Vision mask is produced OFF the render
    /// tick by `PersonSegmentationCoordinator` — this method submits the
    /// current buffer (non-blocking, deduplicated per capture frame) and
    /// blends the latest FRESH mask. No fresh mask — unsupported device,
    /// governor suspension, Vision failure, or simply the first frames —
    /// composites the source UNMODIFIED: the clean fallback, and the reason
    /// the output cadence never depends on segmentation.
    private func applyingBackgroundEffect(_ settings: BackgroundEffectSettings,
                                          to source: CIImage,
                                          buffer: CVPixelBuffer,
                                          key: CaptureSourceKey,
                                          orientation: CGImagePropertyOrientation) -> CIImage {
        segmentation.submit(buffer, for: key, settings: settings,
                            frameIntervalMs: currentFrameIntervalMs)
        guard let maskBuffer = segmentation.latestMask(for: key) else {
            return source
        }
        let extent = source.extent
        guard extent.width > 0, extent.height > 0 else { return source }
        // The mask arrives at the segmentation quality's resolution in the
        // buffer's orientation: orient it like the source, then scale and
        // align it to the source extent so the blend matches pixel-for-pixel.
        var mask = CIImage(cvPixelBuffer: maskBuffer).oriented(orientation)
        let maskExtent = mask.extent
        guard maskExtent.width > 0, maskExtent.height > 0 else { return source }
        mask = mask.transformed(by: CGAffineTransform(
            scaleX: extent.width / maskExtent.width, y: extent.height / maskExtent.height))
        mask = mask.transformed(by: CGAffineTransform(
            translationX: extent.minX - mask.extent.minX, y: extent.minY - mask.extent.minY))

        let background: CIImage
        switch settings.mode {
        case .off:
            return source
        case .blur:
            // Clamp before blurring so the blur pulls edge pixels, not
            // transparent black, from outside the frame; crop back after.
            let radius = CGFloat(settings.strength) * Self.maxBackgroundBlurRadius
            background = source.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: ["inputRadius": radius])
                .cropped(to: extent)
        case .replacement:
            background = CIImage(color: ciColor(settings.replacementColorHex)).cropped(to: extent)
            let feather = CGFloat(settings.strength) * Self.maxMaskFeatherRadius
            if feather > 0 {
                mask = mask.clampedToExtent()
                    .applyingFilter("CIGaussianBlur", parameters: ["inputRadius": feather])
                    .cropped(to: extent)
            }
        }
        return source.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: background,
            kCIInputMaskImageKey: mask
        ])
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
        image = applyingShapeStyle(layer.style, to: image, rect: rect, canvas: canvas)
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
        image = applyingShapeStyle(layer.style, to: image, rect: rect, canvas: canvas)
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

    private func applyEffects(_ image: CIImage, layer: LayerNode, canvas: CGRect) -> CIImage {
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
                break   // legacy border is superseded by `LayerStyle.border`
                        // (G03); chromaKey is E02's seam in the styling pass
            }
        }
        // G03: the style's resting opacity multiplies any legacy fade value.
        let opacity = layer.style.opacity
        if opacity < 0.999 {
            image = image.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(max(0, opacity)))
            ])
        }
        return applyingShadow(layer.style, to: image, canvas: canvas)
    }

    // MARK: - G03 layer styling (issue #106)

    /// Reference-pixel scale: style geometry is authored against the 1080p
    /// canvas and scales with the render height (the text `fontSize`
    /// precedent), so a style renders identically at any encode resolution.
    private func styleScale(_ canvas: CGRect) -> CGFloat {
        canvas.height / 1080
    }

    /// The pre-rotation styling pass over a placed layer image: shape mask →
    /// border → perspective tilt. `rect` is the layer's anchor-resolved
    /// canvas rect (CI coordinates). Non-destructive and alpha-preserving:
    /// the mask is an alpha blend, the border an overlaid stroke raster, and
    /// perspective a corner projection of the layer box.
    private func applyingShapeStyle(_ style: LayerStyle, to image: CIImage,
                                    rect: CGRect, canvas: CGRect) -> CIImage {
        var image = image
        if style.hasMask {
            image = applyingMask(style.mask, to: image, rect: rect, canvas: canvas)
        }
        if style.hasBorder {
            image = applyingBorder(style.border, maskShape: style.mask, to: image,
                                   rect: rect, canvas: canvas)
        }
        if style.hasPerspective {
            image = applyingPerspective(style.perspective, to: image, rect: rect, canvas: canvas)
        }
        return image
    }

    /// Clips the layer image to the style mask's alpha. An unresolvable
    /// custom mask is the documented no-op (the P03 asset seam).
    private func applyingMask(_ mask: LayerMask, to image: CIImage,
                              rect: CGRect, canvas: CGRect) -> CIImage {
        guard let maskImage = maskImage(for: mask, rect: rect, canvas: canvas) else {
            return image
        }
        return image.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(),
            kCIInputMaskImageKey: maskImage
        ])
    }

    /// The mask image covering `rect`: the shape raster (cached by shape +
    /// pixel size through the generated-content cache), feathered, then
    /// optionally inverted. Feather blurs WITHOUT clamping so the edge fades
    /// to transparent rather than smearing edge pixels outward.
    private func maskImage(for mask: LayerMask, rect: CGRect, canvas: CGRect) -> CIImage? {
        let scale = styleScale(canvas)
        let pixelWidth = Int(rect.width.rounded())
        let pixelHeight = Int(rect.height.rounded())
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }
        let radius = min(CGFloat(mask.cornerRadius) * scale,
                         min(rect.width, rect.height) / 2)
        let shapeImage: CIImage?
        switch mask.shape {
        case .none:
            return nil
        case .rectangle:
            if radius > 0 {
                shapeImage = generated(key: GeneratedKey(descriptor: "g03mask|rounded|\(radius)",
                                                         width: pixelWidth,
                                                         height: pixelHeight)) { context, bounds in
                    context.setFillColor(CGColor(gray: 1, alpha: 1))
                    context.addPath(CGPath(roundedRect: bounds, cornerWidth: radius,
                                           cornerHeight: radius, transform: nil))
                    context.fillPath()
                }
            } else {
                shapeImage = CIImage(color: .white)
                    .cropped(to: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
            }
        case .circle:
            shapeImage = generated(key: GeneratedKey(descriptor: "g03mask|ellipse",
                                                     width: pixelWidth,
                                                     height: pixelHeight)) { context, bounds in
                context.setFillColor(CGColor(gray: 1, alpha: 1))
                context.fillEllipse(in: bounds)
            }
        case .custom:
            // P03 asset-library seam: no render path resolves asset
            // identifiers yet, so a custom mask renders the layer UNMASKED.
            return nil
        }
        guard var result = shapeImage else { return nil }
        result = result.transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
        let feather = CGFloat(mask.feather) * scale
        if feather > 0 {
            result = result.applyingFilter("CIGaussianBlur", parameters: ["inputRadius": feather])
        }
        if mask.isInverted {
            // Alpha invert: white wherever the mask is transparent.
            result = CIImage.empty().applyingFilter("CIBlendWithAlphaMask", parameters: [
                kCIInputBackgroundImageKey: CIImage(color: .white),
                kCIInputMaskImageKey: result
            ])
        }
        return result
    }

    /// The border stroke composited over the (masked) layer image. The
    /// stroke is rasterized INSIDE the rect (inset by half the line width)
    /// through the generated-content cache and follows the mask shape:
    /// ellipse for a circle mask, rounded rect for a rectangle mask, the
    /// plain rect otherwise.
    private func applyingBorder(_ border: LayerBorder, maskShape mask: LayerMask,
                                to image: CIImage, rect: CGRect, canvas: CGRect) -> CIImage {
        let scale = styleScale(canvas)
        let pixelWidth = Int(rect.width.rounded())
        let pixelHeight = Int(rect.height.rounded())
        let width = CGFloat(border.width) * scale
        guard pixelWidth > 0, pixelHeight > 0, width > 0 else { return image }
        let radius: CGFloat = mask.shape == .rectangle
            ? min(CGFloat(mask.cornerRadius) * scale, min(rect.width, rect.height) / 2)
            : 0
        let descriptor = "g03border|\(mask.shape.rawValue)|\(radius)|\(width)|\(border.colorHex)"
        let strokeImage = generated(key: GeneratedKey(descriptor: descriptor,
                                                      width: pixelWidth,
                                                      height: pixelHeight)) { context, bounds in
            let lineRect = bounds.insetBy(dx: width / 2, dy: width / 2)
            guard lineRect.width > 0, lineRect.height > 0 else { return }
            context.setStrokeColor(cgColor(border.colorHex))
            context.setLineWidth(width)
            if mask.shape == .circle {
                context.strokeEllipse(in: lineRect)
            } else if radius > 0 {
                context.addPath(CGPath(roundedRect: lineRect, cornerWidth: radius,
                                       cornerHeight: radius, transform: nil))
                context.strokePath()
            } else {
                context.stroke(lineRect)
            }
        }
        guard var stroke = strokeImage else { return image }
        stroke = stroke.transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
        return stroke.composited(over: image)
    }

    /// The perspective tilt: the layer image is cropped to its box (content
    /// outside the box is definitionally clipped under a tilt) and its
    /// corners projected through the pitch/yaw model. The projection helper
    /// works in y-down space; the renderer flips in and out of it (CI is
    /// bottom-left-origin), so the quad here is exactly the quad
    /// `CanvasGeometry` draws for the selection bounds.
    private func applyingPerspective(_ perspective: LayerPerspective, to image: CIImage,
                                     rect: CGRect, canvas: CGRect) -> CIImage {
        guard !perspective.isIdentity else { return image }
        let downRect = CGRect(x: rect.minX, y: canvas.maxY - rect.maxY,
                              width: rect.width, height: rect.height)
        let projected = perspective.projectedCorners(of: downRect)
        func ciPoint(_ point: CGPoint) -> CIVector {
            CIVector(x: point.x, y: canvas.maxY - point.y)
        }
        return image.cropped(to: rect).applyingFilter("CIPerspectiveTransform", parameters: [
            "inputTopLeft": ciPoint(projected.topLeft),
            "inputTopRight": ciPoint(projected.topRight),
            "inputBottomRight": ciPoint(projected.bottomRight),
            "inputBottomLeft": ciPoint(projected.bottomLeft)
        ])
    }

    /// The drop shadow composited UNDER the finished layer image: the
    /// styled silhouette (the shadow color masked by the layer's alpha),
    /// blurred and offset. Runs after opacity so the shadow dims with the
    /// layer. Decorative: excluded from the canvas selection bounds.
    private func applyingShadow(_ style: LayerStyle, to image: CIImage, canvas: CGRect) -> CIImage {
        let shadow = style.shadow
        guard shadow.isEnabled else { return image }
        let extent = image.extent
        guard !extent.isEmpty, !extent.isInfinite else { return image }
        let scale = styleScale(canvas)
        let components = HexColor.components(shadow.colorHex)
        var silhouette = CIImage(color: CIColor(red: components.red, green: components.green,
                                                blue: components.blue, alpha: components.alpha))
            .cropped(to: extent)
            .applyingFilter("CIBlendWithAlphaMask", parameters: [
                kCIInputBackgroundImageKey: CIImage.empty(),
                kCIInputMaskImageKey: image
            ])
        let radius = CGFloat(shadow.radius) * scale
        if radius > 0 {
            silhouette = silhouette.applyingFilter("CIGaussianBlur", parameters: ["inputRadius": radius])
        }
        // CI is bottom-left-origin: the +y-down offset becomes -y.
        silhouette = silhouette.transformed(by: CGAffineTransform(
            translationX: CGFloat(shadow.offsetX) * scale,
            y: -CGFloat(shadow.offsetY) * scale))
        return image.composited(over: silhouette)
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
