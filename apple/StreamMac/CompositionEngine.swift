import CoreMedia
import CoreVideo
import StreamCore
import os.lock

/// One composited program frame, stamped on the engine's shared monotonic
/// media clock. `@unchecked Sendable`: the `CMSampleBuffer` is a retained
/// CoreFoundation object shared read-only across subscribers, exactly like the
/// capture pipelines share their buffers.
struct CompositedFrame: @unchecked Sendable {
    /// Composited BGRA video, timed on the engine clock (see below).
    let sampleBuffer: CMSampleBuffer
    /// Presentation timestamp from the shared timebase (same value as the
    /// sample buffer's PTS; exposed so sinks needn't unpack the buffer).
    let presentationTime: CMTime
    /// Nominal frame duration (1 / output fps).
    let frameDuration: CMTime
    /// 1-based tick counter since the engine last (re)started its clock.
    let sequence: Int64

    var pixelBuffer: CVPixelBuffer? {
        CMSampleBufferGetImageBuffer(sampleBuffer)
    }
}

/// The process-wide hand-off of S07 project-level composition state (overlays
/// + default background) from `SceneStore` (main actor, writes on every
/// persist) to every `CompositionEngine` (its own actor, reads each tick).
/// This bridge exists because the engines' scene seam (`updateScene`) carries
/// only the per-scene value, and overlay edits are deliberately NOT part of
/// any scene's staged snapshot: they are project-level edits that apply
/// immediately to BOTH the staged and program compositions (live-safe, the
/// Ecamm-style behavior issue #74 describes), while per-scene overrides
/// (`Scene.hiddenOverlayIDs`, `Scene.background`) stay on the staged→program
/// Take path as ordinary scene content. Lock-protected value snapshots, so a
/// mid-tick publish can never tear a frame.
final class ProjectOverlayStore: @unchecked Sendable {
    static let shared = ProjectOverlayStore()

    private var lock = os_unfair_lock_s()
    private var context = OverlayContext.empty

    func publish(_ context: OverlayContext) {
        os_unfair_lock_lock(&lock)
        self.context = context
        os_unfair_lock_unlock(&lock)
    }

    func snapshot() -> OverlayContext {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return context
    }
}

/// The process-wide hand-off of the source registry's payload index (C01,
/// issue #76) from `SceneStore` (main actor, publishes on every mutation) to
/// every `CompositionEngine` (its own actor, snapshots each tick). The
/// renderer resolves a bound layer's `sourceID` through this index to the
/// DEFINITION's payload — the registry is the identity authority, exactly as
/// the capture pool's demand resolution reads it — so the layer's frame comes
/// from the source its registry binding names. Lock-protected value
/// snapshots, so a mid-tick publish can never tear a frame.
final class SourcePayloadStore: @unchecked Sendable {
    static let shared = SourcePayloadStore()

    private var lock = os_unfair_lock_s()
    private var payloads: [SourceDefinitionID: LayerPayload] = [:]

    func publish(_ sources: [SourceDefinition]) {
        let index = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0.payload) })
        os_unfair_lock_lock(&lock)
        self.payloads = index
        os_unfair_lock_unlock(&lock)
    }

    func snapshot() -> [SourceDefinitionID: LayerPayload] {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return payloads
    }
}

/// The process-wide hand-off of the scene registry (S06, issue #96) from
/// `SceneStore` (main actor, publishes on every mutation) to every
/// `CompositionEngine` (its own actor, snapshots each tick). S06 nested-scene
/// references resolve LIVE against this registry — never against a copy
/// baked into the staged/program snapshot — so editing a referenced scene
/// and Taking it (which persists through `SceneStore`) updates every nesting
/// site in both the staged and program compositions on their next tick. This
/// is the Take-policy reading of "shared child-scene edits propagate": a
/// staged (unpublished) edit to a child scene shows only in that child
/// scene's own preview; once Taken it propagates everywhere it is nested.
/// Lock-protected value snapshots, so a mid-tick publish can never tear a
/// frame.
final class SceneRegistryStore: @unchecked Sendable {
    static let shared = SceneRegistryStore()

