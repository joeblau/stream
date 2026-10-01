import Foundation
import Testing
import StreamCore

@Suite struct TickerOverlayTests {
    @Test func serializationPreservesSharedIdentity() throws {
        let ticker = TickerOverlayConfiguration(direction: .right, speed: 175, gap: 80)
        let copy = try JSONDecoder().decode(TickerOverlayConfiguration.self,
                                             from: JSONEncoder().encode(ticker))
        #expect(copy == ticker)
        let old = try JSONDecoder().decode(TickerOverlayConfiguration.self, from: Data("{}".utf8))
        #expect(old.speed == 100)
        #expect(old.validationError == nil)
    }

    @Test func payloadBoundsCountUnicodeAndBytes() {
        #expect(TickerOverlayConfiguration.textValidationError(String(repeating: "😀", count: 4096)) == nil)
        #expect(TickerOverlayConfiguration.textValidationError(String(repeating: "a", count: 4097)) != nil)
        // Combining characters form few graphemes but still consume bytes.
        #expect(TickerOverlayConfiguration.textValidationError("a" + String(repeating: "\u{0301}", count: 20_000)) != nil)
    }

    @Test func scrollingUsesContinuousClockAndDirection() {
        var config = TickerOverlayConfiguration(speed: 100, gap: 50)
        #expect(config.offset(elapsed: 1, textWidth: 250, viewportWidth: 500) == -100)
        #expect(config.offset(elapsed: 4, textWidth: 250, viewportWidth: 500) == -100)
        #expect(config.offset(elapsed: 1, textWidth: 250, viewportWidth: 500, scale: 2) == -200)
        config.direction = .right
        #expect(config.offset(elapsed: 1, textWidth: 250, viewportWidth: 500) == 350)
    }

    @Test func pauseFreezesAndResumeKeepsOffset() {
        var state = TimerRuntimeState()
        state.start(at: 100)
        state.pause(at: 102)
        let config = TickerOverlayConfiguration()
        let frozen = config.offset(elapsed: state.elapsed(at: 900), textWidth: 300, viewportWidth: 500)
        state.start(at: 900)
        #expect(config.offset(elapsed: state.elapsed(at: 900), textWidth: 300, viewportWidth: 500) == frozen)
        #expect(state.elapsed(at: 901) == 3)
        state.reset()
        #expect(state.elapsed(at: 901) == 0)
    }

    @Test func malformedValuesStayFinite() {
        let bad = TickerOverlayConfiguration(speed: .nan, gap: .infinity)
        #expect(bad.validationError != nil)
        #expect(bad.clamped().validationError == nil)
        #expect(bad.offset(elapsed: .infinity, textWidth: 200, viewportWidth: 500) == 0)
        #expect(TimerDisplay.elapsedString(seconds: .nan, format: .tenths, roundsUp: false) == "0:00.0")
        #expect(TimerDisplay.elapsedString(seconds: 90.7, format: .tenths, roundsUp: false) == "1:30.7")
    }
}
