import AudioToolbox
import AVFAudio
import CoreMedia
import os

/// `AVAudioConverterInputBlock` is `@Sendable` in the iOS 26 SDK. Keep its
/// one-shot input state behind a lock instead of capturing a mutable local, and
/// explicitly carry the non-Sendable AVAudioPCMBuffer inside this confined box.
private final class ConverterInputState: @unchecked Sendable {
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

/// Broadcast-style vocal chain applied to live mic buffers, ported from sludge's
/// `VOICE_POLISH` ffmpeg graph onto Apple-native audio units — no FFmpeg, no
/// third-party DSP. Runs inside an `AVAudioEngine` in manual (offline) rendering
/// mode, so it processes `CMSampleBuffer`s synchronously on the caller's thread
/// with no audio hardware involved:
///
///   player → AVAudioUnitEQ (7 bands) → DynamicsProcessor (fast)
///          → DynamicsProcessor (slow) → PeakLimiter → mainMixer
///
/// Chain mapping (sludge ffmpeg → AU settings):
///
///   highpass=f=30                    → EQ band 0: .highPass 30 Hz
///   lowshelf=f=800:g=+7.5:w=0.35     → EQ band 1: .lowShelf 800 Hz, +7.5 dB, 0.35 oct
///   equalizer=f=140:g=+3             → EQ band 2: .parametric 140 Hz, +3 dB
///   equalizer=f=1150:g=-2.5          → EQ band 3: .parametric 1150 Hz, −2.5 dB
///   equalizer=f=4200:g=+3            → EQ band 4: .parametric 4200 Hz, +3 dB
///   highshelf=f=3400:g=+5.5          → EQ band 5: .highShelf 3400 Hz, +5.5 dB
///   equalizer=f=8500:g=+2            → EQ band 6: .parametric 8500 Hz, +2 dB
///   acompressor fast −22 dB/3:1, 12 ms/160 ms, +2 mk
///       → DynamicsProcessor #1: Threshold −22, HeadRoom 7.3, Attack 0.012,
///         Release 0.160, OverallGain +2
///   acompressor slow −26 dB/2.5:1, 200 ms/1.5 s, +2 mk
///       → DynamicsProcessor #2: Threshold −26, HeadRoom 10.4, Attack 0.200,
///         Release 1.5, OverallGain +2
///   alimiter=limit=-1.5dB            → PeakLimiter PreGain −1.5 (ceiling −1.5 dBFS)
///
/// Two translation notes:
///
/// - AUDynamicsProcessor has no literal ratio parameter: it compresses so a full-scale
///   input lands at threshold + headRoom, giving effective ratio = |threshold| /
///   headRoom — hence headRoom = |threshold| / ratio (22/3 ≈ 7.3, 26/2.5 = 10.4).
/// - sludge's trailing `loudnorm=I=-14:TP=-1.5` is NOT ported: two-pass loudness
///   normalization has no live equivalent. Its job (hot output, −1.5 dBTP ceiling) is
///   covered by the two +2 dB makeup stages and the limiter ceiling.
///
/// The engine persists across buffers, so EQ/compressor state carries continuously —
/// the same "no pumping at seams" property sludge gets by processing the uncut take.
/// Exactly the input frame count is rendered per call, so no latency accumulates.
///
/// Failure policy: any format/engine/convert/render problem logs once and returns the
/// input buffer UNCHANGED. Polish must never drop or mute the mic.
///
/// Not `Sendable`: each publisher actor owns its own instance and confines it.
public final class VoicePolishProcessor {

    private static let log = Logger(subsystem: "com.joeblau.Stream", category: "voice-polish")

    /// Upper bound per `renderOffline` call. Mic buffers are typically 1024 frames;
    /// larger ones are rendered in chunks.
    private static let maxRenderFrames: AVAudioFrameCount = 4096

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    /// Engine/render format: deinterleaved Float32 PCM at the mic's rate and channels.
    private var renderFormat: AVAudioFormat?
    /// Converts the source LPCM layout (int16/int32/float, any interleave) into
    /// `renderFormat`. Rebuilt when the source format changes.
    private var converter: AVAudioConverter?
    /// The (sampleRate, channelCount) the engine is currently built for.
    private var builtRate = 0.0
    private var builtChannels: UInt32 = 0
    /// Cached output format description (interleaved Float32 at the built rate).
    private var outputFormatDescription: CMAudioFormatDescription?
    /// Logged failures are one-shot per build so a broken route can't spam the log
    /// at ~150 buffers/s.
    private var didLogFailure = false