    private var lock = os_unfair_lock_s()
    private var scenes: [SceneID: Scene] = [:]

    func publish(_ scenes: [Scene]) {
        let index = SceneGraph.index(scenes)
        os_unfair_lock_lock(&lock)
        self.scenes = index
        os_unfair_lock_unlock(&lock)
    }

    func snapshot() -> [SceneID: Scene] {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return scenes
    }
}

/// The W08 GPU composition engine (issue #65): renders the current scene graph
/// ONCE per output tick and broadcasts the result to any number of independent
/// consumers — preview, recording, publishers, and future virtual/NDI outputs.
///
/// Clock: one monotonic timebase for every output. At (re)start the engine
/// anchors on the host clock (`CMClockGetTime(CMClockGetHostTimeClock())`) and
/// derives each frame's PTS as `anchor + sequence / fps`, so every subscriber
/// sees identical, regularly spaced presentation timestamps regardless of
/// which source produced pixels or how jittery the tick loop is. A renderer
/// restart (profile change) re-anchors; that only happens when no output owns
/// the encode geometry (W07 staging rules).
///
/// Cadence: the engine ticks at the configured output fps whether or not any
/// source delivered a fresh frame — it always composites the LATEST sample
/// from each source (a static screen keeps its last buffer; a stalled camera
/// ages out via `LatestCameraFrame`). Missing sources render the documented
/// fallback (black — see `SceneRenderer`). The tick never gates on a source.
///
/// Fan-out: each subscriber gets a `FrameMailbox` — a bounded (default 2),
/// drop-oldest queue drained on its own serial dispatch queue. `post` is a
/// non-blocking O(1) hand-off from the engine, so a slow consumer only ever
/// drops its own frames and cannot stall the compositor or other outputs.
///
/// Concurrency: the engine is an actor; all rendering (CI/Metal) runs on its
/// executor, never on the main actor. Source frames are pulled through
/// injected, thread-safe providers (`LatestScreenFrame` / `LatestCameraFrame`
/// style lock-protected holders).
///
/// S09 (issue #100): a Take armed through `ProgramTransitionStore` turns the
/// scene switch into a rendered transition — both scene composites render
/// per tick and blend (overlays stable above the blend), or a stinger video
/// masks the cut-point swap — while same-scene visibility edits animate as
/// per-layer fades. Neither path blocks the tick cadence: the transition is
/// just the frame the tick renders.
actor CompositionEngine {
    /// Receives composited frames on the subscriber's private serial queue.
    typealias FrameSink = @Sendable (CompositedFrame) -> Void

    private let renderer = SceneRenderer()
    private let screenProvider: @Sendable () -> CVPixelBuffer?
    private let cameraProvider: @Sendable () -> LatestCameraFrame.Frame?
    /// C01 (issue #76): the per-source frame read path the renderer routes
    /// each camera/screen layer through. Defaults to the shared pool's keyed
    /// providers (with the injected legacy providers as the unknown-key
    /// fallback), so existing call sites need no new argument and the
    /// single-source behavior stays bit-identical.
    private let frameLookup: SourceFrameLookup
    /// A10 (issue #122): the lookup the renderer actually reads — `frameLookup`
    /// with each camera/screen read routed through the per-source video delay
    /// lines. Sources with no configured delay pass straight through (zero
    /// overhead); media playout is never delayed (it already rides the shared
    /// clock via the render-tick pull).
    private let delayedFrameLookup: SourceFrameLookup
    /// A10: the frame-hold stores behind `delayedFrameLookup`, configured via
    /// `setVideoDelays`.
    private let delayLines = VideoFrameDelayLines()
    /// A10: the persisted per-source video delays (ms) last pushed by the
    /// controller; re-rendered into frames whenever the output fps changes.
    private var videoDelaysMs: [CaptureSourceKey: Double] = [:]
    /// C01: where the engine snapshots the source registry's payload index
    /// each tick — the lookup a bound layer's `sourceID` resolves to its
    /// capture identity through. Defaults to the shared `SourcePayloadStore`
    /// (fed by `SceneStore`).
    private let sourcePayloadProvider: @Sendable () -> [SourceDefinitionID: LayerPayload]
    /// S07: where the engine reads the project-level overlay/background
    /// context each tick. Defaults to the shared `ProjectOverlayStore` (fed
    /// by `SceneStore`), so existing call sites need no new argument; tests
    /// and future wiring can inject any source.
    private let overlayContextProvider: @Sendable () -> OverlayContext
    /// S06: where the engine snapshots the scene registry each tick — the
    /// lookup S06 nested-scene references resolve against. Defaults to the
    /// shared `SceneRegistryStore` (fed by `SceneStore`).
    private let sceneRegistryProvider: @Sendable () -> [SceneID: Scene]
    /// S09: where the engine peeks at the armed Take transition (the
    /// dispatcher arms one per scene-change Take). Defaults to the shared
    /// `ProgramTransitionStore`.
    private let transitionRequestProvider: @Sendable () -> ProgramTransitionRequest?
    /// S09: where the engine pulls the in-flight stinger's playback state
    /// (frames + cut-point timing). Defaults to the shared
    /// `TransitionStingerStore` (driven by `TransitionController`).
    private let stingerProvider: @Sendable () -> StingerSnapshot
    /// G11 (issue #117): where the engine snapshots program annotations each
    /// tick. Defaults to the shared `ProgramAnnotationStore`; the preview
    /// engine injects `{ .empty }` because preview shows annotations as
    /// SwiftUI chrome (painting them into the image too would double-draw).
    private let annotationProvider: @Sendable () -> AnnotationRenderSnapshot

    private var scene: Scene?
    private var canvasSize: CGSize
    private var frameRate: Int

    /// S09 (issue #100): the in-flight scene transition, if any. Set by
    /// `updateScene` when a scene-id switch arrives with a fresh armed
    /// transition request (the dispatcher's Take path); rendered per tick by
    /// `renderTransitionFrame`; cleared on completion, on cut, and on
    /// engine (re)start.
    private var transition: ActiveTransition?
    /// S09: in-flight per-layer visibility fades (same-scene edits). Keyed
    /// by stable LayerID so an interrupted fade reverses from its current
    /// opacity — the defined final state is always the latest scene value.
    private var layerFades: [LayerID: LayerFade] = [:]

    private var tickTask: Task<Void, Never>?
    private var clockAnchor: CMTime = .zero
    private var frameSequence: Int64 = 0

    private var subscribers: [UUID: FrameMailbox] = [:]
    /// Tokens cancelled before their (asynchronously delivered) registration
    /// arrived; the late `addSink` is dropped instead of leaking a sink.
    private var cancelledTokens: Set<UUID> = []

    init(screenProvider: @escaping @Sendable () -> CVPixelBuffer?,
         cameraProvider: @escaping @Sendable () -> LatestCameraFrame.Frame?,
         frameLookup: SourceFrameLookup? = nil,
         sourcePayloadProvider: @escaping @Sendable () -> [SourceDefinitionID: LayerPayload] =
            { SourcePayloadStore.shared.snapshot() },
         overlayContextProvider: @escaping @Sendable () -> OverlayContext =
            { ProjectOverlayStore.shared.snapshot() },
         sceneRegistryProvider: @escaping @Sendable () -> [SceneID: Scene] =
            { SceneRegistryStore.shared.snapshot() },
         transitionRequestProvider: @escaping @Sendable () -> ProgramTransitionRequest? =
            { ProgramTransitionStore.shared.snapshot() },
         stingerProvider: @escaping @Sendable () -> StingerSnapshot =
            { TransitionStingerStore.shared.snapshot() },
         annotationProvider: @escaping @Sendable () -> AnnotationRenderSnapshot =
            { ProgramAnnotationStore.shared.snapshot() },
         canvasSize: CGSize = OutputProfile.default.canvasSize,
         frameRate: Int = OutputProfile.default.frameRate) {
        self.screenProvider = screenProvider
        self.cameraProvider = cameraProvider
        self.frameLookup = frameLookup ?? SourceFrameLookup(
            camera: { key in
                let frames = SourceFrameProviders.shared
                return frames.hasCameraSource(for: key)
                    ? frames.cameraFrame(for: key)
                    : cameraProvider()
            },
            screen: { key in
                let frames = SourceFrameProviders.shared
                return frames.hasScreenSource(for: key)
                    ? frames.screenFrame(for: key)
                    : screenProvider()
            },
            // A02 (issue #97): media layers pull their frame (and top up
            // their mix-engine audio) from the pool's playback engines on
            // this very tick — playout cadence IS the render tick, so media
            // adds no second clock. An unknown key means no playback engine
            // exists: the documented paint-nothing fallback.
            media: { key in
                let frames = SourceFrameProviders.shared
                return frames.hasMediaSource(for: key)
                    ? frames.mediaFrame(for: key)
                    : nil
            })
        self.sourcePayloadProvider = sourcePayloadProvider
        self.overlayContextProvider = overlayContextProvider
        self.sceneRegistryProvider = sceneRegistryProvider
        self.transitionRequestProvider = transitionRequestProvider
        self.stingerProvider = stingerProvider
        self.annotationProvider = annotationProvider
        self.canvasSize = canvasSize
        self.frameRate = frameRate
        // A10 (issue #122): wrap the resolved lookup with the delay lines.
        let delayLines = self.delayLines
        let rawLookup = self.frameLookup
        self.delayedFrameLookup = SourceFrameLookup(
            camera: { key in delayLines.cameraFrame(for: key, fresh: rawLookup.camera(key)) },
            screen: { key in delayLines.screenFrame(for: key, fresh: rawLookup.screen(key)) },
            media: rawLookup.media)
    }

    // MARK: - Lifecycle (driven by the W02 pipeline-demand model)

    /// Atomically (re)configures the composition and starts the tick loop.
    /// StreamController calls this when the W02 pipeline demand goes 0 → 1.
    func run(scene: Scene?, canvasSize: CGSize, frameRate: Int) {
        self.scene = scene
        self.canvasSize = canvasSize
        self.frameRate = max(1, frameRate)
        // S09: a (re)start lands on the composition directly — no
        // transition, no carried-over layer fades.
        transition = nil
        layerFades.removeAll()
        startTicking()
    }

    /// Stops composition (pipeline demand back to 0). Subscribers stay
    /// registered — they simply receive no frames until the next `run`.
    func stop() {
        tickTask?.cancel()
        tickTask = nil
    }

    // MARK: - Live reconfiguration

    /// Swaps the composed scene graph mid-program (scene switch/edit). The swap
    /// is a plain value assignment between ticks — the tick loop and clock keep
    /// running — so a Take changes the composition atomically per frame without
    /// interrupting cadence. W03 (preview/program) uses one engine per
    /// composition: StreamController runs a program engine (this path) plus a
    /// separate preview engine fed through the same `updateScene` seam.
    ///
    /// S09 (issue #100) transition handling: a same-scene edit diffs layer
    /// visibility and registers show/hide fades (rendered over the next
    /// ticks, never delaying the swap). A scene-ID switch with a fresh armed
    /// transition request (the dispatcher arms one per Take) opens an
    /// `ActiveTransition` instead of cutting; anything else cuts, abandoning
    /// any in-flight transition — the documented mid-transition Take policy
    /// is "the newest Take wins: cut to the newest target, then render that
    /// Take's own armed transition".
    func updateScene(_ scene: Scene?) {
        let previous = self.scene
        if let previous, let scene, previous.id == scene.id {
            registerLayerFades(from: previous, to: scene)
        } else {
            layerFades.removeAll()
        }
        self.scene = scene
        transition = resolveTransition(from: previous, to: scene)
    }

    /// Applies a new output geometry/fps. While running, this restarts the
    /// tick loop and re-anchors the clock (the renderer's pool/format
    /// description re-create themselves on the next frame at the new size).
    func setOutput(canvasSize: CGSize, frameRate: Int) {
        self.canvasSize = canvasSize
        self.frameRate = max(1, frameRate)
        // A10: the same millisecond delays span a different number of frames
        // at the new rate.
        applyVideoDelays()
        if tickTask != nil {
            startTicking()
        }
    }

    // MARK: - A10 video delay alignment (issue #122)

    /// Pushes the persisted per-source video delays (MILLISECONDS, keyed by
    /// capture identity). Each delayed source's frames are held in a bounded
    /// per-source line (`VideoFrameDelayLines`) and emitted that many output
    /// ticks later — compensation for capture latency differences, on the
    /// same shared clock, with no timestamp regressions (the output PTS is
    /// always `anchor + sequence / fps` regardless of source delay). Takes
    /// effect between ticks: no scene swap, no clock re-anchor, no click.
    func setVideoDelays(_ delaysMs: [CaptureSourceKey: Double]) {
        videoDelaysMs = delaysMs
        applyVideoDelays()
    }

    private func applyVideoDelays() {
        let fps = max(1, frameRate)
        var frames: [CaptureSourceKey: Int] = [:]
        for (key, ms) in videoDelaysMs {
            frames[key] = AVSyncDelay.videoFrames(forMilliseconds: ms, framesPerSecond: fps)
        }
        delayLines.setDelays(frames)
    }

    // MARK: - S09 scene transitions (issue #100)

    /// An in-flight scene transition. Blend styles (dissolve/dip/wipe/slide)
    /// are timed in frames against the tick counter; a stinger is timed on
    /// the shared host clock from playback start and completes when the
    /// stinger store clears (end/failure/supersession) or the safety cap
    /// trips.
    private struct ActiveTransition {
        var from: Scene
        var to: Scene
        /// The resolved style — a stinger whose media is missing resolves
        /// to `.dissolve` here (the documented honest fallback).
        var style: SceneTransitionStyle
        var startSequence: Int64
        var durationFrames: Int
        var direction: TransitionDirection
        var dipColorHex: String
        var stingerCutPointSeconds: Double
        var stingerStartedAt: CMTime
        var motionEasing: MotionEasing = .easeInOut
        var motionFallback: MotionFallback = .dissolve
    }

    /// One layer's in-flight visibility fade. `exitingLayer` holds the OLD
    /// content for a fade-out (the layer no longer renders from the new
    /// scene); nil for a fade-in. `backToFrontIndex` preserves the old
    /// z-order among exiting layers.
    private struct LayerFade {
        var exitingLayer: LayerNode?
        var backToFrontIndex: Int
        var fromOpacity: Double
        var toOpacity: Double
        var startSequence: Int64
        var durationFrames: Int
    }

    /// Show/hide fades are intentionally brief — long enough to read as a
    /// transition, short enough that a capture stopping on demand loss is
    /// unlikely to outlive the fade-out.
    private static let layerFadeDurationSeconds = 0.25
    /// A stinger that never reports its end (e.g. a file that fails after
    /// loading) still completes: the base scene has long since swapped at
    /// the cut point, so this cap only bounds the mask's lifetime.
    private static let stingerSafetySeconds = 10.0

    /// The transition a scene switch opens, if any: only a scene-ID change
    /// carrying a fresh armed request (a Take) transitions — plain edits,
    /// re-renders, and stale requests all cut.
    private func resolveTransition(from previous: Scene?, to scene: Scene?) -> ActiveTransition? {
        guard let previous, let scene, scene.id != previous.id,
              let request = transitionRequestProvider(),
              request.targetSceneID == scene.id,
              request.isFresh else { return nil }
        let config = request.transition
        let fps = max(1, frameRate)
        switch config.style {
        case .cut:
            return nil
        case .stinger:
            let stinger = stingerProvider()
            guard stinger.playback != nil else {
                return makeBlendTransition(from: previous, to: scene,
                                           style: .dissolve, config: config, fps: fps)
            }
            return ActiveTransition(from: previous, to: scene, style: .stinger,
                                    startSequence: frameSequence, durationFrames: 0,
                                    direction: config.direction,
                                    dipColorHex: config.dipColorHex,
                                    stingerCutPointSeconds: max(0, config.stingerCutPointSeconds),
                                    stingerStartedAt: stinger.startedAt)
        default:
            guard config.durationSeconds > 0 else { return nil }
            return makeBlendTransition(from: previous, to: scene,
                                       style: config.style, config: config, fps: fps)
        }
    }

    private func makeBlendTransition(from: Scene, to: Scene,
                                     style: SceneTransitionStyle,
                                     config: SceneTransition, fps: Int) -> ActiveTransition? {
        guard config.durationSeconds.isFinite, (0...10).contains(config.durationSeconds) else { return nil }
        let durationFrames = Int((config.durationSeconds * Double(fps)).rounded())
        guard durationFrames > 0 else { return nil }
        return ActiveTransition(from: from, to: to, style: style,
                                startSequence: frameSequence,
                                durationFrames: durationFrames,
                                direction: config.direction,
                                dipColorHex: config.dipColorHex,
                                stingerCutPointSeconds: 0,
                                stingerStartedAt: .zero,
                                motionEasing: config.motionEasing,
                                motionFallback: config.motionFallback)
    }

    /// One frame of the in-flight transition, or nil when the transition
    /// completes this tick (the caller then clears it and renders the
    /// settled scene — which is already `transition.to`, set at Take time).
    private func renderTransitionFrame(_ active: ActiveTransition,
                                       overlayContext: OverlayContext,
                                       sourcePayloads: [SourceDefinitionID: LayerPayload],
                                       scenes: [SceneID: Scene],
                                       presentationTime pts: CMTime,
                                       frameDuration: CMTime) -> CompositedFrame? {
        if active.style == .stinger {
            let stinger = stingerProvider()
            let elapsed = CMTimeSubtract(pts, active.stingerStartedAt).seconds
            let ended = stinger.playback == nil
                || (stinger.durationSeconds > 0
                    && elapsed > stinger.durationSeconds + 0.5)
                || elapsed > active.stingerCutPointSeconds + Self.stingerSafetySeconds
            guard !ended else { return nil }
            // The scene swaps under the stinger at the cut point; the video
            // mask (pulled per tick — the pull also tops up its mix audio)
            // covers the swap.
            let base = elapsed < active.stingerCutPointSeconds ? active.from : active.to
            let stingerFrame = stinger.playback?.pullFrame()
            return renderer.render(scene: base,
                                   overlayContext: overlayContext,
                                   canvasSize: canvasSize,
                                   frames: delayedFrameLookup,
                                   sourcePayloads: sourcePayloads,
                                   scenes: scenes,
                                   presentationTime: pts,
                                   frameDuration: frameDuration,
                                   sequence: frameSequence,
                                   stinger: stingerFrame)
        }
        let progress = Double(frameSequence - active.startSequence)
            / Double(max(1, active.durationFrames))
        guard progress < 1 else { return nil }
        return renderer.renderTransition(from: active.from, to: active.to,
                                         blend: SceneBlend(style: active.style,
                                                           progress: progress,
                                                           direction: active.direction,
                                                           dipColorHex: active.dipColorHex,
                                                           motionEasing: active.motionEasing,
                                                           motionFallback: active.motionFallback),
                                         overlayContext: overlayContext,
                                         canvasSize: canvasSize,
                                         frames: delayedFrameLookup,
                                         sourcePayloads: sourcePayloads,
                                         scenes: scenes,
                                         presentationTime: pts,
                                         frameDuration: frameDuration,
                                         sequence: frameSequence)
    }

    // MARK: - S09 layer show/hide fades

    /// Diffs a same-scene edit for layer visibility changes (individual
    /// layers and group toggles — a group's visibility edit flips each
    /// member's `isVisible`, so both land here) and registers fades.
    /// Interrupting a fade starts the reverse fade from the CURRENT
    /// interpolated opacity, so the defined final state of an interrupted
    /// transition is always the latest scene value.
    private func registerLayerFades(from old: Scene, to new: Scene) {
        let fps = max(1, frameRate)
        let durationFrames = max(1, Int((Self.layerFadeDurationSeconds * Double(fps)).rounded()))
        let oldVisible = Set(old.layers.filter(\.isVisible).map(\.id))
        let newVisible = Set(new.layers.filter(\.isVisible).map(\.id))
        for layer in new.layers where layer.isVisible && !oldVisible.contains(layer.id) {
            let current = currentFadeValue(layer.id) ?? 0
            layerFades[layer.id] = LayerFade(exitingLayer: nil,
                                             backToFrontIndex: 0,
                                             fromOpacity: current,
                                             toOpacity: 1,
                                             startSequence: frameSequence,
                                             durationFrames: durationFrames)
        }
        for (index, layer) in old.layers.enumerated()
        where layer.isVisible && !newVisible.contains(layer.id) {
            let current = currentFadeValue(layer.id) ?? 1
            layerFades[layer.id] = LayerFade(exitingLayer: layer,
                                             backToFrontIndex: index,
                                             fromOpacity: current,
                                             toOpacity: 0,
                                             startSequence: frameSequence,
                                             durationFrames: durationFrames)
        }
    }

    /// A fade's interpolated opacity right now, or its endpoint once past
    /// the duration (nil when no fade is in flight for the layer).
    private func currentFadeValue(_ id: LayerID) -> Double? {
        guard let fade = layerFades[id] else { return nil }
        let progress = Double(frameSequence - fade.startSequence)
            / Double(max(1, fade.durationFrames))
        guard progress < 1 else { return fade.toOpacity }
        return fade.fromOpacity + (fade.toOpacity - fade.fromOpacity) * max(0, progress)
    }

    /// The per-tick render inputs from the fade set: alpha overrides per
    /// layer and the exiting layers (old content, old back-to-front order).
    /// Completed fades leave the map here — fade-ins end at full opacity,
    /// fade-outs drop their layer.
    private func layerFadeOverrides() -> (opacity: [LayerID: Double], exiting: [LayerNode]) {
        guard !layerFades.isEmpty else { return ([:], []) }
        var opacity: [LayerID: Double] = [:]
        var exiting: [(index: Int, layer: LayerNode)] = []
        var completed: [LayerID] = []
        for (id, fade) in layerFades {
            let progress = Double(frameSequence - fade.startSequence)
                / Double(max(1, fade.durationFrames))
            guard progress < 1 else {
                completed.append(id)
                continue
            }
            opacity[id] = fade.fromOpacity
                + (fade.toOpacity - fade.fromOpacity) * max(0, progress)
            if let layer = fade.exitingLayer {
                exiting.append((fade.backToFrontIndex, layer))
            }
        }
        for id in completed {
            layerFades.removeValue(forKey: id)
        }
        return (opacity, exiting.sorted { $0.index < $1.index }.map(\.layer))
    }

    // MARK: - Subscriber fan-out

    /// Registers a frame sink under a caller-chosen token. The caller picks
    /// the token so subscription and cancellation can be issued from any
    /// context (e.g. MainActor) without awaiting the engine; a cancel that
    /// lands before its register is still honored.
    func addSink(token: UUID, capacity: Int = 2, sink: @escaping FrameSink) {
        if cancelledTokens.remove(token) != nil { return }
        subscribers[token] = FrameMailbox(capacity: capacity, token: token, sink: sink)
    }

    func removeSink(_ token: UUID) {
        if subscribers.removeValue(forKey: token) == nil {
            cancelledTokens.insert(token)
        }
    }

    var subscriberCount: Int { subscribers.count }

    // MARK: - Tick loop

    private func startTicking() {
        tickTask?.cancel()
        // Re-anchor the shared clock: PTS = anchor + sequence / fps.
        clockAnchor = CMClockGetTime(CMClockGetHostTimeClock())
        frameSequence = 0
        let interval = UInt64(1_000_000_000) / UInt64(max(1, frameRate))
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    /// One output frame: pull the latest sample from every source, composite
    /// the scene graph once, stamp it on the shared clock, and broadcast.
    /// Never gated on a fresh source frame (issue #65, criterion 2).
    ///
    /// S09: an in-flight scene transition renders instead of the settled
    /// scene (both sides keep compositing — the cadence never blocks and no
    /// output drops); completion falls through to the settled render in the
    /// same tick, so the tick that ends a transition already paints the new
    /// composition.
    private func tick() {
        guard let scene else { return }
        frameSequence += 1
        let timescale = CMTimeScale(max(1, frameRate))
        let pts = CMTimeAdd(clockAnchor, CMTime(value: frameSequence, timescale: timescale))
        let duration = CMTime(value: 1, timescale: timescale)
        let overlayContext = overlayContextProvider()
        let sourcePayloads = sourcePayloadProvider()
        let scenes = sceneRegistryProvider()
        let annotations = annotationProvider()

        if let active = transition {
            if let frame = renderTransitionFrame(active,
                                                 overlayContext: overlayContext,
                                                 sourcePayloads: sourcePayloads,
                                                 scenes: scenes,
                                                 presentationTime: pts,
                                                 frameDuration: duration) {
                for mailbox in subscribers.values {
                    mailbox.post(frame)
                }
                return
            }
            transition = nil   // completed this tick → settled render below
        }

        let fades = layerFadeOverrides()
        guard let frame = renderer.render(scene: scene,
                                          overlayContext: overlayContext,
                                          canvasSize: canvasSize,
                                          frames: delayedFrameLookup,
                                          sourcePayloads: sourcePayloads,
                                          scenes: scenes,
                                          presentationTime: pts,
                                          frameDuration: duration,
                                          sequence: frameSequence,
                                          layerOpacity: fades.opacity,
                                          exitingLayers: fades.exiting,
                                          annotations: annotations) else { return }
        for mailbox in subscribers.values {
            mailbox.post(frame)
        }
    }
}

/// One subscriber's bounded, drop-oldest frame queue. The engine's `post`
/// never blocks: at capacity the oldest pending frame is dropped. Delivery to
/// the sink happens on the mailbox's own serial queue, so a slow sink backs up
/// (and sheds) only its own frames.
private final class FrameMailbox: @unchecked Sendable {
    private let capacity: Int
    private let sink: CompositionEngine.FrameSink
    private let queue: DispatchQueue
    private var lock = os_unfair_lock_s()
    private var pending: [CompositedFrame] = []
    private var isDraining = false

    init(capacity: Int, token: UUID, sink: @escaping CompositionEngine.FrameSink) {
        self.capacity = max(1, capacity)
        self.sink = sink
        self.queue = DispatchQueue(label: "com.joeblau.StreamMac.engine.sink.\(token.uuidString)",
                                   qos: .userInitiated)
    }

    func post(_ frame: CompositedFrame) {
        os_unfair_lock_lock(&lock)
        if pending.count >= capacity {
            pending.removeFirst()   // drop-oldest
        }
        pending.append(frame)
        let shouldSchedule = !isDraining
        if shouldSchedule { isDraining = true }
        os_unfair_lock_unlock(&lock)
        if shouldSchedule {
            queue.async { self.drain() }
        }
    }

    private func drain() {
        while true {
            os_unfair_lock_lock(&lock)
            guard !pending.isEmpty else {
                isDraining = false
                os_unfair_lock_unlock(&lock)
                return
            }
            let frame = pending.removeFirst()
            os_unfair_lock_unlock(&lock)
            sink(frame)
        }
    }
}
