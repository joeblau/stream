import AVFoundation
import CoreMedia
import Foundation

enum NativeGuestReturnAudioError: Error { case unavailable, malformed, codec }
struct NativeGuestReturnOpusPacket: Sendable {
    let data: Data
    /// Packet start on the original mixer grid, including declared codec
    /// priming. No first-arrival or output-delivery timestamp is substituted.
    let pts: CMTime
    let frames: Int
    let rtp: UInt32
    let ntp: UInt64
}
private final class ReturnEncoderInput: @unchecked Sendable {
    // The synchronous converter invocation serializes this one owned input.
    let pcm: AVAudioPCMBuffer
    private var supplied = false
    init(_ pcm: AVAudioPCMBuffer) { self.pcm = pcm }
    func next(_ state: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        guard !supplied else { state.pointee = .noDataNow; return nil }
        supplied = true; state.pointee = .haveData; return pcm
    }
}

/// One serial return-mailbox consumer owns this encoder. It assembles the
/// actual512-frame mixer chunks into supported20ms Opus frames. Bounded input
/// gaps reset codec history while retaining each new original source PTS.
final class NativeGuestReturnAudioEncoder {
    static let packetFrames = 960
    private let pcmFormat: AVAudioFormat, opusFormat: AVAudioFormat
    private var converter: AVAudioConverter
    private var leading: Int64
    private let ntpHostOffset: Double
    private var sourceOrigin = CMTime.invalid
    private var sourceRTP: Int64 = 0, appendedFrames: Int64 = 0, encodedFrames: Int64 = 0
    private var revision: UInt64?
    private var pending: [Float] = []
    private(set) var discardedFrames: Int64 = 0
    private(set) var encodedPackets: UInt64 = 0

