import HaishinKit       // MediaMixer, VideoCodecSettings, AudioCodecSettings
import RTMPHaishinKit   // RTMPConnection, RTMPStream
import AVFoundation
import CoreMedia
import Network          // NWPathMonitor drives proactive Wi-Fi <-> 5G handoff
import VideoToolbox
import StreamCore
import os

/// Connection, congestion, and recovery diagnostics. Filter with:
/// subsystem:com.joeblau.Stream category:rtmp
private let streamLog = Logger(subsystem: "com.joeblau.Stream", category: "rtmp")

/// Actor wrapping the HaishinKit pipeline: a `MediaMixer` in manual capture mode
/// wired to an `RTMPStream` over an `RTMPConnection`. All HaishinKit access is
/// serialized through this actor; `ScreenCaptureController` dispatches each buffer in.
///
/// rtmps:// URLs auto-negotiate TLS on port 443; rtmp:// uses 1935 — the scheme
/// alone drives the decision, no extra flag required.
actor RTMPPublisher: Publisher {
    private let mixer = MediaMixer(captureSessionMode: .manual,
                                   multiTrackAudioMixingEnabled: true)
    /// Built lazily on the first `stream` access — which happens inside `start`,
    /// AFTER `settings` is assigned — so its connect payload can depend on the
    /// chosen codec. See `makeConnection`.
    private lazy var connection = makeConnection()
    private lazy var stream = RTMPStream(connection: connection)
    /// Device resolution/fps ceiling (1080p60 on capable hardware, else 720p30),
    /// computed once. The thermal governor + ABR cap the live rate below it.
    private let capability = StreamCapability.current
    private lazy var networkController = BroadcastAdaptiveBitRateController(
        maximumBitRate: settings.videoBitrate,
        frameRate: settings.encodeFrameRate(maxFrameRate: capability.maxFrameRate)
    )
    private var isRunning = false
    private var settings: StreamSettings = .default

    /// The frame rate this device can encode: the user's chosen rate clamped to
    /// the device capability ceiling. Replaces the old hard `min(frameRate, 30)`
    /// scattered across the encode/repeat paths.
    private var encodeFrameRate: Int { settings.encodeFrameRate(maxFrameRate: capability.maxFrameRate) }
    /// The encode dimensions are locked once, from the first screen frame, so the
    /// stream matches the device orientation/aspect. Until set, video is dropped.
    private var outputSizeConfigured = false
    private var isPaused = false
    private var streamAttached = false
    private var recoveryInProgress = false
    /// Shared jittered exponential backoff ladder (1s→30s); reset on a successful
    /// reconnect, after 30s stable, or when a fresh route appears.
    private var backoff = ReconnectBackoff()
    private var lastMediaAt = DispatchTime.now().uptimeNanoseconds
    private var timeline = MediaTimelineNormalizer()
    private var hasPublished = false
    /// Sheds input video frames when the outbound queue is deep, to bound latency
    /// (HaishinKit's send queue is otherwise unbounded). Refreshed by checkNetworkHealth.
    private let videoAdmission = VideoFrameAdmission()
    /// Shared frame-drop / achieved-fps counters (issue #23 / M8). This actor records
    /// the admission shed + every encoded append; the capture side records the
    /// capture/pacing/backpressure/compositor sites into the same instance, and the
    /// controller reads one snapshot per telemetry poll. Reachable here so the
    /// adaptive logic (M9) can consume the congestion-drop signal.
    private let telemetry: FrameTelemetry

    // Ordered, lossless audio ingress: ScreenCaptureKit yields synchronously, a
    // single consumer per track awaits each append — preserving PTS order so
    // HaishinKit's ring buffer never silence-fills or swaps out-of-order PCM.
    private let micStream: AsyncStream<CMSampleBuffer>
    private let micCont: AsyncStream<CMSampleBuffer>.Continuation
    private let appStream: AsyncStream<CMSampleBuffer>
    private let appCont: AsyncStream<CMSampleBuffer>.Continuation
    private var audioConsumers: [Task<Void, Never>] = []

    // Frame-repeat: screen capture may emit no complete frame for static content,
    // so the observed rate stalls and keyframe cadence drifts. Re-send the frame at
    // the target rate to hold a steady fps + regular keyframes (unchanged content
    // encodes to near-zero bytes).
    private var lastVideoBuffer: CMSampleBuffer?
    private var lastVideoAppendAt: UInt64 = 0
    private var lastVideoPTS: CMTime = .negativeInfinity   // monotonic guard for frame-repeat
    private var frameRepeatTask: Task<Void, Never>?
    /// Shared outbound-queue stall watchdog state (stalledTicks + lastQueueBytes).
    private var watchdog = WatchdogState()

    init(telemetry: FrameTelemetry = FrameTelemetry()) {
        self.telemetry = telemetry
        (micStream, micCont) = AsyncStream.makeStream(of: CMSampleBuffer.self, bufferingPolicy: .unbounded)
        (appStream, appCont) = AsyncStream.makeStream(of: CMSampleBuffer.self, bufferingPolicy: .unbounded)
    }

    nonisolated func enqueueMic(_ sb: CMSampleBuffer) { micCont.yield(sb) }
    nonisolated func enqueueApp(_ sb: CMSampleBuffer) { appCont.yield(sb) }

    /// Builds the RTMP connection for the current `settings`.
    ///
    /// HEVC over RTMP requires *enhanced* RTMP (E-RTMP): the connect command must
    /// advertise the `hvc1` FourCC so the ingest accepts the HEVC bitstream (the
    /// RTMP video tags are then framed with the E-RTMP exHeader automatically). We
    /// send that enhanced payload ONLY when the user selected HEVC — traditional
    /// ingests such as Restream speak H.264 and some reject the enhanced connect
    /// fields, so the H.264 path keeps the conservative nil payload. AAC audio is
    /// still what's published in both cases (set via `setAudioSettings`); the audio
    /// FourCc advert is a capability, not an obligation.
    private func makeConnection() -> RTMPConnection {
        let enhanced = settings.videoCodec == .hevc
        return RTMPConnection(
            fourCcList: enhanced ? RTMPConnection.supportedFourCcList : nil,
            videoFourCcInfoMap: enhanced ? RTMPConnection.supportedVideoFourCcInfoMap : nil,
            audioFourCcInfoMap: enhanced ? RTMPConnection.supportedAudioFourCcInfoMap : nil,
            capsEx: 0,
            requestTimeout: 5_000,
            // Continuous socket work must not outrank touch/animation delivery.
            qualityOfService: .userInitiated)
    }

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
    /// interval — holding a steady fps and keyframe cadence on a static screen.
    private func repeatLastFrameIfIdle(interval: UInt64) async {
        guard outputSizeConfigured, isRunning, !isPaused, streamAttached,
              let last = lastVideoBuffer else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        guard now &- lastVideoAppendAt >= interval else { return }
        if let dupe = duplicateVideoBufferWithCurrentTiming(last) {
            await appendVideo(dupe)
        }
    }

    /// Set to true ONLY by `stop()`, when the user (or the system) ends the
    /// broadcast. It is the single signal that distinguishes a deliberate teardown
    /// from an unexpected drop: while it is false, any disconnect auto-reconnects.
    private var userInitiatedStop = false
    /// Long-lived task that watches the RTMP connection and reconnects on any
    /// unexpected drop, for the life of the broadcast. Cancelled by `stop()`.
    private var connectionSupervisorTask: Task<Void, Never>?
    private var streamSupervisorTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var stableConnectionTask: Task<Void, Never>?

    /// Proactive network-path supervision (Wi-Fi <-> 5G handoffs, dead zones).
    /// All of it is control-plane state — one NWPathMonitor queue plus a few
    /// Ints/continuations — with no effect on the extension's jetsam budget.
    private var pathSupervisorTask: Task<Void, Never>?
    private var handoffDebounceTask: Task<Void, Never>?
    private var pathLossDebounceTask: Task<Void, Never>?
    private var currentPath: NetworkPathSnapshot?
    private var lastPathChangeAt: UInt64 = 0
    private var lastPathLostAt: UInt64 = 0
    /// The reconnect loop's currently-sleeping backoff; cancelling = "retry now".
    private var backoffSleepTask: Task<Void, any Error>?
    /// Reconnect loops parked because NWPath is unsatisfied.
    private var pathWaiters: [CheckedContinuation<Void, Never>] = []

    /// Mic-stall fallback: HaishinKit renders the audio mix only when the MAIN
    /// track appends, so a silently dead mic route would mute app audio too.
    private var lastMicAppendAt: UInt64 = 0
    private var lastAppAppendAt: UInt64 = 0
    private var micTrackStalled = false
    /// When the broadcast went live, so a mic route that is dead from the START (no
    /// buffer ever) still trips the failover — its silence is measured from here.
    private var startedAt: UInt64 = 0

    /// Builds + starts the pipeline, connects, and begins publishing. The video
    /// size is NOT set here — it is locked from the first frame via `setOutputSize`.
    func start(_ settings: StreamSettings) async throws {
        self.settings = settings

        // Keep AAC stable across Bluetooth HFP/built-in route changes.
        let a = AudioCodecSettings(bitRate: settings.audioBitrate,
                                   sampleRate: 48_000,
                                   format: .aac)
        try await stream.setAudioSettings(a)
        await applyAudioMixerSettings()

        // Latest-only raw video buffering keeps memory bounded under sustained
        // capture. Admission is also bounded in the capture output.
        var vm = await mixer.videoMixerSettings
        vm.mode = .passthrough
        await mixer.setVideoMixerSettings(vm)
        await stream.setVideoInputBufferCounts(1)
        await stream.setBitRateStrategy(networkController)

        await mixer.startRunning()

        // stop() may have interleaved during the setup awaits above (actor reentrancy)
        // and early-returned via its `guard isRunning` branch before we set isRunning.
        // Bail out cleanly rather than spawn long-lived tasks it could never cancel.
        guard !userInitiatedStop else { await mixer.stopRunning(); return }

        if settings.backupEnabled {
            streamLog.warning("Local backup disabled: a second real-time video encoder is not enabled")
        }

        // A broadcast is user-owned, not network-owned. Initial DNS, TLS, RTMP,
        // and publish failures therefore retry just like a mid-stream drop instead
        // of ending the user-owned capture session.
        isRunning = true
        startedAt = DispatchTime.now().uptimeNanoseconds
        startAudioConsumers()
        startFrameRepeat()
        // 4th long-lived task, spawned BEFORE the first connect so path gating
        // covers it. NWPathMonitor is Sendable + AsyncSequence on this target;
        // the first element is the CURRENT path (baseline), then one per change.
        // Cancellation ends iteration at the next emission at the latest; the
        // weak-self + isRunning guards make any late delivery a no-op. This task
        // never touches the single-continuation status streams below.
        pathSupervisorTask = Task { [weak self] in
            for await path in NWPathMonitor() {
                if Task.isCancelled { return }
                await self?.handlePathUpdate(NetworkPathSnapshot(path))
            }
        }
        // Single-flight marker: while ANY reconnect loop runs (including this
        // initial one) path events must wake/steer that loop rather than start
        // a competing one on the same RTMPConnection.
        recoveryInProgress = true
        await reconnect(immediately: true)
        recoveryInProgress = false
        guard isRunning, !userInitiatedStop else { return }

        // Each property owns a single continuation, so capture each exactly once.
        // Capture after the initial retry loop succeeds so failures from earlier
        // attempts cannot be replayed as stale recovery events.
        let connectionStatuses = await connection.status
        let streamStatuses = await stream.status
        // stop() can interleave during the two status awaits above (actor reentrancy)
        // after passing its own `guard isRunning`; re-check so the supervisors and the
        // watchdog timer aren't spawned — and then leaked, uncancellable — post-teardown.
        guard isRunning, !userInitiatedStop else { return }

        connectionSupervisorTask = Task { [weak self] in
            await self?.superviseConnection(connectionStatuses)
        }
        streamSupervisorTask = Task { [weak self] in
            await self?.superviseStream(streamStatuses)
        }
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await self?.checkNetworkHealth()
            }
        }
    }

    /// Establishes (or re-establishes) the live connection: opens the RTMP
    /// connection, then publishes under the stream key. Atomic — if `publish()`
    /// fails after a successful connect (e.g. the server still holds the previous
    /// session), it tears the connection back down so `connection.connected`
    /// returns to false and the next attempt starts clean (RTMPConnection rejects a
    /// re-connect while already connected).
    ///
    /// Reuses the SAME connection and stream across reconnects. The mixer output
    /// is detached while offline so captured buffers cannot accumulate in the
    /// network encoder, then attached again only after publish succeeds.
    ///
    /// rtmps:// -> TLS + port 443 automatically; rtmp:// -> 1935. No extra flag.
    private func connectAndPublish() async throws {
        _ = try await connection.connect(settings.rtmpURL)
        // `stop()` may have run (actor reentrancy) while we were parked in the
        // non-cancellable connect(). Its `connection.close()` is a no-op while the
        // socket is still in the `.uninitialized` handshake window, so we must tear
        // down here rather than proceed to a LIVE publish the user already ended.
        if userInitiatedStop {
            _ = try? await connection.close()
            throw CancellationError()
        }
        do {
            _ = try await stream.publish(settings.streamKey)   // stream key = publish name
        } catch {
            _ = try? await connection.close()
            throw error
        }
        // The same race can land during publish(); never leave a live stream up
        // after the user stopped.
        if userInitiatedStop {
            _ = try? await stream.close()
            _ = try? await connection.close()
            throw CancellationError()
        }
        if hasPublished {
            timeline.markDiscontinuity()
        } else {
            hasPublished = true
        }
        if !streamAttached {
            await mixer.addOutput(stream)
            streamAttached = true
        }
    }

    /// Converts a HaishinKit connect/publish failure into a useful diagnostic,
    /// surfacing the server's real RTMP reject code (e.g.
    /// `NetStream.Publish.BadName`) instead of an opaque enum error.
    private func describe(_ error: any Error) -> any Error {
        let domain = "com.joeblau.Stream.Broadcast"
        func rejected(_ what: String, _ response: RTMPResponse) -> NSError {
            let code = response.status?.code ?? "unknown"
            let reason = response.status?.description ?? ""
            streamLog.error("\(what, privacy: .public) rejected: \(code, privacy: .public) — \(reason, privacy: .public)")
            var message = "\(what) rejected by the server (\(code))."
            if !reason.isEmpty { message += " \(reason)" }
            let hint = Self.publishHint(for: code)
            if !hint.isEmpty { message += " \(hint)" }
            return NSError(domain: domain, code: 1,
                           userInfo: [NSLocalizedDescriptionKey: message])
        }
        func plain(_ code: Int, _ message: String) -> NSError {
            streamLog.error("Broadcast start failed: \(message, privacy: .public)")
            return NSError(domain: domain, code: code,
                           userInfo: [NSLocalizedDescriptionKey: message])
        }
        switch error {
        case let e as RTMPStream.Error:
            switch e {
            case .requestFailed(let response): return rejected("Publish", response)
            case .requestTimedOut: return plain(2, "The server accepted the connection but never answered the publish request. Check the stream key and your network.")
            case .invalidState: return plain(3, "The stream was in an invalid state when publishing.")
            case .unsupportedCodec: return plain(4, "The server does not support the negotiated codec.")
            @unknown default: return error
            }
        case let e as RTMPConnection.Error:
            switch e {
            case .requestFailed(let response): return rejected("Connection", response)
            case .connectionTimedOut, .requestTimedOut: return plain(5, "Could not reach the RTMP server (timed out). Check the URL and your network.")
            case .socketErrorOccurred(let underlying): return plain(6, "Network error connecting to the RTMP server. \(underlying.map { String(describing: $0) } ?? "")")
            case .unsupportedCommand(let command): return plain(7, "The server rejected an unsupported RTMP command (\(command)).")
            case .invalidState: return plain(8, "The connection was in an invalid state.")
            @unknown default: return error
            }
        default:
            return error
        }
    }

    /// Human-readable next step for the most common publish/connect reject codes.
    private static func publishHint(for code: String) -> String {
        switch code {
        case "NetStream.Publish.BadName":
            return "The stream key is invalid or already publishing — verify the key and stop any other active broadcast, then retry."
        case "NetStream.Publish.Denied":
            return "Publishing was denied — check that the stream key is authorized."
        case "NetConnection.Connect.Rejected":
            return "The server rejected the connection — check the RTMP URL, application path, and stream key."
        case "NetConnection.Connect.InvalidApp":
            return "The RTMP application path in the URL is incorrect."
        default:
            return ""
        }
    }

    private func superviseConnection(_ statuses: AsyncStream<RTMPStatus>) async {
        for await status in statuses {
            if userInitiatedStop { return }
            if await connection.connected { continue }
            streamLog.error("RTMP connection dropped (\(status.code, privacy: .public)); reconnecting")
            await requestRecovery(reason: status.code)
        }
    }

    /// A server may retire only the publishing NetStream while leaving the TCP
    /// connection alive. Those events never appear on RTMPConnection.status.
    private func superviseStream(_ statuses: AsyncStream<RTMPStatus>) async {
        // NOTE: publishIdle ("NetStream.Publish.Idle") is deliberately NOT here.
        // It's a benign, resumable "no media for a moment" notice (HaishinKit marks
        // it level "status") — it fires exactly when outbound media goes briefly
        // sparse (leaving the app to a static screen), and reconnecting can't fix
        // idleness, only sending media can. Treating it as fatal recycled a healthy
        // socket → "Connection lost… reconnecting".
        let fatalCodes: Set<String> = [
            RTMPStream.Code.publishBadName.rawValue,
            RTMPStream.Code.failed.rawValue,
            RTMPStream.Code.connectClosed.rawValue,
            RTMPStream.Code.connectFailed.rawValue,
            RTMPStream.Code.connectRejected.rawValue
        ]
        for await status in statuses {
            if userInitiatedStop { return }
            guard fatalCodes.contains(status.code) || status.level == "error" else { continue }
            streamLog.error("RTMP publisher rejected/stopped (\(status.code, privacy: .public)); recovering")
            await requestRecovery(reason: status.code)
        }
    }

    /// Coalesces connection, stream, watchdog, and path failures into one
    /// recovery loop. `immediately: true` (proactive path events) skips the
    /// first backoff sleep; every reconnect still flows through
    /// `connectAndPublish`, preserving the timeline-discontinuity rebase and
    /// HaishinKit's structural SPS/PPS + IDR re-send on publish.
    private func requestRecovery(reason: String, immediately: Bool = false) async {
        guard isRunning, !userInitiatedStop, !recoveryInProgress else { return }
        recoveryInProgress = true
        defer { recoveryInProgress = false }

        streamLog.warning("RTMP recovery requested: \(reason, privacy: .public)")
        // The fresh connection starts admitting every frame; shedding only
        // re-raises via checkNetworkHealth if congestion actually returns.
        videoAdmission.reset()
        watchdog = WatchdogState()
        if streamAttached {
            await mixer.removeOutput(stream)
            streamAttached = false
        }
        _ = try? await stream.close()
        _ = try? await connection.close()
        await reconnect(immediately: immediately)
    }

    /// Jittered exponential backoff is retained across short-lived successful
    /// connections. It resets only after 30 seconds of stable publishing, or
    /// when a fresh network route appears. While iOS reports no satisfied path
    /// the loop parks at zero cost instead of burning backoff doublings (each
    /// dead attempt would also eat RTMPSocket's hardcoded 15 s connect timeout).
    private func reconnect(immediately: Bool) async {
        var attempt = 0
        var shouldDelay = !immediately
        while isRunning, !userInitiatedStop {
            let waited = await waitUntilPathUsable()
            guard isRunning, !userInitiatedStop else { return }
            if waited {
                // A fresh route just appeared — probe it immediately with a
                // reset budget; a flapping path costs at most one fast attempt
                // per transition (RTMPSocket fast-fails on .waiting).
                shouldDelay = false
                backoff.reset()
            }
            if shouldDelay {
                await interruptibleBackoffSleep()
                guard isRunning, !userInitiatedStop else { return }
                // A path event may have ended the sleep early; if the route is
                // gone, park at the gate instead of burning a doomed attempt.
                if let path = currentPath, !path.isSatisfied { continue }
            }
            shouldDelay = true
            attempt += 1
            do {
                try await connectAndPublish()
                // A reconnect that SUCCEEDS costs ~1s next time; backoff grows only
                // across consecutive FAILED attempts (catch branch). Escalating on
                // success turned a burst of (individually recoverable) false recycles
                // into progressively longer 2→4→8→…→30s dead-air windows.
                backoff.reset()
                streamLog.info("RTMP reconnected after \(attempt) attempt(s)")
                stableConnectionTask?.cancel()
                stableConnectionTask = Task { [weak self] in
                    do {
                        try await Task.sleep(nanoseconds: 30_000_000_000)
                    } catch {
                        return
                    }
                    await self?.markConnectionStable()
                }
                return
            } catch {
                if userInitiatedStop || !isRunning { return }
                // A failed RTMP command can leave the TCP socket open even though
                // `connected` is false. Always clear both layers before retrying.
                _ = try? await stream.close()
                _ = try? await connection.close()
                let described = describe(error)
                streamLog.error("RTMP reconnect attempt \(attempt) failed: \(described.localizedDescription, privacy: .public)")
                backoff.escalate()
            }
        }
    }

    /// Sleeps the current backoff with jitter. A path event (or stop) cancels
    /// `backoffSleepTask` to end the wait early; early wake is progress, not error.
    private func interruptibleBackoffSleep() async {
        let nanoseconds = backoff.jittered()
        let sleeper = Task { try await Task.sleep(nanoseconds: nanoseconds) }
        backoffSleepTask = sleeper
        defer { backoffSleepTask = nil }
        _ = try? await sleeper.value
    }

    /// Parks while iOS reports no satisfied path. Returns true when it actually
    /// waited (a route transition happened while parked). Passes straight
    /// through when the path is satisfied or the monitor has not reported yet,
    /// so the first connect is never blocked on monitor startup.
    private func waitUntilPathUsable() async -> Bool {
        var waited = false
        while isRunning, !userInitiatedStop,
              let path = currentPath, !path.isSatisfied {
            waited = true
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                pathWaiters.append(continuation)
            }
        }
        return waited
    }

    /// Reacts to every NWPathMonitor emission. Supervisor discipline: this never
    /// touches the single-continuation status streams; all recovery funnels
    /// through the existing requestRecovery/reconnect machinery, so proactive
    /// recycles inherit the timeline rebase and keyframe re-send for free.
    private func handlePathUpdate(_ snapshot: NetworkPathSnapshot) async {
        guard isRunning, !userInitiatedStop else { return }
        let previous = currentPath
        currentPath = snapshot
        // Any parked reconnect loop re-checks its gate on every update.
        defer { resumePathWaiters() }

        // Ceiling first: cheap, idempotent, applied immediately (not at the
        // next 1 Hz strategy event). The baseline flag keeps the very first
        // emission from reseeding the ABR's full-rate starting target.
        // Only touch the encoder when the path actually changed (or first emission).
        // NWPathMonitor re-emits equal paths on DNS/VPN/agent churn; an unconditional
        // setVideoSettings round-trip here contends the same actor executor that
        // serializes every appended frame.
        if previous == nil || snapshot != previous {
            await networkController.setPathProfile(
                ceiling: snapshot.videoBitRateCeiling(configuredMaximum: settings.videoBitrate),
                seed: snapshot.videoBitRateSeed(configuredMaximum: settings.videoBitrate),
                interface: snapshot.interface,
                isBaseline: previous == nil,
                applyingTo: stream)
        }

        guard let previous, snapshot != previous else { return }  // baseline / no-op
        let now = DispatchTime.now().uptimeNanoseconds
        // Only a reachability or interface change should tighten the watchdog's
        // stall tolerance (recentPathChange halves the queue budget). isExpensive/
        // isConstrained/linkQuality flips are benign metadata — radios waking as
        // other apps run — and must NOT halve the budget, or ordinary app-switch
        // uplink contention trips a false recycle.
        if snapshot.isSatisfied != previous.isSatisfied || snapshot.linkIdentity != previous.linkIdentity {
            lastPathChangeAt = now
        }
        handoffDebounceTask?.cancel()
        pathLossDebounceTask?.cancel()
        streamLog.info("Network path: \(previous.linkIdentity, privacy: .public) -> \(snapshot.linkIdentity, privacy: .public), satisfied=\(snapshot.isSatisfied), expensive=\(snapshot.isExpensive), constrained=\(snapshot.isConstrained)")

        if !snapshot.isSatisfied {
            // PATH LOST. Debounce briefly — AP roams and VPN/agent churn pass
            // through unsatisfied for well under a second and must not disturb
            // a TCP flow that survives them.
            lastPathLostAt = now
            pathLossDebounceTask = Task { [weak self] in
                // 1.5s: ordinary app-switch / AP-roam / VPN-agent flaps pass through
                // unsatisfied for well under a second and must not detach a TCP flow
                // that survives them.
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled else { return }
                await self?.confirmPathLost()
            }
            return
        }

        if !previous.isSatisfied {
            // PATH RESTORED. A parked/sleeping reconnect loop only needs waking
            // (the defer above resumes gate waiters); a loop mid-connect on the
            // dead route needs its socket fast-failed so it retries on the new
            // path now instead of after the 15 s hardcoded connect timeout.
            wakeBackoff(resetDelay: true)
            if recoveryInProgress {
                _ = try? await connection.close()
            } else if !isPaused {
                let connected = await connection.connected
                // Recycle only if the flow is actually gone. If the socket is still
                // connected AND the output is still attached, the TCP flow rode
                // through the blip — do NOT tear down a healthy connection (the
                // supervisors + watchdog own any latent failure). Detaching only
                // happens after the 1.5s confirmPathLost debounce, so a survived
                // blip keeps streamAttached==true here.
                if !streamAttached || !connected {
                    await requestRecovery(reason: "network path restored (\(snapshot.linkIdentity))",
                                          immediately: true)
                }
            }
            return
        }

        if snapshot.linkIdentity != previous.linkIdentity {
            // LIVE HANDOFF (Wi-Fi <-> 5G) while both old and new report
            // satisfied: the TCP flow is bound to the old interface and is dead
            // or dying. Debounce 500 ms so a Wi-Fi-edge flap can't tear down a
            // healthy connection twice; genuine handoffs still beat the 1-10 s
            // reactive detection by an order of magnitude.
            let identity = snapshot.linkIdentity
            handoffDebounceTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return }
                await self?.recycleForHandoff(expectedIdentity: identity)
            }
        }
        // Same link with only isExpensive/isConstrained/linkQuality flips:
        // ceiling already updated above — never reconnect for that.
    }

    /// The path stayed unsatisfied through the debounce: pause sending cleanly.
    /// Detaching the mixer output keeps encoded frames from piling into
    /// RTMPSocket's unbounded Data queue while the socket dies; the reconnect
    /// loop parks in waitUntilPathUsable() until a route returns.
    private func confirmPathLost() async {
        guard isRunning, !userInitiatedStop,
              currentPath?.isSatisfied == false else { return }
        streamLog.warning("Network path lost; pausing outbound media until a route returns")
        if streamAttached {
            await mixer.removeOutput(stream)
            streamAttached = false
        }
        // Wake a sleeping backoff so the loop parks at the path gate (the
        // post-sleep gate re-check keeps it from burning a doomed attempt).
        wakeBackoff(resetDelay: false)
    }

    /// Wi-Fi <-> 5G handoff confirmed by the debounce: recycle onto the new
    /// interface. Single-flight: while a reconnect loop is live it is steered
    /// (socket fast-failed, backoff woken) rather than raced with a second
    /// loop on the same RTMPConnection.
    private func recycleForHandoff(expectedIdentity: String) async {
        guard isRunning, !userInitiatedStop, !isPaused,
              currentPath?.isSatisfied == true,
              currentPath?.linkIdentity == expectedIdentity else { return }
        wakeBackoff(resetDelay: true)
        if recoveryInProgress {
            _ = try? await connection.close()
            return
        }
        await requestRecovery(reason: "network path changed (\(expectedIdentity))",
                              immediately: true)
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

    /// HaishinKit exposes queue telemetry only through StreamBitRateStrategy. A
    /// growing/zero-progress queue is our post-connect liveness signal; recycling
    /// the socket is the only public way to purge its unbounded Data queue.
    private func checkNetworkHealth() async {
        guard isRunning, !userInitiatedStop, !recoveryInProgress else { return }
        guard await connection.connected else {
            streamLog.error("RTMP watchdog found a disconnected socket; recovering")
            await requestRecovery(reason: "connection state is disconnected")
            return
        }
        guard await stream.readyState == .publishing else {
            streamLog.error("RTMP watchdog found a non-publishing stream; recovering")
            await requestRecovery(reason: "publisher state is not publishing")
            return
        }
        // No queue-health conclusion can be drawn while capture is paused or
        // the device is showing static content and no recent samples arrived.
        // Reset the stall streak too — a gap in these ticks is not a stall.
        guard !isPaused else { watchdog.stalledTicks = 0; return }
        let now = DispatchTime.now().uptimeNanoseconds
        guard now &- lastMediaAt < 10_000_000_000 else { watchdog.stalledTicks = 0; return }
        // Mic-stall fallback (control plane only): HaishinKit's multitrack mixer
        // renders the mix only when the MAIN track appends, so a dead mic route
        // would silence app audio too. If app audio is flowing but the mic went
        // quiet, promote track 1 to the mix clock; the first mic buffer back
        // flips it home (see appendMic). No timeline rebase on either side —
        // video/app kept flowing, so mic samples re-enter already aligned.
        if settings.includeAppAudio, !micTrackStalled, startedAt > 0,
           MicStallEvaluator.shouldPromoteApp(now: now,
                                              lastMicAppendAt: lastMicAppendAt,
                                              lastAppAppendAt: lastAppAppendAt,
                                              startedAt: startedAt) {
            micTrackStalled = true
            await applyAudioMixerSettings()
            streamLog.warning("Mic buffers stalled >4s; app audio is now the mix clock")
        }
        let health = await networkController.healthSnapshot()
        videoAdmission.setQueueDepth(health.queueBytes)
        // The stall math — strictly-GROWING queue (not merely frozen, which happens
        // when a backgrounded app starves the ~1Hz telemetry), independent zero-output
        // stall, N-tick persistence, and the halved tolerance for 10s after a path
        // change — lives in the shared, unit-tested WatchdogEvaluator. eventAgeSeconds
        // is deliberately NOT an input (it freezes on backgrounding); the
        // connected/readyState guards above already catch a genuinely dead socket.
        let recentPathChange = lastPathChangeAt > 0
            && now &- lastPathChangeAt < PathDebounce.recentPathChangeWindow
        let decision = WatchdogEvaluator.evaluate(queueBytes: health.queueBytes,
                                                  zeroOutputSeconds: health.zeroOutputSeconds,
                                                  recentPathChange: recentPathChange,
                                                  state: &watchdog)
        if decision.shouldRecycle {
            streamLog.error("RTMP socket stalled \(decision.stalledTicks) ticks: queue=\(health.queueBytes) bytes, zeroOut=\(health.zeroOutputSeconds)s, target=\(health.targetBitRate) bps")
            await requestRecovery(reason: "outbound queue stalled")
        }
    }

    func pause() async {
        guard isRunning, !isPaused, !userInitiatedStop else { return }
        isPaused = true
        await networkController.setCapturePaused(true)
        timeline.markDiscontinuity()
    }

    func resume() async {
        guard isRunning, isPaused, !userInitiatedStop else { return }
        isPaused = false
        await networkController.setCapturePaused(false)
        timeline.markDiscontinuity()
        let isConnected = await connection.connected
        let publishState = await stream.readyState
        // `!streamAttached` covers a path loss during the pause that detached
        // the mixer output while the TCP session itself survived.
        if !isConnected || publishState != .publishing || !streamAttached {
            await requestRecovery(reason: "Capture resumed without an active publisher")
        }
    }

    /// Locks the encoder to a concrete output size (derived from the first screen
    /// frame's real aspect ratio). `.letterbox` scaling guarantees the source is
    /// fit without distortion even if a later frame's aspect differs slightly.
    /// Idempotent — only the first call takes effect.
    func setOutputSize(_ size: CGSize, nativeShortEdge _: Int) async {
        guard !outputSizeConfigured else { return }
        let frameRate = encodeFrameRate
        var v = await stream.videoSettings
        v.videoSize = size
        v.scalingMode = .letterbox
        // Seed the encoder at the ABR's current (possibly path-clamped) target
        // so a size lock landing after a path change cannot overwrite the
        // learned rate until the next 1 Hz strategy event.
        v.bitRate = min(settings.videoBitrate, await networkController.currentTargetBitRate())
        v.expectedFrameRate = Double(frameRate)
        v.frameInterval = max(0, (1.0 / Double(frameRate)) - 0.001)
        v.maxKeyFrameIntervalDuration = 2
        // VBR (.average), not CBR: a mostly-static screen compresses to near-
        // nothing instead of being padded to the full target, and mid-session
        // AverageBitRate changes are reliably applied so the ABR actually takes
        // effect. HaishinKit auto-derives a ~1.5x burst cap (dataRateLimits).
        v.bitRateMode = .average
        // HEVC (enhanced-RTMP) when the user opted in, else H.264 Main. The
        // profileLevel string also flips the encoder's codec — VideoCodecSettings
        // switches to HEVC on the "HEVC" substring — which drives the hvc1 RTMP
        // packet framing. makeConnection negotiated the matching E-RTMP payload.
        v.profileLevel = settings.videoCodec.videoToolboxProfileLevel
        // Low-latency VideoToolbox rate control: tightens encoder queuing latency
        // (makeEncoderSpecification enables EnableLowLatencyRateControl).
        v.isLowLatencyRateControlEnabled = true
        v.allowFrameReordering = false
        do {
            try await stream.setVideoSettings(v)
            outputSizeConfigured = true
        } catch {
            streamLog.error("Video encoder configuration failed: \(String(describing: error), privacy: .public)")
        }
    }

    func setThermalCeiling(bitRateScale: Double, frameRateCap: Int) async {
        await networkController.setThermalCeiling(bitRateScale: bitRateScale,
                                                  frameRateCap: frameRateCap,
                                                  applyingTo: stream)
    }

    /// Live encode/uplink metrics for the stats HUD. `nil` until the stream is
    /// actually attached and has published, so the UI shows "connecting…" rather
    /// than stale zeros during the initial connect/reconnect windows.
    func statsSnapshot() async -> LiveStats? {
        guard isRunning, streamAttached else { return nil }
        let health = await networkController.healthSnapshot()
        let fps = await networkController.currentFrameRate()
        return LiveStats(bitRate: health.targetBitRate,
                         frameRate: fps,
                         queueBytes: health.queueBytes,
                         zeroOutputSeconds: health.zeroOutputSeconds)
    }

    /// Appends a (raw or composited) screen video buffer. Dropped until the output
    /// size is locked, so the encoder never starts at the wrong dimensions.
    func appendVideo(_ sb: CMSampleBuffer) async {
        guard outputSizeConfigured, isRunning, !isPaused, streamAttached else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        lastMediaAt = now
        lastVideoAppendAt = now
        lastVideoBuffer = sb
        // Under outbound congestion, drop a proportion of video frames (audio is
        // never dropped) so latency stays bounded instead of the queue growing.
        guard videoAdmission.admit() else {
            telemetry.recordDrop(.admission)
            return
        }
        let duration = CMTime(value: 1,
                              timescale: CMTimeScale(encodeFrameRate))
        let normalized = timeline.normalize(sb, kind: .video, fallbackDuration: duration)
        telemetry.recordEncoded()
        await mixer.append(enforceMonotonicVideo(normalized, minStep: duration))
    }

    /// Frame-repeat dupes are stamped at host-`now`, but a real capture frame
    /// carries its slightly-earlier capture PTS — so a real frame arriving just
    /// after a repeat would move the video timeline BACKWARDS, which some RTMP
    /// muxers/ingests reject (a wrapped ~49-day timestamp jump) and drop the
    /// publisher. Nudge any non-monotonic frame forward by one interval.
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

    /// Appends microphone audio on track 0.
    func appendMic(_ sb: CMSampleBuffer) async {
        guard isRunning, !isPaused, streamAttached else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        lastMediaAt = now
        lastMicAppendAt = now
        if micTrackStalled {
            // The mic route came back: hand the mix clock straight back to it.
            // Mic samples share the capture host clock with the still-continuous
            // video/app timeline, so no discontinuity rebase is needed (or safe).
            micTrackStalled = false
            await applyAudioMixerSettings()
            streamLog.info("Mic buffers resumed; mic is the mix clock again")
        }
        let normalized = timeline.normalize(sb, kind: .mic,
                                             fallbackDuration: CMTime(value: 1_024, timescale: 48_000))
        await mixer.append(normalized, track: 0)
    }

    /// Appends app/system audio on track 1.
    func appendApp(_ sb: CMSampleBuffer) async {
        guard isRunning, !isPaused, streamAttached else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        lastMediaAt = now
        lastAppAppendAt = now
        let normalized = timeline.normalize(sb, kind: .app,
                                             fallbackDuration: CMTime(value: 1_024, timescale: 48_000))
        await mixer.append(normalized, track: 1)
    }

    /// Configures the multitrack audio mixer: mic on track 0 (its user level
    /// applied as a linear gain, clamped to a safe range), app audio on track 1.
    /// Mic is the main track, so it also drives the mix clock.
    private func applyAudioMixerSettings() async {
        let gain = Float(max(0.0, min(settings.micVolume, 2.0)))
        // While the mic route is stalled, app audio (track 1) drives the mix
        // clock so the whole mix does not fall silent with it. Threaded through
        // here so a mid-fallback setMicVolume cannot silently revert the clock.
        await mixer.setAudioMixerSettings(AudioMixerSettings(
            sampleRate: 48_000,
            // Mono mic-only → 1 channel (halves AAC payload); stereo only when app
            // audio (track 1) is actually mixed in.
            channels: settings.includeAppAudio ? 2 : 1,
            mainTrack: micTrackStalled ? 1 : 0,
            tracks: [0: AudioMixerTrackSettings(volume: gain),
                     1: .default]
        ))
    }

    /// Updates the mic level, live — the app's Mic Volume slider reaches this via
    /// the broadcast control channel while streaming. Only re-applies the mixer's
    /// track volume, so it is smooth and safe to call repeatedly.
    func setMicVolume(_ volume: Double) async {
        settings.micVolume = volume
        await applyAudioMixerSettings()
    }

    /// Tears down every long-lived task and the media/network pipeline.
    func stop() async {
        userInitiatedStop = true
        isPaused = false
        micCont.finish()
        appCont.finish()
        audioConsumers.forEach { $0.cancel() }
        audioConsumers = []
        frameRepeatTask?.cancel()
        frameRepeatTask = nil
        lastVideoBuffer = nil
        connectionSupervisorTask?.cancel()
        connectionSupervisorTask = nil
        streamSupervisorTask?.cancel()
        streamSupervisorTask = nil
        watchdogTask?.cancel()
        watchdogTask = nil
        stableConnectionTask?.cancel()
        stableConnectionTask = nil
        pathSupervisorTask?.cancel()
        pathSupervisorTask = nil
        handoffDebounceTask?.cancel()
        handoffDebounceTask = nil
        pathLossDebounceTask?.cancel()
        pathLossDebounceTask = nil
        // The reconnect loop's backoff sleep and path parking are unstructured;
        // wake both explicitly so the loop observes userInitiatedStop and exits.
        backoffSleepTask?.cancel()
        resumePathWaiters()

        guard isRunning else {
            await mixer.stopRunning()
            return
        }
        isRunning = false
        if streamAttached {
            await mixer.removeOutput(stream)
            streamAttached = false
        }
        _ = try? await stream.close()
        _ = try? await connection.close()
        await mixer.stopRunning()
    }
}

