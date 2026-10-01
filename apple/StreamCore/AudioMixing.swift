import Foundation

/// The A01 routing buses (issue #82). Every bus is an independent mix tap with
/// its own bounded, drop-oldest delivery queues, so a slow consumer of one bus
/// can never stall the mix or the other outputs (the W08 video fan-out rule,
/// applied to audio).
public enum AudioBus: String, Sendable, CaseIterable, Hashable {
    /// The master mix: every routed channel post-fader. Feeds the stream
    /// publisher and the local recorder, each through its own tap.
    case program
    /// The monitor/headphone mix. Same channel routing as program with an
    /// independent master gain; A07 (monitoring) attaches the output device.
    case monitor
    /// The auxiliary/guest-return mix: per-channel aux sends (default 0), so a
    /// future guest hears everything except themselves (mix-minus).
    case aux
}

/// Per-channel and per-tap loss counters for the audio engine. The drop
/// policy these measure is documented on `AudioRingBuffer`.
public struct AudioChannelStatistics: Hashable, Sendable {
    /// Frames dropped on ring overflow (drop-oldest, latency stays bounded).
    public var droppedFrames: Int64 = 0
    /// Silence frames inserted where samples were missing (underrun).
    public var underrunFrames: Int64 = 0
    /// Real frames written by the source.
    public var receivedFrames: Int64 = 0

    public init() {}
}

/// A whole-engine snapshot: per-channel counters keyed by the channel's stable
/// ID string, plus chunks shed by bounded tap queues (a slow output sheds only
/// its own chunks — never the mix).
public struct AudioEngineStatistics: Sendable {
    public var channels: [String: AudioChannelStatistics] = [:]
    /// Chunks dropped by bounded tap queues, keyed by tap description.
    public var tapDrops: [String: Int64] = [:]

    public init() {}
}

/// A click-free linear gain ramp (issue #82: "no clicks/glitches on scene Take
/// — ramped gain changes"). Every gain/mute change eases from the current
/// value to the target over a fixed number of frames instead of stepping, so
/// muting a source or re-binding it on a Take never produces a discontinuity
/// in the summed waveform.
public struct ChannelGainRamp: Sendable {
    /// The gain applied to the most recently advanced frame.
    public private(set) var current: Float
    /// The gain the ramp is moving toward.
    public private(set) var target: Float
    private var step: Float = 0
    private var framesRemaining: Int = 0

    public init(gain: Float) {
        current = gain
        target = gain
    }

    /// Starts a ramp toward `gain` over `rampFrames` frames. A ramp of 0
    /// frames applies immediately (engine start, channel creation).
    public mutating func setTarget(_ gain: Float, rampFrames: Int) {
        let clamped = max(0, gain)
        target = clamped
        if rampFrames <= 0 {
            current = clamped
            step = 0
            framesRemaining = 0
            return
        }
        step = (clamped - current) / Float(rampFrames)
        framesRemaining = rampFrames
    }

    /// Returns the gain for the next frame and advances the ramp one frame.
    public mutating func advance() -> Float {
        if framesRemaining > 0 {
            current += step
            framesRemaining -= 1
            if framesRemaining == 0 { current = target }
        }
        return current
    }

    /// Applies `frameCount` frames of ramping in one step, returning the gain
    /// trajectory's END value. For callers that apply one gain per chunk
    /// rather than per frame.
    public mutating func advance(by frameCount: Int) -> Float {
        var value = current
        for _ in 0..<max(0, frameCount) { value = advance() }
        return value
    }
}

/// A04 (issue #83): one meter reading for a channel or bus — the values the
/// mixer's meter bars draw. `peak`/`rms` are linear (0…1+; convert to dB at
/// display time); `isClipping` is a latched "the signal hit full scale"
/// indication that holds briefly so a single clipped chunk stays visible.
public struct AudioLevels: Hashable, Sendable {
    public var peak: Float = 0
    public var rms: Float = 0
    public var isClipping = false

    public init(peak: Float = 0, rms: Float = 0, isClipping: Bool = false) {
        self.peak = peak
        self.rms = rms
        self.isClipping = isClipping
    }
}

/// A04 (issue #83): a cheap chunk-rate meter for one channel or bus. Fed one
/// interleaved stereo chunk per mix chunk (~94 Hz) and polled by the UI at
/// ~15–30 Hz, it keeps an instant-attack/exponential-decay peak, a smoothed
/// RMS, and a latched clip flag. All arithmetic is per-chunk over the samples
/// the mix loop already touches — no extra passes over the rings, no locks of
/// its own (the caller confines it: channel ingest lock for channels, the
/// engine actor for buses).
public struct LevelMeter: Sendable {
    /// The displayed peak: jumps to a hotter chunk instantly, decays per
    /// chunk otherwise (≈250 ms to fall 20 dB at the engine's chunk rate).
    public private(set) var peak: Float = 0
    /// The displayed RMS, smoothed halfway toward each chunk's value.
    public private(set) var rms: Float = 0
    /// Chunks left on the clip latch (0 = not clipping).
    public private(set) var clipHoldChunks = 0

    /// |sample| at/above this reads as clipping (full-scale digital).
    static let clipThreshold: Float = 0.999
    /// ~0.5 s of latch at the engine's 512-frame chunk period.
    static let clipHoldChunksOnClip = 45
    /// Per-chunk peak decay (chunkPeak wins instantly above it).
    static let peakDecay: Float = 0.92

    public init() {}

    /// Measures one chunk at unity gain.
    public mutating func ingest(interleaved samples: [Float]) {
        ingest(interleaved: samples, gain: 1)
    }