    init() throws {
        guard let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false) else {
            throw NativeGuestReturnAudioError.unavailable
        }
        var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatOpus,
            mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 960, mBytesPerFrame: 0,
            mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
        guard let opus = AVAudioFormat(streamDescription: &asbd) else { throw NativeGuestReturnAudioError.unavailable }
        pcmFormat = pcm; opusFormat = opus
        converter = try Self.makeConverter(pcm, opus)
        leading = Int64(converter.primeInfo.leadingFrames)
        let host = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        ntpHostOffset = Date().timeIntervalSince1970 + 2_208_988_800 - host
        pending.reserveCapacity((Self.packetFrames + 512) * 2)
    }
    private static func makeConverter(_ pcm: AVAudioFormat, _ opus: AVAudioFormat) throws -> AVAudioConverter {
        guard let value = AVAudioConverter(from: pcm, to: opus) else { throw NativeGuestReturnAudioError.unavailable }
        value.bitRate = 64_000; value.primeMethod = .none
        // Core Audio advertises1276 bytes here on the qualified OS. Allocate
        // that bounded codec workspace; every actual RTP packet remains<=1275.
        guard value.maximumOutputPacketSize > 0, value.maximumOutputPacketSize <= 4_096,
              value.primeInfo.leadingFrames <= 960 else { throw NativeGuestReturnAudioError.unavailable }
        return value
    }
    private func begin(_ frame: GuestReturnAudioFrame) throws {
        // Account for owned PCM and the codec's declared un-emitted lookahead;
        // EOS padding is deliberately not sent across a revoked source window.
        discardedFrames += max(0, appendedFrames - max(0, encodedFrames - leading))
        pending.removeAll(keepingCapacity: true)
        converter = try Self.makeConverter(pcmFormat, opusFormat)
        leading = Int64(converter.primeInfo.leadingFrames)
        sourceOrigin = frame.pts; appendedFrames = 0; encodedFrames = 0; revision = frame.routingRevision
        sourceRTP = CMTimeConvertScale(sourceOrigin, timescale: 48_000, method: .roundHalfAwayFromZero).value
    }
    func encode(_ frame: GuestReturnAudioFrame) throws -> [NativeGuestReturnOpusPacket] {
        let sample = frame.sample
        guard frame.pts.isNumeric, sample.numSamples == 512,
              let format = sample.formatDescription, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format),
              asbd.pointee.mSampleRate == 48_000, asbd.pointee.mChannelsPerFrame == 2,
              asbd.pointee.mFormatID == kAudioFormatLinearPCM,
              asbd.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.pointee.mBytesPerFrame == 8, let block = sample.dataBuffer,
              CMBlockBufferGetDataLength(block) == 512 * 8 else { throw NativeGuestReturnAudioError.malformed }
        let expected = sourceOrigin.isNumeric ? sourceOrigin + CMTime(value: appendedFrames, timescale: 48_000) : .invalid
        let contiguous = expected.isNumeric
            && ProgramRecordingSession.audioFrameOffset(from: expected, to: frame.pts, rate: 48_000, rounding: .roundTowardPositiveInfinity) == 0
            && ProgramRecordingSession.audioFrameOffset(from: expected, to: frame.pts, rate: 48_000, rounding: .roundTowardNegativeInfinity) == 0
        if !contiguous || revision != frame.routingRevision { try begin(frame) }
        var samples = [Float](repeating: 0, count: 1_024)
        let copied = samples.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
        }
        guard copied == noErr, samples.allSatisfy(\.isFinite), pending.count + samples.count <= (960 + 512) * 2 else {
            throw NativeGuestReturnAudioError.malformed
        }
        pending.append(contentsOf: samples); appendedFrames += 512
        var packets: [NativeGuestReturnOpusPacket] = []
        if pending.count >= 960 * 2 {
            guard let pcm = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: 960) else { throw NativeGuestReturnAudioError.codec }
            pcm.frameLength = 960
            for index in 0..<960 { for side in 0..<2 { pcm.floatChannelData![side][index] = pending[index * 2 + side] } }
            pending.removeFirst(960 * 2)
            let input = ReturnEncoderInput(pcm)
            for _ in 0..<3 {
                let output = AVAudioCompressedBuffer(format: opusFormat, packetCapacity: 1, maximumPacketSize: converter.maximumOutputPacketSize)
                var error: NSError?
                let status = converter.convert(to: output, error: &error) { _, state in input.next(state) }
                guard status != .error, error == nil else { throw NativeGuestReturnAudioError.codec }
                guard output.packetCount > 0 else { break }
                guard output.packetCount == 1, output.byteLength > 0, output.byteLength <= 1275 else { throw NativeGuestReturnAudioError.codec }
                let data = Data(bytes: output.data, count: Int(output.byteLength))
                guard Self.opusFrames(data) == 960 else { throw NativeGuestReturnAudioError.codec }
                let offset = encodedFrames - leading
                let pts = sourceOrigin + CMTime(value: offset, timescale: 48_000)
                let ntpSeconds = pts.seconds + ntpHostOffset
                guard ntpSeconds.isFinite, ntpSeconds > 0, ntpSeconds < Double(UInt32.max) else { throw NativeGuestReturnAudioError.malformed }
                let whole = UInt64(ntpSeconds.rounded(.down))
                let fraction = UInt64((ntpSeconds - Double(whole)) * 4_294_967_296)
                packets.append(.init(data: data, pts: pts, frames: 960,
                    rtp: UInt32(truncatingIfNeeded: sourceRTP + offset), ntp: whole << 32 | fraction))
                encodedFrames += 960; encodedPackets += 1
            }
        }
        return packets
    }
    static func opusFrames(_ data: Data) -> Int? {
        guard let toc = data.first else { return nil }
        let configuration = Int(toc >> 3)
        let samples = configuration < 12 ? [480, 960, 1920, 2880][configuration & 3]
            : configuration < 16 ? [480, 960][configuration & 1] : [120, 240, 480, 960][configuration & 3]
        let count: Int
        switch toc & 3 {
        case 0: count = 1
        case 1, 2: count = 2
        default: guard data.count > 1 else { return nil }; count = Int(data[data.startIndex + 1] & 63)
        }
        guard count > 0, count <= 48, samples * count <= 5_760 else { return nil }
        return samples * count
    }
}