extension VideoCodec {
    /// The VideoToolbox profile-level string for this codec, shared by both
    /// publishers. Assigning it to `VideoCodecSettings.profileLevel` also flips the
    /// encoder's internal `format` to HEVC (its `didSet` keys off the "HEVC"
    /// substring), so the encoded bitstream, the RTMP `hvc1` exHeader framing, and
    /// the transport payload all follow from this one property.
    var videoToolboxProfileLevel: String {
        switch self {
        case .h264: return kVTProfileLevel_H264_Main_AutoLevel as String
        case .hevc: return kVTProfileLevel_HEVC_Main_AutoLevel as String
        }
    }
}

/// Re-timestamps a video sample buffer to an explicit PTS.
func restampVideoBuffer(_ sb: CMSampleBuffer, pts: CMTime) -> CMSampleBuffer? {
    var timing = CMSampleTimingInfo(duration: .invalid,
                                    presentationTimeStamp: pts,
                                    decodeTimeStamp: .invalid)
    var out: CMSampleBuffer?
    guard CMSampleBufferCreateCopyWithNewTiming(
        allocator: kCFAllocatorDefault,
        sampleBuffer: sb,
        sampleTimingEntryCount: 1,
        sampleTimingArray: &timing,
        sampleBufferOut: &out) == noErr else { return nil }
    return out
}

