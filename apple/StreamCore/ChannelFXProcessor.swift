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
/// the same Apple-native, offline-render graph pattern on the capture thread.
/// A11 (issue #123) adds hosted third-party Audio Unit effects between the
/// compressor and the limiter:
///
///   player → AVAudioUnitEQ (high-pass + 3 bands) → gate (DynamicsProcessor,
///   downward expansion) → compressor (DynamicsProcessor)
///   → [hosted AU slots, in chain order] → PeakLimiter → mainMixer
///
/// The hosted units sit there deliberately: after the dynamics that shape the
/// voice, before the safety ceiling that catches anything a plugin outputs
/// hot. The native effect ORDER is fixed and matches
/// `ChannelFXChain.effectOrder`; each section's enable maps to band bypass /
/// `shouldBypassEffect`, so toggling a section never rebuilds the graph and
/// preserves channel count, timing, and audio continuity (the issue's
/// criteria). Exactly the input frame count is rendered per call — the native
/// sections add ZERO latency (`ChannelFXChain.latencySeconds`); a hosted AU
/// may REPORT latency (`AUAudioUnit.latency`), which the offline render does
/// not compensate (frame counts are preserved, so content shifts by that
/// amount) — the rack surfaces it per slot.
///
/// **Live parameter updates** (no capture restarts): the caller hands the
/// latest `ChannelFXChain` to every `process(_:chain:)` call — the chain is a
/// tiny value type the owning insert box swaps under a lock, so the audio
/// thread never blocks on UI work. A changed chain re-writes the AU
/// parameters in place (thread-safe `AUParameterTree` writes); an unchanged
/// one costs one value comparison. A chain whose hosted-slot STRUCTURE
/// changed (add/remove/reorder/component swap) rebuilds the graph in place —
/// same format, same converter, between two buffers. An inactive chain
/// (`ChannelFXChain.isActive == false`) takes the zero-cost identity path:
/// the SAME buffer object is returned and no engine is ever built.
///
/// **A11 failure isolation (documented honestly):** hosted units are
/// instantiated IN-PROCESS — a plugin that crashes (vs. returns an error)
/// takes the app with it; macOS offers no out-of-process hosting for
/// arbitrary v2 component AUs. What the host DOES contain: a component that
/// is no longer installed never reaches instantiation (`isAvailable`
/// pre-check → bypassed placeholder, chain runs); a unit whose graph build
/// or engine start throws degrades the chain to native-only (logged once);
/// a render error passes the buffer through unchanged. The rack reads which
/// slots actually loaded via `hostedHandles()`.
///
/// Failure policy otherwise matches VoicePolishProcessor: any
/// format/engine/render problem logs once and returns the input UNCHANGED —
/// FX must never drop or mute a source.
///
/// Not `Sendable`: each channel's insert owns its own instance, confined to
/// the channel's ingest lock (the same confinement the publishers gave their
/// VoicePolishProcessor instances). The published handles cross to the main
/// thread under their own unfair lock (`hostedHandles()`).
public final class ChannelFXProcessor {

    private static let log = Logger(subsystem: "com.joeblau.Stream", category: "channel-fx")

    /// Upper bound per `renderOffline` call (see VoicePolishProcessor).
    private static let maxRenderFrames: AVAudioFrameCount = 4096

    /// One hosted unit running in the graph, tied to its chain slot.
    private struct HostedUnit {
        let slotID: UUID
        let unit: AVAudioUnitEffect
    }

