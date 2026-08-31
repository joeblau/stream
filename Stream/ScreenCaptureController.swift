import AVFoundation
import CoreMedia
import Observation
import os
#if canImport(ScreenCaptureKit)
import ScreenCaptureKit
#endif
import StreamCore

#if canImport(ScreenCaptureKit)
private let captureLog = Logger(subsystem: "com.joeblau.Stream", category: "screen-capture")

/// Owns the iOS 27 ScreenCaptureKit flow: system content selection, sample
/// capture, and the existing network publisher. Capture now runs in the app;
/// ReplayKit and a broadcast upload extension are not involved.
@MainActor
@Observable
final class ScreenCaptureController: NSObject {
    private(set) var isLive = false
    /// Remains true until capture, publisher, and audio-session teardown all finish.
    /// The record button stays disabled so a new activation cannot race the old
    /// broadcast's final deactivation.
    private(set) var isStopping = false
    private(set) var errorMessage: String?
    /// A user-facing note when the device's thermal/power state is forcing a
    /// quality reduction, or nil when unrestricted. Shown in the live stats HUD.
    private(set) var thermalNotice: String?
    /// The latest live telemetry snapshot (bitrate / fps / queue health) for the
    /// stats HUD, or nil when nothing is publishing yet. Polled ~1s while live.
    private(set) var liveStats: LiveStats?
    /// When the current broadcast went live, for the elapsed-time display; nil when
    /// not live. Uptime is ticked in the UI (TimelineView) off this Date, not off
    /// the encoder's `eventAgeSeconds`, which freezes when the app is backgrounded.
    private(set) var broadcastStartedAt: Date?

    @ObservationIgnored private let picker = SCContentSharingPicker.shared
    @ObservationIgnored private var pendingSettings: StreamSettings?
    /// Camera session started while the system picker is onscreen. Warming it here
    /// hides AVCaptureSession's cold-start latency behind content selection instead
    /// of showing an empty PiP after the broadcast has already gone live.
    @ObservationIgnored private var pendingFacecam: FacecamCapture?
    @ObservationIgnored private var stream: SCStream?
    @ObservationIgnored private var output: ScreenCaptureOutput?
    @ObservationIgnored private var publisher: (any Publisher)?
    @ObservationIgnored private var publisherTask: Task<Void, Never>?
    @ObservationIgnored private var heartbeatTask: Task<Void, Never>?
    @ObservationIgnored private var micVolumeObserver: DarwinSignalObserver?
    @ObservationIgnored private var lastAppliedCeiling: ThermalPowerCeiling?
    @ObservationIgnored private var thermalApplyTask: Task<Void, Never>?
    /// ~1s telemetry poll, live only. Cancelled on every teardown path (they all
    /// funnel through `stopCapture`).
    @ObservationIgnored private var statsTask: Task<Void, Never>?
    /// Shared frame-drop / achieved-fps counters (issue #23 / M8), created per
    /// broadcast and handed to BOTH the capture output and the publisher so the four
    /// shed sites and the encoded rate land in one place. Read once per stats poll to
    /// fold measured fps + congestion drops into `liveStats`.
    @ObservationIgnored private var frameTelemetry: FrameTelemetry?
    /// The previous telemetry snapshot + its capture time, so each poll derives
    /// achieved fps from the delta over the real elapsed window.
    @ObservationIgnored private var lastTelemetrySnapshot: FrameTelemetrySnapshot?
    @ObservationIgnored private var lastTelemetryAt: UInt64 = 0