    public init() {}

    /// Tears the engine down so the next buffer rebuilds it. Called on broadcast
    /// stop so compressor state never leaks into the next stream.
    public func reset() {
        engine?.stop()
        engine = nil
        player = nil
        converter = nil
        renderFormat = nil
        outputFormatDescription = nil
        builtRate = 0
        builtChannels = 0
    }

    /// Runs one mic buffer through the chain. Timing is preserved verbatim (source
    /// PTS; duration derived from the frame count); on any failure the input is
    /// returned unchanged.
    public func process(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer {
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

        // 1. Source AudioBufferList → render-format AVAudioPCMBuffer.
        guard let sourcePCM = Self.extractPCM(sampleBuffer, asbd: asbd, frameCount: AVAudioFrameCount(frameCount)) else {
            return fail(sampleBuffer, "could not read source PCM")
        }
        guard let input = AVAudioPCMBuffer(pcmFormat: renderFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return fail(sampleBuffer, "input buffer alloc failed")
        }
        input.frameLength = AVAudioFrameCount(frameCount)
        do {
            let inputState = ConverterInputState(buffer: sourcePCM)
            var converterError: NSError?
            let status = converter.convert(to: input, error: &converterError) { _, outStatus in
                inputState.next(status: outStatus)
            }
            guard status != .error, converterError == nil else {
                return fail(sampleBuffer, "format conversion failed")
            }
        }

        // 2. Schedule the whole input, then render it out in chunks. Render the
        // converter's ACTUAL output count — asking for unscheduled frames starves
        // the render and would fail the whole buffer into passthrough.
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

    /// Builds and starts the manual-rendering graph at the mic's live format.
    /// Returns false (and leaves the processor in passthrough) on any failure.
    private func buildEngine(sampleRate: Double, channels: UInt32) -> Bool {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sampleRate,
                                         channels: AVAudioChannelCount(channels),
                                         interleaved: false) else { return false }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let eq = AVAudioUnitEQ(numberOfBands: 7)
        configureEQ(eq)
        let fast = Self.effect(kAudioUnitSubType_DynamicsProcessor)
        let slow = Self.effect(kAudioUnitSubType_DynamicsProcessor)
        let limiter = Self.effect(kAudioUnitSubType_PeakLimiter)
        // Fast compressor: evens out syllables (−22 dB / 3:1, 12 ms / 160 ms, +2).
        Self.configureDynamics(fast, threshold: -22, headRoom: 22 / 3,
                               attack: 0.012, release: 0.160, makeup: 2)
        // Slow compressor: evens out the take (−26 dB / 2.5:1, 200 ms / 1.5 s, +2).
        Self.configureDynamics(slow, threshold: -26, headRoom: 26 / 2.5,
                               attack: 0.200, release: 1.5, makeup: 2)
        // −1.5 dBFS ceiling (alimiter=limit=-1.5dB).
        Self.setParameter(limiter, address: AUParameterAddress(kLimiterParam_PreGain), value: -1.5)

        for node in [player, eq, fast, slow, limiter] { engine.attach(node) }
        engine.connect(player, to: eq, format: format)
        engine.connect(eq, to: fast, format: format)
        engine.connect(fast, to: slow, format: format)
        engine.connect(slow, to: limiter, format: format)
        engine.connect(limiter, to: engine.mainMixerNode, format: format)

        do {
            try engine.enableManualRenderingMode(.offline, format: format,
                                                 maximumFrameCount: Self.maxRenderFrames)
            try engine.start()
        } catch {
            return false
        }
        player.play()

        // Output format description for the repacked buffer: interleaved Float32,
        // matching the layout `process` writes into the CMBlockBuffer.
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
        self.renderFormat = format
        self.outputFormatDescription = description
        self.builtRate = sampleRate
        self.builtChannels = channels
        self.didLogFailure = false
        return true
    }

    /// The sludge EQ, in order: rumble out, chest weight, dip the boxy midrange,
    /// presence so it cuts on a phone speaker, air. Sludge's `equalizer` bands specify
    /// no width; 1.0 octave is the voice-chain default used here.
    private func configureEQ(_ eq: AVAudioUnitEQ) {
        eq.globalGain = 0
        let bands = eq.bands
        bands[0].filterType = .highPass;   bands[0].frequency = 30
        bands[1].filterType = .lowShelf;   bands[1].frequency = 800;  bands[1].gain = 7.5;  bands[1].bandwidth = 0.35
        bands[2].filterType = .parametric; bands[2].frequency = 140;  bands[2].gain = 3;    bands[2].bandwidth = 1.0
        bands[3].filterType = .parametric; bands[3].frequency = 1150; bands[3].gain = -2.5; bands[3].bandwidth = 1.0
        bands[4].filterType = .parametric; bands[4].frequency = 4200; bands[4].gain = 3;    bands[4].bandwidth = 1.0
        bands[5].filterType = .highShelf;  bands[5].frequency = 3400; bands[5].gain = 5.5
        bands[6].filterType = .parametric; bands[6].frequency = 8500; bands[6].gain = 2;    bands[6].bandwidth = 1.0
        for band in bands { band.bypass = false }
    }

    /// A08: shared with `ChannelFXProcessor` — the AUDynamicsProcessor
    /// threshold/headRoom/attack/release/makeup mapping (headRoom =
    /// |threshold| / ratio gives the effective ratio; see the class docs).
    static func configureDynamics(_ unit: AVAudioUnitEffect, threshold: Float,
                                  headRoom: Float, attack: Float, release: Float,
                                  makeup: Float) {
        Self.setParameter(unit, address: AUParameterAddress(kDynamicsProcessorParam_Threshold), value: threshold)
        Self.setParameter(unit, address: AUParameterAddress(kDynamicsProcessorParam_HeadRoom), value: headRoom)
        Self.setParameter(unit, address: AUParameterAddress(kDynamicsProcessorParam_AttackTime), value: attack)
        Self.setParameter(unit, address: AUParameterAddress(kDynamicsProcessorParam_ReleaseTime), value: release)
        Self.setParameter(unit, address: AUParameterAddress(kDynamicsProcessorParam_OverallGain), value: makeup)
    }

    /// Instantiates an Apple system effect AU. An unavailable subtype surfaces as a
    /// `start()` throw (→ passthrough), not here — the init is non-failable.
    /// A08: shared with `ChannelFXProcessor`.
    static func effect(_ subType: OSType) -> AVAudioUnitEffect {
        AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: subType,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        ))
    }

