import AudioToolbox
import AVFAudio
import CoreMedia
import os

/// `AVAudioConverterInputBlock` is `@Sendable` in the iOS 26 SDK. Keep its
/// one-shot input state behind a lock instead of capturing a mutable local —
/// the same confined box VoicePolishProcessor uses.
private final class FXConverterInputState: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private var lock = os_unfair_lock_s()
    private var consumed = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func next(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        os_unfair_lock_lock(&lock)
        let hasData = !consumed
        consumed = true
        os_unfair_lock_unlock(&lock)

        if hasData {
            status.pointee = .haveData
            return buffer
        }
        status.pointee = .endOfStream
        return nil
    }
}

/// A08 (issue #120): the configurable per-channel effect chain — the
/// controllable successor to `VoicePolishProcessor`'s fixed curve, running
/// the same Apple-native, offline-render graph pattern on the capture thread:
///
///   player → AVAudioUnitEQ (high-pass + 3 bands) → gate (DynamicsProcessor,
///   downward expansion) → compressor (DynamicsProcessor) → PeakLimiter
///   → mainMixer
///
/// The effect ORDER is fixed and matches `ChannelFXChain.effectOrder`; each
/// section's enable maps to band bypass / `shouldBypassEffect`, so toggling a
/// section never rebuilds the graph and preserves channel count, timing, and
/// audio continuity (the issue's criteria). Exactly the input frame count is
/// rendered per call — the chain adds ZERO latency
/// (`ChannelFXChain.latencySeconds`).
///
/// **Live parameter updates** (no capture restarts): the caller hands the
/// latest `ChannelFXChain` to every `process(_:chain:)` call — the chain is a
/// tiny value type the owning insert box swaps under a lock, so the audio
/// thread never blocks on UI work. A changed chain re-writes the AU
/// parameters in place (thread-safe `AUParameterTree` writes); an unchanged
/// one costs one value comparison. An inactive chain
/// (`ChannelFXChain.isActive == false`) takes the zero-cost identity path:
/// the SAME buffer object is returned and no engine is ever built.
///
/// Failure policy matches VoicePolishProcessor: any format/engine/render
/// problem logs once and returns the input UNCHANGED — FX must never drop or
/// mute a source. Unavailable native processing modes (true broadband
/// denoise, de-esser) are documented on the chain model; they arrive through
/// A11 (Audio Unit hosting).
///
/// Not `Sendable`: each channel's insert owns its own instance, confined to
/// the channel's ingest lock (the same confinement the publishers gave their
/// VoicePolishProcessor instances).
public final class ChannelFXProcessor {

    private static let log = Logger(subsystem: "com.joeblau.Stream", category: "channel-fx")

    /// Upper bound per `renderOffline` call (see VoicePolishProcessor).
    private static let maxRenderFrames: AVAudioFrameCount = 4096

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var eq: AVAudioUnitEQ?
    private var gate: AVAudioUnitEffect?
    private var compressor: AVAudioUnitEffect?
    private var limiter: AVAudioUnitEffect?
    /// Engine/render format: deinterleaved Float32 PCM at the source's rate
    /// and channels.
    private var renderFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var builtRate = 0.0
    private var builtChannels: UInt32 = 0
    private var outputFormatDescription: CMAudioFormatDescription?
    /// The chain last written onto the graph; `process` re-applies on change.
    private var appliedChain: ChannelFXChain?
    private var didLogFailure = false

    public init() {}

    /// Tears the engine down so the next buffer rebuilds it (graph state must
    /// never leak across broadcast sessions — same rule as VoicePolish).
    public func reset() {
        engine?.stop()
        engine = nil
        player = nil
        eq = nil
        gate = nil
        compressor = nil
        limiter = nil
        converter = nil
        renderFormat = nil
        outputFormatDescription = nil
        builtRate = 0
        builtChannels = 0
        appliedChain = nil
    }

