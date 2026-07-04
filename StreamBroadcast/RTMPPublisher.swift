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
    /// Use the conservative RTMP connect payload understood by traditional
    /// ingests such as Restream. The enhanced-codec fields are unnecessary for
    /// this H.264/AAC publisher and some RTMP frontends reject them.
    private let connection = RTMPConnection(fourCcList: nil,
                                            videoFourCcInfoMap: nil,
                                            audioFourCcInfoMap: nil,
                                            capsEx: 0,
                                            requestTimeout: 5_000,
                                            qualityOfService: .userInteractive)
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
    private var nextRecoveryDelay: UInt64 = 1_000_000_000
    private var lastMediaAt = DispatchTime.now().uptimeNanoseconds
    private var timeline = MediaTimelineNormalizer()
    private var hasPublished = false
    /// Sheds input video frames when the outbound queue is deep, to bound latency
    /// (HaishinKit's send queue is otherwise unbounded). Refreshed by checkNetworkHealth.
    private let videoAdmission = VideoFrameAdmission()

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
    private var lastQueueBytes: Int = 0                    // watchdog: detect a draining queue
    private var stalledTicks: Int = 0                      // watchdog: consecutive stalled checks

    init() {
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

        if settings.backupEnabled {
            streamLog.warning("Local backup disabled: a second real-time video encoder is not enabled")
        }

        // A broadcast is user-owned, not network-owned. Initial DNS, TLS, RTMP,
        // and publish failures therefore retry just like a mid-stream drop instead
        // of ending the user-owned capture session.
        isRunning = true
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
        lastQueueBytes = 0
        stalledTicks = 0
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
        let maxDelay: UInt64 = 30_000_000_000
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
                nextRecoveryDelay = 1_000_000_000
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
                nextRecoveryDelay = 1_000_000_000
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
                nextRecoveryDelay = min(nextRecoveryDelay * 2, maxDelay)
            }
        }
    }

    /// Sleeps the current backoff with jitter. A path event (or stop) cancels
    /// `backoffSleepTask` to end the wait early; early wake is progress, not error.
    private func interruptibleBackoffSleep() async {
        let jitter = Double.random(in: 0.8...1.2)
        let nanoseconds = UInt64(Double(nextRecoveryDelay) * jitter)
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
        if resetDelay { nextRecoveryDelay = 1_000_000_000 }
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
        nextRecoveryDelay = 1_000_000_000
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
        guard !isPaused else { stalledTicks = 0; return }
        let now = DispatchTime.now().uptimeNanoseconds
        guard now &- lastMediaAt < 10_000_000_000 else { stalledTicks = 0; return }
        // Mic-stall fallback (control plane only): HaishinKit's multitrack mixer
        // renders the mix only when the MAIN track appends, so a dead mic route
        // would silence app audio too. If app audio is flowing but the mic went
        // quiet, promote track 1 to the mix clock; the first mic buffer back
        // flips it home (see appendMic). No timeline rebase on either side —
        // video/app kept flowing, so mic samples re-enter already aligned.
        if settings.includeAppAudio, !micTrackStalled,
           lastMicAppendAt > 0,
           now &- lastAppAppendAt < 2_000_000_000,
           now &- lastMicAppendAt > 4_000_000_000 {
            micTrackStalled = true
            await applyAudioMixerSettings()
            streamLog.warning("Mic buffers stalled >4s; app audio is now the mix clock")
        }
        let health = await networkController.healthSnapshot()
        videoAdmission.setQueueDepth(health.queueBytes)
        // A growing queue by itself means congestion, not a dead connection. The
        // adaptive controller needs time to lower the encoder rate and drain it.
        // Reconnect only when progress has stopped, telemetry has stopped, or the
        // backlog is large enough that viewers would receive several stale seconds.
        // For 10 s after a network path change the tolerance halves: the old flow
        // is known-suspect, so a genuine stall should recycle fast.
        let recentPathChange = lastPathChangeAt > 0 && now &- lastPathChangeAt < 10_000_000_000
        let queueLimit = recentPathChange ? 2_000_000 : 4_000_000
        let zeroLimit = recentPathChange ? 2 : 4
        // A deep queue is only a recycle reason if it is NOT draining — a transient
        // backlog that is already shrinking clears on its own once the ABR lowers
        // the encoder rate. zeroOutputSeconds independently catches a truly stalled
        // (bytesOut==0) queue.
        //
        // Require the backlog to be strictly GROWING (`>`), not merely frozen (`>=`):
        // when the container app is backgrounded the OS starves the ~1Hz ABR timer
        // that feeds queueBytes/zeroOutputSeconds, so those figures FREEZE at their
        // last value. A frozen-equal queue (`>=`) read that as a permanent stall and
        // recycled a socket the fork deliberately keeps open across `.waiting`. Only
        // a queue that keeps climbing is genuinely wedged.
        let queueStuck = health.queueBytes >= queueLimit && health.queueBytes > lastQueueBytes
        lastQueueBytes = health.queueBytes
        // eventAgeSeconds is intentionally NOT a recycle condition. It is the age of
        // HaishinKit's ~1Hz ABR callback (a wall-clock timer, default QoS), which the
        // OS starves when the container app is backgrounded behind another app — it
        // is NOT a probe of the socket. The connection.connected + readyState guards
        // above already detect a genuinely dead socket, and queue/zeroOutput cover
        // real stalls. Recycling on it tore down healthy connections on every
        // app-switch — the primary cause of the "Connection lost" dropouts.
        //
        // Even a real stall must PERSIST before we recycle: an app-switch drives the
        // socket into a transient `.waiting` that the RTMPSocket fork keeps open and
        // that recovers on the SAME session (no reconnect) once a usable path returns
        // — often the instant the app is foregrounded. Tearing it down after a single
        // 2 s tick converted that survivable blip into a hard, destination-visible
        // RTMP disconnect. Require several consecutive stalled ticks (~12 s, or ~6 s
        // right after a path change when the flow is already suspect) so the socket
        // layer's keep-open policy is honoured instead of fought.
        if queueStuck || health.zeroOutputSeconds >= zeroLimit {
            stalledTicks += 1
        } else {
            stalledTicks = 0
        }
        let ticksToRecycle = recentPathChange ? 3 : 6
        if stalledTicks >= ticksToRecycle {
            let ticks = stalledTicks
            streamLog.error("RTMP socket stalled \(ticks) ticks: queue=\(health.queueBytes) bytes, zeroOut=\(health.zeroOutputSeconds)s, target=\(health.targetBitRate) bps")
            stalledTicks = 0
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
        v.profileLevel = kVTProfileLevel_H264_Main_AutoLevel as String
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
        guard videoAdmission.admit() else { return }
        let duration = CMTime(value: 1,
                              timescale: CMTimeScale(encodeFrameRate))
        let normalized = timeline.normalize(sb, kind: .video, fallbackDuration: duration)
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

/// Bounded video-frame admission under outbound congestion. HaishinKit's RTMP
/// send queue is unbounded, so when the uplink can't drain it, SHEDDING input
/// video frames (proportional to how deep the queue is) keeps glass-to-glass
/// latency bounded instead of letting it grow to seconds and then hard-recycling.
/// Audio is never dropped. The depth is refreshed ~every 2s from the real socket
/// queue by checkNetworkHealth; this is the fast, coarse bound that complements
/// the encoder-level bitrate/frame-rate reductions the ABR already applies.
final class VideoFrameAdmission: @unchecked Sendable {
    private struct State { var keep = 1; var period = 1; var counter = 0 }
    private let lock = OSAllocatedUnfairLock<State>(initialState: State())

    /// Maps outbound queue depth to a keep/period frame-pacing ratio.
    func setQueueDepth(_ bytes: Int) {
        let keep: Int, period: Int
        switch bytes {
        case ..<524_288:   (keep, period) = (1, 1)  // < 0.5 MB: keep every frame
        case ..<1_048_576: (keep, period) = (2, 3)  // 0.5-1 MB: drop 1 in 3
        case ..<2_097_152: (keep, period) = (1, 2)  // 1-2 MB: drop 1 in 2
        default:           (keep, period) = (1, 3)  // > 2 MB: drop 2 in 3
        }
        lock.withLock { state in
            if state.period != period { state.counter = 0 }
            state.keep = keep
            state.period = period
        }
    }

    /// True when this video frame should be encoded and sent.
    func admit() -> Bool {
        lock.withLock { state in
            guard state.period > 1 else { return true }
            let keep = state.counter % state.period < state.keep
            state.counter &+= 1
            return keep
        }
    }

    func reset() {
        lock.withLock { $0 = State() }
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
    let mamimumVideoBitRate: Int
    let mamimumAudioBitRate = 0

    private let minimumVideoBitRate: Int
    private let configuredFrameRate: Int
    private let preferredFrameInterval: Double
    private var targetBitRate: Int
    private var healthySeconds = 0
    private var zeroOutputSeconds = 0
    private var queueBytes = 0
    private var congestionActive = false
    private var capturePaused = false
    private var lastEventAt = DispatchTime.now().uptimeNanoseconds

    /// Per-network-path ceiling and seeding. The protocol requires a
    /// synchronous get-only `mamimumVideoBitRate`, which on an actor must stay
    /// a nonisolated `let`; the dynamic per-path ceiling therefore lives here.
    private var pathCeiling: Int
    private var currentInterface: NetworkPathSnapshot.Interface?
    private var lastGoodTarget: [NetworkPathSnapshot.Interface: Int] = [:]

    /// Thermal / Low-Power ceiling from `ThermalPowerGovernor`, composed with the
    /// network path ceiling. `min()`'d into `effectiveMaximum` so the upward probe
    /// never climbs past it, and folded into every frame-interval decision.
    private var thermalBitRateScale: Double = 1.0
    private var thermalFrameRateCap: Int = .max

    private var effectiveMaximum: Int {
        let thermalCeiling = Int(Double(mamimumVideoBitRate) * thermalBitRateScale)
        return max(minimumVideoBitRate,
                   min(min(mamimumVideoBitRate, pathCeiling), thermalCeiling))
    }

    init(maximumBitRate: Int, frameRate: Int) {
        mamimumVideoBitRate = maximumBitRate
        minimumVideoBitRate = max(300_000, maximumBitRate / 10)
        targetBitRate = maximumBitRate
        pathCeiling = maximumBitRate
        // Clamp only to a sane hardware maximum, NOT 30. The caller already passes
        // a capability-resolved rate (≤60 on capable devices); keeping the real
        // value here is what makes the `configuredFrameRate > 30` congestion tier
        // in `frameInterval` reachable — it was dead code while this pinned to ≤30.
        let clampedFrameRate = min(max(frameRate, 1), 120)
        configuredFrameRate = clampedFrameRate
        preferredFrameInterval = max(0, (1.0 / Double(clampedFrameRate)) - 0.001)
    }

    func adjustBitrate(_ event: NetworkMonitorEvent,
                       stream: some StreamConvertible) async {
        lastEventAt = DispatchTime.now().uptimeNanoseconds
        switch event {
        case .reset:
            // Keep the bitrate learned from the previous socket. Returning to the
            // configured maximum here caused a congestion/reconnect feedback loop
            // on constrained Wi-Fi links.
            healthySeconds = 0
            zeroOutputSeconds = 0
            queueBytes = 0
            await applyTarget(to: stream)

        case .publishInsufficientBWOccured(let report):
            queueBytes = report.currentQueueBytesOut
            guard !capturePaused else {
                zeroOutputSeconds = 0
                healthySeconds = 0
                return
            }
            healthySeconds = 0
            congestionActive = true
            let audio = await stream.audioSettings
            if report.currentBytesOutPerSecond > 0 {
                zeroOutputSeconds = 0
                let available = max(0, report.currentBytesOutPerSecond * 8 - audio.bitRate)
                // Leave substantial headroom for Wi-Fi variance, RTMP overhead,
                // and keyframes instead of targeting the measured ceiling.
                let reduced = Int(Double(available) * 0.65)
                targetBitRate = max(minimumVideoBitRate,
                                    min(targetBitRate, reduced))
            } else {
                zeroOutputSeconds += 1
                targetBitRate = max(minimumVideoBitRate, targetBitRate / 2)
            }
            await applyTarget(to: stream,
                              severe: report.currentBytesOutPerSecond == 0)
            streamLog.warning("ABR reduced video to \(self.targetBitRate) bps; queue=\(self.queueBytes) bytes")

        case .status(let report):
            queueBytes = report.currentQueueBytesOut
            guard !capturePaused else {
                zeroOutputSeconds = 0
                healthySeconds = 0
                return
            }
            // Zero output with an empty queue is normal for a paused/static
            // capture. It is a stall only when bytes are waiting to be sent.
            if report.currentBytesOutPerSecond == 0, queueBytes > 0 {
                zeroOutputSeconds += 1
                if zeroOutputSeconds >= 2 {
                    congestionActive = true
                    healthySeconds = 0
                    targetBitRate = max(minimumVideoBitRate, targetBitRate / 2)
                    await applyTarget(to: stream, severe: true)
                }
            } else {
                zeroOutputSeconds = 0
            }
            if queueBytes <= 32 * 1_024, report.currentBytesOutPerSecond > 0 {
                healthySeconds += 1
            } else {
                healthySeconds = 0
            }
            // Probe upward only after a sustained clean queue and in small steps.
            // A fast 10%-every-10s ramp repeatedly overshot variable Wi-Fi uplinks.
            guard healthySeconds >= 30 else { return }
            healthySeconds = 0
            if targetBitRate < effectiveMaximum {
                targetBitRate = min(effectiveMaximum,
                                    targetBitRate + max(75_000, effectiveMaximum / 20))
            } else {
                congestionActive = false
            }
            await applyTarget(to: stream)
            streamLog.info("ABR recovered video to \(self.targetBitRate) bps")
        }
    }

    func setCapturePaused(_ paused: Bool) {
        capturePaused = paused
        healthySeconds = 0
        zeroOutputSeconds = 0
    }

    /// Called from RTMPPublisher.handlePathUpdate on every path emission.
    /// Remembers the last achieved target per interface so Wi-Fi -> 5G does not
    /// inherit Wi-Fi's degraded learned rate (which `.reset` deliberately
    /// keeps), and 5G -> Wi-Fi does not re-climb 30 s per probe step from a low
    /// seed. The baseline (first) emission only adopts the interface and the
    /// ceiling, so a broadcast still STARTS at the configured full bitrate.
    func setPathProfile(ceiling: Int,
                        interface: NetworkPathSnapshot.Interface,
                        isBaseline: Bool,
                        applyingTo stream: some StreamConvertible) async {
        let clamped = max(minimumVideoBitRate, min(ceiling, mamimumVideoBitRate))
        if isBaseline || currentInterface == nil {
            currentInterface = interface
        } else if let current = currentInterface, interface != current {
            lastGoodTarget[current] = targetBitRate
            currentInterface = interface
            let seed = lastGoodTarget[interface] ?? Int(Double(clamped) * 0.6)
            targetBitRate = max(minimumVideoBitRate, min(seed, clamped))
            healthySeconds = 0
            zeroOutputSeconds = 0
        }
        let raised = clamped > pathCeiling
        pathCeiling = clamped
        // Clamp to effectiveMaximum (which folds in the thermal ceiling), not just
        // pathCeiling: otherwise an interface change re-seeds targetBitRate from a
        // full-rate last-good value and silently defeats an active thermal cap.
        targetBitRate = min(targetBitRate, effectiveMaximum)
        if raised { healthySeconds = 0 }   // restart the upward probe cleanly
        await applyTarget(to: stream)      // apply NOW, not at the next 1 Hz event
    }

    func currentTargetBitRate() -> Int { targetBitRate }

    /// Applies the learned bitrate and an adaptive frame-rate ceiling together.
    /// On a requested 60 fps stream, using 30 fps while congested gives each frame
    /// enough bits to remain legible and reduces encoder pressure. The configured
    /// frame rate returns only after the uplink has proven stable.
    private func applyTarget(to stream: some StreamConvertible,
                             severe: Bool = false) async {
        var video = await stream.videoSettings
        video.bitRate = targetBitRate
        video.frameInterval = frameInterval(severe: severe)
        try? await stream.setVideoSettings(video)
    }

    /// The frame interval for the current congestion + thermal state. A larger
    /// interval is a lower frame rate, so taking `max()` of the congestion and
    /// thermal intervals always yields the more restrictive of the two.
    private func frameInterval(severe: Bool) -> Double {
        let congestionInterval: Double
        if severe {
            congestionInterval = VideoCodecSettings.frameInterval10
        } else if congestionActive, configuredFrameRate > 30 {
            congestionInterval = VideoCodecSettings.frameInterval30
        } else {
            congestionInterval = preferredFrameInterval
        }
        let cappedFrameRate = max(1, min(configuredFrameRate, thermalFrameRateCap))
        let thermalInterval = max(0, (1.0 / Double(cappedFrameRate)) - 0.001)
        return max(congestionInterval, thermalInterval)
    }

    /// Stores a thermal/Low-Power ceiling and clamps the current target to it.
    /// Used when there is no stream to apply to yet (pre-connect); the value then
    /// takes effect on the first adaptive event after connect.
    func storeThermalCeiling(bitRateScale: Double, frameRateCap: Int) {
        thermalBitRateScale = min(max(bitRateScale, 0.1), 1.0)
        thermalFrameRateCap = max(1, frameRateCap)
        // Only lower the target to fit a tightened ceiling. Leave healthySeconds
        // alone: resetting it on every change would let brief thermal flapping
        // across a boundary keep restarting the up-probe and starve recovery.
        targetBitRate = min(targetBitRate, effectiveMaximum)
    }

    func currentFrameInterval() -> Double { frameInterval(severe: false) }

    /// The effective encode frame rate the ABR is currently targeting (fps), folding
    /// in the same congestion + thermal caps as `frameInterval()` (most-restrictive
    /// wins). Used by the live stats HUD; not a measured output rate (measured fps
    /// needs M8). Mirrors `frameInterval`'s steady-state branches directly rather
    /// than lossily inverting the interval Double.
    func currentFrameRate() -> Int {
        let congestionFps = (congestionActive && configuredFrameRate > 30) ? 30 : configuredFrameRate
        let thermalFps = max(1, min(configuredFrameRate, thermalFrameRateCap))
        return min(congestionFps, thermalFps)
    }

    /// Applies the current (possibly thermally-clamped) target + frame interval to
    /// a freshly-connected stream. SRT/WHIP emit no `.reset` event, so the
    /// pre-connect store path relies on this to land the ceiling on the encoder.
    func applyCurrentTarget(to stream: any StreamConvertible) async {
        var video = await stream.videoSettings
        video.bitRate = targetBitRate
        video.frameInterval = frameInterval(severe: false)
        try? await stream.setVideoSettings(video)
    }

    /// Applies a thermal/Low-Power ceiling to the encoder immediately, instead of
    /// waiting for the next ~1 Hz adaptive event. Takes `any StreamConvertible` so
    /// both the concrete RTMPStream and SessionPublisher's existential stream can
    /// drive it.
    func setThermalCeiling(bitRateScale: Double,
                           frameRateCap: Int,
                           applyingTo stream: any StreamConvertible) async {
        storeThermalCeiling(bitRateScale: bitRateScale, frameRateCap: frameRateCap)
        var video = await stream.videoSettings
        video.bitRate = targetBitRate
        video.frameInterval = frameInterval(severe: false)
        try? await stream.setVideoSettings(video)
    }

    func healthSnapshot() -> BroadcastNetworkHealth {
        let now = DispatchTime.now().uptimeNanoseconds
        return BroadcastNetworkHealth(
            queueBytes: queueBytes,
            zeroOutputSeconds: zeroOutputSeconds,
            eventAgeSeconds: Int((now &- lastEventAt) / 1_000_000_000),
            targetBitRate: targetBitRate
        )
    }
}

enum MediaTimelineKind: Hashable {
    case video
    case mic
    case app
}

/// Removes capture/reconnect wall-clock gaps before samples reach HaishinKit.
/// Without this, its audio ring buffer materializes a long pause as thousands of
/// silence buffers and its RTMP timestamp accumulator sends a large first delta.
struct MediaTimelineNormalizer {
    private var accumulatedOffset = CMTime.zero
    private var lastPresentationTime: [MediaTimelineKind: CMTime] = [:]
    private var needsRebase = false

    mutating func markDiscontinuity() {
        needsRebase = true
    }

    mutating func normalize(_ sampleBuffer: CMSampleBuffer,
                            kind: MediaTimelineKind,
                            fallbackDuration: CMTime) -> CMSampleBuffer {
        let sourcePTS = sampleBuffer.presentationTimeStamp
        guard sourcePTS.isValid, sourcePTS.isNumeric else { return sampleBuffer }

        let sampleDuration = sampleBuffer.duration.isValid && sampleBuffer.duration.isNumeric && sampleBuffer.duration > .zero
            ? sampleBuffer.duration
            : fallbackDuration

        if needsRebase {
            let prior = lastPresentationTime[kind]
                ?? lastPresentationTime.values.max(by: { CMTimeCompare($0, $1) < 0 })
            if let prior {
                let prospective = CMTimeSubtract(sourcePTS, accumulatedOffset)
                let desired = CMTimeAdd(prior, sampleDuration)
                let gap = CMTimeSubtract(prospective, desired)
                if CMTimeCompare(gap, .zero) > 0 {
                    accumulatedOffset = CMTimeAdd(accumulatedOffset, gap)
                }
            }
            needsRebase = false
        }

        // Steady-state fast path: with no accumulated offset the copy below would
        // produce a bit-identical buffer (PTS − 0 == PTS), so skip the per-buffer
        // heap alloc + CMSampleBuffer copy entirely. This is the state for the
        // whole broadcast until the first pause/reconnect sets an offset — at
        // ~150 buffers/s it was pure waste on the gated real-time append path.
        if accumulatedOffset == .zero {
            lastPresentationTime[kind] = sourcePTS
            return sampleBuffer
        }

        var entryCount: CMItemCount = 0
        guard CMSampleBufferGetSampleTimingInfoArray(
            sampleBuffer,
            entryCount: 0,
            arrayToFill: nil,
            entriesNeededOut: &entryCount
        ) == noErr, entryCount > 0 else {
            return sampleBuffer
        }

        var timings = [CMSampleTimingInfo](
            repeating: CMSampleTimingInfo(duration: .invalid,
                                          presentationTimeStamp: .invalid,
                                          decodeTimeStamp: .invalid),
            count: entryCount
        )
        let status = timings.withUnsafeMutableBufferPointer { buffer in
            CMSampleBufferGetSampleTimingInfoArray(
                sampleBuffer,
                entryCount: entryCount,
                arrayToFill: buffer.baseAddress,
                entriesNeededOut: nil
            )
        }
        guard status == noErr else { return sampleBuffer }

        for index in timings.indices {
            if timings[index].presentationTimeStamp.isValid {
                timings[index].presentationTimeStamp = CMTimeSubtract(
                    timings[index].presentationTimeStamp,
                    accumulatedOffset
                )
            }
            if timings[index].decodeTimeStamp.isValid {
                timings[index].decodeTimeStamp = CMTimeSubtract(
                    timings[index].decodeTimeStamp,
                    accumulatedOffset
                )
            }
        }

        var adjusted: CMSampleBuffer?
        let copyStatus = timings.withUnsafeMutableBufferPointer { buffer in
            CMSampleBufferCreateCopyWithNewTiming(
                allocator: kCFAllocatorDefault,
                sampleBuffer: sampleBuffer,
                sampleTimingEntryCount: entryCount,
                sampleTimingArray: buffer.baseAddress!,
                sampleBufferOut: &adjusted
            )
        }
        guard copyStatus == noErr, let adjusted else { return sampleBuffer }
        lastPresentationTime[kind] = adjusted.presentationTimeStamp
        return adjusted
    }
}
