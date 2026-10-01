import Foundation
import Testing
import StreamCore

/// Unit tests for G04 (issue #111): the timer-overlay value model (additive
/// wire format, clamping, validation), the transport state machine (the
/// preview/program sharing rules), the display formatting, and the explicit
/// timezone rules for clock and scheduled-start overlays.
@Suite struct TimerOverlayTests {

    // MARK: - Configuration model

    @Test("The default configuration is a five-minute countdown holding at zero")
    func defaults() {
        let config = TimerOverlayConfiguration()
        #expect(config.kind == .countdown)
        #expect(config.durationSeconds == 300)
        #expect(config.format == .hMMss)
        #expect(config.zeroBehavior == .hold)
        #expect(!config.zeroMessage.isEmpty)
        #expect(config.targetHour == 9)
        #expect(config.targetMinute == 0)
        #expect(config.timeZoneIdentifier.isEmpty)
        #expect(config.validationError == nil)
    }

    @Test("Additive decode: an empty object yields defaults")
    func additiveDecodeEmpty() throws {
        let config = try JSONDecoder().decode(TimerOverlayConfiguration.self, from: Data("{}".utf8))
        #expect(config.kind == .countdown)
        #expect(config.durationSeconds == 300)
        #expect(config.validationError == nil)
    }

