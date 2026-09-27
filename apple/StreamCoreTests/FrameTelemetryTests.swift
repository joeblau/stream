import Testing
import StreamCore

/// Unit tests for the frame-drop / achieved-fps telemetry (issue #23 / M8): the
/// cumulative counters, the congestion-vs-total accounting, and the pure per-second
/// rate math the stats HUD and the adaptive logic read.
@Suite struct FrameTelemetryCounterTests {

    @Test("A fresh telemetry is all zeros")
    func freshIsZero() {
        let snapshot = FrameTelemetry().snapshot()
        #expect(snapshot == FrameTelemetrySnapshot())
        #expect(snapshot.captured == 0)
        #expect(snapshot.encoded == 0)
        #expect(snapshot.totalDrops == 0)
        #expect(snapshot.congestionDrops == 0)
    }

    @Test("Captured and encoded frames accumulate independently")
    func capturedAndEncoded() {
        let telemetry = FrameTelemetry()
        for _ in 0..<5 { telemetry.recordCaptured() }
        for _ in 0..<3 { telemetry.recordEncoded() }
        let snapshot = telemetry.snapshot()
        #expect(snapshot.captured == 5)
        #expect(snapshot.encoded == 3)
    }

    @Test("Each drop reason increments only its own counter")
    func dropsByReason() {
        let telemetry = FrameTelemetry()
        telemetry.recordDrop(.pacing)
        telemetry.recordDrop(.pacing)
        telemetry.recordDrop(.backpressure)
        telemetry.recordDrop(.compositor)
        telemetry.recordDrop(.compositor)
        telemetry.recordDrop(.compositor)
        telemetry.recordDrop(.admission)
        let snapshot = telemetry.snapshot()
        #expect(snapshot.pacingDrops == 2)
        #expect(snapshot.backpressureDrops == 1)
        #expect(snapshot.compositorDrops == 3)
        #expect(snapshot.admissionDrops == 1)
        for reason in FrameDropReason.allCases {
            #expect(snapshot.count(of: reason) == {
                switch reason {
                case .pacing: return 2
                case .backpressure: return 1
                case .compositor: return 3
                case .admission: return 1
                }
            }())
        }
    }

    @Test("Congestion drops are backpressure + admission only; total is all four")
    func congestionExcludesPacingAndCompositor() {
        let telemetry = FrameTelemetry()
        telemetry.recordDrop(.pacing)          // intentional downsample — excluded
        telemetry.recordDrop(.compositor)      // overlay only, frame still sent — excluded
        telemetry.recordDrop(.backpressure)
        telemetry.recordDrop(.admission)
        telemetry.recordDrop(.admission)
        let snapshot = telemetry.snapshot()
        #expect(snapshot.congestionDrops == 3)   // 1 backpressure + 2 admission
        #expect(snapshot.totalDrops == 5)        // + 1 pacing + 1 compositor
    }

    @Test("reset() returns every counter to zero")
    func resetZeroes() {
        let telemetry = FrameTelemetry()
        telemetry.recordCaptured()
        telemetry.recordEncoded()
        telemetry.recordDrop(.admission)
        telemetry.reset()
        #expect(telemetry.snapshot() == FrameTelemetrySnapshot())
    }
}

@Suite struct FrameTelemetryRateTests {

    @Test("Achieved fps is the encoded delta over the elapsed window")
    func achievedFrameRate() {
        let previous = FrameTelemetrySnapshot(encoded: 100)
        let current = FrameTelemetrySnapshot(encoded: 130)
        #expect(FrameTelemetry.rate(from: previous, to: current, elapsed: 1.0).achievedFrameRate == 30)
        // Over a 1.5s window the same 30 frames read as 20 fps (rounded).
        #expect(FrameTelemetry.rate(from: previous, to: current, elapsed: 1.5).achievedFrameRate == 20)
        // A short 0.5s window doubles the rate.
        #expect(FrameTelemetry.rate(from: FrameTelemetrySnapshot(encoded: 0),
                                    to: FrameTelemetrySnapshot(encoded: 30),
                                    elapsed: 0.5).achievedFrameRate == 60)
    }

    @Test("Congestion drops per second use backpressure + admission deltas")
    func congestionDropsPerSecond() {
        let previous = FrameTelemetrySnapshot(backpressureDrops: 1, admissionDrops: 1)
        let current = FrameTelemetrySnapshot(pacingDrops: 999,          // ignored
                                             backpressureDrops: 3,
                                             compositorDrops: 999,      // ignored
                                             admissionDrops: 2)
        let rate = FrameTelemetry.rate(from: previous, to: current, elapsed: 1.0)
        #expect(rate.congestionDropsPerSecond == 3)   // (3-1) backpressure + (2-1) admission
    }

    @Test("A window shorter than 0.2s yields zero instead of a divide spike")
    func tooShortWindowIsZero() {
        let previous = FrameTelemetrySnapshot(encoded: 0)
        let current = FrameTelemetrySnapshot(encoded: 5)
        let rate = FrameTelemetry.rate(from: previous, to: current, elapsed: 0.05)
        #expect(rate == FrameTelemetryRates(achievedFrameRate: 0, congestionDropsPerSecond: 0))
        #expect(FrameTelemetry.rate(from: previous, to: current, elapsed: 0).achievedFrameRate == 0)
    }

    @Test("A reset between samples floors deltas at zero (never negative)")
    func resetBetweenSamplesFloorsAtZero() {
        let previous = FrameTelemetrySnapshot(encoded: 100, backpressureDrops: 50, admissionDrops: 10)
        let current = FrameTelemetrySnapshot(encoded: 5, backpressureDrops: 1)   // counters reset then ran
        let rate = FrameTelemetry.rate(from: previous, to: current, elapsed: 1.0)
        #expect(rate.achievedFrameRate == 0)
        #expect(rate.congestionDropsPerSecond == 0)
    }
}