    /// A08: shared with `ChannelFXProcessor`.
    static func setParameter(_ unit: AVAudioUnitEffect,
                             address: AUParameterAddress, value: Float) {
        unit.auAudioUnit.parameterTree?.parameter(withAddress: address)?.setValue(value, originator: nil)
    }

    // MARK: - PCM extraction

    /// Copies the sample buffer's LPCM out of its AudioBufferList into an
    /// `AVAudioPCMBuffer` described by the buffer's own ASBD (any bit depth /
    /// interleave). `AVAudioConverter` does the rest on the way to the render format.
    /// A08: shared with `ChannelFXProcessor`.
    static func extractPCM(_ sampleBuffer: CMSampleBuffer,
                           asbd: AudioStreamBasicDescription,
                           frameCount: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        var mutableASBD = asbd
        guard let format = AVAudioFormat(streamDescription: &mutableASBD),
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        pcm.frameLength = frameCount

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

        let ablPointer = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
        let source = UnsafeMutableAudioBufferListPointer(list)
        let count = min(source.count, ablPointer.count)
        for index in 0..<count {
            ablPointer[index].mNumberChannels = source[index].mNumberChannels
            ablPointer[index].mDataByteSize = min(source[index].mDataByteSize,
                                                  ablPointer[index].mDataByteSize)
            if let dst = ablPointer[index].mData, let src = source[index].mData {
                memcpy(dst, src, Int(ablPointer[index].mDataByteSize))
            }
        }
        return pcm
    }

    /// One-shot failure log + passthrough. Polish degrades to dry mic, never silence.
    private func fail(_ sampleBuffer: CMSampleBuffer, _ reason: String) -> CMSampleBuffer {
        if !didLogFailure {
            didLogFailure = true
            Self.log.error("Voice polish passthrough: \(reason, privacy: .public)")
        }
        return sampleBuffer
    }
}