    @Test("Additive decode: a partial document keeps loading")
    func additiveDecodePartial() throws {
        let config = try JSONDecoder().decode(
            TimerOverlayConfiguration.self,
            from: Data(#"{"kind": "scheduledStart", "targetHour": 18, "targetMinute": 30}"#.utf8))
        #expect(config.kind == .scheduledStart)
        #expect(config.targetHour == 18)
        #expect(config.targetMinute == 30)
        #expect(config.durationSeconds == 300)
        #expect(config.zeroBehavior == .hold)
    }

    @Test("Full round-trip preserves every field")
    func roundTrip() throws {
        let config = TimerOverlayConfiguration(kind: .scheduledStart,
                                               durationSeconds: 1800,
                                               format: .clock12,
                                               zeroBehavior: .message,
                                               zeroMessage: "We're live!",
                                               targetHour: 17,
                                               targetMinute: 45,
                                               timeZoneIdentifier: "America/New_York")
        let decoded = try JSONDecoder().decode(
            TimerOverlayConfiguration.self, from: JSONEncoder().encode(config))
        #expect(decoded == config)
    }

    @Test("Clamping pins duration, target time, and message length to their ranges")
    func clamping() {
        var config = TimerOverlayConfiguration()
        config.durationSeconds = -50
        config.targetHour = 99
        config.targetMinute = -1
        config.zeroMessage = String(repeating: "x", count: 500)
        let clamped = config.clamped()
        #expect(clamped.durationSeconds == 1)
        #expect(clamped.targetHour == 23)
        #expect(clamped.targetMinute == 0)
        #expect(clamped.zeroMessage.count == 200)
        #expect(clamped.validationError == nil)
    }

    @Test("Validation rejects out-of-range values with reasons")
    func validation() {
        var config = TimerOverlayConfiguration()
        config.durationSeconds = 0
        #expect(config.validationError != nil)
        config.durationSeconds = .infinity
        #expect(config.validationError != nil)
        config.durationSeconds = 300
        config.targetHour = 24
        #expect(config.validationError != nil)
        config.targetHour = 12
        config.targetMinute = 60
        #expect(config.validationError != nil)
        config.targetMinute = 30
        #expect(config.validationError == nil)
    }

    @Test("Only elapsed kinds use the transport")
    func transportKinds() {
        #expect(TimerOverlayKind.countdown.usesTransport)
        #expect(TimerOverlayKind.stopwatch.usesTransport)
        #expect(!TimerOverlayKind.clock.usesTransport)
        #expect(!TimerOverlayKind.scheduledStart.usesTransport)
    }

    // MARK: - Transport state machine

    @Test("Idle timers bank nothing; start anchors; elapsed accumulates")
    func startAndElapse() {
        var state = TimerRuntimeState()
        #expect(state.phase == .idle)
        #expect(state.elapsed(at: 1000) == 0)
        state.start(at: 1000)
        #expect(state.phase == .running)
        #expect(state.elapsed(at: 1000) == 0)
        #expect(state.elapsed(at: 1042.5) == 42.5)
    }

    @Test("Start on a running timer is a no-op — a live timer is never reset by a second start")
    func startDoesNotResetRunning() {
        var state = TimerRuntimeState()
        state.start(at: 1000)
        state.start(at: 1050) // e.g. a preview engine re-staging the scene
        #expect(state.elapsed(at: 1050) == 50)
        #expect(state.anchorSeconds == 1000)
    }

    @Test("Pause banks the elapsed; resume continues from the bank")
    func pauseAndResume() {
        var state = TimerRuntimeState()
        state.start(at: 1000)
        state.pause(at: 1010)
        #expect(state.phase == .paused)
        #expect(state.elapsed(at: 9999) == 10)
        state.pause(at: 2000) // no-op while paused
        #expect(state.elapsed(at: 9999) == 10)
        state.start(at: 2000)
        #expect(state.elapsed(at: 2000) == 10)
        #expect(state.elapsed(at: 2005) == 15)
    }

    @Test("Reset returns to idle with a zeroed bank — the only re-anchor")
    func reset() {
        var state = TimerRuntimeState()
        state.start(at: 1000)
        state.pause(at: 1010)
        state.reset()
        #expect(state.phase == .idle)
        #expect(state.elapsed(at: 2000) == 0)
        state.start(at: 2000)
        #expect(state.elapsed(at: 2003) == 3)
    }

    // MARK: - Formatting

    @Test("Elapsed formats pin their strings")
    func elapsedFormatting() {
        #expect(TimerDisplay.elapsedString(seconds: 3909, format: .hMMss, roundsUp: false) == "1:05:09")
        #expect(TimerDisplay.elapsedString(seconds: 65, format: .hMMss, roundsUp: false) == "1:05")
        #expect(TimerDisplay.elapsedString(seconds: 3909, format: .mmss, roundsUp: false) == "65:09")
        #expect(TimerDisplay.elapsedString(seconds: 3909, format: .seconds, roundsUp: false) == "3909")
        #expect(TimerDisplay.elapsedString(seconds: 65.07, format: .tenths, roundsUp: false) == "1:05.0")
        #expect(TimerDisplay.elapsedString(seconds: 5.9, format: .tenths, roundsUp: false) == "0:05.9")
        // Negative input clamps to zero.
        #expect(TimerDisplay.elapsedString(seconds: -3, format: .hMMss, roundsUp: true) == "0:00")
    }

    @Test("Countdowns round up, stopwatches round down")
    func roundingConvention() {
        #expect(TimerDisplay.elapsedString(seconds: 299.2, format: .hMMss, roundsUp: true) == "5:00")
        #expect(TimerDisplay.elapsedString(seconds: 299.2, format: .hMMss, roundsUp: false) == "4:59")
    }

    @Test("A wall-clock format on an elapsed value falls back to H:MM:SS")
    func elapsedFormatFallback() {
        #expect(TimerDisplay.elapsedString(seconds: 65, format: .clock12, roundsUp: false) == "1:05")
        #expect(TimerDisplay.elapsedString(seconds: 65, format: .clock24, roundsUp: false) == "1:05")
    }

    // MARK: - Timezone rules

    @Test("Clock formatting applies the explicit timezone")
    func clockFormatting() {
        // 2026-10-01 15:45:00 UTC.
        let epoch = 1_790_869_500.0
        #expect(TimerDisplay.wallClockString(epochSeconds: epoch, format: .clock24,
                                             timeZoneIdentifier: "UTC") == "15:45")
        #expect(TimerDisplay.wallClockString(epochSeconds: epoch, format: .clock12,
                                             timeZoneIdentifier: "UTC") == "3:45 PM")
        // EDT is UTC-4 in October.
        #expect(TimerDisplay.wallClockString(epochSeconds: epoch, format: .clock24,
                                             timeZoneIdentifier: "America/New_York") == "11:45")
        #expect(TimerDisplay.wallClockString(epochSeconds: epoch, format: .clock12,
                                             timeZoneIdentifier: "America/New_York") == "11:45 AM")
        // An elapsed format picked for a clock falls back to the 24-hour clock.
        #expect(TimerDisplay.wallClockString(epochSeconds: epoch, format: .hMMss,
                                             timeZoneIdentifier: "UTC") == "15:45")
    }

    @Test("Empty and unknown timezone identifiers fall back to the system zone")
    func timezoneFallback() {
        #expect(TimerDisplay.resolvedTimeZone(identifier: "") == .current)
        #expect(TimerDisplay.resolvedTimeZone(identifier: "Not/AZone") == .current)
        #expect(TimerDisplay.resolvedTimeZone(identifier: "Europe/Berlin")
                == TimeZone(identifier: "Europe/Berlin"))
    }

    @Test("Scheduled target resolves on the same calendar day in the configured timezone")
    func scheduledSameDay() {
        // 2026-10-01 15:45:00 UTC = 11:45 EDT.
        let epoch = 1_790_869_500.0
        let target = TimerDisplay.scheduledEpoch(onDayOf: epoch, hour: 12, minute: 30,
                                                 timeZoneIdentifier: "America/New_York")
        // 12:30 EDT = 16:30 UTC.
        #expect(target == epoch + 45 * 60)
    }

    @Test("The next scheduled occurrence rolls to tomorrow once today's has passed")
    func scheduledNextDay() {
        // 2026-10-01 15:45:00 UTC; target 09:00 UTC has passed today.
        let epoch = 1_790_869_500.0
        let next = TimerDisplay.nextScheduledEpoch(after: epoch, hour: 9, minute: 0,
                                                   timeZoneIdentifier: "UTC")
        // 2026-10-02 09:00:00 UTC.
        #expect(next == epoch + (17 * 60 + 15) * 60)
        // A future target today stays today.
        let today = TimerDisplay.nextScheduledEpoch(after: epoch, hour: 18, minute: 0,
                                                    timeZoneIdentifier: "UTC")
        #expect(today == epoch + (2 * 60 + 15) * 60)
    }

    // MARK: - Sampling

    @Test("An idle countdown reads its full duration and is never finished")
    func countdownIdle() {
        let config = TimerOverlayConfiguration(durationSeconds: 300)
        let sample = TimerOverlayResolver.sample(configuration: config,
                                                 state: TimerRuntimeState(),
                                                 engineSeconds: 999, wallClockEpoch: 0)
        #expect(sample.text == "5:00")
        #expect(sample.phase == .idle)
        #expect(!sample.isFinished)
    }

    @Test("A running countdown counts down to the zero behavior")
    func countdownRunning() {
        let config = TimerOverlayConfiguration(durationSeconds: 60)
        var state = TimerRuntimeState()
        state.start(at: 1000)
        var sample = TimerOverlayResolver.sample(configuration: config, state: state,
                                                 engineSeconds: 1030.2, wallClockEpoch: 0)
        #expect(sample.text == "0:30") // rounds up from 29.8
        #expect(!sample.isFinished)
        sample = TimerOverlayResolver.sample(configuration: config, state: state,
                                             engineSeconds: 1060, wallClockEpoch: 0)
        #expect(sample.text == "0:00")
        #expect(sample.isFinished)
    }

    @Test("Zero behaviors: hold, hide, message (empty message hides), restart wraps")
    func zeroBehaviors() {
        var state = TimerRuntimeState()
        state.start(at: 1000)
        let atZero = 1000 + 305.0 // five minutes plus five seconds, 300s countdown

        var config = TimerOverlayConfiguration(durationSeconds: 300, zeroBehavior: .hold)
        #expect(TimerOverlayResolver.sample(configuration: config, state: state,
                                            engineSeconds: atZero, wallClockEpoch: 0).text == "0:00")

        config.zeroBehavior = .hide
        #expect(TimerOverlayResolver.sample(configuration: config, state: state,
                                            engineSeconds: atZero, wallClockEpoch: 0).text == nil)

        config.zeroBehavior = .message
        config.zeroMessage = "We're live!"
        #expect(TimerOverlayResolver.sample(configuration: config, state: state,
                                            engineSeconds: atZero, wallClockEpoch: 0).text == "We're live!")
        config.zeroMessage = ""
        #expect(TimerOverlayResolver.sample(configuration: config, state: state,
                                            engineSeconds: atZero, wallClockEpoch: 0).text == nil)

        config.zeroBehavior = .restart
        let sample = TimerOverlayResolver.sample(configuration: config, state: state,
                                                 engineSeconds: atZero, wallClockEpoch: 0)
        #expect(!sample.isFinished)
        #expect(sample.text == "4:55") // five seconds into the second lap
    }

    @Test("A paused countdown holds its remaining reading")
    func countdownPaused() {
        let config = TimerOverlayConfiguration(durationSeconds: 60)
        var state = TimerRuntimeState()
        state.start(at: 1000)
        state.pause(at: 1045)
        let sample = TimerOverlayResolver.sample(configuration: config, state: state,
                                                 engineSeconds: 9999, wallClockEpoch: 0)
        #expect(sample.text == "0:15")
        #expect(sample.phase == .paused)
        #expect(sample.displaySeconds == 15)
    }

    @Test("A stopwatch counts up while running and freezes paused")
    func stopwatch() {
        let config = TimerOverlayConfiguration(kind: .stopwatch, format: .hMMss)
        var state = TimerRuntimeState()
        var sample = TimerOverlayResolver.sample(configuration: config, state: state,
                                                 engineSeconds: 500, wallClockEpoch: 0)
        #expect(sample.text == "0:00") // idle
        state.start(at: 1000)
        sample = TimerOverlayResolver.sample(configuration: config, state: state,
                                             engineSeconds: 1090.7, wallClockEpoch: 0)
        #expect(sample.text == "1:30") // rounds down from 90.7
        #expect(!sample.isFinished)
    }

    @Test("The clock overlay reads the wall clock in the configured timezone")
    func clockSample() {
        let config = TimerOverlayConfiguration(kind: .clock, format: .clock12,
                                               timeZoneIdentifier: "America/New_York")
        let sample = TimerOverlayResolver.sample(configuration: config,
                                                 state: TimerRuntimeState(),
                                                 engineSeconds: 42,
                                                 wallClockEpoch: 1_790_869_500)
        #expect(sample.text == "11:45 AM")
        #expect(!sample.isFinished)
    }

    @Test("Scheduled start counts down to the target, then applies the zero behavior")
    func scheduledStartSample() {
        // 2026-10-01 15:45:00 UTC; target 18:00 UTC = 2h15m away.
        let epoch = 1_790_869_500.0
        var config = TimerOverlayConfiguration(kind: .scheduledStart, format: .hMMss,
                                               targetHour: 18, targetMinute: 0,
                                               timeZoneIdentifier: "UTC")
        var sample = TimerOverlayResolver.sample(configuration: config,
                                                 state: TimerRuntimeState(),
                                                 engineSeconds: 0, wallClockEpoch: epoch)
        #expect(sample.text == "2:15:00")
        #expect(!sample.isFinished)

        // Past the target: hold reads zero and finishes.
        config.zeroBehavior = .hold
        sample = TimerOverlayResolver.sample(configuration: config,
                                             state: TimerRuntimeState(),
                                             engineSeconds: 0, wallClockEpoch: epoch + 3 * 3600)
        #expect(sample.text == "0:00")
        #expect(sample.isFinished)

        // Restart rolls to tomorrow's occurrence.
        config.zeroBehavior = .restart
        sample = TimerOverlayResolver.sample(configuration: config,
                                             state: TimerRuntimeState(),
                                             engineSeconds: 0, wallClockEpoch: epoch)
        #expect(sample.text == "2:15:00") // today's target still upcoming
        sample = TimerOverlayResolver.sample(configuration: config,
                                             state: TimerRuntimeState(),
                                             engineSeconds: 0, wallClockEpoch: epoch + 3 * 3600)
        #expect(sample.text == "23:15:00") // 23h15m until 18:00 UTC tomorrow
        #expect(!sample.isFinished)
    }

    @Test("Sampling never mutates the shared state — preview and program read the same timer")
    func samplingIsPure() {
        let config = TimerOverlayConfiguration(durationSeconds: 60)
        var state = TimerRuntimeState()
        state.start(at: 1000)
        let before = state
        // Two engines in the same host-clock domain sample at their own ticks.
        let preview = TimerOverlayResolver.sample(configuration: config, state: state,
                                                  engineSeconds: 1010, wallClockEpoch: 0)
        let program = TimerOverlayResolver.sample(configuration: config, state: state,
                                                  engineSeconds: 1010.033, wallClockEpoch: 0)
        #expect(state == before)
        #expect(preview.text == program.text)
        #expect(preview.text == "0:50")
    }
}
