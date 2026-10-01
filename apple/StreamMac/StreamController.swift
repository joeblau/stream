import AVFoundation
import Combine
import CoreImage
import CoreMedia
import CoreVideo
import StreamCore
import os.lock

/// The heart of the macOS app: owns the capture sources (screen, camera, mic),
/// drives the `CompositionEngine` that renders the selected scene onto the
/// output-profile canvas, and routes engine frames to the outputs (preview,
/// publisher, recording) as independent subscribers.
///
/// W08 (issue #65): rendering lives in the `CompositionEngine` actor — a
/// Metal/Core Image compositor ticking at the profile fps on a shared
/// monotonic clock, broadcasting timestamped frames through bounded,
/// drop-oldest per-subscriber queues. Nothing on this main-actor controller
/// renders pixels anymore; it only configures the engine (scene, canvas, fps)
/// and manages subscriptions.
///
/// W07 (issue #64): the canvas is owned by the persisted `OutputProfile`, not
/// by the first arriving source frame — see `activeProfile`/`stagedProfile`
/// for the staged-vs-active application rules.
///
/// W02 (issue #62): preview, streaming, and recording are INDEPENDENT session
/// state machines (see SessionState.swift). The streaming machine is folded
/// from the publisher's own `PublisherEvent`s — LIVE only on an acknowledged
/// publish — so stopping preview or closing the window never silently kills an
/// active output: the engine stays up while ANY output demands frames.
///
/// One ordered video consumer serializes `appendVideo` into the publisher (a
/// `Task` per frame could reorder buffers); audio goes through the publisher's
/// own ordered, nonisolated ingress exactly like the iOS pipeline.
@MainActor
final class StreamController: ObservableObject {
    /// Streaming (publishing) output lifecycle — read `streamState`, never a bool.
    @Published private(set) var streamState: StreamSessionState = .idle
    /// On-screen preview lifecycle. Independent from streaming/recording.
    @Published private(set) var previewState: PreviewSessionState = .idle
    /// The latest composited frame for the SwiftUI preview, throttled to ~30 fps.
    @Published private(set) var previewImage: CGImage?
    @Published var errorMessage: String?

    /// Convenience for UI; `streamState` carries the full picture.
    var isLive: Bool { streamState.isLive }
    var isPreviewing: Bool { previewState == .active }

    let sceneStore: SceneStore
    let screenCapture = ScreenSourceCapture()
    let audio = MacAudioInput()
    private let facecam = FacecamCapture()

    /// The W08 composition engine. Pulls the latest screen/camera frames
    /// through the lock-protected holders below; runs only while the W02
    /// pipeline demand is > 0.
    private let engine: CompositionEngine
    /// Reached from the capture callbacks (arbitrary queues) and the main actor.
    private let publisherBox = PublisherBox()
    private let latestScreen = LatestScreenFrame()
    private var publisher: (any Publisher)? {
        didSet { publisherBox.publisher = publisher }
    }
    private var publisherTask: Task<Void, Never>?
    /// Folds the publisher's lifecycle events into `streamState`.
    private var eventTask: Task<Void, Never>?
    /// Ordered publisher video path: the engine's publisher sink yields into
    /// this newest-only stream; one consumer awaits `appendVideo` in order.
    private var videoConsumer: Task<Void, Never>?
    private var videoContinuation: AsyncStream<CMSampleBuffer>.Continuation?
    /// Captures + engine are up. Independent from preview: an active stream
    /// or recording keeps the pipeline running with the preview off (W02).
    private var isPipelineRunning = false
    /// Count of recording outputs tapping the composited frames (0 or 1 today).
    private var recordingDemand = 0
    /// The preview output's engine subscription (registered while previewing).
    private var previewSubscription: FrameSubscription?
    /// Converts engine frames to CGImages for the preview, off the main actor.
    private let previewConverter = PreviewImageConverter()

    private var settings: StreamSettings = .default
    /// Hardware + destination gating for the output profile (W07); the single
    /// auditable capability place lives in StreamCore's OutputCapabilities.
    private let capabilities = OutputCapabilities.current
    /// The canvas + fps the pipeline renders at RIGHT NOW (W07, issue #64).
    /// Owned by the persisted `StreamSettings.outputProfile`, never derived
    /// from the first source frame: sources are aspect-fit into this fixed
    /// canvas, so a source's native size changing mid-program never resizes
    /// the output. Changes apply only at a compatible output (re)start.
    @Published private(set) var activeProfile: OutputProfile
    /// A profile edit waiting for the active stream/recording to end; non-nil
    /// means "applies on next session". The settings UI marks this state.
    @Published private(set) var stagedProfile: OutputProfile?
    private var outputSizeSentToPublisher = false
    private var cancellables: Set<AnyCancellable> = []

