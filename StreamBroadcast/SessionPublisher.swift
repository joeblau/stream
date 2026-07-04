import HaishinKit        // MediaMixer, StreamSessionBuilderFactory, StreamConvertible, codec settings
import SRTHaishinKit     // SRTSessionFactory  (srt://)
import RTCHaishinKit     // HTTPSessionFactory (WHIP over http/https)
import AVFoundation
import CoreMedia
import CoreGraphics
import VideoToolbox
import StreamCore
import os

private let sessionLog = Logger(subsystem: "com.joeblau.Stream", category: "session")

/// The publisher surface, so `ScreenCaptureController` can drive either the
/// dedicated `RTMPPublisher` or the unified-transport `SessionPublisher` behind one
/// type. Both are actors sharing the same encode pipeline (mixer, ABR, timeline
/// normalizer, frame admission).
protocol Publisher: Actor {
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
    private lazy var networkController = BroadcastAdaptiveBitRateController(
        maximumBitRate: settings.videoBitrate,
        frameRate: settings.frameRate)
    private var settings: StreamSettings = .default

    private var session: (any StreamSession)?
    private var stream: (any StreamConvertible)?
    private var isRunning = false
    private var isPaused = false
    private var outputSizeConfigured = false
    private var outputSize: CGSize?
    private var userInitiatedStop = false
    private var reconnectTask: Task<Void, Never>?

    private var timeline = MediaTimelineNormalizer()
    private let videoAdmission = VideoFrameAdmission()

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

    init(protocol streamProtocol: StreamCore.StreamProtocol) {
        self.transport = streamProtocol
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
        let fps = UInt64(max(1, min(settings.frameRate, 30)))
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

        isRunning = true
        startAudioConsumers()
        startFrameRepeat()
        try await connectAndPublish()
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
        let builder = try await StreamSessionBuilderFactory.shared.make(url)
        _ = await builder.setMode(.publish)
        guard let session = try await builder.build() else {
            throw NSError(domain: "com.joeblau.Stream.Broadcast", code: 21, userInfo: [
                NSLocalizedDescriptionKey: "No transport is registered for this \(transport.displayName) URL."])
        }
        let stream = await session.stream
        try await stream.setAudioSettings(AudioCodecSettings(
            bitRate: settings.audioBitrate, sampleRate: 48_000, format: audioFormat))
        await stream.setVideoInputBufferCounts(1)
        await stream.setBitRateStrategy(networkController)

        // Re-apply the locked encoder size to the fresh stream (across reconnects).
        if let outputSize {
            try? await stream.setVideoSettings(
                await makeVideoSettings(await stream.videoSettings, size: outputSize)
            )
        }

        await mixer.addOutput(stream)
        self.session = session
        self.stream = stream

        // Land any thermal ceiling stored before the stream existed. SRT/WHIP emit
        // no `.reset` event, so no adaptive event would otherwise apply a hot-at-
        // go-live ceiling to this fresh encoder until congestion or a state change.
        await networkController.applyCurrentTarget(to: stream)

        try await session.connect { [weak self] in
            guard let self else { return }
            Task { await self.handleDisconnect() }
        }
        sessionLog.info("\(self.transport.displayName, privacy: .public) connected: \(url.absoluteString, privacy: .public)")
    }

    private func handleDisconnect() async {
        guard isRunning, !userInitiatedStop, !isPaused, reconnectTask == nil else { return }
        sessionLog.error("\(self.transport.displayName, privacy: .public) transport dropped; reconnecting")
        if let stream { await mixer.removeOutput(stream) }
        try? await session?.close()
        session = nil
        stream = nil
        reconnectTask = Task { [weak self] in await self?.reconnectLoop() }
    }

    private func reconnectLoop() async {
        defer { reconnectTask = nil }
        var delay: UInt64 = 1_000_000_000
        let maxDelay: UInt64 = 30_000_000_000
        var attempt = 0
        while isRunning, !userInitiatedStop, !isPaused {
            attempt += 1
            do {
                try await connectAndPublish()
                timeline.markDiscontinuity()
                sessionLog.info("\(self.transport.displayName, privacy: .public) reconnected after \(attempt) attempt(s)")
                return
            } catch {
                if userInitiatedStop || !isRunning { return }
                sessionLog.error("\(self.transport.displayName, privacy: .public) reconnect \(attempt) failed: \(String(describing: error), privacy: .public)")
                try? await Task.sleep(nanoseconds: delay)
                delay = min(delay * 2, maxDelay)
            }
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

    private func makeVideoSettings(_ current: VideoCodecSettings, size: CGSize? = nil) async -> VideoCodecSettings {
        let frameRate = min(max(settings.frameRate, 1), 30)
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
        v.profileLevel = kVTProfileLevel_H264_Main_AutoLevel as String
        v.allowFrameReordering = false
        return v
    }

    func appendVideo(_ sb: CMSampleBuffer) async {
        guard outputSizeConfigured, isRunning, !isPaused, stream != nil else { return }
        lastVideoAppendAt = DispatchTime.now().uptimeNanoseconds
        lastVideoBuffer = sb
        guard videoAdmission.admit() else { return }
        let duration = CMTime(value: 1, timescale: CMTimeScale(min(max(settings.frameRate, 1), 30)))
        let normalized = timeline.normalize(sb, kind: .video, fallbackDuration: duration)
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
        await mixer.append(timeline.normalize(sb, kind: .mic,
                                              fallbackDuration: CMTime(value: 1_024, timescale: 48_000)),
                           track: 0)
    }

    func appendApp(_ sb: CMSampleBuffer) async {
        guard isRunning, !isPaused, stream != nil else { return }
        await mixer.append(timeline.normalize(sb, kind: .app,
                                              fallbackDuration: CMTime(value: 1_024, timescale: 48_000)),
                           track: 1)
    }

    private func applyAudioMixerSettings() async {
        let gain = Float(max(0.0, min(settings.micVolume, 2.0)))
        await mixer.setAudioMixerSettings(AudioMixerSettings(
            sampleRate: 48_000, channels: settings.includeAppAudio ? 2 : 1, mainTrack: 0,
            tracks: [0: AudioMixerTrackSettings(volume: gain), 1: .default]))
    }

    func setMicVolume(_ volume: Double) async {
        settings.micVolume = volume
        await applyAudioMixerSettings()
    }

    func pause() async {
        guard isRunning, !isPaused, !userInitiatedStop else { return }
        isPaused = true
        timeline.markDiscontinuity()
    }

    func resume() async {
        guard isRunning, isPaused, !userInitiatedStop else { return }
        isPaused = false
        timeline.markDiscontinuity()
        if await session?.connected != true, reconnectTask == nil {
            reconnectTask = Task { [weak self] in await self?.reconnectLoop() }
        }
    }

    func stop() async {
        userInitiatedStop = true
        isPaused = false
        reconnectTask?.cancel()
        reconnectTask = nil
        micCont.finish()
        appCont.finish()
        audioConsumers.forEach { $0.cancel() }
        audioConsumers = []
        frameRepeatTask?.cancel()
        frameRepeatTask = nil
        lastVideoBuffer = nil
        guard isRunning else {
            await mixer.stopRunning()
            return
        }
        isRunning = false
        if let stream { await mixer.removeOutput(stream) }
        try? await session?.close()
        session = nil
        stream = nil
        await mixer.stopRunning()
    }
}
