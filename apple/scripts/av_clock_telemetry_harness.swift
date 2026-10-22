import Foundation

@main struct AVClockTelemetryHarness {
    static func main() throws {
        func measured(offset: Double = 0, skew: Double = 0, drop: Bool = false) -> AVClockSnapshot {
            let clock = AVClockTelemetry()
            for index in 0...1000 {
                let t = Double(index) / 100
                if !drop || index % 7 != 0 { clock.record(.audio, presentationSeconds: 100 + offset + t * (1 + skew), observedHostSeconds: 100 + t) }
                if !drop || index % 5 != 0 { clock.record(.video, presentationSeconds: 100 + t, observedHostSeconds: 100 + t) }
            }
            return clock.snapshot(at: 110)
        }
        let stable = measured(), offset = measured(offset: 0.2), skew = measured(skew: 0.01), drops = measured(drop: true)
        precondition(stable.state == .stable && abs(stable.audioMinusVideoMilliseconds!) < 0.001)
        precondition(offset.state == .offset && abs(offset.audioMinusVideoMilliseconds! - 200) < 0.001 && abs(offset.relativeRateMillisecondsPerSecond!) < 0.001)
        precondition(skew.state == .drifting && abs(skew.relativeRateMillisecondsPerSecond! - 10) < 0.001)
        precondition(drops.state == .stable && abs(drops.relativeRateMillisecondsPerSecond!) < 0.001)
        precondition(drops.audioSamples <= 256 && drops.videoSamples <= 256)
        let held = AVClockTelemetry()
        for index in 0...600 {
            let t = Double(index) / 100
            held.record(.audio, presentationSeconds: t, observedHostSeconds: t + (index == 500 ? 0.1 : 0))
            held.record(.video, presentationSeconds: t, observedHostSeconds: t)
        }
        precondition(held.snapshot(at: 6).state == .unstable && held.snapshot(at: 6).relativeRateMillisecondsPerSecond == nil)
        precondition(held.snapshot(at: 8.1).state == .staleAudio)
        let epoch = AVClockTelemetry()
        epoch.record(.audio, presentationSeconds: 100, observedHostSeconds: 0)
        epoch.record(.audio, presentationSeconds: 0, observedHostSeconds: 0.1)
        precondition(epoch.snapshot(at: 0.1).discontinuities == 1)
        held.reset(); held.record(.video, presentationSeconds: 0, observedHostSeconds: 10)
        precondition(held.snapshot(at: 10).state == .noAudio)
        held.reset(); held.record(.audio, presentationSeconds: 0, observedHostSeconds: 20)
        precondition(held.snapshot(at: 20).state == .noVideo)
        held.record(.audio, presentationSeconds: .nan, observedHostSeconds: 20)
        precondition(held.snapshot(at: 20).rejectedSamples == 1)
        _ = try JSONEncoder().encode([stable, offset, skew, drops, held.snapshot(at: 20)])
        print("PASS: actual AVClockTelemetry fixed offset vs rate skew, stable clocks, dropped samples, held callback confidence, stale/missing tracks, bounded samples, new epoch and redacted numeric JSON")
    }
}
