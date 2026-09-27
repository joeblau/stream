/// A pure exponentially-weighted moving average of measured egress throughput,
/// fed the 1 Hz `currentBytesOutPerSecond` deltas HaishinKit's `NetworkMonitor`
/// already surfaces. It smooths the single-sample capacity reading the ABR used
/// to react to, so a lone keyframe burst or a momentary radio stall no longer
/// drives an over-deep cut, and it gives the upward probe measured evidence that
/// a link is actually carrying the current rate before it climbs above the
/// conservative per-path seed (issue #24).
///
/// Lives in StreamCore, `Sendable` + `Equatable`, so the arithmetic is unit-tested
/// on CI alongside `AdaptiveBitRateState` rather than resting on device testing.
public struct ThroughputEstimator: Sendable, Equatable {
    /// EWMA weight on the newest sample. 0.4 tracks a genuine capacity change
    /// (e.g. a 5G→LTE handoff) within a few ticks while still filtering the
    /// per-second jitter of RTMP framing and keyframes.
    public static let smoothingFactor = 0.4

    /// The smoothed estimate in BITS per second (the sample is bytes/s × 8), or 0
    /// before the first positive sample.
    public private(set) var bitsPerSecond = 0

    /// False until at least one positive sample has seeded the average, so the
    /// first sample is adopted verbatim instead of being blended with 0.
    public private(set) var hasSample = false

    public init() {}

    /// Fold one 1 Hz egress sample (bytes/s, as reported by the network monitor)
    /// into the average. Non-positive samples are ignored: a zero-output tick is a
    /// stall, not evidence of low capacity, and blending it in would poison the
    /// estimate right when the ABR most needs a stable capacity read.
    public mutating func record(bytesOutPerSecond: Int) {
        guard bytesOutPerSecond > 0 else { return }
        let sample = bytesOutPerSecond * 8
        if hasSample {
            bitsPerSecond = Int(Self.smoothingFactor * Double(sample)
                                + (1 - Self.smoothingFactor) * Double(bitsPerSecond))
        } else {
            bitsPerSecond = sample
            hasSample = true
        }
    }

    /// Drop the learned estimate. Called on a handoff to a DIFFERENT physical link
    /// whose capacity is unknown, so a stale Wi-Fi average can never justify
    /// probing a fresh, weaker cellular link above its seed.
    public mutating func reset() {
        bitsPerSecond = 0
        hasSample = false
    }
}
