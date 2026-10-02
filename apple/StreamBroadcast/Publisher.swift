import CoreMedia
import CoreGraphics
import StreamCore

/// Coarse publishing-lifecycle signals, emitted from the points where the
/// publisher itself observes them (never optimistic UI flags). `StreamController`
/// folds these into the streaming session state machine, so the LIVE badge
/// lights only on an acknowledged publish and reconnects are visible.
enum PublisherEvent: Sendable {
    /// A connect/publish attempt has begun (initial go-live and every retry).
    case connecting
    /// The ingest acknowledged the publish: RTMP `publish()` resolved with
    /// onStatus success, or the SRT/WHIP session's `connect()` returned.
    case published
    /// The connection dropped or stalled and a supervised reconnect is running.
    case reconnecting(reason: String)
    /// A non-recoverable failure ended the session (setup errors; the supervised
    /// reconnect loop otherwise retries indefinitely while the user owns it).
    case failed(message: String)
    /// `stop()` finished tearing the pipeline down.
    case stopped
}

/// The publisher surface, so `ScreenCaptureController` can drive either the
/// dedicated `RTMPPublisher` or the unified-transport `SessionPublisher` behind one
/// type. Both are actors sharing the same encode pipeline (mixer, ABR, timeline
/// normalizer, frame admission).
protocol Publisher: Actor {
    /// Lifecycle events for the session state machine. Single-consumer (the
    /// controller); created in `init` so it is safe to read before `start`.
    nonisolated var events: AsyncStream<PublisherEvent> { get }
    func start(_ settings: StreamSettings) async throws
    func stop() async
    func pause() async
    func resume() async
    func setOutputSize(_ size: CGSize, nativeShortEdge: Int) async
    func appendVideo(_ sb: CMSampleBuffer) async
    /// Audio is enqueued synchronously (thread-safe, FIFO) from the capture serial
    /// callback and drained by a single ordered consumer — NOT one Task per buffer,
    /// which reorders mic PTS and makes HaishinKit's ring buffer chop the audio.
    nonisolated func enqueueMic(_ sb: CMSampleBuffer)
    nonisolated func enqueueApp(_ sb: CMSampleBuffer)
    /// A01 (issue #82): the defined mixed-audio path — ONE pre-mixed 48 kHz
    /// stereo program track from the studio audio engine (macOS). Mutually
    /// exclusive with `enqueueMic`/`enqueueApp` within a session: in program
    /// mode the publisher does NO track mixing, voice processing, or mic
    /// volume of its own (the engine owns all three), so audio is never
    /// doubled. iOS keeps the per-track path above, unchanged.
    nonisolated func enqueueProgram(_ sb: CMSampleBuffer)
    func setMicVolume(_ volume: Double) async
    /// Applies a device thermal / Low-Power ceiling (bitrate scale + fps cap) to
    /// the encoder, composed with the network ceiling by the adaptive controller.
    func setThermalCeiling(bitRateScale: Double, frameRateCap: Int) async
    /// A snapshot of the live encode/uplink metrics for the stats HUD, or `nil`
    /// when nothing is being published yet (pre-connect / torn down).
    func statsSnapshot() async -> LiveStats?
}

