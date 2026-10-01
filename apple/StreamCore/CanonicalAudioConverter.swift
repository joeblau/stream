import AudioToolbox
import AVFAudio
import CoreMedia
import os

/// `AVAudioConverterInputBlock` is `@Sendable`: carry the one-shot input
/// buffer across it in a lock-confined box (the VoicePolishProcessor pattern).
/// Between buffers the block answers `.noDataNow` (never `.endOfStream`) so
/// the converter treats the channel as one CONTINUOUS stream and keeps its
/// sample-rate-conversion state across calls — no per-buffer priming loss.
private final class ConverterInputBox: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private var lock = os_unfair_lock_s()
    private var delivered = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func next(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        os_unfair_lock_lock(&lock)
        let first = !delivered
        delivered = true
        os_unfair_lock_unlock(&lock)
        if first {
            status.pointee = .haveData
            return buffer
        }
        status.pointee = .noDataNow
        return nil
    }
}

/// Normalizes any LPCM capture format to the A01 engine's canonical mix
/// format — 48 kHz, stereo, interleaved Float32 — one instance per channel
/// (issue #82: "normalize sample rate/channel layout/timestamps").
///
/// The converter is rebuilt when the source format changes (device switch,
/// C10 hot-plug onto a differently-clocked input). Conversion is continuous:
/// input blocks report `.noDataNow` rather than `.endOfStream` between
/// buffers, so `AVAudioConverter`'s resampler state persists across calls and
/// a 44.1 kHz mic neither loses tail samples nor drifts against the 48 kHz
/// mix clock.
///
/// Timestamps are NOT touched: the caller maps the source PTS onto the engine
/// clock and writes the converted frames at that ring position.
///
/// Not `Sendable`: each audio channel owns one instance, confined to the
/// channel's lock. Failure policy: return nil (the buffer is dropped and
/// counted) — conversion failures never crash the capture callback.
public final class CanonicalAudioConverter {
    /// The engine-wide mix format: 48 kHz stereo interleaved Float32.
    public static let canonicalFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 2,
        interleaved: true
    )!

    private static let log = Logger(subsystem: "com.joeblau.Stream", category: "audio-converter")

    private var converter: AVAudioConverter?
    private var sourceRate: Double = 0
    private var sourceChannels: AVAudioChannelCount = 0
    private var sourceCommonFormat: AVAudioCommonFormat?
    private var sourceInterleaved = false
    private var didLogFailure = false

    public init() {}

    /// Tears conversion state down (pipeline stop / format authority change).
    public func reset() {
        converter = nil
        sourceRate = 0
        sourceChannels = 0
        sourceCommonFormat = nil
        sourceInterleaved = false
        didLogFailure = false
    }

    /// Converts one PCM buffer to the canonical format. A buffer already in
    /// the canonical format is returned unchanged (zero-copy fast path).
    public func convert(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let format = input.format
        if format.sampleRate == Self.canonicalFormat.sampleRate,
           format.channelCount == Self.canonicalFormat.channelCount,
           format.commonFormat == .pcmFormatFloat32,
           format.isInterleaved {
            return input
        }
        if converter == nil
            || sourceRate != format.sampleRate
            || sourceChannels != format.channelCount
            || sourceCommonFormat != format.commonFormat
            || sourceInterleaved != format.isInterleaved {
            converter = AVAudioConverter(from: format, to: Self.canonicalFormat)
            sourceRate = format.sampleRate
            sourceChannels = format.channelCount
            sourceCommonFormat = format.commonFormat
            sourceInterleaved = format.isInterleaved
        }
        guard let converter else { return fail("converter creation failed") }
        let ratio = Self.canonicalFormat.sampleRate / format.sampleRate
        // +64 frames of headroom: the resampler emits slightly more/fewer than
        // the exact ratio per call as its phase accumulates.
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.canonicalFormat,
                                            frameCapacity: capacity) else {
            return fail("output buffer alloc failed")
        }
        let box = ConverterInputBox(buffer: input)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            box.next(status: outStatus)
        }
        guard conversionError == nil, status != .error else {
            return fail("conversion failed")
        }
        // `.inputRanOut` is the steady state (continuous-stream conversion) —
        // whatever frames landed are valid; the resampler keeps the rest.
        return output
    }

    /// Converts one captured `CMSampleBuffer` (any LPCM layout) to the
    /// canonical format. Returns nil for non-LPCM or unreadable buffers.
    public func convert(_ sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let pcm = Self.makePCMBuffer(from: sampleBuffer) else { return nil }
        return convert(pcm)
    }

    /// Copies a sample buffer's LPCM out of its AudioBufferList into an
    /// `AVAudioPCMBuffer` described by the buffer's own ASBD (any bit depth /
    /// interleave). Returns nil for compressed formats — capture sources all
    /// deliver LPCM, and dropping is the documented policy for the rest.
    public static func makePCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let asbd = CMSampleBufferGetFormatDescription(sampleBuffer)
                .flatMap({ CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }),
              asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mSampleRate > 0, asbd.mChannelsPerFrame > 0 else { return nil }
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else { return nil }
        var mutableASBD = asbd
        guard let format = AVAudioFormat(streamDescription: &mutableASBD),
              let pcm = AVAudioPCMBuffer(pcmFormat: format,
                                         frameCapacity: AVAudioFrameCount(frameCount)) else {
            return nil
        }
        pcm.frameLength = AVAudioFrameCount(frameCount)

        var listSize = 0
        var blockBuffer: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: &listSize,
            bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &blockBuffer
        ) == noErr, listSize > 0 else { return nil }

        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: listSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        let list = storage.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil,
            bufferListOut: list, bufferListSize: listSize,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &blockBuffer
        ) == noErr else { return nil }

        let destination = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
        let source = UnsafeMutableAudioBufferListPointer(list)
        let count = min(source.count, destination.count)
        for index in 0..<count {
            destination[index].mNumberChannels = source[index].mNumberChannels
            destination[index].mDataByteSize = min(source[index].mDataByteSize,
                                                   destination[index].mDataByteSize)
            if let dst = destination[index].mData, let src = source[index].mData {
                memcpy(dst, src, Int(destination[index].mDataByteSize))
            }
        }
        return pcm
    }

    /// The interleaved Float32 samples of a canonical-format buffer, or nil
    /// for any other layout (callers pass only `convert` output through here).
    public static func interleavedFloats(_ pcm: AVAudioPCMBuffer) -> [Float]? {
        guard pcm.format.commonFormat == .pcmFormatFloat32, pcm.format.isInterleaved,
              let data = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList).first?.mData
        else { return nil }
        let count = Int(pcm.frameLength) * Int(pcm.format.channelCount)
        let samples = data.assumingMemoryBound(to: Float.self)
        return Array(UnsafeBufferPointer(start: samples, count: count))
    }

    /// One-shot failure log + drop. Conversion problems drop one buffer, never
    /// the channel (the ring underrun policy covers the hole with silence).
    private func fail(_ reason: String) -> AVAudioPCMBuffer? {
        if !didLogFailure {
            didLogFailure = true
            Self.log.error("Audio conversion passthrough-drop: \(reason, privacy: .public)")
        }
        return nil
    }
}
