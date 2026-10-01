import CoreMedia
import StreamCore
import os.lock

/// A09 (issue #121): the capture-thread side of feedback diagnostics. Receives
/// the engine's MONITOR bus tap (the reference — what is playing out loud) and
/// one isolated (pre-fader) tap per mic channel, mono-sums each chunk, and
/// feeds every channel's `HowlRiskDetector`. Runs entirely on the tap delivery
/// queues behind one unfair lock — the taps' bounded, drop-oldest contract
/// means a slow diagnostics consumer can never stall the mix (the W02 rule).
///
/// Kept separate from `StreamController` so the main actor only polls
/// `riskByChannel()` a few times a second; the DSP never touches the UI thread.
final class FeedbackAnalyzer: @unchecked Sendable {
    private var lock = os_unfair_lock_s()
    private var converter = CanonicalAudioConverter()
    /// One detector per mic channel, keyed by the channel's stable label.
    private var detectors: [String: HowlRiskDetector] = [:]

    /// Registers a mic channel for analysis (idempotent). Called when the
    /// channel's isolated tap is registered.
    func addChannel(label: String) {
        os_unfair_lock_lock(&lock)
        if detectors[label] == nil {
            detectors[label] = HowlRiskDetector()
        }
        os_unfair_lock_unlock(&lock)
    }

    func removeChannel(label: String) {
        os_unfair_lock_lock(&lock)
        detectors[label] = nil
        os_unfair_lock_unlock(&lock)
    }

    /// Monitor bus tap sink: every channel's detector sees the reference (the
    /// loop needs the monitor to be live — see `HowlRiskDetector`).
    func ingestReference(_ sample: CMSampleBuffer) {
        guard let mono = monoSamples(sample) else { return }
        os_unfair_lock_lock(&lock)
        for detector in detectors.values {
            detector.ingestReference(mono)
        }
        os_unfair_lock_unlock(&lock)
    }

    /// Isolated mic tap sink for one channel.
    func ingestMic(_ sample: CMSampleBuffer, channelLabel: String) {
        guard let mono = monoSamples(sample) else { return }
        os_unfair_lock_lock(&lock)
        detectors[channelLabel]?.ingestMic(mono)
        os_unfair_lock_unlock(&lock)
    }

    /// The latest per-channel risk readings (cheap — reads detector state).
    func riskByChannel() -> [String: HowlRisk] {
        os_unfair_lock_lock(&lock)
        let readings = detectors.mapValues { $0.risk }
        os_unfair_lock_unlock(&lock)
        return readings
    }

    /// Drops all analysis state (pipeline stop / engine restart), so a new
    /// session never inherits a stale howl run.
    func reset() {
        os_unfair_lock_lock(&lock)
        for detector in detectors.values { detector.reset() }
        os_unfair_lock_unlock(&lock)
    }

    /// Canonicalizes one tap chunk (48 kHz stereo Float32 from the engine,
    /// but defensive — tap consumers must never throw on an odd buffer) and
    /// mono-sums it.
    private func monoSamples(_ sample: CMSampleBuffer) -> [Float]? {
        os_unfair_lock_lock(&lock)
        let pcm = converter.convert(sample)
        os_unfair_lock_unlock(&lock)
        guard let pcm, let interleaved = CanonicalAudioConverter.interleavedFloats(pcm),
              !interleaved.isEmpty else { return nil }
        let channels = Int(pcm.format.channelCount)
        let frames = interleaved.count / channels
        var mono = [Float](repeating: 0, count: frames)
        for frame in 0..<frames {
            var sum: Float = 0
            for channel in 0..<channels {
                sum += interleaved[frame * channels + channel]
            }
            mono[frame] = sum / Float(channels)
        }
        return mono
    }
}
