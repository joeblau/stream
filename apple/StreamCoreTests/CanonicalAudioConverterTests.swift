import AVFAudio
import Testing
@testable import StreamCore

/// A01 (issue #82): format normalization onto the canonical 48 kHz stereo
/// Float32 mix format, including continuous sample-rate conversion.
@Suite("CanonicalAudioConverter")
struct CanonicalAudioConverterTests {
    private func pcm(rate: Double, channels: AVAudioChannelCount,
                     interleaved: Bool = false, frames: Int,
                     value: Float = 0.5) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: rate,
                                         channels: channels,
                                         interleaved: interleaved),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(frames))
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        if interleaved {
            let data = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)[0]
                .mData!.assumingMemoryBound(to: Float.self)
            for index in 0..<(frames * Int(channels)) { data[index] = value }
        } else if let channelData = buffer.floatChannelData {
            for channel in 0..<Int(channels) {
                for frame in 0..<frames { channelData[channel][frame] = value }
            }
        }
        return buffer
    }

    @Test func canonicalInputPassesThroughUnchanged() throws {
        let input = try #require(pcm(rate: 48_000, channels: 2, interleaved: true,
                                     frames: 512, value: 0.25))
        let output = try #require(CanonicalAudioConverter().convert(input))
        #expect(output === input)
        #expect(output.frameLength == 512)
    }

    @Test func mono44k1ConvertsToStereo48kWithDuplicatedChannels() throws {
        let input = try #require(pcm(rate: 44_100, channels: 1, frames: 441, value: 0.5))
        let output = try #require(CanonicalAudioConverter().convert(input))
        #expect(output.format.sampleRate == 48_000)
        #expect(output.format.channelCount == 2)
        // 441 frames @44.1k ≈ 480 @48k. The FIRST buffer may be short by the
        // resampler's one-time priming latency (~18 frames — held internally,
        // released by later buffers, so it is latency, not loss or drift).
        #expect(abs(Int(output.frameLength) - 480) <= 24)
        let floats = try #require(CanonicalAudioConverter.interleavedFloats(output))
        #expect(floats.count == Int(output.frameLength) * 2)
        // Mono upmix duplicates: L == R, and the level survives conversion.
        for frame in stride(from: 0, to: Int(output.frameLength), by: 16) {
            #expect(abs(floats[frame * 2] - floats[frame * 2 + 1]) < 0.001)
            #expect(abs(floats[frame * 2] - 0.5) < 0.05)
        }
    }

    @Test func continuousConversionKeepsRatioAcrossBuffers() throws {
        let converter = CanonicalAudioConverter()
        var outputs: [Int] = []
        // Ten 44.1 kHz buffers of 441 frames ≈ ten 480-frame 48 kHz chunks.
        // Continuous-stream conversion (.noDataNow between buffers) must not
        // bleed priming/tail samples per buffer: after the first buffer's
        // one-time priming latency, every buffer yields EXACTLY 480 frames.
        for _ in 0..<10 {
            let input = try #require(pcm(rate: 44_100, channels: 2, frames: 441))
            let output = try #require(converter.convert(input))
            outputs.append(Int(output.frameLength))
        }
        #expect(outputs.dropFirst().allSatisfy { $0 == 480 })
        #expect(outputs.reduce(0, +) >= 4_780)
    }

    @Test func int16SourceConvertsToFloat() throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                         sampleRate: 48_000, channels: 2,
                                         interleaved: true),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256)
        else { Issue.record("format/buffer alloc failed"); return }
        buffer.frameLength = 256
        let data = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)[0]
            .mData!.assumingMemoryBound(to: Int16.self)
        for index in 0..<512 { data[index] = Int16.max / 2 }
        let output = try #require(CanonicalAudioConverter().convert(buffer))
        let floats = try #require(CanonicalAudioConverter.interleavedFloats(output))
        #expect(floats.count == 512)
        #expect(abs(floats[0] - 0.5) < 0.01)
    }

    @Test func deinterleavedFloatBecomesInterleaved() throws {
        let input = try #require(pcm(rate: 48_000, channels: 2, interleaved: false,
                                     frames: 128, value: 0.75))
        let output = try #require(CanonicalAudioConverter().convert(input))
        #expect(output.format.isInterleaved)
        let floats = try #require(CanonicalAudioConverter.interleavedFloats(output))
        #expect(floats.count == 256)
        #expect(abs(floats[0] - 0.75) < 0.001)
    }
}
