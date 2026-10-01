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

    private var scene: Scene?
    private var canvasSize: CGSize
    private var frameRate: Int

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
            })
        self.sourcePayloadProvider = sourcePayloadProvider
        self.overlayContextProvider = overlayContextProvider
        self.sceneRegistryProvider = sceneRegistryProvider
        self.canvasSize = canvasSize
        self.frameRate = frameRate
    }

    // MARK: - Lifecycle (driven by the W02 pipeline-demand model)

    /// Atomically (re)configures the composition and starts the tick loop.
    /// StreamController calls this when the W02 pipeline demand goes 0 → 1.
    func run(scene: Scene?, canvasSize: CGSize, frameRate: Int) {
        self.scene = scene
        self.canvasSize = canvasSize
        self.frameRate = max(1, frameRate)
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
    func updateScene(_ scene: Scene?) {
        self.scene = scene
    }

    /// Applies a new output geometry/fps. While running, this restarts the
    /// tick loop and re-anchors the clock (the renderer's pool/format
    /// description re-create themselves on the next frame at the new size).
    func setOutput(canvasSize: CGSize, frameRate: Int) {
        self.canvasSize = canvasSize
        self.frameRate = max(1, frameRate)
        if tickTask != nil {
            startTicking()
        }
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
    private func tick() {
        guard let scene else { return }
        frameSequence += 1
        let timescale = CMTimeScale(max(1, frameRate))
        let pts = CMTimeAdd(clockAnchor, CMTime(value: frameSequence, timescale: timescale))
        let duration = CMTime(value: 1, timescale: timescale)
        guard let frame = renderer.render(scene: scene,
                                          overlayContext: overlayContextProvider(),
                                          canvasSize: canvasSize,
                                          frames: frameLookup,
                                          sourcePayloads: sourcePayloadProvider(),
                                          scenes: sceneRegistryProvider(),
                                          presentationTime: pts,
                                          frameDuration: duration,
                                          sequence: frameSequence) else { return }
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
