import CoreMedia
import CoreVideo
import StreamCore
import os.lock

#if STREAM_NATIVE_VALIDATION
/// Gates the real clock task at its actor suspension boundaries. Captured per
/// run so a fixture can release old work after stop/restart without a timer race.
struct CompositionClockValidationHooks: Sendable {
    var initialDeadlineOffset: Duration = .zero
    var beforeTick: (@Sendable () async -> Void)?
    var beforeMissedDeadlines: (@Sendable (Int) async -> Void)?
    var afterIteration: (@Sendable () async -> Void)?
    var onExit: (@Sendable () -> Void)?
}

#endif

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
/// Clock: one monotonic host timebase for every output. Each rendered frame
/// receives its actual host-clock PTS, shared by every subscriber. Missed
/// cadence opportunities therefore leave time gaps rather than compressing
/// media time. A renderer
/// restart (profile change) re-anchors; that only happens when no output owns
/// the encode geometry (W07 staging rules).
///
/// Cadence: the engine ticks at the configured output fps whether or not any
/// source delivered a fresh frame — it always composites the LATEST sample
/// from each source (a static screen keeps its last buffer; a stalled camera
/// ages out via `LatestCameraFrame`). Missing sources render the documented
/// fallback (black — see `SceneRenderer`). The tick never gates on a source.
///
/// Fan-out: a sealed broker holds two shared source frames and performs one
/// trusted transfer at a time. Each logical output owns an admitted private
/// pool and independent callback queue. Escaped consumer pixels cannot pin
/// the compositor's four-buffer source pool.
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
    private var metrics = CompositionMetrics()

    func metricsSnapshot() -> CompositionMetrics {
        var snapshot = metrics
        snapshot.sampledAt = ProcessInfo.processInfo.systemUptime
        for broker in [programDelivery, secondaryDelivery, cleanDelivery] {
            let health = broker.statistics()
            snapshot.subscriberQueueDepth += health.depth
            snapshot.subscriberDrops += health.drops
        }
        return snapshot
    }
    /// Receives composited frames on the subscriber's private serial queue.
    typealias FrameSink = FrameDeliverySink

    private let renderer = SceneRenderer()
    private let secondaryRenderer = SceneRenderer()
    private lazy var cleanRenderer = SceneRenderer()
    private var secondaryCanvasSize = CGSize(width: 720, height: 1280)
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
    private let frameOverrideProvider: @Sendable () -> Scene?

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
    /// elapsed time follows the host clock even when rendering skips ticks. Keyed
    /// by stable LayerID so an interrupted fade reverses from its current
    /// opacity — the defined final state is always the latest scene value.
    private var layerFades: [LayerID: LayerFade] = [:]

    private var tickTask: Task<Void, Never>?
    /// Cancellation alone does not revoke an actor call already enqueued by the
    /// old task. Each clock operation must still belong to this run at entry.
    private var clockAuthority = UUID()
    private var frameSequence: Int64 = 0

    private let programDelivery = FrameDeliveryBroker()
    private let secondaryDelivery = FrameDeliveryBroker()
    private let cleanDelivery = FrameDeliveryBroker()
    private let resourceWorkspaceID = UUID()
    private nonisolated let sourceResources = EngineSourceResources()
    private var subscribers: [UUID: FrameDeliveryLease] = [:]
    private var secondarySubscribers: [UUID: FrameDeliveryLease] = [:]
    private var cleanSubscribers: [UUID: FrameDeliveryLease] = [:]
    private var cleanRenderPermits: [UUID: @Sendable () -> Bool] = [:]
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
         frameRate: Int = OutputProfile.default.frameRate,
         frameOverrideProvider: @escaping @Sendable () -> Scene? = { nil }) {
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
            }, pdf: { key, size in SourceFrameProviders.shared.mediaFrame(for: key, canvasSize: size) })
        self.sourcePayloadProvider = sourcePayloadProvider
        self.overlayContextProvider = overlayContextProvider
        self.sceneRegistryProvider = sceneRegistryProvider
        self.transitionRequestProvider = transitionRequestProvider
        self.stingerProvider = stingerProvider
        self.annotationProvider = annotationProvider
        self.frameOverrideProvider = frameOverrideProvider
        self.canvasSize = canvasSize
        self.frameRate = frameRate
        // A10 (issue #122): wrap the resolved lookup with the delay lines.
        let delayLines = self.delayLines
        let rawLookup = self.frameLookup
        self.delayedFrameLookup = SourceFrameLookup(
            camera: { key in delayLines.cameraFrame(for: key, fresh: rawLookup.camera(key)) },
            screen: { key in delayLines.screenFrame(for: key, fresh: rawLookup.screen(key)) },
            media: rawLookup.media, pdf: rawLookup.pdf, guest: rawLookup.guest)
    }

    // MARK: - Lifecycle (driven by the W02 pipeline-demand model)

    /// Atomically (re)configures the composition and starts the tick loop.
    /// StreamController calls this when the W02 pipeline demand goes 0 → 1.
    func run(scene: Scene?, canvasSize: CGSize, frameRate: Int) {
        metrics = CompositionMetrics()
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
        clockAuthority = UUID()
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
    /// tick loop; timestamps remain on the host clock (the renderer's pool/format
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

    /// Owned output geometry stays fixed until all consumers are stopped.
    func setSecondaryOutput(canvasSize: CGSize) { secondaryCanvasSize = canvasSize }

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
        var startedAt: CMTime
        var durationSeconds: Double
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
        var startedAt: CMTime
        var durationSeconds: Double
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
                                    startedAt: mediaTime(), durationSeconds: 0,
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
                                startedAt: mediaTime(),
                                durationSeconds: Double(durationFrames) / Double(fps),
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
                                       frameDuration: CMTime,
                                       canvas: OutputCanvas = .program, clean: Bool = false) -> CompositedFrame? {
        let renderer = clean ? cleanRenderer : canvas == .program ? self.renderer : secondaryRenderer
        let canvasSize = canvas == .program ? self.canvasSize : secondaryCanvasSize
        let from = active.from.composition(for: canvas)
        let to = active.to.composition(for: canvas)
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
            let base = elapsed < active.stingerCutPointSeconds ? from : to
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
        let progress = max(0, CMTimeSubtract(pts, active.startedAt).seconds)
            / max(Double.ulpOfOne, active.durationSeconds)
        guard progress < 1 else { return nil }
        return renderer.renderTransition(from: from, to: to,
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
        let oldVisible = Set(old.layers.filter(\.isVisible).map(\.id))
        let newVisible = Set(new.layers.filter(\.isVisible).map(\.id))
        for layer in new.layers where layer.isVisible && !oldVisible.contains(layer.id) {
            let current = currentFadeValue(layer.id) ?? 0
            layerFades[layer.id] = LayerFade(exitingLayer: nil,
                                             backToFrontIndex: 0,
                                             fromOpacity: current,
                                             toOpacity: 1,
                                             startedAt: mediaTime(),
                                             durationSeconds: Self.layerFadeDurationSeconds)
        }
        for (index, layer) in old.layers.enumerated()
        where layer.isVisible && !newVisible.contains(layer.id) {
            let current = currentFadeValue(layer.id) ?? 1
            layerFades[layer.id] = LayerFade(exitingLayer: layer,
                                             backToFrontIndex: index,
                                             fromOpacity: current,
                                             toOpacity: 0,
                                             startedAt: mediaTime(),
                                             durationSeconds: Self.layerFadeDurationSeconds)
        }
    }

    /// A fade's interpolated opacity right now, or its endpoint once past
    /// the duration (nil when no fade is in flight for the layer).
    private func currentFadeValue(_ id: LayerID) -> Double? {
        guard let fade = layerFades[id] else { return nil }
        let progress = max(0, CMTimeSubtract(mediaTime(), fade.startedAt).seconds)
            / max(Double.ulpOfOne, fade.durationSeconds)
        guard progress < 1 else { return fade.toOpacity }
        return fade.fromOpacity + (fade.toOpacity - fade.fromOpacity) * max(0, progress)
    }

    /// The per-tick render inputs from the fade set: alpha overrides per
    /// layer and the exiting layers (old content, old back-to-front order).
    /// Completed fades leave the map here — fade-ins end at full opacity,
    /// fade-outs drop their layer.
    private func layerFadeOverrides(at pts: CMTime) -> (opacity: [LayerID: Double], exiting: [LayerNode]) {
        guard !layerFades.isEmpty else { return ([:], []) }
        var opacity: [LayerID: Double] = [:]
        var exiting: [(index: Int, layer: LayerNode)] = []
        var completed: [LayerID] = []
        for (id, fade) in layerFades {
            let progress = max(0, CMTimeSubtract(pts, fade.startedAt).seconds)
                / max(Double.ulpOfOne, fade.durationSeconds)
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

    /// Admission is complete before this actor ACK. Only independently backed
    /// frames reach the callback; no legacy original-buffer callback remains.
    @discardableResult
    func installFrameDelivery(token: UUID, domain: StableFrameDomainID, generation: UUID,
                              bank: RawVideoResourceBank, sourceBank: RawVideoResourceBank? = nil,
                              sourceReceipt: RawVideoResourceReceipt? = nil, transfer: FrameDeliveryTransfer = .copyBGRA,
                              capacity: Int = 2, cancellation: FrameDeliveryCancellation = FrameDeliveryCancellation(), canvas: OutputCanvas = .program, clean: Bool = false,
                              authorized: @escaping @Sendable () -> Bool = { true },
                              shouldTransfer: @escaping @Sendable () -> Bool = { true },
                              sink: @escaping FrameSink) throws -> FrameDeliveryLease {
        guard !cancellation.isCancelled else { throw FrameDeliveryFailure.cancelled }
        let broker = deliveryBroker(canvas: canvas, clean: clean)
        let lease = try broker.install(token: token, domain: domain, generation: generation, bank: bank,
            transfer: transfer, capacity: capacity, cancellation: cancellation, authorized: authorized, shouldTransfer: shouldTransfer, sink: sink)
        do { try ensureSourceBank(canvas: canvas, clean: clean, prepared: sourceBank, receipt: sourceReceipt) }
        catch { broker.remove(lease); throw error }
        if clean { cleanSubscribers[token] = lease; cleanRenderPermits[token] = authorized }
        else if canvas == .program { subscribers[token] = lease }
        else { secondarySubscribers[token] = lease }
        return lease
    }

    @discardableResult
    func removeFrameDelivery(_ lease: FrameDeliveryLease) -> FrameDeliveryStatistics {
        if subscribers[lease.token] == lease { subscribers[lease.token] = nil; return programDelivery.remove(lease) }
        if secondarySubscribers[lease.token] == lease { secondarySubscribers[lease.token] = nil; return secondaryDelivery.remove(lease) }
        if cleanSubscribers[lease.token] == lease {
            cleanSubscribers[lease.token] = nil; cleanRenderPermits[lease.token] = nil; return cleanDelivery.remove(lease)
        }
        return lease.finalStatistics ?? FrameDeliveryStatistics()
    }
    func cancelFrameDelivery(token: UUID) { removeSink(token) }
    func frameDeliveryStatistics(_ lease: FrameDeliveryLease) -> FrameDeliveryStatistics {
        for broker in [programDelivery, secondaryDelivery, cleanDelivery] where broker.isCurrent(lease) {
            return broker.statistics(for: lease)
        }
        return lease.finalStatistics ?? FrameDeliveryStatistics()
    }

    func frameDeliveryCanvasSize(canvas: OutputCanvas = .program) -> CGSize {
        canvas == .program ? canvasSize : secondaryCanvasSize
    }

    private func deliveryBroker(canvas: OutputCanvas, clean: Bool) -> FrameDeliveryBroker {
        clean ? cleanDelivery : canvas == .program ? programDelivery : secondaryDelivery
    }

    /// Include this synchronous request in the SAME pre-factory batch as the
    /// recipient bank. Preparation does not change the active source geometry.
    nonisolated func sourceFrameResourceRequest(canvasSize: CGSize, canvas: OutputCanvas = .program,
                                                clean: Bool = false) throws -> RawVideoResourceRequest {
        try sourceResources.request(size: canvasSize, canvas: canvas, clean: clean)
    }

    private func ensureSourceBank(canvas: OutputCanvas, clean: Bool, prepared: RawVideoResourceBank? = nil,
                                  receipt: RawVideoResourceReceipt? = nil) throws {
        let size = canvas == .program || clean ? canvasSize : secondaryCanvasSize
        let bank: RawVideoResourceBank
        if let prepared {
            guard let receipt else { throw FrameDeliveryFailure.invalidBank }
            bank = try sourceResources.commit(prepared, receipt: receipt, size: size, canvas: canvas, clean: clean)
        } else if let current = sourceResources.current(size: size, canvas: canvas, clean: clean) {
            bank = current
        } else {
            let request = try sourceResources.request(size: size, canvas: canvas, clean: clean)
            let receipt = try RawVideoResourceCoordinator.shared.reserveBatch([request])
            guard let prepared = receipt.banks.first else { throw FrameDeliveryFailure.invalidBank }
            do { bank = try sourceResources.commit(prepared, receipt: receipt, size: size, canvas: canvas, clean: clean) }
            catch { RawVideoResourceCoordinator.shared.rollback(receipt); throw error }
        }
        if clean { cleanRenderer.setFrameAllocator(bank) }
        else if canvas == .program { renderer.setFrameAllocator(bank) }
        else { secondaryRenderer.setFrameAllocator(bank) }
    }

    /// Compatibility registration still uses the sealed broker. Critical output
    /// starts use installFrameDelivery so admission failure is returned before
    /// their publisher/writer start ACK. This helper never exposes originals.
    func addSink(token: UUID, capacity: Int = 2, cancellation: FrameDeliveryCancellation = FrameDeliveryCancellation(), canvas: OutputCanvas = .program, canvasSize: CGSize? = nil, sink: @escaping FrameSink) {
        if canvas == .secondary, let canvasSize { secondaryCanvasSize = canvasSize }
        addCompatibilitySink(token: token, capacity: capacity, cancellation: cancellation, canvas: canvas, clean: false, authorized: { true }, sink: sink)
    }
    func addCleanSink(token: UUID, capacity: Int = 1, cancellation: FrameDeliveryCancellation = FrameDeliveryCancellation(), authorized: @escaping @Sendable () -> Bool = { true }, sink: @escaping FrameSink) {
        addCompatibilitySink(token: token, capacity: capacity, cancellation: cancellation, canvas: .program, clean: true, authorized: authorized, sink: sink)
    }
    private func addCompatibilitySink(token: UUID, capacity: Int, cancellation: FrameDeliveryCancellation, canvas: OutputCanvas, clean: Bool,
                                      authorized: @escaping @Sendable () -> Bool, sink: @escaping FrameSink) {
        guard !cancellation.isCancelled else { return }
        let size = canvas == .program || clean ? canvasSize : secondaryCanvasSize
        let domain = StableFrameDomainID(workspace: resourceWorkspaceID, kind: .validation,
            outputID: token.uuidString, plane: clean ? .clean : canvas == .program ? .program : .secondary)
        let generation = UUID()
        do {
            let receipt = try RawVideoResourceCoordinator.shared.reserveBatch([.init(domain: domain,
                descriptor: .init(width: max(1, Int(size.width.rounded())), height: max(1, Int(size.height.rounded())), capacity: max(4, min(64, capacity + 2))),
                sessionGeneration: generation)])
            guard let bank = receipt.banks.first else { return }
            do { try installFrameDelivery(token: token, domain: domain, generation: generation, bank: bank,
                capacity: capacity, cancellation: cancellation, canvas: canvas, clean: clean, authorized: authorized, sink: sink) }
            catch { RawVideoResourceCoordinator.shared.rollback(receipt) }
        } catch { /* No unadmitted/original-buffer fallback. */ }
    }

    func removeSink(_ token: UUID) {
        let primary = subscribers.removeValue(forKey: token)
        let secondary = secondarySubscribers.removeValue(forKey: token)
        let clean = cleanSubscribers.removeValue(forKey: token)
        cleanRenderPermits.removeValue(forKey: token)
        if let primary { programDelivery.remove(primary) }
        if let secondary { secondaryDelivery.remove(secondary) }
        if let clean { cleanDelivery.remove(clean) }
    }

    var subscriberCount: Int { subscribers.count + secondarySubscribers.count + cleanSubscribers.count }

    // MARK: - Tick loop

    private func mediaTime() -> CMTime {
        #if STREAM_NATIVE_VALIDATION
        if let validationTime { return validationTime }
        #endif
        return CMClockGetTime(CMClockGetHostTimeClock())
    }

    #if STREAM_NATIVE_VALIDATION
    // Drive actual compositor frames at explicit media times without coupling
    // pixel correctness to the host's scheduling or first-use shader latency.
    private var validationTime: CMTime?
    private var validationClockHooks = CompositionClockValidationHooks()
    func setValidationClockHooks(_ hooks: CompositionClockValidationHooks) {
        validationClockHooks = hooks
    }
    func validationMailboxProbe(token: UUID, canvas: OutputCanvas = .program, clean: Bool = false) -> CompositionMailboxValidationProbe? {
        deliveryBroker(canvas: canvas, clean: clean).validationProbe(token: token)
    }
    func validationBeforeFrameTransfer(_ hook: (@Sendable () -> Void)?, canvas: OutputCanvas = .program, clean: Bool = false) {
        deliveryBroker(canvas: canvas, clean: clean).validationBeforeTransfer(hook)
    }
    func validationFrameDeliveryBarrier(canvas: OutputCanvas = .program, clean: Bool = false) async {
        await deliveryBroker(canvas: canvas, clean: clean).validationTransferBarrier()
    }
    func prepareValidation(scene: Scene, canvasSize: CGSize, frameRate: Int, at time: CMTime) {
        validationTime = time
        run(scene: scene, canvasSize: canvasSize, frameRate: frameRate)
        stop()
    }
    func setValidationTime(_ time: CMTime) { validationTime = time }
    func renderValidationFrame(at time: CMTime) {
        validationTime = time
        // Explicit pixel validation has no autonomous clock owner. In particular,
        // prepareValidation intentionally stops its clock before this entry.
        autoreleasepool { tick(clockAuthority: nil) }
    }
    #endif

    private func startTicking() {
        tickTask?.cancel()
        let authority = UUID()
        clockAuthority = authority
        frameSequence = 0
        let interval = Duration.nanoseconds(Int64(1_000_000_000 / max(1, frameRate)))
        #if STREAM_NATIVE_VALIDATION
        let hooks = validationClockHooks
        #endif
        tickTask = Task { [weak self] in
            #if STREAM_NATIVE_VALIDATION
            defer { hooks.onExit?() }
            #endif
            let clock = ContinuousClock()
            var deadline = clock.now
            #if STREAM_NATIVE_VALIDATION
            deadline += hooks.initialDeadlineOffset
            #endif
            while !Task.isCancelled {
                #if STREAM_NATIVE_VALIDATION
                await hooks.beforeTick?()
                #endif
                await self?.tick(clockAuthority: authority)
                let next = CompositionFrameSchedule.next(after: deadline, interval: interval, completedAt: clock.now)
                deadline = next.deadline
                if next.skipped > 0 {
                    #if STREAM_NATIVE_VALIDATION
                    await hooks.beforeMissedDeadlines?(next.skipped)
                    #endif
                    await self?.noteMissedDeadlines(next.skipped, clockAuthority: authority)
                }
                #if STREAM_NATIVE_VALIDATION
                await hooks.afterIteration?()
                #endif
                if deadline <= clock.now {
                    // An overdue tick can run now. Yield so sustained overload
                    // cannot monopolize this actor or delay stop/reconfigure.
                    await Task.yield()
                } else {
                    // Live cadence requests no extra wake-coalescing tolerance.
                    // The executor or host may still resume after the deadline.
                    do { try await clock.sleep(until: deadline, tolerance: .zero) } catch { break }
                }
            }
        }
    }

    private func permitsClockOperation(_ authority: UUID) -> Bool {
        authority == clockAuthority && !Task.isCancelled
    }

    private func noteMissedDeadlines(_ count: Int, clockAuthority: UUID) {
        guard permitsClockOperation(clockAuthority) else { return } // CLOCK_AUTHORITY_GUARD
        metrics.missedDeadlines += count
    }

    func kernelMetricsSnapshot() -> CompositionKernelMetrics { renderer.kernelMetrics }

    /// One output frame: pull the latest sample from every source, composite
    /// the scene graph once, stamp it on the shared clock, and broadcast.
    /// Never gated on a fresh source frame (issue #65, criterion 2).
    ///
    /// S09: an in-flight scene transition renders instead of the settled
    /// scene (both sides keep compositing — the cadence never blocks and no
    /// output drops); completion falls through to the settled render in the
    /// same tick, so the tick that ends a transition already paints the new
    /// composition.
    private func tick(clockAuthority: UUID?) {
        if let clockAuthority {
            guard permitsClockOperation(clockAuthority) else { return } // CLOCK_AUTHORITY_GUARD
        }
        let override = frameOverrideProvider()
        guard let scene = override ?? self.scene else { return }
        let renderStarted = ProcessInfo.processInfo.systemUptime
        let previousCount = metrics.rendered
        metrics.attempts += 1
        defer {
            let elapsed = (ProcessInfo.processInfo.systemUptime - renderStarted) * 1000
            metrics.totalRenderMilliseconds += elapsed
            metrics.maxRenderMilliseconds = max(metrics.maxRenderMilliseconds, elapsed)
            if metrics.rendered == previousCount { metrics.failed += 1 }
        }
        frameSequence += 1
        let timescale = CMTimeScale(max(1, frameRate))
        // Audio is stamped on the same host clock. A slow render skips an
        // opportunity rather than compressing video time against audio.
        let pts = mediaTime()
        let duration = CMTime(value: 1, timescale: timescale)
        let overlayContext = overlayContextProvider()
        let sourcePayloads = sourcePayloadProvider()
        let scenes = sceneRegistryProvider()
        let annotations = annotationProvider()
        // Both layouts observe this tick's same scene, PTS and shared source
        // registry. A secondary sink never sees staged edits on Program.
        defer {
            renderSecondary(scene: scene, override: override != nil, overlayContext: overlayContext,
                sourcePayloads: sourcePayloads, scenes: scenes, pts: pts, duration: duration, annotations: annotations)
            renderClean(scene: scene, override: override != nil, overlayContext: overlayContext,
                sourcePayloads: sourcePayloads, scenes: scenes, pts: pts, duration: duration)
        }

        do { try ensureSourceBank(canvas: .program, clean: false) } catch { return }
        if override == nil, let active = transition {
            if let frame = renderTransitionFrame(active,
                                                 overlayContext: overlayContext,
                                                 sourcePayloads: sourcePayloads,
                                                 scenes: scenes,
                                                 presentationTime: pts,
                                                 frameDuration: duration) {
                metrics.rendered += 1
                metrics.lastPresentationSeconds = pts.seconds
                programDelivery.offer(frame)
                return
            }
            transition = nil   // completed this tick → settled render below
        }

        let fades = layerFadeOverrides(at: pts)
        guard let frame = renderer.render(scene: scene,
                                          overlayContext: overlayContext,
                                          canvasSize: canvasSize,
                                          frames: delayedFrameLookup,
                                          sourcePayloads: sourcePayloads,
                                          scenes: scenes,
                                          presentationTime: pts,
                                          frameDuration: duration,
                                          sequence: frameSequence,
                                          layerOpacity: override == nil ? fades.opacity : [:],
                                          exitingLayers: override == nil ? fades.exiting : [],
                                          annotations: annotations) else { return }
        metrics.rendered += 1
        metrics.lastPresentationSeconds = pts.seconds
        programDelivery.offer(frame)
    }

    private func renderClean(scene: Scene, override: Bool, overlayContext: OverlayContext,
                             sourcePayloads: [SourceDefinitionID: LayerPayload], scenes: [SceneID: Scene],
                             pts: CMTime, duration: CMTime) {
        let consumers = cleanSubscribers.filter { cleanRenderPermits[$0.key]?() == true }.values
        guard !consumers.isEmpty else { return }
        do { try ensureSourceBank(canvas: .program, clean: true) } catch { return }
        var overlays = overlayContext; overlays.overlays = []
        let frame: CompositedFrame?
        if !override, let active = transition {
            frame = renderTransitionFrame(active, overlayContext: overlays, sourcePayloads: sourcePayloads,
                scenes: scenes, presentationTime: pts, frameDuration: duration, clean: true)
        } else {
            let fades = override ? (opacity: [LayerID: Double](), exiting: [LayerNode]()) : layerFadeOverrides(at: pts)
            frame = cleanRenderer.render(scene: scene, overlayContext: overlays, canvasSize: canvasSize,
                frames: delayedFrameLookup, sourcePayloads: sourcePayloads, scenes: scenes,
                presentationTime: pts, frameDuration: duration, sequence: frameSequence,
                layerOpacity: fades.opacity, exitingLayers: fades.exiting, annotations: .empty)
        }
        if let frame { cleanDelivery.offer(frame) }
    }

    private func renderSecondary(scene: Scene, override: Bool, overlayContext: OverlayContext,
                                 sourcePayloads: [SourceDefinitionID: LayerPayload], scenes: [SceneID: Scene],
                                 pts: CMTime, duration: CMTime, annotations: AnnotationRenderSnapshot) {
        guard !secondarySubscribers.isEmpty else { return }
        do { try ensureSourceBank(canvas: .secondary, clean: false) } catch { return }
        let resolved = override ? scene : scene.composition(for: .secondary)
        let overlays: OverlayContext = !override && scene.secondaryCanvas?.isValid != true ? .empty : overlayContext
        let frame: CompositedFrame?
        if !override, let active = transition {
            frame = renderTransitionFrame(active, overlayContext: overlays, sourcePayloads: sourcePayloads,
                scenes: scenes, presentationTime: pts, frameDuration: duration, canvas: .secondary)
        } else {
            frame = secondaryRenderer.render(scene: resolved, overlayContext: overlays,
                canvasSize: secondaryCanvasSize, frames: delayedFrameLookup, sourcePayloads: sourcePayloads,
                scenes: scenes, presentationTime: pts, frameDuration: duration, sequence: frameSequence, annotations: annotations)
        }
        if let frame { secondaryDelivery.offer(frame) }
    }
}

