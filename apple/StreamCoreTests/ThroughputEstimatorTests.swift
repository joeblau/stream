import Testing
import StreamCore

/// Unit tests for the EWMA throughput estimator (issue #24). These pin the exact
/// smoothing arithmetic so the ABR's smoothed reduction and probe gate can't
/// silently drift.
@Suite struct ThroughputEstimatorTests {

    @Test("The first positive sample is adopted verbatim (bytes → bits)")
    func firstSampleVerbatim() {
        var e = ThroughputEstimator()
        #expect(e.hasSample == false)
        #expect(e.bitsPerSecond == 0)
        e.record(bytesOutPerSecond: 500_000)
        #expect(e.hasSample)
        #expect(e.bitsPerSecond == 4_000_000)   // 500_000 * 8, no blending with 0
    }

    @Test("Subsequent samples blend at the 0.4 smoothing factor")
    func blendsAtSmoothingFactor() {
        var e = ThroughputEstimator()
        e.record(bytesOutPerSecond: 500_000)     // 4_000_000
        e.record(bytesOutPerSecond: 100_000)     // 0.4*800_000 + 0.6*4_000_000 = 2_720_000
        #expect(e.bitsPerSecond == 2_720_000)
        e.record(bytesOutPerSecond: 100_000)     // 0.4*800_000 + 0.6*2_720_000 = 1_952_000
        #expect(e.bitsPerSecond == 1_952_000)
    }

    @Test("Non-positive samples are ignored, not blended toward zero")
    func ignoresNonPositiveSamples() {
        var e = ThroughputEstimator()
        e.record(bytesOutPerSecond: 500_000)
        e.record(bytesOutPerSecond: 0)           // a stall is not evidence of low capacity
        e.record(bytesOutPerSecond: -10)
        #expect(e.bitsPerSecond == 4_000_000)    // unchanged
        #expect(e.hasSample)
    }

    @Test("reset() clears the estimate so a new link starts blind")
    func resetClears() {
        var e = ThroughputEstimator()
        e.record(bytesOutPerSecond: 500_000)
        e.reset()
        #expect(e.bitsPerSecond == 0)
        #expect(e.hasSample == false)
        // After reset the next sample is again adopted verbatim.
        e.record(bytesOutPerSecond: 250_000)
        #expect(e.bitsPerSecond == 2_000_000)
    }
}
