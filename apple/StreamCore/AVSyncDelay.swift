import Foundation

/// A10 (issue #122): the pure math and persisted models behind A/V delay
/// alignment and speech-driven music ducking.
///
/// **Delays.** Capture latency differs per source (USB camera ~30–120 ms,
/// screen ~10 ms, mic ~5 ms), so the shared host clock alone leaves sources
/// misaligned. The user compensates by DELAYING the earlier side: audio
/// delays ride the mix engine's per-channel ring read (bounded by
/// `maxAudioDelayMs`), video delays ride the composition engine's per-source
/// frame hold (bounded by `maxVideoDelayMs`). Only positive delays exist —
/// advancing a source is impossible without a time machine, so the UI
/// documents "delay the other side" instead.
public enum AVSyncDelay {
    /// Maximum per-channel audio delay. The mix engine's rings carry this
    /// much headroom ON TOP of the base 200 ms real-time buffer, so a fully
    /// delayed channel's read window can never overrun the retained samples.
    public static let maxAudioDelayMs = 500.0
    /// Maximum per-source video delay. The composition engine holds at most
    /// `frames(maxVideoDelayMs, fps) + 1` buffers per delayed source — the
    /// documented memory bound (e.g. 31 buffers at 60 fps).
    public static let maxVideoDelayMs = 500.0

    /// Clamps a user-entered audio delay to the supported range.
    public static func clampedAudioDelayMs(_ ms: Double) -> Double {
        guard ms.isFinite else { return 0 }
        return min(max(ms, 0), maxAudioDelayMs)
    }

    /// Clamps a user-entered video delay to the supported range.
    public static func clampedVideoDelayMs(_ ms: Double) -> Double {
        guard ms.isFinite else { return 0 }
        return min(max(ms, 0), maxVideoDelayMs)
    }

    /// Whole sample frames an audio delay of `ms` milliseconds spans at
    /// `sampleRate`, clamped to the bounded range.
    public static func audioFrames(forMilliseconds ms: Double, sampleRate: Int) -> Int {
        let clamped = clampedAudioDelayMs(ms)
        return Int((clamped / 1_000 * Double(max(1, sampleRate))).rounded())
    }

    /// Whole output frames a video delay of `ms` milliseconds spans at
    /// `framesPerSecond`, clamped to the bounded range.
    public static func videoFrames(forMilliseconds ms: Double, framesPerSecond: Int) -> Int {
        let clamped = clampedVideoDelayMs(ms)
        return Int((clamped / 1_000 * Double(max(1, framesPerSecond))).rounded())
    }

    /// Whole mix chunks an envelope time of `ms` milliseconds spans at the
    /// engine's chunk duration (never less than one — a zero-chunk attack or
    /// release would step the gain and click).
    public static func chunkCount(forMilliseconds ms: Double,
                                  chunkDurationSeconds: Double) -> Int {
        guard ms.isFinite, chunkDurationSeconds > 0 else { return 1 }
        return max(1, Int((ms / 1_000 / chunkDurationSeconds).rounded()))
    }
}

/// A10 (issue #122): the persisted speech-ducking configuration — which
/// channels are the sidechain (speech), which channels duck (music/media/
/// app), by how much, and with what envelope timing. Keyed by STABLE STRINGS
/// (the channel's `AudioChannelID.label`) for the same reason the A04 mixer
/// document is: StreamCore never names the macOS channel-ID type, and a
/// label whose channel kind doesn't exist yet round-trips harmlessly.
///
/// **Gain composition.** Ducking never touches the user's gains: the engine
/// keeps a SEPARATE per-channel duck ramp that multiplies the base
/// (mixer/binding) gain — `effective = base × duck`. The A04 faders and the
/// ducker therefore never fight, and bypass (duck back to 1) restores the
/// user-set gain exactly.
public struct DuckingSettings: Hashable, Codable, Sendable {
    /// Master enable. Off = bypass: every duck ramp eases back to unity.
    public var isEnabled = false
    /// Channel labels whose PRE-FADER level drives the detector (the mics).
    public var sidechainLabels: Set<String> = []
    /// RMS level (dBFS) at/above which speech counts as active.
    public var thresholdDb = -40.0
    /// Attenuation applied to duck targets while speech is active (dB,
    /// positive = quieter).
    public var reductionDb = 12.0
    /// How fast the duck engages once speech is detected (ms).
    public var attackMs = 30.0
    /// How long speech must be absent before the release starts (ms) —
    /// keeps the music down between phrases instead of pumping per word.
    public var holdMs = 400.0
    /// How fast the gain restores after the hold expires (ms).
    public var releaseMs = 600.0
    /// Channel labels that duck while speech is active (music playlists,
    /// scene media, app audio — never pads/stingers: ducking a one-shot
    /// would just make the joke quieter).
    public var targetLabels: Set<String> = []

    public static let thresholdDbRange = -80.0...0.0
    public static let reductionDbRange = 0.0...40.0
    public static let attackMsRange = 1.0...500.0
    public static let holdMsRange = 0.0...5_000.0
    public static let releaseMsRange = 10.0...5_000.0

    public init() {}

