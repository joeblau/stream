import Foundation

/// A09 (issue #121): one mic channel's acoustic-feedback (howl) risk, as
/// classified by `HowlRiskDetector`.
public enum HowlRisk: Equatable, Sendable {
    /// No loop signature.
    case clear
    /// A loud, sustained, highly periodic mic signal is present while the
    /// monitor bus is live — the early signature of a monitor→room→mic loop.
    case watch(seconds: Double)
    /// The signature has held long enough (and is rising or very loud) that a
    /// howl is forming. The UI surfaces this with the routing repair.
    case howlRisk(seconds: Double, levelDBFS: Double)

    public var isWarning: Bool {
        if case .howlRisk = self { return true }
        return false
    }

    /// The actionable fix shown next to the warning (issue #121: "surface
    /// actionable warnings with the exact fix").
    public var fixSuggestion: String {
        "Mute the channel or lower the Monitor fader, and move the mic away from the speakers."
    }
}

/// A09 (issue #121): envelope/periodicity acoustic-feedback detector for one
/// mic channel, fed by the engine's isolated (pre-fader) mic tap and a monitor
/// bus tap — both positioned on the engine's shared host clock.
///
/// **Why not cross-correlation alone.** The monitor bus legitimately contains
/// the mic (it mirrors program), so mic↔monitor correlation is high in NORMAL
/// operation and cannot by itself distinguish a person speaking from a
/// regenerative loop. The howl signature used here instead is:
///
/// - the mic signal is LOUD (`rms ≥ candidateFloorDBFS`) and
/// - highly PERIODIC (normalized autocorrelation peak ≥ `periodicityThreshold`
///   over 60 Hz–1 kHz — speech/music rarely sustain that, a howling
///   narrowband oscillation always does), and
/// - SUSTAINED (`watchHoldSeconds`/`howlHoldSeconds`), and
/// - the monitor bus is LIVE (no live monitor ⇒ no loop is possible), and
/// - for the howl-risk escalation: RISING (`riseDBThreshold` over the last
///   second — regenerative gain) or pinned very loud (`hotLevelDBFS`).
///
/// The detector is deliberately heuristic: it DETECTS and WARNS with a routing
/// repair instead of attempting DSP suppression (see `EchoHandlingEvaluation`).
/// Not `Sendable`: confine one instance per mic channel under the caller's lock.
public final class HowlRiskDetector {
    public static let sampleRate = 48_000
    /// Analysis window: ~42.7 ms — short enough to track a rising howl.
    public static let windowFrames = 2_048
    /// History kept for trend evaluation (~3 s).
    public static let historyWindows = 70

    /// Candidate thresholds (see the class docs).
    public static let candidateFloorDBFS = -24.0
    public static let periodicityThreshold = 0.70
    public static let monitorLiveFloorDBFS = -50.0
    public static let watchHoldSeconds = 0.5
    public static let howlHoldSeconds = 1.5
    public static let riseDBThreshold = 6.0
    public static let hotLevelDBFS = -12.0
    /// Candidate runs tolerate this many consecutive non-candidate windows
    /// (a howl doesn't pause; this only absorbs analysis edge effects).
    public static let toleratedMisses = 1

    private struct Window {
        var rmsDBFS: Double
        var periodicity: Double
        var monitorLive: Bool
    }

    private var micPending: [Float] = []
    private var referencePending: [Float] = []
    private var windows: [Window] = []
    /// Consecutive non-candidate windows inside the current run.
    private var misses = 0

    public init() {}

    public func reset() {
        micPending.removeAll(keepingCapacity: true)
        referencePending.removeAll(keepingCapacity: true)
        windows.removeAll(keepingCapacity: true)
        misses = 0
    }

    /// Feeds one chunk of the mic channel (mono samples at `sampleRate`).
    public func ingestMic(_ mono: [Float]) {
        micPending.append(contentsOf: mono)
        evaluatePending()
    }

    /// Feeds one chunk of the monitor/reference bus (mono samples).
    public func ingestReference(_ mono: [Float]) {
        referencePending.append(contentsOf: mono)
        evaluatePending()
    }

    /// The current risk classification, from the retained window history.
    public var risk: HowlRisk {
        var runSeconds = 0.0
        var recentLevels: [Double] = []
        let windowSeconds = Double(Self.windowFrames) / Double(Self.sampleRate)
        // Walk the newest windows backwards: the candidate run ends at the
        // first gap beyond the tolerated misses.
        var missed = 0
        for window in windows.reversed() {
            let candidate = window.periodicity >= Self.periodicityThreshold
                && window.rmsDBFS >= Self.candidateFloorDBFS
                && window.monitorLive
            if candidate {
                runSeconds += windowSeconds
                recentLevels.append(window.rmsDBFS)
            } else {
                missed += 1
                if missed > Self.toleratedMisses { break }
            }
        }
        guard runSeconds >= Self.watchHoldSeconds else { return .clear }
        let level = recentLevels.max() ?? Self.candidateFloorDBFS
        // Rise over roughly the last second of the run (regenerative gain).
        let recentWindowCount = max(1, Int(1.0 / windowSeconds))
        let trend = Array(recentLevels.prefix(recentWindowCount))
        let rise = (trend.first ?? level) - (trend.min() ?? level)
        if runSeconds >= Self.howlHoldSeconds,
           rise >= Self.riseDBThreshold || level >= Self.hotLevelDBFS {
            return .howlRisk(seconds: runSeconds, levelDBFS: level)
        }
        return .watch(seconds: runSeconds)
    }

    // MARK: - Window extraction

    private func evaluatePending() {
        let frames = Self.windowFrames
        while micPending.count >= frames && referencePending.count >= frames {
            let micWindow = Array(micPending.prefix(frames))
            let referenceWindow = Array(referencePending.prefix(frames))
            micPending.removeFirst(frames)
            referencePending.removeFirst(frames)
            let micRMS = Self.rms(micWindow)
            let window = Window(
                rmsDBFS: 20 * log10(max(Double(micRMS), 1e-7)),
                periodicity: micRMS > 1e-5 ? Self.periodicity(micWindow) : 0,
                monitorLive: 20 * log10(max(Double(Self.rms(referenceWindow)), 1e-7))
                    >= Self.monitorLiveFloorDBFS)
            windows.append(window)
            if windows.count > Self.historyWindows {
                windows.removeFirst(windows.count - Self.historyWindows)
            }
        }
    }

    private static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return (sum / Float(samples.count)).squareRoot()
    }

    /// Normalized autocorrelation peak over 60 Hz–1 kHz lags: 1 for a pure
    /// tone, near 0 for broadband noise. Computed on the window's mean-removed
    /// signal so a DC offset can't masquerade as periodicity.
    private static func periodicity(_ samples: [Float]) -> Double {
        let count = samples.count
        let mean = samples.reduce(0, +) / Float(count)
        var energy: Float = 0
        var centered = [Float](repeating: 0, count: count)
        for index in 0..<count {
            let value = samples[index] - mean
            centered[index] = value
            energy += value * value
        }
        guard energy > 1e-8 else { return 0 }
        let minLag = max(1, Self.sampleRate / 1_000)   // 1 kHz
        let maxLag = min(count / 2, Self.sampleRate / 60) // 60 Hz
        var best: Float = 0
        for lag in minLag...maxLag {
            var correlation: Float = 0
            for index in 0..<(count - lag) {
                correlation += centered[index] * centered[index + lag]
            }
            let normalized = correlation / energy
            if normalized > best { best = normalized }
        }
        return Double(best)
    }
}
