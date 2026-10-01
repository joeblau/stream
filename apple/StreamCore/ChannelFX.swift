import Foundation

/// A08 (issue #120): one channel's persisted effect chain — the controllable
/// successor to the single global `voicePolishEnabled` toggle. Chains are
/// keyed by `AudioChannelID.label` in `StreamSettings.channelFX` (the shared
/// StreamCore model never names the macOS channel-ID type, same rule as the
/// A04 mixer document), persist additive `decodeIfPresent`, and apply LIVE:
/// edits ride the existing per-channel insert seam as parameter updates on
/// the running `ChannelFXProcessor` — no capture restart, no ring reset.
///
/// **Effect order is fixed and visible** (the issue's "visible effect order"
/// criterion): high-pass → noise gate → EQ → compressor → limiter. Every
/// section carries its own enable (bypass), and each preset can restore its
/// per-section defaults (reset). The processor renders exactly the input
/// frame count, so the chain adds ZERO latency (see
/// `ChannelFXProcessor.latencySeconds`) and preserves channel count and
/// timing verbatim when sections toggle.
///
/// **Back-compat:** a channel with no persisted chain falls back to the
/// legacy mapping — `voicePolishEnabled ? .voice : .off` — so a pre-A08
/// settings blob behaves exactly as before (see
/// `StreamSettings.fxChain(forChannelLabel:)`). The `.voice` preset voices
/// the same broadcast curve the fixed `VoicePolishProcessor` runs, mapped
/// onto this chain's 3-band EQ and single compressor stage.
public struct ChannelFXChain: Hashable, Codable, Sendable {

    // MARK: - Sections (fixed processing order)

    /// High-pass filter: rumble/handling-noise removal before anything else.
    public struct HighPass: Hashable, Codable, Sendable {
        public var isEnabled: Bool
        /// Cutoff in Hz (20…400).
        public var frequency: Double

        public init(isEnabled: Bool = false, frequency: Double = 80) {
            self.isEnabled = isEnabled
            self.frequency = frequency
        }
    }

    /// Noise gate, implemented natively as the downward-expansion region of
    /// an AUDynamicsProcessor (a high-ratio expander below the threshold —
    /// the gate behavior every host exposes). True broadband DENOISE has no
    /// Apple-native offline-renderable equivalent; it is documented as an
    /// unavailable native processing mode and would arrive via A11 (Audio
    /// Unit hosting).
    public struct NoiseGate: Hashable, Codable, Sendable {
        public var isEnabled: Bool
        /// Signals below this level are expanded (attenuated) away, −80…−20 dBFS.
        public var threshold: Double

        public init(isEnabled: Bool = false, threshold: Double = -50) {
            self.isEnabled = isEnabled
            self.threshold = threshold
        }
    }

    /// 3-band EQ: low shelf (250 Hz) and high shelf (6 kHz) with gain, plus a
    /// sweepable parametric mid — the "parametric-ish" band set of the issue.
    public struct Equalizer: Hashable, Codable, Sendable {
        public var isEnabled: Bool
        /// Low shelf gain at 250 Hz, −12…+12 dB.
        public var lowGain: Double
        /// Parametric mid frequency in Hz (200…4000).
        public var midFrequency: Double
        /// Parametric mid gain (1-octave width), −12…+12 dB.
        public var midGain: Double
        /// High shelf gain at 6 kHz, −12…+12 dB.
        public var highGain: Double

        public init(isEnabled: Bool = false, lowGain: Double = 0,
                    midFrequency: Double = 1_000, midGain: Double = 0,
                    highGain: Double = 0) {
            self.isEnabled = isEnabled
            self.lowGain = lowGain
            self.midFrequency = midFrequency
            self.midGain = midGain
            self.highGain = highGain
        }
    }

    /// Compressor (AUDynamicsProcessor): threshold/ratio/attack/release plus
    /// makeup gain. Apple's unit has no literal ratio parameter — a full-scale
    /// input lands at threshold + headRoom, so headRoom = |threshold| / ratio
    /// (the mapping `VoicePolishProcessor` documents and reuses).
    public struct Compressor: Hashable, Codable, Sendable {
        public var isEnabled: Bool
        /// Compression threshold, −40…0 dBFS (the AUDynamicsProcessor floor).
        public var threshold: Double
        /// Effective ratio, 1…10:1.
        public var ratio: Double
        /// Attack time in ms (1…200).
        public var attackMs: Double
        /// Release time in ms (20…2000).
        public var releaseMs: Double
        /// Makeup gain, 0…+24 dB.
        public var makeupGain: Double