    /// Runs one buffer through the chain. Timing is preserved verbatim
    /// (source PTS; duration from the frame count); an inactive chain or any
    /// failure returns the input unchanged.
    public func process(_ sampleBuffer: CMSampleBuffer, chain: ChannelFXChain) -> CMSampleBuffer {
        // Zero-cost bypass: Off preset / all sections disabled.
        guard chain.isActive else { return sampleBuffer }
        guard let asbd = CMSampleBufferGetFormatDescription(sampleBuffer)
                .flatMap({ CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }),
              asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mSampleRate > 0, asbd.mChannelsPerFrame > 0 else {
            return sampleBuffer
        }
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else { return sampleBuffer }

        if engine == nil || builtRate != asbd.mSampleRate || builtChannels != asbd.mChannelsPerFrame {
            reset()
            guard buildEngine(sampleRate: asbd.mSampleRate, channels: asbd.mChannelsPerFrame) else {
                return fail(sampleBuffer, "engine build failed")
            }
            var sourceASBD = asbd
            guard let sourceFormat = AVAudioFormat(streamDescription: &sourceASBD) else {
                return fail(sampleBuffer, "source format unsupported")
            }
            converter = AVAudioConverter(from: sourceFormat, to: renderFormat!)
        }
        guard let engine, let player, let renderFormat, let converter,
              let outputFormatDescription else {
            return fail(sampleBuffer, "engine not ready")
        }
        // Live parameter update: write the chain onto the graph only when it
        // changed (value-type diff — no per-buffer cost when idle).
        applyChain(chain)

        // 1. Source AudioBufferList → render-format AVAudioPCMBuffer.
        guard let sourcePCM = VoicePolishProcessor.extractPCM(
                sampleBuffer, asbd: asbd, frameCount: AVAudioFrameCount(frameCount)) else {
            return fail(sampleBuffer, "could not read source PCM")
        }
        guard let input = AVAudioPCMBuffer(pcmFormat: renderFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return fail(sampleBuffer, "input buffer alloc failed")
        }
        input.frameLength = AVAudioFrameCount(frameCount)
        do {
            let inputState = FXConverterInputState(buffer: sourcePCM)
            var converterError: NSError?
            let status = converter.convert(to: input, error: &converterError) { _, outStatus in
                inputState.next(status: outStatus)
            }
            guard status != .error, converterError == nil else {
                return fail(sampleBuffer, "format conversion failed")
            }
        }

        // 2. Schedule the whole input, then render it out in chunks (exactly
        // the converter's output count — asking for unscheduled frames would
        // starve the render into passthrough).
        let framesToRender = Int(input.frameLength)
        guard framesToRender > 0 else { return fail(sampleBuffer, "conversion produced no frames") }
        player.scheduleBuffer(input, completionHandler: nil)
        let interleaved = UnsafeMutablePointer<Float>.allocate(capacity: framesToRender * Int(asbd.mChannelsPerFrame))
        defer { interleaved.deallocate() }
        var renderedFrames = 0
        let channels = Int(renderFormat.channelCount)
        while renderedFrames < framesToRender {
            let chunk = min(Self.maxRenderFrames, AVAudioFrameCount(framesToRender - renderedFrames))
            guard let out = AVAudioPCMBuffer(pcmFormat: renderFormat, frameCapacity: chunk) else {
                return fail(sampleBuffer, "output buffer alloc failed")
            }
            do {
                let status = try engine.renderOffline(chunk, to: out)
                guard status != .error else {
                    return fail(sampleBuffer, "offline render failed")
                }
            } catch {
                return fail(sampleBuffer, "offline render threw")
            }
            let got = Int(out.frameLength)
            guard got > 0 else { return fail(sampleBuffer, "offline render starved") }
            guard let channelData = out.floatChannelData else {
                return fail(sampleBuffer, "render output not float")
            }
            for frame in 0..<got {
                for channel in 0..<channels {
                    interleaved[(renderedFrames + frame) * channels + channel] = channelData[channel][frame]
                }
            }
            renderedFrames += got
        }

        // 3. Repack as a CMSampleBuffer with the source timing.
        let byteCount = renderedFrames * channels * MemoryLayout<Float>.size
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: byteCount,
            blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: byteCount, flags: 0,
            blockBufferOut: &blockBuffer
        ) == noErr, let blockBuffer else {
            return fail(sampleBuffer, "block buffer alloc failed")
        }
        guard CMBlockBufferReplaceDataBytes(
            with: interleaved, blockBuffer: blockBuffer,
            offsetIntoDestination: 0, dataLength: byteCount
        ) == noErr else {
            return fail(sampleBuffer, "block buffer fill failed")
        }
        var out: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: blockBuffer,
            formatDescription: outputFormatDescription,
            sampleCount: renderedFrames,
            presentationTimeStamp: sampleBuffer.presentationTimeStamp,
            packetDescriptions: nil,
            sampleBufferOut: &out
        ) == noErr, let out else {
            return fail(sampleBuffer, "sample buffer wrap failed")
        }
        return out
    }

    // MARK: - Engine construction

    /// Builds and starts the manual-rendering graph at the source's live
    /// format, with every section bypassed; `applyChain` then writes the
    /// real parameters. Returns false (→ passthrough) on any failure.
    private func buildEngine(sampleRate: Double, channels: UInt32) -> Bool {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sampleRate,
                                         channels: AVAudioChannelCount(channels),
                                         interleaved: false) else { return false }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        // 4 bands, fixed roles: 0 high-pass, 1 low shelf, 2 parametric mid,
        // 3 high shelf.
        let eq = AVAudioUnitEQ(numberOfBands: 4)
        let gate = VoicePolishProcessor.effect(kAudioUnitSubType_DynamicsProcessor)
        let compressor = VoicePolishProcessor.effect(kAudioUnitSubType_DynamicsProcessor)
        let limiter = VoicePolishProcessor.effect(kAudioUnitSubType_PeakLimiter)

        for node in [player, eq, gate, compressor, limiter] { engine.attach(node) }
        engine.connect(player, to: eq, format: format)
        engine.connect(eq, to: gate, format: format)
        engine.connect(gate, to: compressor, format: format)
        engine.connect(compressor, to: limiter, format: format)
        engine.connect(limiter, to: engine.mainMixerNode, format: format)

        do {
            try engine.enableManualRenderingMode(.offline, format: format,
                                                 maximumFrameCount: Self.maxRenderFrames)
            try engine.start()
        } catch {
            return false
        }
        player.play()

        var outASBD = AudioStreamBasicDescription(
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
        guard CMAudioFormatDescriptionCreate(allocator: nil,
                                             asbd: &outASBD,
                                             layoutSize: 0, layout: nil,
                                             magicCookieSize: 0, magicCookie: nil,
                                             extensions: nil,
                                             formatDescriptionOut: &description) == noErr,
              let description else { return false }

        self.engine = engine
        self.player = player
        self.eq = eq
        self.gate = gate
        self.compressor = compressor
        self.limiter = limiter
        self.renderFormat = format
        self.outputFormatDescription = description
        self.builtRate = sampleRate
        self.builtChannels = channels
        self.appliedChain = nil
        self.didLogFailure = false
        return true
    }

    // MARK: - Live chain application

    /// Writes a changed chain onto the running graph: EQ band parameters and
    /// per-band bypass, the gate's expansion region, the compressor's
    /// dynamics mapping (headRoom = |threshold| / ratio), and the limiter's
    /// ceiling. Section enables map to bypass flags — the graph never
    /// rebuilds, so a toggle mid-stream keeps the buffer stream continuous.
    private func applyChain(_ chain: ChannelFXChain) {
        guard appliedChain != chain, let eq, let gate, let compressor, let limiter else { return }
        appliedChain = chain

        eq.globalGain = 0
        let bands = eq.bands
        // Band 0 — high-pass.
        bands[0].filterType = .highPass
        bands[0].frequency = Float(chain.highPass.frequency)
        bands[0].bypass = !chain.highPass.isEnabled
        // Band 1 — low shelf at 250 Hz.
        bands[1].filterType = .lowShelf
        bands[1].frequency = 250
        bands[1].gain = Float(chain.equalizer.lowGain)
        bands[1].bypass = !chain.equalizer.isEnabled
        // Band 2 — sweepable parametric mid, 1-octave width (the voice-chain
        // default VoicePolishProcessor documents).
        bands[2].filterType = .parametric
        bands[2].frequency = Float(chain.equalizer.midFrequency)
        bands[2].gain = Float(chain.equalizer.midGain)
        bands[2].bandwidth = 1.0
        bands[2].bypass = !chain.equalizer.isEnabled
        // Band 3 — high shelf at 6 kHz.
        bands[3].filterType = .highShelf
        bands[3].frequency = 6_000
        bands[3].gain = Float(chain.equalizer.highGain)
        bands[3].bypass = !chain.equalizer.isEnabled

        // Noise gate = the DynamicsProcessor's downward-expansion region.
        // Threshold 0 keeps the compression region out of reach of any legal
        // signal (input ≤ 0 dBFS); headRoom 0.1 (the AU's floor) is
        // effectively no compression, so the unit ONLY expands — ratio 12:1
        // below the gate threshold is effectively a gate.
        VoicePolishProcessor.configureDynamics(
            gate, threshold: 0, headRoom: 0.1,
            attack: 0.002, release: 0.150, makeup: 0)
        VoicePolishProcessor.setParameter(
            gate, address: AUParameterAddress(kDynamicsProcessorParam_ExpansionThreshold),
            value: Float(chain.noiseGate.threshold))
        VoicePolishProcessor.setParameter(
            gate, address: AUParameterAddress(kDynamicsProcessorParam_ExpansionRatio),
            value: 12)
        gate.auAudioUnit.shouldBypassEffect = !chain.noiseGate.isEnabled

        let c = chain.compressor
        VoicePolishProcessor.configureDynamics(
            compressor,
            threshold: Float(c.threshold),
            headRoom: Float(abs(c.threshold) / max(c.ratio, 1)),
            attack: Float(c.attackMs / 1_000),
            release: Float(c.releaseMs / 1_000),
            makeup: Float(c.makeupGain))
        compressor.auAudioUnit.shouldBypassEffect = !c.isEnabled

        VoicePolishProcessor.setParameter(
            limiter, address: AUParameterAddress(kLimiterParam_PreGain),
            value: Float(chain.limiter.ceiling))
        limiter.auAudioUnit.shouldBypassEffect = !chain.limiter.isEnabled
    }

    /// One-shot failure log + passthrough. FX degrade to dry source, never
    /// silence (the VoicePolishProcessor contract).
    private func fail(_ sampleBuffer: CMSampleBuffer, _ reason: String) -> CMSampleBuffer {
        if !didLogFailure {
            didLogFailure = true
            Self.log.error("Channel FX passthrough: \(reason, privacy: .public)")
        }
        return sampleBuffer
    }
}