    /// Backward-compatible decode: a partial blob (written by a build with
    /// fewer ducking controls) falls back to the default per missing key, so
    /// the settings round-trip can never wipe the user's configuration.
    /// `encode(to:)` stays synthesized.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DuckingSettings()
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? d.isEnabled
        sidechainLabels = try c.decodeIfPresent(Set<String>.self, forKey: .sidechainLabels) ?? d.sidechainLabels
        thresholdDb = try c.decodeIfPresent(Double.self, forKey: .thresholdDb) ?? d.thresholdDb
        reductionDb = try c.decodeIfPresent(Double.self, forKey: .reductionDb) ?? d.reductionDb
        attackMs = try c.decodeIfPresent(Double.self, forKey: .attackMs) ?? d.attackMs
        holdMs = try c.decodeIfPresent(Double.self, forKey: .holdMs) ?? d.holdMs
        releaseMs = try c.decodeIfPresent(Double.self, forKey: .releaseMs) ?? d.releaseMs
        targetLabels = try c.decodeIfPresent(Set<String>.self, forKey: .targetLabels) ?? d.targetLabels
    }

    /// The detector threshold as a linear RMS value.
    public var thresholdLinear: Float {
        Float(pow(10, thresholdDb / 20))
    }

    /// The duck target gain (1 = no duck), e.g. 12 dB reduction ≈ 0.25.
    public var duckGain: Float {
        Float(pow(10, -reductionDb / 20))
    }

    /// Nil when every parameter is inside its documented range (the UI
    /// clamps to the same ranges; this guards automation input).
    public var validationError: String? {
        if !Self.thresholdDbRange.contains(thresholdDb) {
            return "Ducking threshold must be between \(Int(Self.thresholdDbRange.lowerBound)) and 0 dB."
        }
        if !Self.reductionDbRange.contains(reductionDb) {
            return "Ducking reduction must be between 0 and \(Int(Self.reductionDbRange.upperBound)) dB."
        }
        if !Self.attackMsRange.contains(attackMs) {
            return "Ducking attack must be between 1 and \(Int(Self.attackMsRange.upperBound)) ms."
        }
        if !Self.holdMsRange.contains(holdMs) {
            return "Ducking hold must be between 0 and \(Int(Self.holdMsRange.upperBound)) ms."
        }
        if !Self.releaseMsRange.contains(releaseMs) {
            return "Ducking release must be between 10 and \(Int(Self.releaseMsRange.upperBound)) ms."
        }
        return nil
    }
}

/// A10 (issue #122): the ducker's envelope state machine, advanced once per
/// mix chunk. Pure value type so the exact engage/hold/release behavior is
/// unit-tested; the engine translates each emitted target change into a
/// ramped duck-gain push (the A01 `ChannelGainRamp` keeps it click-free).
///
/// States: OPEN (no duck) → DUCKING (speech active; gain target = duckGain,
/// attack ramp) — speech absent → HOLD (target stays ducked for `holdChunks`
/// silent chunks) → RELEASING (target = 1, release ramp) → OPEN when the
/// ramp lands. Speech during hold or release re-engages the attack from the
/// current gain (no zipper noise, no pumping).
public struct DuckEnvelope: Sendable {
    public enum Phase: String, Equatable, Sendable {
        case open, ducking, releasing
    }

    /// Envelope timings in whole mix chunks (see `AVSyncDelay.chunkCount`).
    public struct Parameters: Equatable, Sendable {
        public var attackChunks: Int
        public var holdChunks: Int
        public var releaseChunks: Int

        public init(attackChunks: Int, holdChunks: Int, releaseChunks: Int) {
            self.attackChunks = max(1, attackChunks)
            self.holdChunks = max(0, holdChunks)
            self.releaseChunks = max(1, releaseChunks)
        }
    }

    /// What the engine should do after one `advance`: the duck-gain target
    /// and how many chunks to ramp over. `changed` is false for steady
    /// states, so the engine only touches channel ramps on transitions.
    public struct Decision: Equatable, Sendable {
        public var targetGain: Float
        public var rampChunks: Int
        public var changed: Bool
    }

    public private(set) var phase: Phase = .open
    private var holdRemaining = 0

    public init() {}

    public mutating func reset() {
        phase = .open
        holdRemaining = 0
    }

    /// Advances the envelope by one chunk. `speechActive` is the detector
    /// output for this chunk (sidechain RMS ≥ threshold); `duckGain` is the
    /// attenuated target (see `DuckingSettings.duckGain`).
    public mutating func advance(speechActive: Bool, duckGain: Float,
                                 parameters: Parameters) -> Decision {
        if speechActive {
            // Every active chunk re-arms the hold, so release only starts
            // after `holdChunks` of CONTINUOUS silence.
            holdRemaining = parameters.holdChunks
            if phase != .ducking {
                phase = .ducking
                return Decision(targetGain: duckGain,
                                rampChunks: parameters.attackChunks,
                                changed: true)
            }
            return Decision(targetGain: duckGain,
                            rampChunks: parameters.attackChunks,
                            changed: false)
        }
        switch phase {
        case .open:
            return Decision(targetGain: 1, rampChunks: 0, changed: false)
        case .ducking:
            holdRemaining -= 1
            guard holdRemaining < 0 else {
                // Hold: stay ducked through short pauses.
                return Decision(targetGain: duckGain,
                                rampChunks: parameters.attackChunks,
                                changed: false)
            }
            phase = .releasing
            return Decision(targetGain: 1,
                            rampChunks: parameters.releaseChunks,
                            changed: true)
        case .releasing:
            return Decision(targetGain: 1,
                            rampChunks: parameters.releaseChunks,
                            changed: false)
        }
    }
}