    override init() {
        super.init()
        picker.add(self)
        picker.isActive = true
        micVolumeObserver = DarwinSignalObserver(name: BroadcastControl.micVolumeSignal) { [weak self] in
            Task { @MainActor [weak self] in self?.applyMicVolume() }
        }
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(thermalOrPowerChanged),
                           name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(thermalOrPowerChanged),
                           name: NSNotification.Name.NSProcessInfoPowerStateDidChange, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Thermal-state and power-state notifications arrive on an arbitrary thread;
    /// hop to the main actor to re-evaluate the governor.
    @objc private nonisolated func thermalOrPowerChanged() {
        Task { @MainActor [weak self] in self?.applyThermalCeiling() }
    }

    func presentPicker(settings: StreamSettings) {
        // `pendingSettings` is set before the serialized audio activation awaits.
        // Reject a second toolbar tap during that window so only one activation and
        // one system-picker presentation can be queued.
        guard stream == nil, pendingSettings == nil, !isStopping else { return }
        guard settings.isPublishable else {
            errorMessage = "Complete the connection settings before starting a stream."
            return
        }
        guard picker.isAvailable else {
            errorMessage = "Screen capture is not available on this device."
            return
        }

        pendingSettings = settings
        if settings.pipEnabled {
            let facecam = FacecamCapture()
            pendingFacecam = facecam
            facecam.start(with: settings)
        }
        Task {
            await configurePreferredMicrophone(settings.preferredAudioInputUID)
            presentSystemPicker(settings: settings)
        }
    }

    private func presentSystemPicker(settings: StreamSettings) {
        guard pendingSettings != nil, stream == nil, !isStopping else { return }
        var configuration = SCContentSharingPickerConfiguration()
        configuration.showsMicrophoneControl = true
        // ScreenCaptureKit's system camera effect only supports current-app
        // capture. Full-display streams keep using our frame compositor.
        configuration.showsCameraControl = false
        picker.defaultConfiguration = configuration
        picker.isActive = true
        captureLog.info("Presenting ScreenCaptureKit full-display picker")
        picker.present(using: .display)
    }

    func stop() {
        Task { await stopCapture() }
    }

    func clearError() {
        errorMessage = nil
    }

    /// Polls the publisher's telemetry ~1s into `liveStats` for the stats HUD.
    /// Sleeps AFTER the await so the cadence is (poll latency + 1s), and re-reads
    /// `publisher` each turn so teardown — which nils it and cancels this task —
    /// ends the loop cleanly with no stale write (statsSnapshot self-guards to nil).
    private func startStatsPolling() {
        statsTask?.cancel()
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                let snapshot = await self?.publisher?.statsSnapshot()
                // Re-check after the await: teardown may have cancelled us and
                // cleared liveStats while this poll was in flight — don't write back.
                if Task.isCancelled { return }
                // Write through INCLUDING nil: the publishers return nil during a
                // reconnect, which must clear the card to its "—" placeholders rather
                // than freezing on stale last-good telemetry while the stream is down.
                self?.applyPolledStats(snapshot)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// One stats tick: fold the measured frame telemetry (achieved fps + cumulative
    /// congestion drops) into the publisher's target-based snapshot, then store it.
    /// Advances the achieved-fps delta baseline as a side effect, so it must run
    /// exactly once per poll.
    private func applyPolledStats(_ base: LiveStats?) {
        updateLiveStats(enrichWithTelemetry(base))
    }

    /// Merges the shared `FrameTelemetry` into the publisher's snapshot: the measured
    /// achieved fps (from the encoded-frame delta over the real elapsed window) and
    /// the cumulative congestion drops. Returns `base` untouched when telemetry isn't
    /// available (pre-live / torn down). Mutates the delta baseline.
    private func enrichWithTelemetry(_ base: LiveStats?) -> LiveStats? {
        guard let telemetry = frameTelemetry else { return base }
        let current = telemetry.snapshot()
        let now = DispatchTime.now().uptimeNanoseconds
        var achieved = 0
        if let previous = lastTelemetrySnapshot, lastTelemetryAt > 0, now > lastTelemetryAt {
            let elapsed = Double(now &- lastTelemetryAt) / 1_000_000_000
            achieved = FrameTelemetry.rate(from: previous, to: current, elapsed: elapsed).achievedFrameRate
        }
        // Advance the baseline every tick — even when `base` is nil (reconnecting) —
        // so the next window measures against a fresh, ~1s-old sample.
        lastTelemetrySnapshot = current
        lastTelemetryAt = now
        guard var stats = base else { return nil }
        stats.achievedFrameRate = achieved
        stats.droppedFrames = current.congestionDrops
        return stats
    }

    /// Assigns the latest telemetry, skipping a redundant write (and the 1 Hz leaf
    /// re-render it would otherwise trigger) when the snapshot is unchanged.
    private func updateLiveStats(_ stats: LiveStats?) {
        if liveStats != stats { liveStats = stats }
    }

    private func makePublisher(for transport: StreamCore.StreamProtocol,
                               telemetry: FrameTelemetry) -> any Publisher {
        switch transport {
        case .rtmp, .rtmps:
            RTMPPublisher(telemetry: telemetry)
        case .srt, .whip:
            SessionPublisher(protocol: transport, telemetry: telemetry)
        }
    }

    private func startCapture(with filter: SCContentFilter) async {
        if stream != nil { await stopCapture() }

        let settings = pendingSettings ?? SettingsStore().load()
        pendingSettings = nil
        guard settings.isPublishable else {
            errorMessage = "Complete the connection settings before starting a stream."
            return
        }

        // One telemetry instance per broadcast, shared by the capture output (the
        // four shed sites) and the publisher (admission + encoded rate).
        let telemetry = FrameTelemetry()
        frameTelemetry = telemetry
        lastTelemetrySnapshot = nil
        lastTelemetryAt = 0
        let publisher = makePublisher(for: settings.selectedProtocol, telemetry: telemetry)
        let facecam = pendingFacecam ?? FacecamCapture()
        pendingFacecam = nil
        let output = ScreenCaptureOutput(publisher: publisher, settings: settings,
                                         facecam: facecam,
                                         telemetry: telemetry) { [weak self] error in
            Task { @MainActor [weak self] in await self?.captureDidStop(error: error) }
        }

        let configuration = SCStreamConfiguration()
        let nativeWidth = max(2, Int((filter.contentRect.width * CGFloat(filter.pointPixelScale)).rounded()))
        let nativeHeight = max(2, Int((filter.contentRect.height * CGFloat(filter.pointPixelScale)).rounded()))
        // Ask ScreenCaptureKit for the actual encode dimensions up front. Capturing
        // a native 3x display only to downscale it in VideoToolbox wastes memory
        // bandwidth and GPU/encoder work (often 2–3x the pixels for a 720p stream).
        // `encodeSize` preserves orientation/aspect, clamps to the device ceiling,
        // and returns the even dimensions required by H.264/HEVC.
        let captureSize = settings.encodeSize(
            forOrientedWidth: nativeWidth,
            height: nativeHeight,
            maxShortEdge: StreamCapability.current.maxShortEdge
        )
        configuration.width = Int(captureSize.width)
        configuration.height = Int(captureSize.height)
        configuration.capturesAudio = settings.includeAppAudio
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.excludesCurrentProcessAudio = true

        let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        do {
            try stream.addStreamOutput(output, type: .screen,
                                       sampleHandlerQueue: output.sampleQueue)
            if settings.includeAppAudio {
                try stream.addStreamOutput(output, type: .audio,
                                           sampleHandlerQueue: output.sampleQueue)
            }
            // The picker owns whether microphone capture is enabled. Registering
            // the output here makes samples available when the user turns it on.
            try stream.addStreamOutput(output, type: .microphone,
                                       sampleHandlerQueue: output.sampleQueue)

            self.publisher = publisher
            self.output = output
            self.stream = stream
            publisherTask = Task { [weak self] in
                do {
                    try await publisher.start(settings)
                } catch {
                    await self?.publisherDidFail(error)
                }
            }

            try await stream.startCapture()
            isLive = true
            broadcastStartedAt = Date()
            liveStats = nil
            startStatsPolling()
            publishState(true)
            lastAppliedCeiling = nil
            applyThermalCeiling()
            heartbeatTask = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(3))
                    if !Task.isCancelled { publishState(true) }
                }
            }
            captureLog.info("ScreenCaptureKit stream started")
        } catch {
            facecam.stop()
            await stopCapture()
            let nsError = error as NSError
            errorMessage = "\(nsError.localizedDescription) (\(nsError.domain) \(nsError.code))"
            captureLog.error("Stream start failed: domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) message=\(nsError.localizedDescription, privacy: .public)")
        }
    }

    private func stopCapture() async {
        guard !isStopping else { return }
        isStopping = true
        defer { isStopping = false }

        let stream = self.stream
        let publisher = self.publisher
        let output = self.output

        self.stream = nil
        self.publisher = nil
        self.output = nil
        publisherTask?.cancel()
        publisherTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        statsTask?.cancel()
        statsTask = nil
        frameTelemetry = nil
        lastTelemetrySnapshot = nil
        lastTelemetryAt = 0
        isLive = false
        thermalNotice = nil
        liveStats = nil
        broadcastStartedAt = nil
        lastAppliedCeiling = nil
        thermalApplyTask = nil
        output?.finish()

        if let stream, stream.isCapturing {
            try? await stream.stopCapture()
        }
        if let publisher { await publisher.stop() }
        await deactivateAudioSession()
        publishState(false)
        captureLog.info("ScreenCaptureKit stream stopped")
    }

    private func captureDidStop(error: Error) async {
        // Flip the record button to "not live" immediately — before any teardown
        // await and regardless of whether the stream was already cleared — so an
        // error/background stop always reflects on the control.
        isLive = false
        guard stream != nil else { return }
        let nsError = error as NSError
        captureLog.error("Capture stopped: domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) message=\(nsError.localizedDescription, privacy: .public)")
        await stopCapture()
        if nsError.code != SCStreamError.Code.userStopped.rawValue {
            errorMessage = error.localizedDescription
        }
    }

    private func publisherDidFail(_ error: Error) async {
        isLive = false
        guard stream != nil else { return }
        captureLog.error("Publisher failed: \(String(describing: error), privacy: .public)")
        await stopCapture()
        errorMessage = error.localizedDescription
    }

    private func applyMicVolume() {
        let volume = SettingsStore().load().micVolume
        setMicVolume(volume)
    }

    /// Applies an in-memory UI edit directly to the live pipeline. This avoids a
    /// synchronous settings reload (and a race with debounced persistence) for the
    /// Settings slider and mute button; the Darwin observer remains as a fallback.
    func setMicVolume(_ volume: Double) {
        output?.setMicVolume(volume)
        guard let publisher else { return }
        Task { await publisher.setMicVolume(volume) }
    }

    /// The same latest-frame holder feeding the compositor. The UI renders from it
    /// without opening a second camera session.
    var facecamPreviewFrames: LatestCameraFrame? {
        output?.facecamPreviewFrames
    }

    /// Keeps drag-to-corner UI changes synchronized with the live compositor.
    func setPIPCorner(_ corner: PIPCorner) {
        output?.setPIPCorner(corner)
    }

    func setPIPScale(_ scale: Double) {
        output?.setPIPScale(scale)
    }

    /// Applies the toolbar/settings facecam toggle to an active broadcast.
    func setPIPEnabled(_ enabled: Bool) {
        output?.setPIPEnabled(enabled)
    }

    /// Once the software preview has produced its first capturable frame, the
    /// foreground screen already contains PiP and the compositor copy is disabled.
    func setPIPRenderedInApp(_ isRenderedInApp: Bool) {
        output?.setPIPRenderedInApp(isRenderedInApp)
    }

    /// Recomputes the thermal/Low-Power ceiling and pushes it to the encoder (via
    /// the adaptive controller) and the compositor. Reuses the existing throttle
    /// path rather than adding a parallel one. No-op while not capturing.
    private func applyThermalCeiling() {
        guard let publisher, let output else { return }
        let ceiling = ThermalPowerGovernor.current()
        guard ceiling != lastAppliedCeiling else { return }
        lastAppliedCeiling = ceiling
        thermalNotice = ceiling.notice
        output.applyThermalProfile(frameRateCap: ceiling.frameRateCap,
                                   allowPiP: ceiling.allowPiP)
        let scale = ceiling.bitRateScale
        let cap = ceiling.frameRateCap
        // Serialize applies in submission order so two notifications firing close
        // together cannot land on the ABR actor out of order and leave a stale
        // ceiling stored while thermalNotice reports otherwise.
        let previous = thermalApplyTask
        thermalApplyTask = Task {
            await previous?.value
            await publisher.setThermalCeiling(bitRateScale: scale, frameRateCap: cap)
        }
        if ceiling.notice != nil {
            captureLog.notice("Thermal governor engaged: fpsCap=\(cap, privacy: .public) bitrateScale=\(scale, privacy: .public) lowPower=\(ProcessInfo.processInfo.isLowPowerModeEnabled, privacy: .public)")
        } else {
            captureLog.info("Thermal governor cleared; full quality restored")
        }
    }

    private func configurePreferredMicrophone(_ uid: String?) async {
        let activated = await AudioSessionCoordinator.shared.activate(
            preferredInputUID: uid
        )
        guard activated else {
            captureLog.warning("Could not preconfigure the preferred microphone; ScreenCaptureKit will use the system default")
            return
        }
    }

    private func deactivateAudioSession() async {
        await AudioSessionCoordinator.shared.deactivateAndWait()
    }

    private func publishState(_ live: Bool) {
        BroadcastStateStore.write(BroadcastState(
            isBroadcasting: live,
            heartbeat: Date().timeIntervalSince1970
        ))
        BroadcastControl.post(BroadcastControl.stateSignal)
    }
}