/// Re-timestamps a video sample buffer to the current host time (frame-repeat).
func duplicateVideoBufferWithCurrentTiming(_ sb: CMSampleBuffer) -> CMSampleBuffer? {
    restampVideoBuffer(sb, pts: CMClockGetTime(CMClockGetHostTimeClock()))
}

struct BroadcastNetworkHealth: Sendable {
    let queueBytes: Int
    let zeroOutputSeconds: Int
    let eventAgeSeconds: Int
    let targetBitRate: Int
}

/// HaishinKit 2.2.5's built-in adaptive controller calculates a normal
/// congestion reduction but does not apply it. This implementation applies every
/// reduction immediately and exposes the socket telemetry needed by the watchdog.
actor BroadcastAdaptiveBitRateController: StreamBitRateStrategy {
    // `StreamBitRateStrategy` requires a synchronous get-only `mamimumVideoBitRate`,
    // which on an actor must stay a nonisolated `let` (sic misspelling is HaishinKit's).
    let mamimumVideoBitRate: Int
    let mamimumAudioBitRate = 0

    /// All the numeric decision math now lives in the pure, unit-tested StreamCore
    /// `AdaptiveBitRateState` (issue #21); this actor is a thin wrapper that reads/
    /// writes HaishinKit's encoder around it.
    private var abr: AdaptiveBitRateState
    private var lastEventAt = DispatchTime.now().uptimeNanoseconds   // telemetry only

    init(maximumBitRate: Int, frameRate: Int) {
        mamimumVideoBitRate = maximumBitRate
        abr = AdaptiveBitRateState(maximumBitRate: maximumBitRate, frameRate: frameRate)
    }

    func adjustBitrate(_ event: NetworkMonitorEvent,
                       stream: some StreamConvertible) async {
        lastEventAt = DispatchTime.now().uptimeNanoseconds
        switch event {
        case .reset:
            let decision = abr.onReset()
            if decision.shouldApply { await applyDecision(decision, to: stream) }

        case .publishInsufficientBWOccured(let report):
            // Read the LIVE audio bitrate only when not paused — the original
            // returned before touching stream.audioSettings on the paused path, so
            // this adds no `await` it lacked.
            let audioBitRate = abr.capturePaused ? 0 : await stream.audioSettings.bitRate
            let decision = abr.onInsufficientBandwidth(
                bytesOutPerSecond: report.currentBytesOutPerSecond,
                queueBytesOut: report.currentQueueBytesOut,
                audioBitRate: audioBitRate)
            if decision.shouldApply {
                await applyDecision(decision, to: stream)
                streamLog.warning("ABR reduced video to \(self.abr.targetBitRate) bps; queue=\(self.abr.queueBytes) bytes")
            }

        case .status(let report):
            // Pass live audio bitrate so the upward-probe's throughput gate compares
            // video-vs-video (the estimate carries total socket egress). Paused → 0,
            // mirroring the insufficient-bandwidth path's guard.
            let audioBitRate = abr.capturePaused ? 0 : await stream.audioSettings.bitRate
            let decision = abr.onStatus(bytesOutPerSecond: report.currentBytesOutPerSecond,
                                        queueBytesOut: report.currentQueueBytesOut,
                                        audioBitRate: audioBitRate)
            if decision.shouldApply {
                await applyDecision(decision, to: stream)
                // Match the original: only the upward-PROBE apply logs "recovered".
                // The severe stall-halving apply (decision.severe) logged nothing —
                // logging "recovered" there would misread as recovery during a cut.
                if !decision.severe {
                    streamLog.info("ABR recovered video to \(self.abr.targetBitRate) bps")
                }
            }
        }
    }

    /// Applies the pure decision's target bitrate + frame interval to the encoder.
    /// `abr.frameInterval` uses constants bit-identical to VideoCodecSettings's, so
    /// the encoder value is byte-identical to the pre-extraction controller.
    private func applyDecision(_ decision: ABRDecision, to stream: some StreamConvertible) async {
        var video = await stream.videoSettings
        video.bitRate = abr.targetBitRate
        video.frameInterval = abr.frameInterval(severe: decision.severe)
        try? await stream.setVideoSettings(video)
    }

    func setCapturePaused(_ paused: Bool) { abr.onCapturePaused(paused) }

    /// Called from RTMPPublisher.handlePathUpdate on every path emission.
    /// Remembers the last achieved target per interface so Wi-Fi -> 5G does not
    /// inherit Wi-Fi's degraded learned rate (which `.reset` deliberately
    /// keeps), and 5G -> Wi-Fi does not re-climb 30 s per probe step from a low
    /// seed. The baseline (first) emission only adopts the interface and the
    /// ceiling, so a broadcast still STARTS at the configured full bitrate.
    func setPathProfile(ceiling: Int,
                        seed: Int,
                        interface: NetworkPathSnapshot.Interface,
                        isBaseline: Bool,
                        applyingTo stream: some StreamConvertible) async {
        let decision = abr.onPathProfile(ceiling: ceiling, seed: seed,
                                         interface: interface, isBaseline: isBaseline)
        if decision.shouldApply { await applyDecision(decision, to: stream) }
    }

    func currentTargetBitRate() -> Int { abr.targetBitRate }

    /// Stores a thermal/Low-Power ceiling and clamps the current target to it.
    /// Used when there is no stream to apply to yet (pre-connect); the value then
    /// takes effect on the first adaptive event after connect.
    func storeThermalCeiling(bitRateScale: Double, frameRateCap: Int) {
        abr.onThermalCeiling(bitRateScale: bitRateScale, frameRateCap: frameRateCap)
    }

    func currentFrameInterval() -> Double { abr.frameInterval(severe: false) }

    func currentFrameRate() -> Int { abr.currentFrameRate() }

    /// Applies the current (possibly thermally-clamped) target + frame interval to
    /// a freshly-connected stream. SRT/WHIP emit no `.reset` event, so the
    /// pre-connect store path relies on this to land the ceiling on the encoder.
    func applyCurrentTarget(to stream: any StreamConvertible) async {
        var video = await stream.videoSettings
        video.bitRate = abr.targetBitRate
        video.frameInterval = abr.frameInterval(severe: false)
        try? await stream.setVideoSettings(video)
    }

    /// Applies a thermal/Low-Power ceiling to the encoder immediately, instead of
    /// waiting for the next ~1 Hz adaptive event. Takes `any StreamConvertible` so
    /// both the concrete RTMPStream and SessionPublisher's existential stream can
    /// drive it.
    func setThermalCeiling(bitRateScale: Double,
                           frameRateCap: Int,
                           applyingTo stream: any StreamConvertible) async {
        abr.onThermalCeiling(bitRateScale: bitRateScale, frameRateCap: frameRateCap)
        var video = await stream.videoSettings
        video.bitRate = abr.targetBitRate
        video.frameInterval = abr.frameInterval(severe: false)
        try? await stream.setVideoSettings(video)
    }

    func healthSnapshot() -> BroadcastNetworkHealth {
        let now = DispatchTime.now().uptimeNanoseconds
        return BroadcastNetworkHealth(
            queueBytes: abr.queueBytes,
            zeroOutputSeconds: abr.zeroOutputSeconds,
            eventAgeSeconds: Int((now &- lastEventAt) / 1_000_000_000),
            targetBitRate: abr.targetBitRate
        )
    }
}
