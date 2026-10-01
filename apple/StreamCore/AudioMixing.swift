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

    /// Applies the bus master gain and clamps every sample to [-1, 1] — the
    /// safety ceiling so a hot sum of N sources can never wrap the encoder.
    public static func applyBusGainAndClamp(_ samples: inout [Float], gain: Float) {
        for index in samples.indices {
            let scaled = samples[index] * gain
            samples[index] = min(1, max(-1, scaled))
        }
    }
}
