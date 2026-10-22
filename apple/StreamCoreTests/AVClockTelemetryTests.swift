import Testing
import StreamCore

@Suite struct AVClockTelemetryTests {
    private func measured(offset: Double = 0, skew: Double = 0, drops: Bool = false) -> AVClockSnapshot {
        let clock = AVClockTelemetry()
        for index in 0...1000 {
            let t = Double(index) / 100
            if !drops || index % 7 != 0 { clock.record(.audio, presentationSeconds: 100 + offset + t * (1 + skew), observedHostSeconds: 100 + t) }
            if !drops || index % 5 != 0 { clock.record(.video, presentationSeconds: 100 + t, observedHostSeconds: 100 + t) }
        }
        return clock.snapshot(at: 110)
    }
    @Test func stableOffsetAndSkewAreDifferent() throws {
        let stable = measured(), offset = measured(offset: 0.2), skew = measured(skew: 0.01)
        #expect(stable.state == .stable)
        #expect(abs(try #require(stable.audioMinusVideoMilliseconds)) < 0.001)
        #expect(offset.state == .offset)
        #expect(abs(try #require(offset.audioMinusVideoMilliseconds) - 200) < 0.001)
        #expect(abs(try #require(offset.relativeRateMillisecondsPerSecond)) < 0.001)
        #expect(skew.state == .drifting)
        #expect(abs(try #require(skew.relativeRateMillisecondsPerSecond) - 10) < 0.001)
    }
    @Test func realTimeGapsDoNotChangeRate() throws {
        let snapshot = measured(drops: true)
        #expect(snapshot.state == .stable)
        #expect(abs(try #require(snapshot.relativeRateMillisecondsPerSecond)) < 0.001)
        #expect(snapshot.audioSamples <= 256 && snapshot.videoSamples <= 256)
    }
    @Test func heldCallbackIsNotConfidentClockDrift() {
        let clock = AVClockTelemetry()
        for index in 0...600 {
            let t = Double(index) / 100
            clock.record(.audio, presentationSeconds: t, observedHostSeconds: t + (index == 500 ? 0.1 : 0))
            clock.record(.video, presentationSeconds: t, observedHostSeconds: t)
        }
        let snapshot = clock.snapshot(at: 6)
        #expect(snapshot.state == .unstable)
        #expect(snapshot.relativeRateMillisecondsPerSecond == nil)
        #expect(snapshot.rejectedSamples > 0)
    }
    @Test func freshnessAvailabilityDiscontinuityAndExplicitEpoch() {
        let clock = AVClockTelemetry()
        #expect(clock.snapshot(at: 0).state == .noAudio)
        clock.record(.video, presentationSeconds: 0, observedHostSeconds: 0)
        #expect(clock.snapshot(at: 0).state == .noAudio) // Camera without associated audio.
        for index in 0...300 {
            let t = Double(index) / 100
            clock.record(.audio, presentationSeconds: t, observedHostSeconds: t)
            clock.record(.video, presentationSeconds: t, observedHostSeconds: t)
        }
        #expect(clock.snapshot(at: 5.1).state == .staleAudio)
        clock.record(.audio, presentationSeconds: 10, observedHostSeconds: 10)
        #expect(clock.snapshot(at: 10).state == .staleVideo)
        clock.record(.video, presentationSeconds: 10, observedHostSeconds: 10)
        #expect(clock.snapshot(at: 10).state == .warming)
        #expect(clock.snapshot(at: 10).discontinuities == 2)
        clock.reset()
        clock.record(.audio, presentationSeconds: 0, observedHostSeconds: 20)
        #expect(clock.snapshot(at: 20).state == .noVideo)
        #expect(clock.snapshot(at: 20).discontinuities == 0)
        clock.record(.audio, presentationSeconds: .nan, observedHostSeconds: 20)
        #expect(clock.snapshot(at: 20).rejectedSamples == 1)
    }
}