    init(sceneStore: SceneStore) {
        self.sceneStore = sceneStore
        // The persisted profile is the canvas authority from launch, so the
        // preview opens at the configured geometry before any source frame
        // ever arrives.
        let persisted = SettingsStore().load()
        self.settings = persisted
        self.activeProfile = persisted.outputProfile

        // The engine pulls source pixels off-main through the holders; it
        // never touches this controller's MainActor state.
        let latestScreen = self.latestScreen
        let facecam = self.facecam
        self.engine = CompositionEngine(
            screenProvider: { latestScreen.latest() },
            cameraProvider: { facecam.latest.freshest() },
            canvasSize: persisted.outputProfile.canvasSize,
            frameRate: persisted.outputProfile.frameRate)

        // Scene selection or edits apply to the live pipeline immediately.
        sceneStore.$scenes
            .combineLatest(sceneStore.$selectedID)
            .sink { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.applySceneSources()
                    self?.pushSceneToEngine()
                }
            }
            .store(in: &cancellables)

        // Capture callbacks may arrive on ScreenCaptureKit / audio queues, so
        // everything they touch is lock-protected storage, never MainActor state.
        screenCapture.onVideoSample = { [latestScreen] sample in
            if let buffer = CMSampleBufferGetImageBuffer(sample) {
                latestScreen.store(buffer)
            }
        }
        screenCapture.onAudioSample = { [publisherBox] sample in
            publisherBox.publisher?.enqueueApp(sample)
        }
        audio.onMicSample = { [publisherBox] sample in
            publisherBox.publisher?.enqueueMic(sample)
        }