extension ScreenCaptureController: SCContentSharingPickerObserver {
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker,
                                          didCancelFor stream: SCStream?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.pendingSettings = nil
            self.pendingFacecam?.stop()
            self.pendingFacecam = nil
            captureLog.info("ScreenCaptureKit picker cancelled")
            await self.deactivateAudioSession()
        }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker,
                                          didUpdateWith filter: SCContentFilter,
                                          for stream: SCStream?) {
        let filter = UncheckedSendableBox(filter)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let selectedFilter = filter.value
            captureLog.info("Picker selected content: style=\(String(describing: selectedFilter.style), privacy: .public) rect=\(String(describing: selectedFilter.contentRect), privacy: .public) scale=\(selectedFilter.pointPixelScale, privacy: .public)")
            await self.startCapture(with: selectedFilter)
        }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        let error = UncheckedSendableBox(error as NSError)
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.pendingSettings = nil
            self.pendingFacecam?.stop()
            self.pendingFacecam = nil
            let nsError = error.value
            captureLog.error("Picker failed: domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) message=\(nsError.localizedDescription, privacy: .public)")
            await self.deactivateAudioSession()
            self.errorMessage = "\(nsError.localizedDescription) (\(nsError.domain) \(nsError.code))"
        }
    }
}

/// ScreenCaptureKit's Objective-C observer callbacks arrive on a framework queue
/// and its reference types aren't annotated Sendable. The box transfers immutable
/// callback values into an explicit MainActor task without actor-assuming thunks.
private final class UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