        public init(isEnabled: Bool = false, threshold: Double = -22,
                    ratio: Double = 3, attackMs: Double = 12,
                    releaseMs: Double = 160, makeupGain: Double = 2) {
            self.isEnabled = isEnabled
            self.threshold = threshold
            self.ratio = ratio
            self.attackMs = attackMs
            self.releaseMs = releaseMs
            self.makeupGain = makeupGain
        }
    }

    /// Trailing brickwall-ish ceiling (AUPeakLimiter pre-gain), so EQ/makeup
    /// can run hot without ever wrapping the mix.
    public struct Limiter: Hashable, Codable, Sendable {
        public var isEnabled: Bool
        /// Output ceiling, −12…0 dBFS.
        public var ceiling: Double

        public init(isEnabled: Bool = false, ceiling: Double = -1.5) {
            self.isEnabled = isEnabled
            self.ceiling = ceiling
        }
    }

    /// The preset the chain was last seeded from. Any manual tweak flips it
    /// to `.custom` so the UI shows honestly that the values no longer match
    /// a named preset; the section values themselves are always authoritative.
    public var preset: ChannelFXPreset
    public var highPass: HighPass
    public var noiseGate: NoiseGate
    public var equalizer: Equalizer
    public var compressor: Compressor
    public var limiter: Limiter
    /// A11 (issue #123): hosted third-party Audio Unit effects, in signal
    /// order, inserted BETWEEN the compressor and the limiter (the safety
    /// ceiling always stays last). Ordered, individually bypassable,
    /// persisted by component identity + a `fullState` blob; a missing
    /// plugin degrades to a bypassed placeholder and the chain still runs.
    /// AU add/remove/reorder/bypass never flips `preset` — presets describe
    /// the native sections, slots are orthogonal to them.
    public var audioUnits: [HostedAudioUnitSlot]

    public init(preset: ChannelFXPreset = .off,
                highPass: HighPass = HighPass(),
                noiseGate: NoiseGate = NoiseGate(),
                equalizer: Equalizer = Equalizer(),
                compressor: Compressor = Compressor(),
                limiter: Limiter = Limiter(),
                audioUnits: [HostedAudioUnitSlot] = []) {
        self.preset = preset
        self.highPass = highPass
        self.noiseGate = noiseGate
        self.equalizer = equalizer
        self.compressor = compressor
        self.limiter = limiter
        self.audioUnits = audioUnits
    }

