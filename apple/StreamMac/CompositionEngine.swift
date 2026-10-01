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
         canvasSize: CGSize = OutputProfile.default.canvasSize,
         frameRate: Int = OutputProfile.default.frameRate) {
        self.screenProvider = screenProvider
        self.cameraProvider = cameraProvider
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

    /// Swaps the composed scene graph mid-program (scene switch/edit). For W03
    /// (preview/program) this is where a staged-vs-live pair of compositions
    /// plugs in: one engine per composition, or a composition slot swap here.
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
                                          canvasSize: canvasSize,
                                          screen: screenProvider(),
                                          camera: cameraProvider(),
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
