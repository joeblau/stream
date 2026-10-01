import CoreMedia
import Testing
import StreamCore

/// Tests for the A08 per-channel FX chain (issue #120). Mirrors the
/// VoicePolishProcessor suite: interleaved Float32 LPCM `CMSampleBuffer`s in,
/// measured output out. Gain comparisons are RELATIVE (tone under test vs a
/// ~flat 2.5 kHz reference) so the compressor's makeup gain cancels out.
@Suite struct ChannelFXProcessorTests {

    // MARK: - PCM helpers

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

    /// Processes a 2 s tone through a fresh processor running `chain` and
    /// returns its output RMS (long enough for the compressor's envelope to
    /// settle into steady state).
    private func processedRMS(frequency: Double, amplitude: Float,
                              chain: ChannelFXChain,
                              processor: ChannelFXProcessor = ChannelFXProcessor()) -> Double {
        guard let sb = makeBuffer(samples: tone(frequency: frequency, amplitude: amplitude,
                                                seconds: 2),
                                  sampleRate: 48_000, channels: 1, pts: .zero) else {
            Issue.record("failed to synthesize tone buffer")
            return 0
        }
        return rms(floatSamples(processor.process(sb, chain: chain)))
    }

    // MARK: - Model (presets, validation, bypass semantics)

    @Test("The Off preset runs no sections; every named preset runs at least one")
    func presetActivity() {
        #expect(!ChannelFXChain.preset(.off).isActive)
        #expect(ChannelFXChain.preset(.voice).isActive)
        #expect(ChannelFXChain.preset(.podcast).isActive)
        #expect(ChannelFXChain.preset(.music).isActive)
    }