        // The publisher output subscribes once for the controller's lifetime:
        // the sink never blocks the engine (newest-only stream), and the
        // consumer below drops frames while no publisher owns the session.
        let (stream, continuation) = AsyncStream.makeStream(
            of: CMSampleBuffer.self, bufferingPolicy: .bufferingNewest(1))
        videoContinuation = continuation
        let publisherBox = self.publisherBox
        videoConsumer = Task {
            for await sample in stream {
                if let publisher = publisherBox.publisher {
                    await publisher.appendVideo(sample)
                }
            }
        }
        let engine = self.engine
        let subscription = FrameSubscription()
        Task { [continuation] in
            await engine.addSink(token: subscription.token, capacity: 1) { frame in
                continuation.yield(frame.sampleBuffer)
            }
        }
    }

    /// Live encode/uplink metrics for the stats HUD, straight from the publisher.
    func statsSnapshot() async -> LiveStats? {
        await publisher?.statsSnapshot()
    }

    // MARK: - Frame subscriptions (W08 fan-out)

    /// Opaque handle for an engine frame subscription. Cheap to create on the
    /// caller's side; register/cancel are delivered to the engine actor
    /// asynchronously and are race-safe (a cancel landing before its register
    /// is still honored).
    struct FrameSubscription: Hashable, Sendable {
        fileprivate let token = UUID()
    }

    /// Subscribes an output to composited program frames. The sink runs on the
    /// subscription's own bounded (default 2, drop-oldest) serial queue — a
    /// slow consumer sheds its own frames and can never stall the engine or
    /// the other outputs.
    @discardableResult
    func addFrameSink(capacity: Int = 2,
                      sink: @escaping @Sendable (CompositedFrame) -> Void) -> FrameSubscription {
        let subscription = FrameSubscription()
        Task { await engine.addSink(token: subscription.token, capacity: capacity, sink: sink) }
        return subscription
    }

    func removeFrameSink(_ subscription: FrameSubscription) {
        Task { await engine.removeSink(subscription.token) }
    }

    // MARK: - Preview / stream lifecycle

    func startPreview() {
        guard previewState == .idle else { return }
        settings = SettingsStore().load()
        applyOutputProfile(settings.outputProfile)
        previewState = .active
        let converter = previewConverter
        previewSubscription = addFrameSink { [weak self] frame in
            // Conversion runs on the subscription's serial queue, off-main;
            // the sink self-throttles to ~30 fps before hopping to the UI.
            guard let image = converter.makeImage(frame, throttleNanoseconds: 33_000_000) else { return }
            Task { @MainActor [weak self] in
                self?.previewImage = image
            }
        }
        updatePipelineDemand()
    }

    /// Stops the on-screen preview ONLY. An active stream or recording keeps
    /// running (issue #62): the pipeline demand check below keeps captures and
    /// the engine alive for the outputs still consuming frames.
    func stopPreview() {
        guard previewState == .active else { return }
        if let previewSubscription {
            removeFrameSink(previewSubscription)
        }
        previewSubscription = nil
        previewState = .idle
        previewImage = nil
        updatePipelineDemand()
    }

    func goLive() {
        guard streamState.canStart else { return }
        settings = SettingsStore().load()
        guard settings.isPublishable else {
            errorMessage = "Complete the connection settings before going live."
            return
        }
        applyOutputProfile(settings.outputProfile)
        // Go Live needs the render pipeline (frames to publish); the demand
        // check below starts it even if the user never turned the preview on.
        let publisher = makePublisher(for: settings.selectedProtocol)
        self.publisher = publisher
        outputSizeSentToPublisher = false
        streamState = .connecting
        updatePipelineDemand()
        let settings = self.settings
        publisherTask = Task { [weak self] in
            do {
                try await publisher.start(settings)
            } catch {
                self?.publisherDidFail(error)
            }
        }
        eventTask = Task { [weak self] in
            for await event in publisher.events {
                self?.handlePublisherEvent(event)
            }
        }
        // The canvas is known up front (profile-owned), so hand the encoder
        // its output size immediately instead of waiting for a first frame.
        applyOutputSizeIfPossible()
    }

    func stopStream() {
        guard streamState.isActive else { return }
        streamState = .stopping
        publisherTask?.cancel()
        publisherTask = nil
        eventTask?.cancel()
        eventTask = nil
        outputSizeSentToPublisher = false
        let ending = publisher
        publisher = nil
        guard let ending else {
            streamState = .idle
            updatePipelineDemand()
            return
        }
        Task { [weak self] in
            await ending.stop()
            self?.streamDidStop()
        }
    }

    // MARK: - Streaming state machine (folded from PublisherEvents)

    private func handlePublisherEvent(_ event: PublisherEvent) {
        switch event {
        case .connecting:
            // A retry attempt during .reconnecting keeps that state; only the
            // acknowledged publish below ends it.
            if !streamState.isActive {
                streamState = .connecting
            }
        case .published:
            // The ingest acknowledged the publish — the ONLY path to LIVE.
            if streamState.isActive {
                streamState = .live
                errorMessage = nil
            }
        case .reconnecting(let reason):
            if streamState == .live || streamState == .connecting {
                streamState = .reconnecting(reason: reason)
            }
        case .failed(let message):
            if streamState.isActive {
                failStream(message)
            }
        case .stopped:
            streamDidStop()
        }
    }

    private func streamDidStop() {
        guard streamState == .stopping else { return }
        streamState = .idle
        promoteStagedProfileIfOutputsIdle()
        updatePipelineDemand()
    }

    private func publisherDidFail(_ error: Error) {
        // `.stopping` excluded: a late error from a publisher the user already
        // stopped must not flip the session to `.failed`.
        guard streamState.isActive, streamState != .stopping else { return }
        failStream(error.localizedDescription)
    }

    /// Ends the session into `.failed`: tears the publisher down and surfaces
    /// the message. From `.failed` the transport bar offers a fresh Go Live.
    private func failStream(_ message: String) {
        publisherTask?.cancel()
        publisherTask = nil
        eventTask?.cancel()
        eventTask = nil
        outputSizeSentToPublisher = false
        let ending = publisher
        publisher = nil
        streamState = .failed(message)
        errorMessage = message
        if let ending {
            Task { await ending.stop() }
        }
        promoteStagedProfileIfOutputsIdle()
        updatePipelineDemand()
    }

    // MARK: - Pipeline demand (preview / stream / recording independence)

    /// RecordingController subscribes to the engine's frames here so its
    /// output keeps the render pipeline alive even with the preview off
    /// (and vice versa).
    func noteRecordingStarted() {
        recordingDemand += 1
        updatePipelineDemand()
    }

    func noteRecordingStopped() {
        recordingDemand = max(0, recordingDemand - 1)
        promoteStagedProfileIfOutputsIdle()
        updatePipelineDemand()
    }

    private var pipelineNeeded: Bool {
        previewState == .active || streamState.isActive || recordingDemand > 0
    }

    private func updatePipelineDemand() {
        if pipelineNeeded, !isPipelineRunning {
            startPipeline()
        } else if !pipelineNeeded, isPipelineRunning {
            stopPipeline()
        }
    }

    // MARK: - Output profile (staged vs active, W07)

    /// True when an output owns the encode geometry: resolution/fps edits made
    /// now must wait for the next session (encoders can't be re-dimensioned
    /// mid-program, and the recording writer's input is locked to the size of
    /// its first frame).
    private var outputsOwnProfile: Bool {
        streamState.isActive || recordingDemand > 0
    }

    /// Public read for the W04 settings session: while this is true,
    /// connection and canvas/fps edits stage for the next session.
    var outputSessionActive: Bool { outputsOwnProfile }

    /// Applies a just-saved settings snapshot from the shared settings
    /// session (W04, issue #67). Updates the controller's working copy so no
    /// consumer reads a stale snapshot, then applies what is safe RIGHT NOW:
    /// the output profile follows the W07 staged/active rules, a mic-volume
    /// change reaches a live publisher in place, and a preferred-input change
    /// restarts mic capture only while no output owns the session. Everything
    /// else (connection, bitrate, codec, voice polish) is read at the next
    /// session start, exactly as before.
    func applySavedSettings(_ newSettings: StreamSettings) {
        let previous = settings
        settings = newSettings
        applyOutputProfile(newSettings.outputProfile,
                           destination: newSettings.selectedProtocol)
        if newSettings.micVolume != previous.micVolume,
           let publisher = publisherBox.publisher {
            Task { await publisher.setMicVolume(newSettings.micVolume) }
        }
        if newSettings.preferredAudioInputUID != previous.preferredAudioInputUID,
           isPipelineRunning, !outputsOwnProfile {
            startAudioInput()
        }
    }

    /// Entry point for settings edits (W04: `applySavedSettings(_:)` routes
    /// here after the shared settings session persists; the controller's own
    /// `settings` snapshot is also refreshed at session start). With a stream
    /// or recording active the edit is STAGED and surfaces via `stagedProfile`
    /// ("applies on next session"); otherwise it applies immediately,
    /// reconfiguring the preview pipeline in place.
    func applyOutputProfile(_ profile: OutputProfile,
                            destination proto: StreamCore.StreamProtocol? = nil) {
        let clamped = capabilities.clamped(profile, destination: proto ?? settings.selectedProtocol)
        if outputsOwnProfile {
            stagedProfile = clamped == activeProfile ? nil : clamped
            return
        }
        setActiveProfile(clamped)
    }

    private func setActiveProfile(_ profile: OutputProfile) {
        let changed = profile != activeProfile
        activeProfile = profile
        stagedProfile = nil
        // Align the scene graph's canvas reference (S01) with the output
        // canvas; transforms are normalized, so layers are not repositioned.
        sceneStore.setCanvasSize(profile.canvasSize)
        guard changed, isPipelineRunning else { return }
        // Live output change (only possible while no stream/recording owns the
        // geometry): the engine re-anchors its clock and re-pools its buffers
        // at the new canvas/fps on the next tick.
        let canvasSize = profile.canvasSize
        let fps = encodeFrameRate
        Task { await engine.setOutput(canvasSize: canvasSize, frameRate: fps) }
    }

    /// Applies a staged profile once no stream/recording owns the geometry.
    /// Safe to call from every session-end path; a no-op unless staged + idle.
    private func promoteStagedProfileIfOutputsIdle() {
        guard let stagedProfile, !outputsOwnProfile else { return }
        setActiveProfile(stagedProfile)
    }

    private func startPipeline() {
        isPipelineRunning = true
        startAudioInput()
        applySceneSources()
        let scene = sceneStore.selected
        let canvasSize = activeProfile.canvasSize
        let fps = encodeFrameRate
        Task { await engine.run(scene: scene, canvasSize: canvasSize, frameRate: fps) }
    }

    /// Starts mic capture on the preferred input from settings, falling back
    /// to the system default when none is chosen or the chosen device is gone.
    private func startAudioInput() {
        if let uid = settings.preferredAudioInputUID,
           let device = audio.devices.first(where: { $0.uniqueID == uid }) {
            audio.start(device: device)
        } else {
            audio.start()
        }
    }

    private func stopPipeline() {
        isPipelineRunning = false
        let engine = self.engine
        Task { await engine.stop() }
        facecam.stop()
        audio.stop()
        let screenCapture = self.screenCapture
        Task { await screenCapture.stop() }
        latestScreen.clear()
        outputSizeSentToPublisher = false
        promoteStagedProfileIfOutputsIdle()
    }

    private func makePublisher(for transport: StreamCore.StreamProtocol) -> any Publisher {
        switch transport {
        case .rtmp, .rtmps:
            return RTMPPublisher()
        case .srt, .whip:
            return SessionPublisher(protocol: transport)
        }
    }

    // MARK: - Scene → source routing

    /// Starts/stops the screen capture and camera to match the selected scene's
    /// layout. Screen capture uses the system content picker, so a switch into a
    /// screen layout may need one user confirmation; a cancel simply leaves the
    /// scene showing its other source until picked.
    private func applySceneSources() {
        guard isPipelineRunning, let scene = sceneStore.selected else { return }
        let layout = scene.layout
        let screenCapture = self.screenCapture
        if layout.usesScreen, !screenCapture.isCapturing {
            Task { await screenCapture.pickAndStart() }
        } else if !layout.usesScreen, screenCapture.isCapturing {
            Task { await screenCapture.stop() }
        }
        if layout.usesCamera {
            facecam.start(with: settings)
        } else {
            facecam.stop()
        }
    }

    /// Hands the engine the current scene graph. Called on every scene edit /
    /// selection change and at pipeline start; the engine composites whatever
    /// graph it holds at each tick, so edits apply on the very next frame.
    private func pushSceneToEngine() {
        let scene = sceneStore.selected
        Task { await engine.updateScene(scene) }
    }

    // MARK: - Engine cadence

    private var encodeFrameRate: Int {
        // The profile's rate, defensively clamped to the hardware ceiling —
        // the settings UI gates on the same `OutputCapabilities`, so this only
        // fires for hand-edited or migrated settings files.
        min(max(activeProfile.frameRate, 1), max(1, capabilities.hardwareMaxFrameRate))
    }

    /// Hands the profile's canvas to the publisher exactly once per broadcast
    /// (`setOutputSize` itself also locks after the first call). The size is
    /// known at Go Live — no first-frame wait — so the encoder never starts at
    /// a source-derived size.
    private func applyOutputSizeIfPossible() {
        guard streamState.isActive, !outputSizeSentToPublisher,
              let publisher else { return }
        outputSizeSentToPublisher = true
        let canvasSize = activeProfile.canvasSize
        Task { await publisher.setOutputSize(canvasSize, nativeShortEdge: Int(min(canvasSize.width, canvasSize.height))) }
    }
}

