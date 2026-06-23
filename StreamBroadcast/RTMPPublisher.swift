import HaishinKit       // MediaMixer, VideoCodecSettings, AudioCodecSettings
import RTMPHaishinKit   // RTMPConnection, RTMPStream
import AVFoundation
import CoreMedia
import VideoToolbox
import StreamCore

/// Actor wrapping the HaishinKit pipeline: a `MediaMixer` in manual capture mode
/// wired to an `RTMPStream` over an `RTMPConnection`. All HaishinKit access is
/// serialized through this actor; the `SampleHandler` dispatches each buffer in.
///
/// rtmps:// URLs auto-negotiate TLS on port 443; rtmp:// uses 1935 — the scheme
/// alone drives the decision, no extra flag required.
actor RTMPPublisher {
    private let mixer = MediaMixer(captureSessionMode: .manual,
                                   multiTrackAudioMixingEnabled: true)
    private let connection = RTMPConnection()
    private lazy var stream = RTMPStream(connection: connection)
    private var isRunning = false
    private var settings: StreamSettings = .default
    /// The encode dimensions are locked once, from the first screen frame, so the
    /// stream matches the device orientation/aspect. Until set, video is dropped.
    private var outputSizeConfigured = false

    /// Builds + starts the pipeline, connects, and begins publishing. The video
    /// size is NOT set here — it is locked from the first frame via `setOutputSize`.
    func start(_ settings: StreamSettings) async throws {
        self.settings = settings

        // Audio encode settings.
        var a = await stream.audioSettings
        a.bitRate = settings.audioBitrate
        try await stream.setAudioSettings(a)

        // Passthrough video mixing + cap encoder input for the ~50MB budget.
        var vm = await mixer.videoMixerSettings
        vm.mode = .passthrough
        await mixer.setVideoMixerSettings(vm)
        await stream.setVideoInputBufferCounts(5)

        await mixer.addOutput(stream)
        await mixer.startRunning()

        // rtmps:// -> TLS + port 443 automatically; rtmp:// -> 1935. No extra flag.
        _ = try await connection.connect(settings.rtmpURL)
        _ = try await stream.publish(settings.streamKey)   // stream key = publish name
        isRunning = true
    }

    /// Locks the encoder to a concrete output size (derived from the first screen
    /// frame's real aspect ratio). `.letterbox` scaling guarantees the source is
    /// fit without distortion even if a later frame's aspect differs slightly.
    /// Idempotent — only the first call takes effect.
    func setOutputSize(_ size: CGSize) async {
        guard !outputSizeConfigured else { return }
        var v = await stream.videoSettings
        v.videoSize = size
        v.scalingMode = .letterbox
        v.bitRate = settings.videoBitrate
        v.expectedFrameRate = Double(settings.frameRate)
        // 2-second keyframe interval (GOP) — required by most RTMP ingests
        // (restream.io, YouTube, etc.) for clean stream startup and seeking.
        v.maxKeyFrameIntervalDuration = 2
        v.profileLevel = kVTProfileLevel_H264_Baseline_AutoLevel as String
        try? await stream.setVideoSettings(v)
        outputSizeConfigured = true
    }

    /// Appends a (raw or composited) screen video buffer. Dropped until the output
    /// size is locked, so the encoder never starts at the wrong dimensions.
    func appendVideo(_ sb: CMSampleBuffer) async {
        guard outputSizeConfigured else { return }
        await mixer.append(sb)
    }

    /// Appends microphone audio on track 0.
    func appendMic(_ sb: CMSampleBuffer) async { await mixer.append(sb, track: 0) }

    /// Appends app/system audio on track 1.
    func appendApp(_ sb: CMSampleBuffer) async { await mixer.append(sb, track: 1) }

    /// Tears down the stream, connection, and mixer.
    func stop() async {
        guard isRunning else {
            await mixer.stopRunning()
            return
        }
        isRunning = false
        _ = try? await stream.close()
        _ = try? await connection.close()
        await mixer.stopRunning()
    }
}
