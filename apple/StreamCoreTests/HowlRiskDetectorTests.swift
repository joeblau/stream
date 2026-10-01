import Foundation
import Testing
import StreamCore

/// Tests for the A09 acoustic-feedback detector. Each test synthesizes named
/// tone/noise fixtures (mono Float32 at 48 kHz — the engine's canonical rate)
/// and feeds the detector's mic + monitor (reference) paths as the taps would.
@Suite struct HowlRiskDetectorTests {

    // MARK: - Fixtures

    private func tone(frequency: Double, amplitude: Double, seconds: Double) -> [Float] {
        let frames = Int(seconds * Double(HowlRiskDetector.sampleRate))
        return (0..<frames).map {
            Float(amplitude * sin(2 * Double.pi * frequency * Double($0) / Double(HowlRiskDetector.sampleRate)))
        }
    }

    /// A tone whose amplitude ramps linearly from `start` to `end` — the
    /// regenerative-growth signature of a forming howl.
    private func growingTone(frequency: Double, from start: Double, to end: Double,
                             seconds: Double) -> [Float] {
        let frames = Int(seconds * Double(HowlRiskDetector.sampleRate))
        return (0..<frames).map { index in
            let amplitude = start + (end - start) * Double(index) / Double(frames)
            return Float(amplitude * sin(2 * Double.pi * frequency * Double(index)
                                         / Double(HowlRiskDetector.sampleRate)))
        }
    }

    /// Deterministic broadband noise (LCG) — loud but aperiodic, like music.
    private func noise(amplitude: Double, seconds: Double) -> [Float] {
        let frames = Int(seconds * Double(HowlRiskDetector.sampleRate))
        var state: UInt64 = 0x1234_5678_9abc_def0
        return (0..<frames).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let uniform = Double(state >> 33) / Double(UInt32.max) - 0.5
            return Float(2 * amplitude * uniform)
        }
    }

    private func silence(seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * Double(HowlRiskDetector.sampleRate)))
    }

    /// Feeds mic + reference in interleaved 20 ms blocks, as the tap delivery
    /// would interleave them on their serial queues.
    private func feed(_ detector: HowlRiskDetector, mic: [Float], reference: [Float]) {
        let block = 960
        let count = min(mic.count, reference.count)
        var offset = 0
        while offset < count {
            let end = min(offset + block, count)
            detector.ingestMic(Array(mic[offset..<end]))
            detector.ingestReference(Array(reference[offset..<end]))
            offset = end
        }
    }

    // MARK: - Howl signatures

    @Test("A rising tone over a live monitor escalates to howl risk")
    func risingToneIsHowlRisk() {
        let detector = HowlRiskDetector()
        feed(detector,
             mic: growingTone(frequency: 220, from: 0.02, to: 0.6, seconds: 3),
             reference: tone(frequency: 220, amplitude: 0.2, seconds: 3))
        guard case .howlRisk(let seconds, _) = detector.risk else {
            Issue.record("expected howl risk, got \(detector.risk)")
            return
        }
        #expect(seconds >= HowlRiskDetector.howlHoldSeconds)
    }

    @Test("A loud steady tone over a live monitor is howl risk (pinned hot)")
    func loudSteadyToneIsHowlRisk() {
        let detector = HowlRiskDetector()
        feed(detector,
             mic: tone(frequency: 440, amplitude: 0.5, seconds: 3),
             reference: tone(frequency: 440, amplitude: 0.2, seconds: 3))
        #expect(detector.risk.isWarning)
    }

    @Test("Loud broadband noise is not a howl (aperiodic, like music)")
    func noiseIsClear() {
        let detector = HowlRiskDetector()
        feed(detector,
             mic: noise(amplitude: 0.5, seconds: 3),
             reference: noise(amplitude: 0.3, seconds: 3))
        #expect(detector.risk == .clear)
    }

    @Test("A loud tone with a SILENT monitor is not a loop")
    func silentMonitorIsClear() {
        let detector = HowlRiskDetector()
        feed(detector,
             mic: tone(frequency: 440, amplitude: 0.5, seconds: 3),
             reference: silence(seconds: 3))
        #expect(detector.risk == .clear)
    }

    @Test("A quiet tone under the candidate floor is clear")
    func quietToneIsClear() {
        let detector = HowlRiskDetector()
        feed(detector,
             mic: tone(frequency: 440, amplitude: 0.02, seconds: 3),
             reference: tone(frequency: 440, amplitude: 0.2, seconds: 3))
        #expect(detector.risk == .clear)
    }

    @Test("A short beep never reaches the watch hold")
    func shortToneIsClear() {
        let detector = HowlRiskDetector()
        feed(detector,
             mic: tone(frequency: 440, amplitude: 0.5, seconds: 0.3),
             reference: tone(frequency: 440, amplitude: 0.2, seconds: 0.3))
        #expect(detector.risk == .clear)
    }

    @Test("A moderate sustained tone reaches watch without escalating")
    func sustainedModerateToneIsWatch() {
        let detector = HowlRiskDetector()
        // −18 dBFS RMS: above the candidate floor, below the hot ceiling, and
        // not rising — watch, not howl risk.
        feed(detector,
             mic: tone(frequency: 330, amplitude: 0.18, seconds: 3),
             reference: tone(frequency: 330, amplitude: 0.2, seconds: 3))
        guard case .watch = detector.risk else {
            Issue.record("expected watch, got \(detector.risk)")
            return
        }
    }

    @Test("The risk clears once the tone stops")
    func riskClearsWhenToneStops() {
        let detector = HowlRiskDetector()
        feed(detector,
             mic: tone(frequency: 440, amplitude: 0.5, seconds: 2.5),
             reference: tone(frequency: 440, amplitude: 0.2, seconds: 2.5))
        #expect(detector.risk.isWarning)
        feed(detector,
             mic: silence(seconds: 1.5),
             reference: tone(frequency: 440, amplitude: 0.2, seconds: 1.5))
        #expect(detector.risk == .clear)
    }
}