/// Lock-protected hand-off of the current publisher to the capture callbacks,
/// which fire on ScreenCaptureKit / audio queues (off the main actor) and call
/// only the publisher's nonisolated, thread-safe audio ingress.
private final class PublisherBox: @unchecked Sendable {
    private var lock = os_unfair_lock_s()
    private var stored: (any Publisher)?

    var publisher: (any Publisher)? {
        get {
            os_unfair_lock_lock(&lock)
            defer { os_unfair_lock_unlock(&lock) }
            return stored
        }
        set {
            os_unfair_lock_lock(&lock)
            stored = newValue
            os_unfair_lock_unlock(&lock)
        }
    }
}

/// Holds the newest screen frame for the engine's screen provider. Unlike the
/// pre-W08 destructive take, reads are non-destructive: the composition ticks
/// at the output fps using the LATEST sample (issue #65), so a static screen
/// keeps compositing — moving camera overlays included — without
/// ScreenCaptureKit producing fresh frames.
private final class LatestScreenFrame: @unchecked Sendable {
    private var lock = os_unfair_lock_s()
    private var buffer: CVPixelBuffer?

    func store(_ buffer: CVPixelBuffer) {
        os_unfair_lock_lock(&lock)
        self.buffer = buffer
        os_unfair_lock_unlock(&lock)
    }

    func latest() -> CVPixelBuffer? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return buffer
    }

    func clear() {
        os_unfair_lock_lock(&lock)
        buffer = nil
        os_unfair_lock_unlock(&lock)
    }
}

/// Converts engine frames to throttled CGImages for the SwiftUI preview.
/// `@unchecked Sendable`: every call arrives on the preview subscription's
/// single serial delivery queue, so the `CIContext` and throttle state are
/// never touched concurrently.
private final class PreviewImageConverter: @unchecked Sendable {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var lastUpdateAt: UInt64 = 0

    func makeImage(_ frame: CompositedFrame, throttleNanoseconds: UInt64) -> CGImage? {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now &- lastUpdateAt >= throttleNanoseconds else { return nil }
        lastUpdateAt = now
        guard let buffer = frame.pixelBuffer else { return nil }
        let image = CIImage(cvPixelBuffer: buffer)
        return context.createCGImage(image, from: image.extent)
    }
}