    /// Identity of the hosted section's STRUCTURE: which slots, with which
    /// components, in which order. State blobs and bypass flags are
    /// deliberately excluded — they never require a graph rebuild.
    private struct HostedSlotKey: Equatable {
        let id: UUID
        let component: AudioUnitComponentID
    }

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var eq: AVAudioUnitEQ?
    private var gate: AVAudioUnitEffect?
    private var compressor: AVAudioUnitEffect?
    private var limiter: AVAudioUnitEffect?
    /// Hosted units in signal order (between compressor and limiter).
    private var hostedUnits: [HostedUnit] = []
    /// The hosted structure the CURRENT graph was built with, so
    /// `applyChain` can tell "parameter edit" from "slot add/remove/reorder".
    private var builtHostedStructure: [HostedSlotKey] = []
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
    /// UI-facing handles for the running hosted units, published after every
    /// graph build under this lock (the only cross-thread surface).
    private var handleLock = os_unfair_lock_s()
    private var handles: [UUID: HostedAudioUnitHandle] = [:]

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
        hostedUnits = []
        builtHostedStructure = []
        converter = nil
        renderFormat = nil
        outputFormatDescription = nil
        builtRate = 0
        builtChannels = 0
        appliedChain = nil
        publishHandles()
    }

    /// The handles of the hosted units currently running in the graph, keyed
    /// by chain-slot ID. Main-thread safe (own lock); a slot with no handle
    /// is NOT loaded — plugin missing, load failed, or the channel is idle.
    public func hostedHandles() -> [UUID: HostedAudioUnitHandle] {
        os_unfair_lock_lock(&handleLock)
        defer { os_unfair_lock_unlock(&handleLock) }
        return handles
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
            guard buildWithFallback(sampleRate: asbd.mSampleRate,
                                    channels: asbd.mChannelsPerFrame, chain: chain) else {
                return fail(sampleBuffer, "engine build failed")
            }
            var sourceASBD = asbd
            guard let sourceFormat = AVAudioFormat(streamDescription: &sourceASBD) else {
                return fail(sampleBuffer, "source format unsupported")
            }
            converter = AVAudioConverter(from: sourceFormat, to: renderFormat!)
        }
        // Live parameter update: write the chain onto the graph only when it
        // changed (value-type diff — no per-buffer cost when idle). A
        // changed hosted-slot structure rebuilds the graph in place (same
        // format, converter kept), so `player`/`engine` are fetched AFTER.
        applyChain(chain)
        guard let engine, let player, let renderFormat, let converter,
              let outputFormatDescription else {
            return fail(sampleBuffer, "engine not ready")
        }

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

    /// Builds the graph for `chain`, degrading honestly when hosted units
    /// fail: first attempt includes every AVAILABLE hosted component; if the
    /// engine refuses to start with them attached, log once and rebuild
    /// native-only (the affected slots simply publish no handle — the rack
    /// shows them as not loaded, and the chain keeps running).
    private func buildWithFallback(sampleRate: Double, channels: UInt32,
                                   chain: ChannelFXChain) -> Bool {
        let wantsHosted = chain.audioUnits.contains { $0.component.isAvailable }
        if buildEngine(sampleRate: sampleRate, channels: channels,
                       chain: chain, includeHosted: wantsHosted) {
            return true
        }
        if wantsHosted {
            logFailure("a hosted Audio Unit failed to load; running native sections only")
            return buildEngine(sampleRate: sampleRate, channels: channels,
                               chain: chain, includeHosted: false)
        }
        return false
    }

    /// Builds and starts the manual-rendering graph at the source's live
    /// format, with every section bypassed; `applyChain` then writes the
    /// real parameters. Returns false (→ passthrough) on any failure.
    private func buildEngine(sampleRate: Double, channels: UInt32,
                             chain: ChannelFXChain, includeHosted: Bool) -> Bool {
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

        // A11: instantiate the chain's hosted slots (those still installed —
        // `isAvailable` pre-checks registration so a missing plugin never
        // reaches the non-failable AVAudioUnitEffect initializer). Each unit
        // is an `AVAudioUnitEffect` from the slot's AudioComponentDescription,
        // the same graph seam the Apple-native effects use.
        var hosted: [HostedUnit] = []
        if includeHosted {
            for slot in chain.audioUnits where slot.component.isAvailable {
                hosted.append(HostedUnit(
                    slotID: slot.id,
                    unit: AVAudioUnitEffect(audioComponentDescription: slot.component.componentDescription)))
            }
        }

        for node in [player, eq, gate, compressor] as [AVAudioNode] { engine.attach(node) }
        for hostedUnit in hosted { engine.attach(hostedUnit.unit) }
        engine.attach(limiter)
        engine.connect(player, to: eq, format: format)
        engine.connect(eq, to: gate, format: format)
        engine.connect(gate, to: compressor, format: format)
        var upstream: AVAudioNode = compressor
        for hostedUnit in hosted {
            engine.connect(upstream, to: hostedUnit.unit, format: format)
            upstream = hostedUnit.unit
        }
        engine.connect(upstream, to: limiter, format: format)
        engine.connect(limiter, to: engine.mainMixerNode, format: format)

        do {
            try engine.enableManualRenderingMode(.offline, format: format,
                                                 maximumFrameCount: Self.maxRenderFrames)
            try engine.start()
        } catch {
            return false
        }
        player.play()

        // Restore persisted plugin state AFTER start (a unit may reject
        // fullState before its render resources exist). Best-effort: a
        // plugin that rejects the blob keeps its own defaults — the slot
        // stays loaded and the chain keeps running.
        for hostedUnit in hosted {
            guard let slot = chain.audioUnits.first(where: { $0.id == hostedUnit.slotID }),
                  let fullState = HostedAudioUnitSlot.decodeState(slot.state) else { continue }
            hostedUnit.unit.auAudioUnit.fullState = fullState
        }

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

        // On an in-place hosted-structure rebuild this replaces a RUNNING
        // graph — stop it first so its render resources release now.
        self.engine?.stop()
        self.engine = engine
        self.player = player
        self.eq = eq
        self.gate = gate
        self.compressor = compressor
        self.limiter = limiter
        self.hostedUnits = hosted
        self.builtHostedStructure = Self.hostedStructure(of: includeHosted ? chain.audioUnits : [])
        self.renderFormat = format
        self.outputFormatDescription = description
        self.builtRate = sampleRate
        self.builtChannels = channels
        self.appliedChain = nil
        self.didLogFailure = false
        publishHandles()
        return true
    }

    private static func hostedStructure(of slots: [HostedAudioUnitSlot]) -> [HostedSlotKey] {
        slots.map { HostedSlotKey(id: $0.id, component: $0.component) }
    }

    /// Publishes the current hosted units as UI-facing handles (called after
    /// every build and on reset, from the confined audio side; readers take
    /// the handle lock).
    private func publishHandles() {
        var published: [UUID: HostedAudioUnitHandle] = [:]
        for hostedUnit in hostedUnits {
            let auAudioUnit = hostedUnit.unit.auAudioUnit
            published[hostedUnit.slotID] = HostedAudioUnitHandle(
                slotID: hostedUnit.slotID,
                audioUnit: auAudioUnit,
                latencySeconds: auAudioUnit.latency)
        }
        os_unfair_lock_lock(&handleLock)
        handles = published
        os_unfair_lock_unlock(&handleLock)
    }

    // MARK: - Live chain application

    /// Writes a changed chain onto the running graph: EQ band parameters and
    /// per-band bypass, the gate's expansion region, the compressor's
    /// dynamics mapping (headRoom = |threshold| / ratio), the limiter's
    /// ceiling, and each hosted unit's bypass. Section enables map to bypass
    /// flags — the graph never rebuilds for a parameter edit, so a toggle
    /// mid-stream keeps the buffer stream continuous. A changed hosted-slot
    /// STRUCTURE (add/remove/reorder/component swap) is the one edit that
    /// rebuilds the graph — in place, between two buffers, same format.
    private func applyChain(_ chain: ChannelFXChain) {
        guard appliedChain != chain else { return }

        if Self.hostedStructure(of: chain.audioUnits) != builtHostedStructure {
            // In-place graph rebuild. Format/converter survive (buildEngine
            // re-creates them identically); a failed rebuild keeps the
            // PREVIOUS graph running — the new parameters below then apply
            // to it as far as they line up, and the rack shows the hosted
            // slots that did not load.
            _ = buildWithFallback(sampleRate: builtRate, channels: builtChannels, chain: chain)
        }
        appliedChain = chain

        guard let eq, let gate, let compressor, let limiter else { return }

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

        // A11: live bypass per hosted slot. `fullState` is applied at build
        // time only — re-applying it here would stomp the user's live edits
        // (the persisted blob is captured FROM the running unit).
        for slot in chain.audioUnits {
            guard let hosted = hostedUnits.first(where: { $0.slotID == slot.id }) else { continue }
            hosted.unit.auAudioUnit.shouldBypassEffect = !slot.isEnabled
        }
    }

    /// One-shot failure log (no buffer to pass through — for build-time
    /// degradations where the chain keeps running, just without a piece).
    private func logFailure(_ reason: String) {
        if !didLogFailure {
            didLogFailure = true
            Self.log.error("Channel FX degradation: \(reason, privacy: .public)")
        }
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
