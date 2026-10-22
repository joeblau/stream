import AVFoundation
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
    /// Desktop-only opt-in. Existing raw capture/iOS callers never enable it.
    nonisolated var supportsSharedH264AAC: Bool { get }
    func configureEncodedInput() async -> Bool
    /// Installs the AAC format before the first IDR when the packetizer needs
    /// both formats. This does not publish an audio packet on its own.
    func prepareEncodedAudio(_ audio: SharedEncodedAudio) async
    func appendEncodedVideo(_ sample: CMSampleBuffer) async -> Bool
    func appendEncodedAudio(_ audio: SharedEncodedAudio) async -> Bool
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
    /// Actual post-admission ingress: normalized raw encoder/mixer input, or
    /// compressed publisher input when shared encoding is selected. Actual
    /// codec callbacks are observed separately by the shared encoder.
    func encoderInputClockSnapshot() async -> AVClockSnapshot
}


/// Frozen after construction. The same compressed sample and packet bytes may
/// be read by independent packetizers; neither the app nor adapters mutate them.
final class SharedEncodedAudio: @unchecked Sendable {
    let sample: CMSampleBuffer
    let buffer: AVAudioCompressedBuffer
    let when: AVAudioTime
    init(sample: CMSampleBuffer, buffer: AVAudioCompressedBuffer, when: AVAudioTime) {
        self.sample = sample; self.buffer = buffer; self.when = when
    }
}

extension Publisher {
    func encoderInputClockSnapshot() async -> AVClockSnapshot { .unsupported }
    nonisolated var supportsSharedH264AAC: Bool { false }
    func configureEncodedInput() async -> Bool { false }
    func prepareEncodedAudio(_ audio: SharedEncodedAudio) async {}
    func appendEncodedVideo(_ sample: CMSampleBuffer) async -> Bool { false }
    func appendEncodedAudio(_ audio: SharedEncodedAudio) async -> Bool { false }
}

#if os(macOS)
/// The native multitrack AudioUnit mixer requires planar Float32 buses on
/// macOS. The studio bus is packed stereo Float32; change only its memory
/// layout before entering HaishinKit, preserving samples and source time.
enum PublisherProgramAudio {
    static func planar(_ sample: CMSampleBuffer) -> (buffer: AVAudioPCMBuffer, when: AVAudioTime)? {
        guard let description = sample.formatDescription,
              let pointer = CMAudioFormatDescriptionGetStreamBasicDescription(description) else { return nil }
        let source = pointer.pointee
        let count = sample.numSamples
        guard source.mFormatID == kAudioFormatLinearPCM, source.mSampleRate == 48_000,
              source.mChannelsPerFrame == 2, source.mBitsPerChannel == 32,
              source.mBytesPerFrame == 8, source.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              source.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0,
              source.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
              count > 0, count <= 48_000,
              let data = sample.dataBuffer, CMBlockBufferGetDataLength(data) == count * 8,
              sample.presentationTimeStamp.isNumeric,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let channels = buffer.floatChannelData else { return nil }
        var packed = [Float](repeating: 0, count: count * 2)
        let status = packed.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: count * 8, destination: $0.baseAddress!)
        }
        guard status == noErr else { return nil }
        for frame in 0..<count {
            channels[0][frame] = packed[frame * 2]
            channels[1][frame] = packed[frame * 2 + 1]
        }
        buffer.frameLength = AVAudioFrameCount(count)
        let pts = sample.presentationTimeStamp
        let when = AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: pts.seconds),
            sampleTime: CMTimeConvertScale(pts, timescale: 48_000, method: .roundTowardZero).value, atRate: 48_000)
        return (buffer, when)
    }
}
#endif