    /// A11: additive decoding — chain blobs written before Audio Unit
    /// hosting existed carry no `audioUnits` key and must still decode (the
    /// synthesized decoder would throw on the missing key and take the whole
    /// settings document down with it).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ChannelFXChain()
        preset = try c.decodeIfPresent(ChannelFXPreset.self, forKey: .preset) ?? defaults.preset
        highPass = try c.decodeIfPresent(HighPass.self, forKey: .highPass) ?? defaults.highPass
        noiseGate = try c.decodeIfPresent(NoiseGate.self, forKey: .noiseGate) ?? defaults.noiseGate
        equalizer = try c.decodeIfPresent(Equalizer.self, forKey: .equalizer) ?? defaults.equalizer
        compressor = try c.decodeIfPresent(Compressor.self, forKey: .compressor) ?? defaults.compressor
        limiter = try c.decodeIfPresent(Limiter.self, forKey: .limiter) ?? defaults.limiter
        audioUnits = try c.decodeIfPresent([HostedAudioUnitSlot].self, forKey: .audioUnits) ?? []
    }

    /// True when no section is active — the processor takes the zero-cost
    /// identity path (the same buffer object out, no engine built), so a
    /// bypassed or Off channel adds literally nothing to the capture thread.
    public var isActive: Bool {
        highPass.isEnabled || noiseGate.isEnabled || equalizer.isEnabled
            || compressor.isEnabled || limiter.isEnabled
            || audioUnits.contains(where: \.isEnabled)
    }

    /// The fixed processing order, for the FX rack's visible-order row.
    public static let effectOrder: [String] =
        ["High-Pass", "Noise Gate", "EQ", "Compressor", "Limiter"]

    /// Latency the chain adds, in seconds: zero — the offline render emits
    /// exactly the input frame count per buffer (see ChannelFXProcessor).
    public static let latencySeconds: Double = 0

    // MARK: - Presets

    /// A fully-formed chain for a named preset (`.custom` and `.off` both
    /// mean "everything bypassed" — custom is only a UI marker and never
    /// arrives here from the preset picker).
    public static func preset(_ preset: ChannelFXPreset) -> ChannelFXChain {
        switch preset {
        case .off, .custom:
            return ChannelFXChain(preset: preset == .off ? .off : .custom)
        case .voice:
            // The voice-polish curve (see VoicePolishProcessor) mapped onto
            // this chain: rumble out, chest weight on the low shelf, the
            // 1150 Hz boxy-midrange dip, presence/air on the high shelf, the
            // fast −22 dB / 3:1 compressor, and the −1.5 dBFS ceiling.
            return ChannelFXChain(
                preset: .voice,
                highPass: HighPass(isEnabled: true, frequency: 30),
                noiseGate: NoiseGate(isEnabled: false, threshold: -50),
                equalizer: Equalizer(isEnabled: true,
                                     lowGain: 3, midFrequency: 1_150,
                                     midGain: -2.5, highGain: 4),
                compressor: Compressor(isEnabled: true, threshold: -22, ratio: 3,
                                       attackMs: 12, releaseMs: 160, makeupGain: 2),
                limiter: Limiter(isEnabled: true, ceiling: -1.5))
        case .podcast:
            // Spoken word with a gate: tighter rumble control, a −50 dB gate
            // for room noise between phrases, gentler EQ, slower compression.
            return ChannelFXChain(
                preset: .podcast,
                highPass: HighPass(isEnabled: true, frequency: 80),
                noiseGate: NoiseGate(isEnabled: true, threshold: -50),
                equalizer: Equalizer(isEnabled: true,
                                     lowGain: 1, midFrequency: 1_000,
                                     midGain: -1.5, highGain: 2),
                compressor: Compressor(isEnabled: true, threshold: -18, ratio: 2.5,
                                       attackMs: 8, releaseMs: 120, makeupGain: 3),
                limiter: Limiter(isEnabled: true, ceiling: -1.0))
        case .music:
            // Near-transparent: flat EQ, slow 1.5:1 glue compression, just a
            // safety ceiling.
            return ChannelFXChain(
                preset: .music,
                highPass: HighPass(isEnabled: true, frequency: 40),
                noiseGate: NoiseGate(isEnabled: false, threshold: -50),
                equalizer: Equalizer(isEnabled: false),
                compressor: Compressor(isEnabled: true, threshold: -12, ratio: 1.5,
                                       attackMs: 30, releaseMs: 300, makeupGain: 1),
                limiter: Limiter(isEnabled: true, ceiling: -0.3))
        }
    }

    // MARK: - Validation (the dispatcher rejects out-of-range values)

    /// The first out-of-range/non-finite value, as a plain-language reason —
    /// nil when the chain is valid. UI sliders clamp to these same ranges, so
    /// this guards automation/hardware-controller input (D-series).
    public var validationError: String? {
        func check(_ value: Double, _ range: ClosedRange<Double>, _ name: String) -> String? {
            value.isFinite && range.contains(value)
                ? nil : "\(name) must be between \(range.lowerBound) and \(range.upperBound)."
        }
        if let error = check(highPass.frequency, 20...400, "High-pass frequency") { return error }
        if let error = check(noiseGate.threshold, -80 ... -20, "Gate threshold") { return error }
        if let error = check(equalizer.lowGain, -12...12, "EQ low gain") { return error }
        if let error = check(equalizer.midFrequency, 200...4_000, "EQ mid frequency") { return error }
        if let error = check(equalizer.midGain, -12...12, "EQ mid gain") { return error }
        if let error = check(equalizer.highGain, -12...12, "EQ high gain") { return error }
        if let error = check(compressor.threshold, -40...0, "Compressor threshold") { return error }
        if let error = check(compressor.ratio, 1...10, "Compressor ratio") { return error }
        if let error = check(compressor.attackMs, 1...200, "Compressor attack") { return error }
        if let error = check(compressor.releaseMs, 20...2_000, "Compressor release") { return error }
        if let error = check(compressor.makeupGain, 0...24, "Compressor makeup") { return error }
        if let error = check(limiter.ceiling, -12...0, "Limiter ceiling") { return error }
        // A11: hosted Audio Unit slots — bounded count (capture-thread
        // render cost) and bounded state blobs (settings-document size).
        if audioUnits.count > HostedAudioUnitSlot.maxSlotsPerChannel {
            return "A channel hosts at most \(HostedAudioUnitSlot.maxSlotsPerChannel) Audio Units."
        }
        for slot in audioUnits {
            if let state = slot.state, state.count > HostedAudioUnitSlot.maxStateBytes {
                return "\(slot.component.displayName) saved state is too large."
            }
        }
        return nil
    }
}

/// A08: the named starting points for a channel's chain (plus `.custom`, the
/// "user tweaked it" marker, and `.off`, the full bypass).
public enum ChannelFXPreset: String, Codable, CaseIterable, Sendable {
    case off, voice, podcast, music, custom

    public var displayName: String {
        switch self {
        case .off: return "Off"
        case .voice: return "Voice"
        case .podcast: return "Podcast"
        case .music: return "Music"
        case .custom: return "Custom"
        }
    }
}
