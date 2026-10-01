import HaishinKit        // MediaMixer, StreamSessionBuilderFactory, StreamConvertible, codec settings
import SRTHaishinKit     // SRTSessionFactory  (srt://)
import RTCHaishinKit     // HTTPSessionFactory (WHIP over http/https)
import AVFoundation
import CoreMedia
import CoreGraphics
import Network          // NWPathMonitor drives the same proactive path supervision as RTMP
import VideoToolbox
import StreamCore
import os

private let sessionLog = Logger(subsystem: "com.joeblau.Stream", category: "session")

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
    func setMicVolume(_ volume: Double) async
    /// Applies a device thermal / Low-Power ceiling (bitrate scale + fps cap) to
    /// the encoder, composed with the network ceiling by the adaptive controller.
    func setThermalCeiling(bitRateScale: Double, frameRateCap: Int) async
    /// A snapshot of the live encode/uplink metrics for the stats HUD, or `nil`
    /// when nothing is being published yet (pre-connect / torn down).
    func statsSnapshot() async -> LiveStats?
}

/// Publishes over SRT or WHIP via HaishinKit's protocol-agnostic `StreamSession`
/// API (RTMP/RTMPS stay on the dedicated `RTMPPublisher`, untouched). The encode
/// pipeline is identical to the RTMP path; only the transport differs.
///
/// WHIP note: WebRTC (libdatachannel + DTLS/ICE/SRTP) adds real memory to the
/// publishing overhead — treat WHIP as experimental and validate its footprint
/// on device against a real endpoint.
actor SessionPublisher: Publisher {
    private let transport: StreamCore.StreamProtocol
    private let mixer = MediaMixer(captureSessionMode: .manual,
                                   multiTrackAudioMixingEnabled: true)
    /// Device resolution/fps ceiling (1080p60 on capable hardware, else 720p30),
    /// computed once. The thermal governor + ABR cap the live rate below it.
    private let capability = StreamCapability.current
    private lazy var networkController = BroadcastAdaptiveBitRateController(
        maximumBitRate: settings.videoBitrate,
        frameRate: settings.encodeFrameRate(maxFrameRate: capability.maxFrameRate))
    private var settings: StreamSettings = .default

    /// The frame rate this device can encode: the user's chosen rate clamped to
    /// the device capability ceiling. Replaces the old hard `min(frameRate, 30)`.
    private var encodeFrameRate: Int { settings.encodeFrameRate(maxFrameRate: capability.maxFrameRate) }

    private var session: (any StreamSession)?
    private var stream: (any StreamConvertible)?
    private var isRunning = false
    private var isPaused = false
    private var outputSizeConfigured = false
    private var outputSize: CGSize?
    private var userInitiatedStop = false

    private var timeline = MediaTimelineNormalizer()
    private let videoAdmission = VideoFrameAdmission()
    /// Shared frame-drop / achieved-fps counters (issue #23 / M8). See RTMPPublisher:
    /// records the admission shed + every encoded append into the same instance the
    /// capture side and controller share.
    private let telemetry: FrameTelemetry

    // Ordered, lossless audio ingress: ScreenCaptureKit yields synchronously, a
    // single consumer per track awaits each append — preserving PTS order.
    private let micStream: AsyncStream<CMSampleBuffer>
    private let micCont: AsyncStream<CMSampleBuffer>.Continuation
    private let appStream: AsyncStream<CMSampleBuffer>
    private let appCont: AsyncStream<CMSampleBuffer>.Continuation
    private var audioConsumers: [Task<Void, Never>] = []
    private var lastVideoBuffer: CMSampleBuffer?
    private var lastVideoAppendAt: UInt64 = 0
    private var lastVideoPTS: CMTime = .negativeInfinity
    private var frameRepeatTask: Task<Void, Never>?

    // MARK: - Shared supervision state (parity with RTMPPublisher, over SRT/WHIP)
    // Brings SRT/WHIP up to the RTMP publisher's resilience using the SAME
    // StreamCore deciders (ReconnectBackoff / WatchdogEvaluator / classifyPathTransition
    // / MicStallEvaluator): NWPath supervision, a queue-stall watchdog, per-path
    // ceilings, frame-shedding admission, mic-stall failover, and a single-flight,
    // path-gated, jittered reconnect that parks (instead of burning attempts) while
    // the network is down.
    /// Single-flight marker: while any recovery runs, path events steer it and the
    /// watchdog stands down, rather than a second loop racing on the same session.
    private var recoveryInProgress = false
    private var backoff = ReconnectBackoff()
    private var watchdog = WatchdogState()
    private var lastMediaAt = DispatchTime.now().uptimeNanoseconds
    /// Lifecycle events for the controller's streaming state machine (W02).
    nonisolated let events: AsyncStream<PublisherEvent>
    private let eventCont: AsyncStream<PublisherEvent>.Continuation
    /// Mic-stall failover: promote app audio (track 1) to the mix clock if the mic
    /// route goes silent while app audio still flows; the first mic buffer flips home.
    private var micTrackStalled = false
    /// Broadcast vocal chain on the mic (StreamCore). Created lazily on the first
    /// mic buffer when enabled, so its EQ/compressor state then carries continuously
    /// across the whole broadcast; torn down in `stop()`.
    private var voicePolish: VoicePolishProcessor?
    private var lastMicAppendAt: UInt64 = 0
    private var lastAppAppendAt: UInt64 = 0
    /// When the broadcast went live, so a mic route dead from the START (no buffer
    /// ever) still trips the failover — its silence is measured from here.
    private var startedAt: UInt64 = 0
    /// Proactive network-path supervision (Wi-Fi <-> 5G handoffs, dead zones).
    private var currentPath: NetworkPathSnapshot?
    private var lastPathChangeAt: UInt64 = 0
    private var lastPathLostAt: UInt64 = 0
    /// Reconnect loops parked because NWPath is unsatisfied; resumed on a route return.
    private var pathWaiters: [CheckedContinuation<Void, Never>] = []
    private var pathSupervisorTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var stableConnectionTask: Task<Void, Never>?
    private var handoffDebounceTask: Task<Void, Never>?
    private var pathLossDebounceTask: Task<Void, Never>?
    /// Owns a recovery kicked off from a debounce task. The parking reconnect loop
    /// must NOT run inside pathLossDebounceTask/handoffDebounceTask, which
    /// `handlePathUpdate` cancels on the next NWPath emission — that sticky
    /// cancellation would defeat the loop's backoff and connect awaits. Cancelled
    /// only by stop(), where a fast exit is what we want.
    private var recoveryTask: Task<Void, Never>?
    /// The reconnect loop's currently-sleeping backoff; cancelling = "retry now".
    private var backoffSleepTask: Task<Void, any Error>?

    init(protocol streamProtocol: StreamCore.StreamProtocol,
         telemetry: FrameTelemetry = FrameTelemetry()) {
        self.transport = streamProtocol
        self.telemetry = telemetry
        (events, eventCont) = AsyncStream.makeStream(of: PublisherEvent.self, bufferingPolicy: .unbounded)
        (micStream, micCont) = AsyncStream.makeStream(of: CMSampleBuffer.self, bufferingPolicy: .unbounded)
        (appStream, appCont) = AsyncStream.makeStream(of: CMSampleBuffer.self, bufferingPolicy: .unbounded)
    }

    nonisolated func enqueueMic(_ sb: CMSampleBuffer) { micCont.yield(sb) }
    nonisolated func enqueueApp(_ sb: CMSampleBuffer) { appCont.yield(sb) }

    private func startAudioConsumers() {
        guard audioConsumers.isEmpty else { return }
        let mic = micStream, app = appStream
        audioConsumers = [
            Task { [weak self] in for await sb in mic { await self?.appendMic(sb) } },
            Task { [weak self] in for await sb in app { await self?.appendApp(sb) } }
        ]
    }

    private func startFrameRepeat() {
        frameRepeatTask?.cancel()
        let fps = UInt64(encodeFrameRate)
        let interval = 1_000_000_000 / fps
        frameRepeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                await self?.repeatLastFrameIfIdle(interval: interval)
            }
        }
    }

    /// Re-sends the last frame if capture hasn't delivered one within the target
    /// interval — a steady fps + keyframe cadence on a static screen.
    private func repeatLastFrameIfIdle(interval: UInt64) async {
        guard outputSizeConfigured, isRunning, !isPaused, stream != nil,
              let last = lastVideoBuffer else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        guard now &- lastVideoAppendAt >= interval else { return }
        if let dupe = duplicateVideoBufferWithCurrentTiming(last) {
            await appendVideo(dupe)
        }
    }

    /// WHIP needs Opus; SRT carries AAC.
    private var audioFormat: AudioCodecSettings.Format {
        transport == .whip ? .opus : .aac
    }

    func start(_ settings: StreamSettings) async throws {
        self.settings = settings
        await Self.registerFactories()

        await applyAudioMixerSettings()

        var vm = await mixer.videoMixerSettings
        vm.mode = .passthrough
        await mixer.setVideoMixerSettings(vm)
        await mixer.startRunning()

        // stop() may have interleaved during the setup awaits above (actor reentrancy)
        // and early-returned via its `guard isRunning` branch before we set isRunning.
        // Bail out cleanly rather than spawn long-lived tasks it could never cancel.
        guard !userInitiatedStop else { await mixer.stopRunning(); return }

        isRunning = true
        startedAt = DispatchTime.now().uptimeNanoseconds
        startAudioConsumers()
        startFrameRepeat()
        // Path supervision spawned BEFORE the first connect so path gating covers it.
        // NWPathMonitor is Sendable + AsyncSequence on this target; cancellation ends
        // iteration at the next emission at the latest.
        pathSupervisorTask = Task { [weak self] in
            for await path in NWPathMonitor() {
                if Task.isCancelled { return }
                await self?.handlePathUpdate(NetworkPathSnapshot(path))
            }
        }
        // A broadcast is user-owned, not network-owned (parity with RTMP): the first
        // connect retries through the SAME path-gated loop rather than failing the
        // capture session, so starting in a dead zone parks until a route returns and
        // a go-live network/server hiccup self-heals. Malformed config is already
        // gated upstream (ScreenCaptureController checks settings.isPublishable).
        // recoveryInProgress marks the loop single-flight so a path event steers it.
        recoveryInProgress = true
        await reconnect(immediately: true)
        recoveryInProgress = false
        guard isRunning, !userInitiatedStop else { return }
        // Queue-stall watchdog: 2s probe, parity with RTMP.
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await self?.checkNetworkHealth()
            }
        }
    }

    private static func registerFactories() async {
        // Idempotent: the factory registry keys by supported scheme, so
        // re-registering simply overwrites.
        await StreamSessionBuilderFactory.shared.register(SRTSessionFactory())
        await StreamSessionBuilderFactory.shared.register(HTTPSessionFactory())
    }

    /// Builds a fresh session for the configured URL (scheme selects SRT vs WHIP),
    /// wires the encoder + ABR, attaches the stream to the mixer, and connects.
    private func connectAndPublish() async throws {
        guard let url = URL(string: settings.rtmpURL) else {
            throw NSError(domain: "com.joeblau.Stream.Broadcast", code: 20, userInfo: [
                NSLocalizedDescriptionKey: "The \(transport.displayName) URL is not valid."])
        }
        // A fresh session starts admitting every frame; shedding only re-raises via
        // the watchdog if congestion actually returns. Refresh the media clock so the
        // watchdog's freshness guard doesn't fire on the reconnect.
        videoAdmission.reset()
        watchdog = WatchdogState()
        lastMediaAt = DispatchTime.now().uptimeNanoseconds
        let builder = try await StreamSessionBuilderFactory.shared.make(url)
        _ = await builder.setMode(.publish)
        guard let session = try await builder.build() else {
            throw NSError(domain: "com.joeblau.Stream.Broadcast", code: 21, userInfo: [
                NSLocalizedDescriptionKey: "No transport is registered for this \(transport.displayName) URL."])
        }
        // The app owns reconnection (single-flight, path-gated). Disable HaishinKit's
        // built-in retry so it can't race the app's loop on the same session.
        await session.setMaxRetryCount(0)
        let stream = await session.stream
        try await stream.setAudioSettings(AudioCodecSettings(
            bitRate: settings.audioBitrate, sampleRate: 48_000, format: audioFormat))
        await stream.setVideoInputBufferCounts(1)
        await stream.setBitRateStrategy(networkController)

        // Re-apply the locked encoder size to the fresh stream (across reconnects).
        if let outputSize {
            try await stream.setVideoSettings(
                await makeVideoSettings(await stream.videoSettings, size: outputSize)
            )
        }

        await mixer.addOutput(stream)
        self.session = session
        self.stream = stream

        // stop() may have run (actor reentrancy) during the awaits above — BEFORE
        // these assignments, so its teardown saw nil session/stream and no-op'd on
        // this in-flight one. Never proceed to a live publish the user already ended.
        if userInitiatedStop || !isRunning {
            await teardownFreshSession(session, stream)
            throw CancellationError()
        }

        // Re-seed the current path's bitrate ceiling onto the fresh stream: a path
        // change that landed during reconnect couldn't apply to a nil stream, so the
        // ABR's per-path ceiling could be stale for this new session.
        if let path = currentPath {
            await networkController.setPathProfile(
                ceiling: path.videoBitRateCeiling(configuredMaximum: settings.videoBitrate),
                seed: path.videoBitRateSeed(configuredMaximum: settings.videoBitrate),
                interface: path.interface,
                isBaseline: false,
                applyingTo: stream)
        }
        // Land any thermal ceiling stored before the stream existed. SRT/WHIP emit
        // no `.reset` event, so no adaptive event would otherwise apply a hot-at-
        // go-live ceiling to this fresh encoder until congestion or a state change.
        await networkController.applyCurrentTarget(to: stream)

        try await session.connect { [weak self] in
            guard let self else { return }
            Task { await self.handleDisconnect() }
        }
        // The same race can land during connect(): never leave a LIVE publish up
        // after the user stopped.
        if userInitiatedStop || !isRunning {
            await teardownFreshSession(session, stream)
            throw CancellationError()
        }
        sessionLog.info("\(self.transport.displayName, privacy: .public) connected: \(url.absoluteString, privacy: .public)")
    }

    /// Tears down a freshly-built session that a reentrant stop() couldn't reach
    /// (it wasn't yet assigned to self). Detaches, clears the handles, and closes.
    private func teardownFreshSession(_ session: any StreamSession, _ stream: any StreamConvertible) async {
        await mixer.removeOutput(stream)
        self.session = nil
        self.stream = nil
        try? await session.close()
    }

    /// The session dropped (HaishinKit's onDisconnect callback). Funnel into the
    /// single-flight recovery so it can't race the watchdog or a path event.
    private func handleDisconnect() async {
        guard isRunning, !userInitiatedStop, !isPaused else { return }
        sessionLog.error("\(self.transport.displayName, privacy: .public) transport dropped; recovering")
        await requestRecovery(reason: "transport dropped")
    }

    /// Coalesces disconnect, watchdog, and path failures into one recovery loop.
    /// `immediately: true` (proactive path events) skips the first backoff sleep.
    /// Single-flight via `recoveryInProgress`, mirroring RTMPPublisher.
    private func requestRecovery(reason: String, immediately: Bool = false) async {
        guard isRunning, !userInitiatedStop, !isPaused, !recoveryInProgress else { return }
        recoveryInProgress = true
        defer { recoveryInProgress = false }

        eventCont.yield(.reconnecting(reason: reason))
        sessionLog.warning("\(self.transport.displayName, privacy: .public) recovery requested: \(reason, privacy: .public)")
        // Detach the dead session so encoded frames stop piling into its unbounded
        // send queue; the fresh session in connectAndPublish resets admission. Nil the
        // handles BEFORE the close await so appends (guarded on stream != nil) stop
        // feeding a detached output during teardown.
        if let stream { await mixer.removeOutput(stream) }
        let dyingSession = session
        session = nil
        stream = nil
        try? await dyingSession?.close()
        await reconnect(immediately: immediately)
    }

    /// Path-gated jittered backoff, parity with `RTMPPublisher.reconnect`: parks at
    /// zero cost while iOS reports no satisfied path (instead of burning attempts),
    /// resets backoff on success / a fresh route, and re-checks the gate after an
    /// early-woken sleep so a path event never burns a doomed attempt.
    private func reconnect(immediately: Bool) async {
        var attempt = 0
        var shouldDelay = !immediately
        while isRunning, !userInitiatedStop, !isPaused {
            let waited = await waitUntilPathUsable()
            guard isRunning, !userInitiatedStop, !isPaused else { return }
            if waited {
                shouldDelay = false
                backoff.reset()
            }
            if shouldDelay {
                await interruptibleBackoffSleep()
                guard isRunning, !userInitiatedStop, !isPaused else { return }
                if let path = currentPath, !path.isSatisfied { continue }
            }
            shouldDelay = true
            attempt += 1
            eventCont.yield(.connecting)
            do {
                try await connectAndPublish()
                timeline.markDiscontinuity()
                backoff.reset()
                eventCont.yield(.published)
                sessionLog.info("\(self.transport.displayName, privacy: .public) reconnected after \(attempt) attempt(s)")
                stableConnectionTask?.cancel()
                stableConnectionTask = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
                    await self?.markConnectionStable()
                }
                return
            } catch {
                if userInitiatedStop || !isRunning { return }
                // connectAndPublish attaches the fresh stream to the mixer (addOutput)
                // BEFORE connect(); a failed attempt must DETACH it, or the closed
                // stream stays registered and mixer.append fans every frame to it —
                // leaking one dead encoder per failed attempt on a flaky uplink. Mirror
                // requestRecovery's teardown order (detach, drop handles, then close).
                if let stream { await mixer.removeOutput(stream) }
                let dyingSession = session
                session = nil
                stream = nil
                try? await dyingSession?.close()
                sessionLog.error("\(self.transport.displayName, privacy: .public) reconnect attempt \(attempt) failed: \(String(describing: error), privacy: .public)")
                backoff.escalate()
            }
        }
    }

    /// Sleeps the current backoff with jitter; a path event (or stop) cancels
    /// `backoffSleepTask` to end the wait early.
    private func interruptibleBackoffSleep() async {
        let nanoseconds = backoff.jittered()
        let sleeper = Task { try await Task.sleep(nanoseconds: nanoseconds) }
        backoffSleepTask = sleeper
        defer { backoffSleepTask = nil }
        _ = try? await sleeper.value
    }

    /// Parks while iOS reports no satisfied path. Returns true when it actually
    /// waited (a route transition happened while parked).
    private func waitUntilPathUsable() async -> Bool {
        var waited = false
        while isRunning, !userInitiatedStop, !isPaused,
              let path = currentPath, !path.isSatisfied {
            waited = true
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                pathWaiters.append(continuation)
            }
        }
        return waited
    }

    private func wakeBackoff(resetDelay: Bool) {
        if resetDelay { backoff.reset() }
        backoffSleepTask?.cancel()
    }

    private func resumePathWaiters() {
        guard !pathWaiters.isEmpty else { return }
        let waiters = pathWaiters
        pathWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func markConnectionStable() {
        guard isRunning, !userInitiatedStop else { return }
        backoff.reset()
    }

    /// Kicks off recovery on the dedicated `recoveryTask` instead of awaiting inline.
    /// Callers that run inside a path debounce task (confirmPathLost / recycleForHandoff)
    /// MUST use this: `handlePathUpdate` cancels those debounce tasks on the very
    /// emission that ends an outage, and a parking reconnect loop running inside one
    /// would be left cancelled (sticky) — its `Task.sleep` backoff would return
    /// instantly and its connect awaits could throw. Single-flight is still enforced
    /// by requestRecovery's `recoveryInProgress` guard.
    private func launchRecovery(reason: String, immediately: Bool = false) {
        guard !recoveryInProgress else { return }
        recoveryTask = Task { [weak self] in
            await self?.requestRecovery(reason: reason, immediately: immediately)
        }
    }

    // MARK: - Path supervision (parity with RTMPPublisher.handlePathUpdate)

    /// Reacts to every NWPathMonitor emission via the shared `classifyPathTransition`
    /// so SRT/WHIP make the SAME decisions RTMP does — proactive Wi-Fi<->5G handoff,
    /// debounced path loss, and per-path bitrate ceilings — funneling all recovery
    /// through the single-flight `requestRecovery`.
    private func handlePathUpdate(_ snapshot: NetworkPathSnapshot) async {
        guard isRunning, !userInitiatedStop else { return }
        let previous = currentPath
        currentPath = snapshot
        defer { resumePathWaiters() }

        let result = classifyPathTransition(previous: previous, snapshot: snapshot)
        // Ceiling first: cheap, idempotent. Applied only when the stream exists; a
        // path change during reconnect (stream == nil) is re-seeded from currentPath
        // in connectAndPublish when the fresh session attaches.
        if result.shouldUpdateCeiling, let stream {
            await networkController.setPathProfile(
                ceiling: snapshot.videoBitRateCeiling(configuredMaximum: settings.videoBitrate),
                seed: snapshot.videoBitRateSeed(configuredMaximum: settings.videoBitrate),
                interface: snapshot.interface,
                isBaseline: result.isBaseline,
                applyingTo: stream)
        }

        let now = DispatchTime.now().uptimeNanoseconds
        if result.bumpsPathChangeClock { lastPathChangeAt = now }
        handoffDebounceTask?.cancel()
        pathLossDebounceTask?.cancel()

        switch result.transition {
        case .none, .baseline, .ceilingOnly:
            return
        case .pathLost:
            lastPathLostAt = now
            pathLossDebounceTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: PathDebounce.pathLoss)
                guard !Task.isCancelled else { return }
                await self?.confirmPathLost()
            }
        case .pathRestored:
            wakeBackoff(resetDelay: true)
            if recoveryInProgress {
                // A loop mid-connect on the dead route: fast-fail its socket so it
                // retries on the new path now instead of after a long timeout.
                try? await session?.close()
            } else if !isPaused {
                let connected = await session?.connected == true
                if stream == nil || !connected {
                    // launchRecovery, not inline await: keep the (possibly parking)
                    // reconnect off pathSupervisorTask so it stays free to process the
                    // next emission and resume a parked loop.
                    launchRecovery(reason: "network path restored (\(snapshot.linkIdentity))",
                                   immediately: true)
                }
            }
        case .liveHandoff(let identity):
            handoffDebounceTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: PathDebounce.handoff)
                guard !Task.isCancelled else { return }
                await self?.recycleForHandoff(expectedIdentity: identity)
            }
        }
    }

    /// The path stayed unsatisfied through the debounce: detach outbound media so
    /// encoded frames stop piling into the dead session; recovery resumes when a
    /// route returns (pathRestored) or the session's onDisconnect fires.
    private func confirmPathLost() async {
        guard isRunning, !userInitiatedStop, !isPaused,
              currentPath?.isSatisfied == false else { return }
        sessionLog.warning("\(self.transport.displayName, privacy: .public) network path lost; tearing down and parking until a route returns")
        // Unlike RTMP (whose forked socket survives `.waiting`), SRT/WHIP has no
        // keep-open optimization AND commonly reports connected==true for seconds
        // after the physical path drops. Detaching the output alone would strand a
        // session that pathRestored's gate then skips — permanent dead air. Fully
        // recover instead: the path-gated reconnect parks at zero cost until a route
        // returns, then rebuilds the session and re-attaches the output. Launched on
        // the dedicated recoveryTask so the parking loop survives this debounce task's
        // cancellation when the route returns.
        launchRecovery(reason: "network path lost")
    }

    /// Wi-Fi <-> 5G handoff confirmed by the debounce: recycle onto the new
    /// interface, steering an in-flight loop rather than racing a second one.
    private func recycleForHandoff(expectedIdentity: String) async {
        guard isRunning, !userInitiatedStop, !isPaused,
              currentPath?.isSatisfied == true,
              currentPath?.linkIdentity == expectedIdentity else { return }
        wakeBackoff(resetDelay: true)
        if recoveryInProgress {
            try? await session?.close()
            return
        }
        // Dedicated task (see launchRecovery): a loss right after the handoff would
        // otherwise park the loop inside this cancellable handoffDebounceTask.
        launchRecovery(reason: "network path changed (\(expectedIdentity))", immediately: true)
    }

    // MARK: - Queue-stall watchdog (parity with RTMPPublisher.checkNetworkHealth)

    /// 2s stall probe. Recycles a genuinely wedged socket via the shared
    /// `WatchdogEvaluator`, feeds `VideoFrameAdmission.setQueueDepth`, and runs the
    /// mic-stall failover — the machinery SRT/WHIP previously lacked entirely.
    private func checkNetworkHealth() async {
        guard isRunning, !userInitiatedStop, !recoveryInProgress else { return }
        // A paused capture's draining queue is not a stall; reset the streak.
        guard !isPaused else { watchdog.stalledTicks = 0; return }
        guard await session?.connected == true else {
            sessionLog.error("\(self.transport.displayName, privacy: .public) watchdog found a disconnected session; recovering")
            await requestRecovery(reason: "session state is disconnected")
            return
        }
        let now = DispatchTime.now().uptimeNanoseconds
        // No queue-health conclusion while static content sends no recent samples.
        guard now &- lastMediaAt < 10_000_000_000 else { watchdog.stalledTicks = 0; return }
        // Mic-stall failover: app audio flowing but the mic gone quiet -> promote
        // track 1 to the mix clock; the first mic buffer back flips it home.
        if settings.includeAppAudio, !micTrackStalled, startedAt > 0,
           MicStallEvaluator.shouldPromoteApp(now: now,
                                              lastMicAppendAt: lastMicAppendAt,
                                              lastAppAppendAt: lastAppAppendAt,
                                              startedAt: startedAt) {
            micTrackStalled = true
            await applyAudioMixerSettings()
            sessionLog.warning("Mic buffers stalled >4s; app audio is now the mix clock")
        }
        let health = await networkController.healthSnapshot()
        videoAdmission.setQueueDepth(health.queueBytes)
        let recentPathChange = lastPathChangeAt > 0
            && now &- lastPathChangeAt < PathDebounce.recentPathChangeWindow
        let decision = WatchdogEvaluator.evaluate(queueBytes: health.queueBytes,
                                                  zeroOutputSeconds: health.zeroOutputSeconds,
                                                  recentPathChange: recentPathChange,
                                                  state: &watchdog)
        if decision.shouldRecycle {
            sessionLog.error("\(self.transport.displayName, privacy: .public) socket stalled \(decision.stalledTicks) ticks: queue=\(health.queueBytes) bytes, zeroOut=\(health.zeroOutputSeconds)s, target=\(health.targetBitRate) bps")
            await requestRecovery(reason: "outbound queue stalled")
        }
    }

    func setOutputSize(_ size: CGSize, nativeShortEdge _: Int) async {
        guard !outputSizeConfigured else { return }
        outputSize = size
        outputSizeConfigured = true
        guard let stream else { return }
        do {
            try await stream.setVideoSettings(await makeVideoSettings(await stream.videoSettings, size: size))
        } catch {
            sessionLog.error("Video encoder configuration failed: \(String(describing: error), privacy: .public)")
        }
    }

    func setThermalCeiling(bitRateScale: Double, frameRateCap: Int) async {
        // Apply immediately when connected; otherwise store the ceiling so the
        // first adaptive event after connect (the `.reset`) picks it up.
        if let stream {
            await networkController.setThermalCeiling(bitRateScale: bitRateScale,
                                                      frameRateCap: frameRateCap,
                                                      applyingTo: stream)
        } else {
            await networkController.storeThermalCeiling(bitRateScale: bitRateScale,
                                                        frameRateCap: frameRateCap)
        }
    }

    /// Live encode/uplink metrics for the stats HUD. `nil` until a session stream
    /// exists (pre-connect / mid-reconnect), so the UI shows "connecting…".
    func statsSnapshot() async -> LiveStats? {
        guard isRunning, stream != nil else { return nil }
        let health = await networkController.healthSnapshot()
        let fps = await networkController.currentFrameRate()
        return LiveStats(bitRate: health.targetBitRate,
                         frameRate: fps,
                         queueBytes: health.queueBytes,
                         zeroOutputSeconds: health.zeroOutputSeconds)
    }

    private func makeVideoSettings(_ current: VideoCodecSettings, size: CGSize? = nil) async -> VideoCodecSettings {
        let frameRate = encodeFrameRate
        var v = current
        if let size { v.videoSize = size }
        v.scalingMode = .letterbox
        // Seed from the adaptive controller's current target + frame interval so a
        // path or thermal ceiling learned before this (re)configuration is honored
        // immediately, instead of starting the fresh encoder at the full rate.
        v.bitRate = min(settings.videoBitrate, await networkController.currentTargetBitRate())
        v.expectedFrameRate = Double(frameRate)
        v.frameInterval = await networkController.currentFrameInterval()
        v.maxKeyFrameIntervalDuration = 2
        v.bitRateMode = .average
        // HEVC when the user opted in and the transport can packetize it (SRT);
        // WHIP is currently H.264-only. The profileLevel string also switches the encoder's codec
        // (VideoCodecSettings flips to HEVC on the "HEVC" substring).
        v.profileLevel = settings.effectiveVideoCodec.videoToolboxProfileLevel
        // Low-latency VideoToolbox rate control: tightens encoder queuing latency
        // (makeEncoderSpecification enables EnableLowLatencyRateControl).
        v.isLowLatencyRateControlEnabled = true
        v.allowFrameReordering = false
        return v
    }

    func appendVideo(_ sb: CMSampleBuffer) async {
        guard outputSizeConfigured, isRunning, !isPaused, stream != nil else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        lastMediaAt = now
        lastVideoAppendAt = now
        lastVideoBuffer = sb
        guard videoAdmission.admit() else {
            telemetry.recordDrop(.admission)
            return
        }
        let duration = CMTime(value: 1, timescale: CMTimeScale(encodeFrameRate))
        let normalized = timeline.normalize(sb, kind: .video, fallbackDuration: duration)
        telemetry.recordEncoded()
        await mixer.append(enforceMonotonicVideo(normalized, minStep: duration))
    }

    /// See RTMPPublisher.enforceMonotonicVideo — a real frame arriving just after a
    /// host-clock-stamped repeat must not move the video timeline backwards.
    private func enforceMonotonicVideo(_ sb: CMSampleBuffer, minStep: CMTime) -> CMSampleBuffer {
        let pts = sb.presentationTimeStamp
        if lastVideoPTS.isValid, pts <= lastVideoPTS {
            let bumped = lastVideoPTS + minStep
            lastVideoPTS = bumped
            return restampVideoBuffer(sb, pts: bumped) ?? sb
        }
        lastVideoPTS = pts
        return sb
    }

    func appendMic(_ sb: CMSampleBuffer) async {
        guard isRunning, !isPaused, stream != nil else { return }
        if settings.voicePolishEnabled, voicePolish == nil { voicePolish = VoicePolishProcessor() }
        let sb = voicePolish?.process(sb) ?? sb
        let now = DispatchTime.now().uptimeNanoseconds
        lastMediaAt = now
        lastMicAppendAt = now
        if micTrackStalled {
            // The mic route came back: hand the mix clock straight back to it. Mic
            // shares the capture host clock with the continuous video/app timeline,
            // so no discontinuity rebase is needed (or safe).
            micTrackStalled = false
            await applyAudioMixerSettings()
            sessionLog.info("Mic buffers resumed; mic is the mix clock again")
        }
        await mixer.append(timeline.normalize(sb, kind: .mic,
                                              fallbackDuration: CMTime(value: 1_024, timescale: 48_000)),
                           track: 0)
    }

    func appendApp(_ sb: CMSampleBuffer) async {
        guard isRunning, !isPaused, stream != nil else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        lastMediaAt = now
        lastAppAppendAt = now
        await mixer.append(timeline.normalize(sb, kind: .app,
                                              fallbackDuration: CMTime(value: 1_024, timescale: 48_000)),
                           track: 1)
    }

    private func applyAudioMixerSettings() async {
        let gain = Float(max(0.0, min(settings.micVolume, 2.0)))
        // While the mic route is stalled, app audio (track 1) drives the mix clock
        // so the whole mix does not fall silent with it.
        await mixer.setAudioMixerSettings(AudioMixerSettings(
            sampleRate: 48_000, channels: settings.includeAppAudio ? 2 : 1,
            mainTrack: micTrackStalled ? 1 : 0,
            tracks: [0: AudioMixerTrackSettings(volume: gain), 1: .default]))
    }

    func setMicVolume(_ volume: Double) async {
        settings.micVolume = volume
        await applyAudioMixerSettings()
    }

    func pause() async {
        guard isRunning, !isPaused, !userInitiatedStop else { return }
        isPaused = true
        // Tell the ABR the capture is paused so it doesn't read the draining queue
        // as congestion (parity with RTMP).
        await networkController.setCapturePaused(true)
        timeline.markDiscontinuity()
    }

    func resume() async {
        guard isRunning, isPaused, !userInitiatedStop else { return }
        isPaused = false
        await networkController.setCapturePaused(false)
        timeline.markDiscontinuity()
        // `isPaused` is now false, so requestRecovery's guard passes; single-flight
        // keeps it from racing a supervisor that also noticed the gap.
        if await session?.connected != true {
            await requestRecovery(reason: "capture resumed without an active session")
        }
    }

    func stop() async {
        userInitiatedStop = true
        isPaused = false
        pathSupervisorTask?.cancel()
        pathSupervisorTask = nil
        watchdogTask?.cancel()
        watchdogTask = nil
        stableConnectionTask?.cancel()
        stableConnectionTask = nil
        handoffDebounceTask?.cancel()
        handoffDebounceTask = nil
        pathLossDebounceTask?.cancel()
        pathLossDebounceTask = nil
        recoveryTask?.cancel()
        recoveryTask = nil
        // The reconnect loop's backoff sleep + path parking are unstructured; wake
        // both so any in-flight recovery observes userInitiatedStop and exits (the
        // loop exits on userInitiatedStop regardless of recoveryTask cancellation).
        backoffSleepTask?.cancel()
        resumePathWaiters()
        micCont.finish()
        appCont.finish()
        audioConsumers.forEach { $0.cancel() }
        audioConsumers = []
        frameRepeatTask?.cancel()
        frameRepeatTask = nil
        lastVideoBuffer = nil
        voicePolish = nil
        guard isRunning else {
            await mixer.stopRunning()
            eventCont.yield(.stopped)
            eventCont.finish()
            return
        }
        isRunning = false
        if let stream { await mixer.removeOutput(stream) }
        try? await session?.close()
        session = nil
        stream = nil
        await mixer.stopRunning()
        eventCont.yield(.stopped)
        eventCont.finish()
    }
}