    @Test("The fixed effect order is high-pass, gate, EQ, compressor, limiter")
    func effectOrderIsFixedAndVisible() {
        #expect(ChannelFXChain.effectOrder
            == ["High-Pass", "Noise Gate", "EQ", "Compressor", "Limiter"])
        #expect(ChannelFXChain.latencySeconds == 0)
    }

    @Test("Preset chains validate; out-of-range values are rejected with a reason")
    func validation() {
        #expect(ChannelFXChain.preset(.voice).validationError == nil)
        #expect(ChannelFXChain.preset(.podcast).validationError == nil)
        #expect(ChannelFXChain.preset(.music).validationError == nil)
        var chain = ChannelFXChain.preset(.voice)
        chain.compressor.ratio = 42
        #expect(chain.validationError != nil)
        chain = ChannelFXChain.preset(.voice)
        chain.limiter.ceiling = .nan
        #expect(chain.validationError != nil)
    }

    // MARK: - Zero-cost bypass

    @Test("An inactive chain returns the SAME buffer object — zero-cost passthrough")
    func offChainIsIdentity() {
        guard let sb = makeBuffer(samples: tone(frequency: 500, amplitude: 0.2, seconds: 0.25),
                                  sampleRate: 48_000, channels: 1, pts: .zero) else {
            Issue.record("failed to synthesize tone buffer")
            return
        }
        let out = ChannelFXProcessor().process(sb, chain: .preset(.off))
        #expect(out === sb)
    }

    // MARK: - EQ (voice preset voices the polish curve)

    @Test("Voice preset: 100 Hz sits well above the 2.5 kHz reference")
    func lowBandBoost() {
        let chain = ChannelFXChain.preset(.voice)
        let reference = processedRMS(frequency: 2_500, amplitude: 0.02, chain: chain)
        let chest = processedRMS(frequency: 100, amplitude: 0.02, chain: chain)
        // The low shelf is configured for +3 dB, not strictly more than
        // +3 dB. Its finite slope, the high-pass, and the reference band's
        // response shift the measured whole-chain result slightly. Keep a
        // narrow tolerance that still rejects bypass or the wrong gain.
        let boost = 20 * log10(chest / reference)
        #expect((2.5...3.5).contains(boost))
    }

    @Test("Voice preset: 1150 Hz dips below the 2.5 kHz reference")
    func midrangeDip() {
        let chain = ChannelFXChain.preset(.voice)
        let reference = processedRMS(frequency: 2_500, amplitude: 0.02, chain: chain)
        let boxy = processedRMS(frequency: 1_150, amplitude: 0.02, chain: chain)
        #expect(20 * log10(boxy / reference) < -1)
    }

    @Test("Voice preset: 6 kHz sits above the 2.5 kHz reference")
    func presenceBoost() {
        let chain = ChannelFXChain.preset(.voice)
        let reference = processedRMS(frequency: 2_500, amplitude: 0.02, chain: chain)
        let presence = processedRMS(frequency: 6_000, amplitude: 0.02, chain: chain)
        #expect(20 * log10(presence / reference) > 2)
    }

    // MARK: - Dynamics and gate

    @Test("A loud tone is held under the limiter ceiling despite EQ + makeup gain")
    func limiterCeilingHolds() {
        guard let sb = makeBuffer(samples: tone(frequency: 500, amplitude: 0.5, seconds: 2),
                                  sampleRate: 48_000, channels: 1, pts: .zero) else {
            Issue.record("failed to synthesize tone buffer")
            return
        }
        let out = floatSamples(ChannelFXProcessor().process(sb, chain: .preset(.voice)))
        #expect(peak(out) < 0.95)
        #expect(rms(out) < rms(tone(frequency: 500, amplitude: 0.5, seconds: 2)) * 2)
    }

    @Test("The podcast gate expands a quiet tone away but passes speech level")
    func noiseGateAttenuatesQuietSignal() {
        let chain = ChannelFXChain.preset(.podcast)
        // −60 dBFS tone: below the −50 dB gate threshold → expanded down.
        let quiet = processedRMS(frequency: 300, amplitude: 0.001, chain: chain)
        // −20 dBFS tone: above the threshold → passes (with compressor gain).
        let speech = processedRMS(frequency: 300, amplitude: 0.1, chain: chain)
        #expect(20 * log10(speech / max(quiet, 1e-9)) > 20)
    }

    @Test("Silence in stays silence out through a full chain")
    func silenceStaysSilent() {
        guard let sb = makeBuffer(samples: [Float](repeating: 0, count: 48_000),
                                  sampleRate: 48_000, channels: 1, pts: .zero) else {
            Issue.record("failed to synthesize silence buffer")
            return
        }
        let out = ChannelFXProcessor().process(sb, chain: .preset(.podcast))
        #expect(peak(floatSamples(out)) < 1e-5)
    }

    // MARK: - Live chain updates and continuity

    @Test("A chain swap mid-stream applies on the next buffer without a reset")
    func liveParameterUpdate() {
        let processor = ChannelFXProcessor()
        // Warm the graph up with the voice chain, then swap in a chain whose
        // EQ scoops 2.5 kHz hard — the SAME processor must apply it.
        let voice = ChannelFXChain.preset(.voice)
        var scooped = ChannelFXChain.preset(.music)
        scooped.equalizer = ChannelFXChain.Equalizer(
            isEnabled: true, lowGain: 0, midFrequency: 2_500, midGain: -12, highGain: 0)
        let reference = processedRMS(frequency: 2_500, amplitude: 0.02, chain: voice,
                                     processor: processor)
        let after = processedRMS(frequency: 2_500, amplitude: 0.02, chain: scooped,
                                 processor: processor)
        #expect(20 * log10(after / reference) < -3)
    }

    @Test("Channel count, frame count, and PTS survive processing verbatim")
    func continuityPreserved() {
        let pts = CMTime(value: 12_000, timescale: 600)
        guard let sb = makeBuffer(samples: tone(frequency: 500, amplitude: 0.02,
                                                seconds: 0.5, channels: 2),
                                  sampleRate: 48_000, channels: 2, pts: pts) else {
            Issue.record("failed to synthesize tone buffer")
            return
        }
        let out = ChannelFXProcessor().process(sb, chain: .preset(.podcast))
        let asbd = CMSampleBufferGetFormatDescription(out)
            .flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
        #expect(asbd?.mChannelsPerFrame == 2)
        #expect(CMSampleBufferGetNumSamples(out) == CMSampleBufferGetNumSamples(sb))
        #expect(out.presentationTimeStamp == pts)
        #expect(abs(CMTimeGetSeconds(out.duration) - 0.5) < 0.001)
    }

    @Test("A mid-stream format change rebuilds the chain and returns valid audio")
    func formatChangeRebuild() {
        let processor = ChannelFXProcessor()
        let chain = ChannelFXChain.preset(.voice)
        guard let first = makeBuffer(samples: tone(frequency: 500, amplitude: 0.02, seconds: 0.25),
                                     sampleRate: 48_000, channels: 1, pts: .zero),
              let second = makeBuffer(samples: tone(frequency: 500, amplitude: 0.02, seconds: 0.25,
                                                    sampleRate: 44_100, channels: 2),
                                      sampleRate: 44_100, channels: 2, pts: .zero) else {
            Issue.record("failed to synthesize tone buffers")
            return
        }
        _ = processor.process(first, chain: chain)
        let out = processor.process(second, chain: chain)
        let asbd = CMSampleBufferGetFormatDescription(out)
            .flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
        #expect(asbd?.mSampleRate == 44_100)
        #expect(asbd?.mChannelsPerFrame == 2)
        #expect(CMSampleBufferGetNumSamples(out) == CMSampleBufferGetNumSamples(second))
        #expect(peak(floatSamples(out)) > 0.001)
    }

    // MARK: - Back-compat mapping

    @Test("A channel with no persisted chain follows the legacy voice-polish toggle")
    func legacyVoicePolishMapping() {
        var settings = StreamSettings()
        settings.voicePolishEnabled = true
        #expect(settings.fxChain(forChannelLabel: "mic.default").preset == .voice)
        settings.voicePolishEnabled = false
        #expect(settings.fxChain(forChannelLabel: "mic.default").preset == .off)
        // A persisted chain wins over the toggle either way.
        settings.channelFX["mic.default"] = .preset(.music)
        #expect(settings.fxChain(forChannelLabel: "mic.default").preset == .music)
    }

    @Test("Pre-A08 settings blobs (no channelFX key) decode to an empty chain map")
    func additiveDecoding() throws {
        let legacy = try JSONDecoder().decode(
            StreamSettings.self,
            from: Data(#"{"selectedProtocol":"rtmp"}"#.utf8))
        #expect(legacy.channelFX.isEmpty)
        #expect(legacy.fxChain(forChannelLabel: "mic.default").preset == .voice)
        // Round-trip: chains persist.
        var settings = StreamSettings()
        settings.channelFX["mic.usb"] = .preset(.podcast)
        let encoded = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(StreamSettings.self, from: encoded)
        #expect(decoded.channelFX["mic.usb"] == .preset(.podcast))
    }
}