/// Routes ScreenCaptureKit's serial sample callbacks into one ordered video
/// consumer and the publishers' existing ordered audio ingress.
private final class ScreenCaptureOutput: NSObject, SCStreamOutput, SCStreamDelegate,
                                         @unchecked Sendable {
    let sampleQueue = DispatchQueue(label: "com.joeblau.Stream.screen-capture.samples",
                                    qos: .userInitiated)

    private let publisher: any Publisher
    private let settings: StreamSettings
    /// Device resolution/fps ceiling. Caps both the encode size (short edge) and
    /// the capture pacing so a 1080p60 pick never asks a device for more than it
    /// can sustain. The thermal governor tightens this further at runtime.
    private let capability = StreamCapability.current
    /// Shared frame telemetry (issue #23 / M8): this output records the capture,
    /// pacing (PTS-deadline), backpressure (`bufferingNewest(1)`), and compositor
    /// (pool-exhaustion) sites on the serial sample queue.
    private let telemetry: FrameTelemetry
    private let onStopped: @Sendable (Error) -> Void
    private let micLevelMeter: ScreenCaptureMicrophoneMeter
    private let micLevelChannel = MicrophoneLevelChannel()
    private let facecam: FacecamCapture
    private let compositor = FacecamCompositor()
    /// Runtime thermal/Low-Power gate. The user setting is immutable for a live
    /// session, but the governor can disable PiP without rebuilding the output.
    /// The video consumer and governor run on different executors, so guard it.
    private let pipAllowed: OSAllocatedUnfairLock<Bool>
    private let pipUserEnabled: OSAllocatedUnfairLock<Bool>
    private let pipThermallyAllowed: OSAllocatedUnfairLock<Bool>
    private let pipRenderedInApp: OSAllocatedUnfairLock<Bool>
    private let pipCorner: OSAllocatedUnfairLock<PIPCorner>
    private let pipScale: OSAllocatedUnfairLock<Double>
    private let videoSamples: AsyncStream<CMSampleBuffer>
    private let videoContinuation: AsyncStream<CMSampleBuffer>.Continuation
    private var videoConsumer: Task<Void, Never>?

    /// Target-frame-rate pacing. SCStream on iOS delivers at the display's native
    /// refresh (up to 120 Hz on ProMotion) and offers NO `minimumFrameInterval`,
    /// so the screen callback itself must throttle down to `settings.frameRate` —
    /// otherwise the encoder is flooded (irregular pacing + CPU/thermal spikes that
    /// stutter both video and audio). Touched only on the serial `sampleQueue`.
    private var targetFrameInterval: CMTime
    private var nextVideoDeadline: CMTime = .invalid

    init(publisher: any Publisher,
         settings: StreamSettings,
         facecam: FacecamCapture,
         telemetry: FrameTelemetry,
         onStopped: @escaping @Sendable (Error) -> Void) {
        self.publisher = publisher
        self.settings = settings
        self.facecam = facecam
        self.telemetry = telemetry
        self.onStopped = onStopped
        micLevelMeter = ScreenCaptureMicrophoneMeter(gain: settings.micVolume)
        pipAllowed = OSAllocatedUnfairLock(initialState: settings.pipEnabled)
        pipUserEnabled = OSAllocatedUnfairLock(initialState: settings.pipEnabled)
        pipThermallyAllowed = OSAllocatedUnfairLock(initialState: true)
        pipRenderedInApp = OSAllocatedUnfairLock(initialState: false)
        pipCorner = OSAllocatedUnfairLock(initialState: settings.pipCorner)
        pipScale = OSAllocatedUnfairLock(initialState: settings.pipScale)
        targetFrameInterval = CMTime(value: 1,
                                     timescale: CMTimeScale(settings.encodeFrameRate(maxFrameRate: capability.maxFrameRate)))
        (videoSamples, videoContinuation) = AsyncStream.makeStream(
            of: CMSampleBuffer.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        super.init()
        if settings.pipEnabled { facecam.start(with: settings) }
        videoConsumer = Task { [videoSamples, publisher, settings, capability] in
            var targetSize: CGSize?
            for await sampleBuffer in videoSamples {
                guard sampleBuffer.isValid,
                      sampleBuffer.dataReadiness == .ready,
                      let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { continue }
                if targetSize == nil {
                    let width = CVPixelBufferGetWidth(image)
                    let height = CVPixelBufferGetHeight(image)
                    let target = settings.encodeSize(forOrientedWidth: width, height: height,
                                                     maxShortEdge: capability.maxShortEdge)
                    await publisher.setOutputSize(target, nativeShortEdge: min(width, height))
                    targetSize = target
                }
                let shouldComposite = self.pipAllowed.withLock { $0 }
                    && !self.pipRenderedInApp.withLock { $0 }
                if shouldComposite, let targetSize {
                    let corner = self.pipCorner.withLock { $0 }
                    let scale = self.pipScale.withLock { $0 }
                    if let composited = self.compositor.composite(
                           screen: image,
                           camera: self.facecam.latest.freshest(),
                           targetSize: targetSize,
                           orientation: .up,
                           corner: corner,
                           scale: scale,
                           cameraPosition: settings.cameraPosition
                       ),
                       let output = self.compositor.makeSampleBuffer(
                           from: composited,
                           timingSource: sampleBuffer
                       ) {
                        await publisher.appendVideo(output)
                    } else {
                        // A raw native-size fallback would change the encoder's input
                        // format and force a VideoToolbox session rebuild. Drop this
                        // frame instead; the next pooled target-size frame stays stable.
                        self.telemetry.recordDrop(.compositor)
                    }
                } else {
                    await publisher.appendVideo(sampleBuffer)
                }
            }
        }
    }

    func finish() {
        pipAllowed.withLock { $0 = false }
        micLevelChannel.publish(0)
        facecam.stop()
        videoContinuation.finish()
        videoConsumer?.cancel()
        videoConsumer = nil
    }

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard sampleBuffer.isValid, sampleBuffer.dataReadiness == .ready else { return }
        switch type {
        case .screen:
            telemetry.recordCaptured()
            // Downsample the native-refresh feed to the target frame rate by PTS
            // deadline: emit the first frame at/after each deadline, then advance
            // by one interval; re-anchor after a stall so a gap doesn't burst.
            let pts = sampleBuffer.presentationTimeStamp
            if pts.isValid {
                if nextVideoDeadline.isValid, CMTimeCompare(pts, nextVideoDeadline) < 0 {
                    // Intentional pacing shed (e.g. 120 Hz → 30 fps), not a fault —
                    // counted separately from the congestion drops the HUD surfaces.
                    telemetry.recordDrop(.pacing)
                    return   // arrived before the next target-fps slot — drop it
                }
                let advanced = CMTimeAdd(nextVideoDeadline.isValid ? nextVideoDeadline : pts,
                                         targetFrameInterval)
                nextVideoDeadline = CMTimeCompare(advanced, pts) > 0
                    ? advanced
                    : CMTimeAdd(pts, targetFrameInterval)
            }
            // `bufferingNewest(1)`: if the consumer (compositor/append) hasn't drained
            // the previous frame, this yield evicts it — a backpressure shed the
            // pipeline couldn't keep up with. `.dropped` carries that evicted frame.
            if case .dropped = videoContinuation.yield(sampleBuffer) {
                telemetry.recordDrop(.backpressure)
            }
        case .audio:
            if settings.includeAppAudio { publisher.enqueueApp(sampleBuffer) }
        case .microphone:
            if let level = micLevelMeter.measure(sampleBuffer) {
                micLevelChannel.publish(level)
            }
            publisher.enqueueMic(sampleBuffer)
        @unknown default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        onStopped(error)
    }

    func setMicVolume(_ volume: Double) {
        micLevelMeter.setGain(volume)
    }

    var facecamPreviewFrames: LatestCameraFrame {
        facecam.latest
    }

    func setPIPCorner(_ corner: PIPCorner) {
        pipCorner.withLock { $0 = corner }
    }

    func setPIPScale(_ scale: Double) {
        pipScale.withLock { $0 = scale }
    }

    func setPIPEnabled(_ enabled: Bool) {
        pipUserEnabled.withLock { $0 = enabled }
        let allowed = enabled && pipThermallyAllowed.withLock { $0 }
        pipAllowed.withLock { $0 = allowed }
        if allowed {
            facecam.start(with: settings)
        } else {
            pipRenderedInApp.withLock { $0 = false }
            facecam.stop()
        }
    }

    func setPIPRenderedInApp(_ isRenderedInApp: Bool) {
        pipRenderedInApp.withLock { $0 = isRenderedInApp }
    }

    /// Applies the device thermal/Low-Power profile to the capture side: paces the
    /// screen callback to the capped frame rate (on the serial sample queue) and
    /// stops the facecam under pressure so the camera + compositor stop burning
    /// power. Re-arms the facecam when the device recovers. PiP toggling only
    /// applies when the user has the facecam enabled.
    func applyThermalProfile(frameRateCap: Int, allowPiP: Bool) {
        pipThermallyAllowed.withLock { $0 = allowPiP }
        let shouldAllowPiP = pipUserEnabled.withLock { $0 } && allowPiP
        pipAllowed.withLock { $0 = shouldAllowPiP }
        sampleQueue.async { [weak self] in
            guard let self else { return }
            // Cap to the device ceiling first, then the thermal frame-rate cap.
            let deviceRate = self.settings.encodeFrameRate(maxFrameRate: self.capability.maxFrameRate)
            let fps = max(1, min(deviceRate, frameRateCap))
            self.targetFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        }
        if shouldAllowPiP {
            facecam.start(with: settings)
        } else {
            facecam.stop()
        }
    }
}

/// Computes a throttled post-gain RMS level from ScreenCaptureKit microphone
/// buffers for the live meter in Settings.
private final class ScreenCaptureMicrophoneMeter: @unchecked Sendable {
    private var lock = os_unfair_lock_s()
    private var lastMeasurementAt: UInt64 = 0
    private var gain: Float

    init(gain: Double) {
        self.gain = Float(max(0, min(gain, 2)))
    }

    func setGain(_ gain: Double) {
        os_unfair_lock_lock(&lock)
        self.gain = Float(max(0, min(gain, 2)))
        os_unfair_lock_unlock(&lock)
    }

    func measure(_ sampleBuffer: CMSampleBuffer) -> Float? {
        let now = DispatchTime.now().uptimeNanoseconds
        os_unfair_lock_lock(&lock)
        guard now &- lastMeasurementAt >= 100_000_000 else {
            os_unfair_lock_unlock(&lock)
            return nil
        }
        lastMeasurementAt = now
        let gain = self.gain
        os_unfair_lock_unlock(&lock)

        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer)
                .flatMap(CMAudioFormatDescriptionGetStreamBasicDescription) else { return nil }
        let asbd = description.pointee
        guard asbd.mFormatID == kAudioFormatLinearPCM else { return nil }

        var listSize = 0
        var retainedBlockBuffer: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &listSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &retainedBlockBuffer
        ) == noErr, listSize > 0 else { return nil }

        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: listSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { storage.deallocate() }
        let list = storage.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: list,
            bufferListSize: listSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &retainedBlockBuffer
        ) == noErr else { return nil }

        var sumOfSquares = 0.0
        var sampleCount = 0
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        for buffer in UnsafeMutableAudioBufferListPointer(list) {
            guard let data = buffer.mData else { continue }
            if isFloat, asbd.mBitsPerChannel == 32 {
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                let samples = data.assumingMemoryBound(to: Float.self)
                for index in 0..<count {
                    let value = Double(samples[index])
                    sumOfSquares += value * value
                }
                sampleCount += count
            } else if asbd.mBitsPerChannel == 16 {
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Int16>.size
                let samples = data.assumingMemoryBound(to: Int16.self)
                for index in 0..<count {
                    let value = Double(samples[index]) / Double(Int16.max)
                    sumOfSquares += value * value
                }
                sampleCount += count
            } else if asbd.mBitsPerChannel == 32 {
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Int32>.size
                let samples = data.assumingMemoryBound(to: Int32.self)
                for index in 0..<count {
                    let value = Double(samples[index]) / Double(Int32.max)
                    sumOfSquares += value * value
                }
                sampleCount += count
            }
        }
        guard sampleCount > 0 else { return nil }

        let rms = min(1, sqrt(sumOfSquares / Double(sampleCount)) * Double(gain))
        let decibels = 20 * log10(max(rms, 0.000_001))
        return Float(max(0, min(1, (decibels + 60) / 60)))
    }
}
#else
/// ScreenCaptureKit's iOS 27 beta module is device-only. Keep previews and the
/// simulator buildable while making the hardware requirement explicit at runtime.
@MainActor
@Observable
final class ScreenCaptureController {
    private(set) var isLive = false
    private(set) var isStopping = false
    private(set) var errorMessage: String?
    private(set) var thermalNotice: String?
    private(set) var liveStats: LiveStats?
    private(set) var broadcastStartedAt: Date?
    var facecamPreviewFrames: LatestCameraFrame? { nil }

    func presentPicker(settings: StreamSettings) {
        errorMessage = "Screen capture requires a physical iOS 27 device."
    }

    func stop() {}

    func setMicVolume(_ volume: Double) {}

    func setPIPCorner(_ corner: PIPCorner) {}

    func setPIPScale(_ scale: Double) {}

    func setPIPEnabled(_ enabled: Bool) {}

    func setPIPRenderedInApp(_ isRenderedInApp: Bool) {}

    func clearError() {
        errorMessage = nil
    }
}
#endif
