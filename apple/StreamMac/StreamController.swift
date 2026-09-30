import AVFoundation
import Combine
import CoreImage
import CoreMedia
import CoreVideo
import StreamCore
import os
import os.lock

/// The heart of the macOS app: owns the capture sources (screen, camera, mic),
/// composites them per the selected scene on a settings-fps render loop, feeds
/// the preview, and drives the network `Publisher` while live.
///
/// W02 (issue #62): preview, streaming, and recording are INDEPENDENT session
/// state machines (see SessionState.swift). The streaming machine is folded
/// from the publisher's own `PublisherEvent`s — LIVE only on an acknowledged
/// publish — so stopping preview or closing the window never silently kills an
/// active output: the render pipeline stays up while ANY output demands frames.
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

    /// Agent C's local recorder taps the composited output here. Invoked for
    /// every composited frame, live or not, on the main actor.
    var onCompositedSample: ((CMSampleBuffer) -> Void)?

    let sceneStore: SceneStore
    let screenCapture = ScreenSourceCapture()
    let audio = MacAudioInput()
    private let facecam = FacecamCapture()
    private let compositor = FacecamCompositor()

    /// Reached from the capture callbacks (arbitrary queues) and the main actor.
    private let publisherBox = PublisherBox()
    private let latestScreen = LatestScreenSample()
    private var publisher: (any Publisher)? {
        didSet { publisherBox.publisher = publisher }
    }
    private var publisherTask: Task<Void, Never>?
    /// Folds the publisher's lifecycle events into `streamState`.
    private var eventTask: Task<Void, Never>?
    private var renderTask: Task<Void, Never>?
    private var videoConsumer: Task<Void, Never>?
    private var videoContinuation: AsyncStream<CMSampleBuffer>.Continuation?
    /// Captures + render loop are up. Independent from preview: an active stream
    /// or recording keeps the pipeline running with the preview off (W02).
    private var isPipelineRunning = false
    /// Count of recording outputs tapping the composited frames (0 or 1 today).
    private var recordingDemand = 0

    private var settings: StreamSettings = .default
    private let capability = StreamCapability.current
    /// Encode geometry, locked from the first source frame of a preview session
    /// (like the iOS pipeline) so the encoder size stays stable for the session.
    private var targetSize: CGSize?
    private var outputSizeSentToPublisher = false
    private var cameraFormatDescription: CMVideoFormatDescription?
    private let previewContext = CIContext(options: [.cacheIntermediates: false])
    private var lastPreviewUpdateAt: UInt64 = 0
    private var cancellables: Set<AnyCancellable> = []

    init(sceneStore: SceneStore) {
        self.sceneStore = sceneStore

        // Scene selection or edits apply to the live pipeline immediately.
        sceneStore.$scenes
            .combineLatest(sceneStore.$selectedID)
            .sink { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.applySceneSources()
                }
            }
            .store(in: &cancellables)

        // Capture callbacks may arrive on ScreenCaptureKit / audio queues, so
        // everything they touch is lock-protected storage, never MainActor state.
        screenCapture.onVideoSample = { [latestScreen] sample in
            latestScreen.store(sample)
        }
        screenCapture.onAudioSample = { [publisherBox] sample in
            publisherBox.publisher?.enqueueApp(sample)
        }
        audio.onMicSample = { [publisherBox] sample in
            publisherBox.publisher?.enqueueMic(sample)
        }
    }

    /// Live encode/uplink metrics for the stats HUD, straight from the publisher.
    func statsSnapshot() async -> LiveStats? {
        await publisher?.statsSnapshot()
    }

    // MARK: - Preview / stream lifecycle

    func startPreview() {
        guard previewState == .idle else { return }
        settings = SettingsStore().load()
        previewState = .active
        updatePipelineDemand()
    }

    /// Stops the on-screen preview ONLY. An active stream or recording keeps
    /// running (issue #62): the pipeline demand check below keeps captures and
    /// the render loop alive for the outputs still consuming frames.
    func stopPreview() {
        guard previewState == .active else { return }
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
        // The encode size may already be locked by the preview; hand it over.
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
        updatePipelineDemand()
    }

    // MARK: - Pipeline demand (preview / stream / recording independence)

    /// RecordingController taps the composited frames here so its output keeps
    /// the render pipeline alive even with the preview off (and vice versa).
    func noteRecordingStarted() {
        recordingDemand += 1
        updatePipelineDemand()
    }

    func noteRecordingStopped() {
        recordingDemand = max(0, recordingDemand - 1)
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

    private func startPipeline() {
        isPipelineRunning = true
        audio.start()
        applySceneSources()
        startRenderLoop()
    }

    private func stopPipeline() {
        isPipelineRunning = false
        renderTask?.cancel()
        renderTask = nil
        videoContinuation?.finish()
        videoContinuation = nil
        videoConsumer?.cancel()
        videoConsumer = nil
        facecam.stop()
        audio.stop()
        let screenCapture = self.screenCapture
        Task { await screenCapture.stop() }
        latestScreen.clear()
        targetSize = nil
        outputSizeSentToPublisher = false
        cameraFormatDescription = nil
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

    // MARK: - Render loop

    private var encodeFrameRate: Int {
        settings.encodeFrameRate(maxFrameRate: capability.maxFrameRate)
    }

    private func startRenderLoop() {
        renderTask?.cancel()
        let intervalNanoseconds = UInt64(1_000_000_000) / UInt64(max(1, encodeFrameRate))
        renderTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.renderTick()
                try? await Task.sleep(nanoseconds: intervalNanoseconds)
            }
        }

        // One ordered consumer serializes appends into the publisher. The stream
        // keeps the newest buffer only, shedding frames the pipeline can't keep
        // up with instead of building latency.
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
    }

    /// One frame of the output pipeline: pull the current sources, composite at
    /// the locked encode size, then fan out to the publisher (live only), the
    /// recorder hook, and the preview.
    private func renderTick() {
        guard isPipelineRunning, let scene = sceneStore.selected else { return }
        let layout = scene.layout

        let screenSample = layout.usesScreen ? latestScreen.take() : nil
        // Screen layouts only render when ScreenCaptureKit produced a fresh
        // frame; on a static screen the publisher's frame-repeat keeps the
        // stream's fps/keyframe cadence alive.
        if layout.usesScreen, screenSample == nil { return }

        let cameraFrame = layout.usesCamera ? facecam.latest.freshest() : nil
        if layout == .cameraSolo, cameraFrame == nil { return }

        guard let source = screenSample.flatMap(CMSampleBufferGetImageBuffer)
                ?? cameraFrame?.buffer else { return }

        if targetSize == nil {
            let width = CVPixelBufferGetWidth(source)
            let height = CVPixelBufferGetHeight(source)
            targetSize = settings.encodeSize(forOrientedWidth: width, height: height,
                                             maxShortEdge: capability.maxShortEdge)
            applyOutputSizeIfPossible()
        }
        guard let targetSize else { return }

        // Mirror by the camera that produced the pixels on hand; on macOS that
        // is always `.front` (see FacecamCapture.effectivePosition).
        let cameraPosition = cameraFrame?.position ?? .front
        guard let composited = compositor.composite(
                screen: source,
                camera: layout.usesCamera ? cameraFrame?.buffer : nil,
                targetSize: targetSize,
                orientation: .up,
                corner: scene.pipCorner,
                scale: scene.pipScale,
                cameraPosition: cameraPosition) else { return }

        let sample: CMSampleBuffer?
        if let screenSample {
            sample = compositor.makeSampleBuffer(from: composited, timingSource: screenSample)
        } else {
            // Camera-solo has no capture timing to copy; stamp the host clock.
            sample = makeCameraTimedSampleBuffer(from: composited)
        }
        guard let sample else { return }

        videoContinuation?.yield(sample)
        onCompositedSample?(sample)
        if previewState == .active {
            updatePreview(with: composited)
        }
    }

    /// Hands the locked encode geometry to the publisher exactly once per
    /// broadcast (`setOutputSize` itself also locks after the first call).
    private func applyOutputSizeIfPossible() {
        guard streamState.isActive, !outputSizeSentToPublisher,
              let publisher, let targetSize else { return }
        outputSizeSentToPublisher = true
        Task { await publisher.setOutputSize(targetSize, nativeShortEdge: Int(min(targetSize.width, targetSize.height))) }
    }

    /// Throttled (~30 fps) CGImage for the SwiftUI preview.
    private func updatePreview(with pixelBuffer: CVPixelBuffer) {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now &- lastPreviewUpdateAt >= 33_000_000 else { return }
        lastPreviewUpdateAt = now
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        previewImage = previewContext.createCGImage(image, from: image.extent)
    }

    /// Wraps a composited camera-solo buffer with host-clock timing (there is
    /// no screen sample to copy timing from in that layout).
    private func makeCameraTimedSampleBuffer(from pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        if cameraFormatDescription == nil {
            var created: CMVideoFormatDescription?
            guard CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &created) == noErr else { return nil }
            cameraFormatDescription = created
        }
        guard let format = cameraFormatDescription else { return nil }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(encodeFrameRate)),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
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

/// Holds the newest screen sample; consumed destructively by the render loop,
/// so a static screen costs no re-encodes while the publisher's frame-repeat
/// keeps the outgoing cadence.
private final class LatestScreenSample: @unchecked Sendable {
    private var lock = os_unfair_lock_s()
    private var sample: CMSampleBuffer?

    func store(_ sample: CMSampleBuffer) {
        os_unfair_lock_lock(&lock)
        self.sample = sample
        os_unfair_lock_unlock(&lock)
    }

    func take() -> CMSampleBuffer? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        let taken = sample
        sample = nil
        return taken
    }

    func clear() {
        os_unfair_lock_lock(&lock)
        sample = nil
        os_unfair_lock_unlock(&lock)
    }
}