    /// Measures one chunk as scaled by `gain` — bus meters ingest the
    /// POST-GAIN, PRE-CLAMP signal so the clip latch means "the clamp
    /// engaged", not merely "the fader is hot".
    public mutating func ingest(interleaved samples: [Float], gain: Float) {
        var chunkPeak: Float = 0
        var sumSquares: Float = 0
        for sample in samples {
            let scaled = abs(sample * gain)
            if scaled > chunkPeak { chunkPeak = scaled }
            sumSquares += scaled * scaled
        }
        let count = max(1, samples.count)
        let chunkRMS = (sumSquares / Float(count)).squareRoot()
        peak = max(chunkPeak, peak * Self.peakDecay)
        rms += (chunkRMS - rms) * 0.5
        if chunkPeak >= Self.clipThreshold {
            clipHoldChunks = Self.clipHoldChunksOnClip
        } else if clipHoldChunks > 0 {
            clipHoldChunks -= 1
        }
    }

    /// The current reading for the UI.
    public var levels: AudioLevels {
        AudioLevels(peak: peak, rms: rms, isClipping: clipHoldChunks > 0)
    }
}

/// A04 (issue #83): the persisted mixer session document, carried inside
/// `StreamSettings` (additive `decodeIfPresent`, so older settings blobs load
/// unchanged). Everything is keyed by STABLE STRINGS — the channel's
/// `AudioChannelID.label` and the bus's `AudioBus.rawValue` — so the shared
/// StreamCore model never names the macOS channel-ID type, and a label whose
/// channel kind doesn't exist yet (media, application, guest) round-trips
/// harmlessly until that surface lands.
///
/// Capture-channel program levels are deliberately NOT here: they are scene
/// content (the S05 `AudioBinding`s persist with the scene document, and the
/// program scene drives the actual mix). This document owns the live,
/// scene-independent mix surface: non-capture faders/mutes, the monitor-only
/// solo set, aux sends, and the bus masters.
public struct MixerSettings: Hashable, Codable, Sendable {
    /// Per-channel fader positions (linear, 0…2), by channel label.
    public var channelVolumes: [String: Double] = [:]
    /// Per-channel mutes, by channel label (absent = unmuted).
    public var channelMutes: [String: Bool] = [:]
    /// Soloed channel labels. Solo is MONITOR-ONLY (issue #83): while any
    /// channel is soloed the monitor bus carries only the soloed channels;
    /// the program bus is never affected.
    public var soloedChannels: Set<String> = []
    /// Per-channel aux/guest-return sends (0…1, absent = 0), by label.
    public var channelAuxSends: [String: Double] = [:]
    /// Per-bus master gains (linear, 0…2, absent = 1), by `AudioBus.rawValue`.
    public var busGains: [String: Double] = [:]
    /// Muted buses (effective master gain 0; the fader value is preserved),
    /// by `AudioBus.rawValue`.
    public var mutedBuses: Set<String> = []

    public init() {}
}

/// The pure summing math of the audio engine: accumulates one channel's
/// interleaved stereo chunk into the program and aux sums with per-frame
/// ramped gains, and finishes a bus chunk with its master gain and a hard
/// safety clamp. Kept in StreamCore (no CoreMedia/AVFAudio) so the exact mix
/// arithmetic is unit-tested on every platform; the macOS `AudioMixEngine`
/// channels call these on their hot path.
public enum AudioMixerCore {
    /// Accumulates `source` (interleaved stereo, `frameCount` frames) into
    /// `program` (post-fader) and `aux` (aux-send), advancing both ramps per
    /// frame. All three buffers must hold `frameCount * 2` samples.
    public static func accumulate(source: [Float],
                                  frameCount: Int,
                                  gain: inout ChannelGainRamp,
                                  auxGain: inout ChannelGainRamp,
                                  program: inout [Float],
                                  aux: inout [Float]) {
        for frame in 0..<frameCount {
            let channelGain = gain.advance()
            let sendGain = auxGain.advance()
            let left = source[frame * 2]
            let right = source[frame * 2 + 1]
            program[frame * 2] += left * channelGain
            program[frame * 2 + 1] += right * channelGain
            aux[frame * 2] += left * sendGain
            aux[frame * 2 + 1] += right * sendGain
        }
    }

    /// A04 (issue #83): the `accumulate` variant that ALSO sums the channel's
    /// post-fader signal into `monitor` — the monitor-only solo path. While
    /// any channel is soloed, the engine builds the monitor bus from soloed
    /// channels only, using exactly the per-frame gain trajectory applied to
    /// program (one ramp advance per frame, so solo never distorts a ramp).
    public static func accumulateWithMonitor(source: [Float],
                                             frameCount: Int,
                                             gain: inout ChannelGainRamp,
                                             auxGain: inout ChannelGainRamp,
                                             program: inout [Float],
                                             aux: inout [Float],
                                             monitor: inout [Float]) {
        for frame in 0..<frameCount {
            let channelGain = gain.advance()
            let sendGain = auxGain.advance()
            let left = source[frame * 2]
            let right = source[frame * 2 + 1]
            program[frame * 2] += left * channelGain
            program[frame * 2 + 1] += right * channelGain
            aux[frame * 2] += left * sendGain
            aux[frame * 2 + 1] += right * sendGain
            monitor[frame * 2] += left * channelGain
            monitor[frame * 2 + 1] += right * channelGain
        }
    }

    /// Applies the bus master gain and clamps every sample to [-1, 1] — the
    /// safety ceiling so a hot sum of N sources can never wrap the encoder.
    public static func applyBusGainAndClamp(_ samples: inout [Float], gain: Float) {
        for index in samples.indices {
            let scaled = samples[index] * gain
            samples[index] = min(1, max(-1, scaled))
        }
    }
}
