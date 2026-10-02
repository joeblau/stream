import CoreMedia
import Testing
import StreamCore

/// Tests for the Apple-native voice-polish chain. Each test synthesizes interleaved
/// Float32 LPCM `CMSampleBuffer`s (the same layout ScreenCaptureKit delivers) and
/// measures the processed output. Gain comparisons are RELATIVE (tone under test vs
/// a ~flat 2.5 kHz reference) so the compressors' fixed +4 dB makeup cancels out.
@Suite struct VoicePolishProcessorTests {

    // MARK: - PCM helpers

    /// Builds an interleaved Float32 LPCM sample buffer holding `samples`
    /// (`frames` frames × `channels` interleaved), stamped at `pts`.
    private func makeBuffer(samples: [Float], sampleRate: Double,
                            channels: UInt32, pts: CMTime) -> CMSampleBuffer? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(MemoryLayout<Float>.size) * channels,
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float>.size) * channels,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 8 * UInt32(MemoryLayout<Float>.size),
            mReserved: 0
        )
        var description: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd,
                                             layoutSize: 0, layout: nil,
                                             magicCookieSize: 0, magicCookie: nil,
                                             extensions: nil,
                                             formatDescriptionOut: &description) == noErr,
              let description else { return nil }
        let byteCount = samples.count * MemoryLayout<Float>.size
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: byteCount,
            blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: byteCount, flags: 0,
            blockBufferOut: &blockBuffer
        ) == noErr, let blockBuffer else { return nil }
        guard CMBlockBufferReplaceDataBytes(with: samples, blockBuffer: blockBuffer,
                                            offsetIntoDestination: 0,
                                            dataLength: byteCount) == noErr else { return nil }
        var sb: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: blockBuffer, formatDescription: description,
            sampleCount: samples.count / Int(channels),
            presentationTimeStamp: pts, packetDescriptions: nil,
            sampleBufferOut: &sb
        ) == noErr else { return nil }
        return sb
    }

    private func tone(frequency: Double, amplitude: Float, seconds: Double,
                      sampleRate: Double = 48_000, channels: Int = 1) -> [Float] {
        let frames = Int(seconds * sampleRate)
        var samples = [Float](repeating: 0, count: frames * channels)
        for frame in 0..<frames {
            let value = amplitude * Float(sin(2 * Double.pi * frequency * Double(frame) / sampleRate))
            for channel in 0..<channels { samples[frame * channels + channel] = value }
        }
        return samples
    }

    /// Reads the (interleaved Float32) PCM payload back out of a sample buffer.
    private func floatSamples(_ sb: CMSampleBuffer) -> [Float] {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sb) else { return [] }
        var length = 0
        var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0,
                                          lengthAtOffsetOut: nil,
                                          totalLengthOut: &length,
                                          dataPointerOut: &pointer) == noErr,
              let pointer else { return [] }
        let raw = UnsafeRawBufferPointer(start: pointer, count: length)
        return Array(raw.bindMemory(to: Float.self))
    }

    private func rms(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        return (sum / Double(samples.count)).squareRoot()
    }

    private func peak(_ samples: [Float]) -> Float {
        samples.reduce(0) { max($0, abs($1)) }
    }

    /// Processes a 2 s tone through a fresh processor and returns its output RMS.
    /// Long enough for both compressors' envelopes to settle into steady state.
    private func processedRMS(frequency: Double, amplitude: Float,
                              sampleRate: Double = 48_000,
                              processor: VoicePolishProcessor = VoicePolishProcessor()) -> Double {
        guard let sb = makeBuffer(samples: tone(frequency: frequency, amplitude: amplitude,
                                                seconds: 2, sampleRate: sampleRate),
                                  sampleRate: sampleRate, channels: 1, pts: .zero) else {
            Issue.record("failed to synthesize tone buffer")
            return 0
        }
        return rms(floatSamples(processor.process(sb)))
    }

    // MARK: - EQ

    @Test("Chest weight: 100 Hz is boosted well above the 2.5 kHz reference")
    func lowBandBoost() {
        let reference = processedRMS(frequency: 2_500, amplitude: 0.02)
        let chest = processedRMS(frequency: 100, amplitude: 0.02)
        #expect(20 * log10(chest / reference) > 3)
    }

    @Test("Boxy midrange: 1150 Hz dips below the 2.5 kHz reference")
    func midrangeDip() {
        let reference = processedRMS(frequency: 2_500, amplitude: 0.02)
        let boxy = processedRMS(frequency: 1_150, amplitude: 0.02)
        #expect(20 * log10(boxy / reference) < -1)
    }

    @Test("Presence/air: 6 kHz sits above the 2.5 kHz reference")
    func presenceBoost() {
        let reference = processedRMS(frequency: 2_500, amplitude: 0.02)
        let presence = processedRMS(frequency: 6_000, amplitude: 0.02)
        #expect(20 * log10(presence / reference) > 2)
    }

    // MARK: - Dynamics

    @Test("A loud tone is held under the −1.5 dBFS ceiling despite EQ + makeup gain")
    func limiterCeilingHolds() {
        // −6 dBFS tone: EQ + the two +2 dB makeup stages would push it far over
        // full scale without the compressors and limiter engaging.
        guard let sb = makeBuffer(samples: tone(frequency: 500, amplitude: 0.5, seconds: 2),
                                  sampleRate: 48_000, channels: 1, pts: .zero) else {
            Issue.record("failed to synthesize tone buffer")
            return
        }
        let out = floatSamples(VoicePolishProcessor().process(sb))
        #expect(peak(out) < 0.95)
        #expect(rms(out) < rms(tone(frequency: 500, amplitude: 0.5, seconds: 2)) * 2)
    }

    @Test("Silence in stays silence out")
    func silenceStaysSilent() {
        guard let sb = makeBuffer(samples: [Float](repeating: 0, count: 48_000),
                                  sampleRate: 48_000, channels: 1, pts: .zero) else {
            Issue.record("failed to synthesize silence buffer")
            return
        }
        #expect(peak(floatSamples(VoicePolishProcessor().process(sb))) < 1e-5)
    }

    // MARK: - Container/timing

    @Test("Presentation time and duration survive processing verbatim")
    func timingPreserved() {
        let pts = CMTime(value: 12_000, timescale: 600)
        guard let sb = makeBuffer(samples: tone(frequency: 500, amplitude: 0.02, seconds: 0.5),
                                  sampleRate: 48_000, channels: 1, pts: pts) else {
            Issue.record("failed to synthesize tone buffer")
            return
        }
        let out = VoicePolishProcessor().process(sb)
        #expect(out.presentationTimeStamp == pts)
        #expect(abs(CMTimeGetSeconds(out.duration) - 0.5) < 0.001)
    }

    @Test("A mid-stream format change rebuilds the chain and returns valid audio")
    func formatChangeRebuild() {
        let processor = VoicePolishProcessor()
        guard let first = makeBuffer(samples: tone(frequency: 500, amplitude: 0.02, seconds: 0.25),
                                     sampleRate: 48_000, channels: 1, pts: .zero),
              let second = makeBuffer(samples: tone(frequency: 500, amplitude: 0.02, seconds: 0.25,
                                                    sampleRate: 44_100, channels: 2),
                                      sampleRate: 44_100, channels: 2, pts: .zero) else {
            Issue.record("failed to synthesize tone buffers")
            return
        }
        _ = processor.process(first)
        let out = processor.process(second)
        let asbd = CMSampleBufferGetFormatDescription(out)
            .flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
        #expect(asbd?.mSampleRate == 44_100)
        #expect(asbd?.mChannelsPerFrame == 2)
        #expect(CMSampleBufferGetNumSamples(out) == CMSampleBufferGetNumSamples(second))
        #expect(peak(floatSamples(out)) > 0.001)
    }

    @Test("A non-LPCM buffer passes through untouched")
    func nonLPCMPassthrough() {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: 1_024, mBytesPerFrame: 0,
            mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0
        )
        var description: CMAudioFormatDescription?
        var bytes: [UInt8] = [0x11, 0x22, 0x33, 0x44]
        var packet = AudioStreamPacketDescription(mStartOffset: 0,
                                                  mVariableFramesInPacket: 0,
                                                  mDataByteSize: 4)
        var blockBuffer: CMBlockBuffer?
        var sb: CMSampleBuffer?
        guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd,
                                             layoutSize: 0, layout: nil,
                                             magicCookieSize: 0, magicCookie: nil,
                                             extensions: nil,
                                             formatDescriptionOut: &description) == noErr,
              let description,
              CMBlockBufferCreateWithMemoryBlock(
                  allocator: nil, memoryBlock: nil, blockLength: bytes.count,
                  blockAllocator: nil, customBlockSource: nil,
                  offsetToData: 0, dataLength: bytes.count, flags: 0,
                  blockBufferOut: &blockBuffer
              ) == noErr, let blockBuffer,
              CMBlockBufferReplaceDataBytes(with: &bytes, blockBuffer: blockBuffer,
                                            offsetIntoDestination: 0,
                                            dataLength: bytes.count) == noErr,
              CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                  allocator: nil, dataBuffer: blockBuffer, formatDescription: description,
                  // One compressed packet has one description. Its ASBD
                  // declares 1,024 decoded frames; that is not the packet count.
                  sampleCount: 1, presentationTimeStamp: .zero,
                  packetDescriptions: &packet,
                  sampleBufferOut: &sb
              ) == noErr, let sb else {
            Issue.record("failed to synthesize AAC buffer")
            return
        }
        #expect(CMSampleBufferGetNumSamples(sb) == 1)
        #expect(abs(CMTimeGetSeconds(CMSampleBufferGetDuration(sb)) - 1_024.0 / 48_000) < 0.000_001)
        #expect(VoicePolishProcessor().process(sb) === sb)
    }
}
