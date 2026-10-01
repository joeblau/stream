import CoreText
import Foundation
import Testing
import StreamCore

/// Unit tests for G02 (issue #110): the text-layer value model (additive
/// wire format, clamping, validation), the timed/fly-in visibility state
/// machine, `{token}` title-template resolution, the pinned font fallback
/// chain, and the CoreText measurement/fit math the renderer's auto-size and
/// scale-down paths are built on.
@Suite struct TextLayoutTests {

    // MARK: - TextTitleStyle model

    @Test("The default style is the pre-G02 behavior — a render-compatible fixed box")
    func defaults() {
        let style = TextTitleStyle()
        #expect(style.fontName == nil)
        #expect(style.fontSize == 48)
        #expect(style.colorHex == "#FFFFFF")
        #expect(style.alignment == .leading)
        #expect(style.verticalAlignment == .center)
        #expect(style.backgroundColorHex == nil)
        #expect(style.padding == 0)
        #expect(style.boxSizing == .fixed)
        #expect(style.wraps)
        #expect(style.overflow == .clip)
        #expect(style.timing == nil)
        #expect(style.validationError == nil)
    }

    @Test("Additive decode: an empty object yields defaults")
    func additiveDecodeEmpty() throws {
        let style = try JSONDecoder().decode(TextTitleStyle.self, from: Data("{}".utf8))
        #expect(style == TextTitleStyle())
    }

    @Test("Additive decode: a document predating G02 fields keeps loading")
    func additiveDecodePartial() throws {
        let style = try JSONDecoder().decode(
            TextTitleStyle.self,
            from: Data(#"{"fontSize": 64, "alignment": "center"}"#.utf8))
        #expect(style.fontSize == 64)
        #expect(style.alignment == .center)
        #expect(style.boxSizing == .fixed)
        #expect(style.timing == nil)
    }

    @Test("Full round-trip preserves every field")
    func roundTrip() throws {
        var style = TextTitleStyle.lowerThird
        style.fontName = "AvenirNext-Bold"
        style.padding = 32
        let decoded = try JSONDecoder().decode(
            TextTitleStyle.self,
            from: JSONEncoder().encode(style))
        #expect(decoded == style)
    }

    @Test("Clamping pins font size, padding, and timing to their ranges")
    func clamping() {
        var style = TextTitleStyle()
        style.fontSize = 9999
        style.padding = -5
        style.timing = TitleTiming(flyInSeconds: 99, holdSeconds: -1, fadeOutSeconds: 42)
        let clamped = style.clamped()
        #expect(clamped.fontSize == 400)
        #expect(clamped.padding == 0)
        #expect(clamped.timing?.flyInSeconds == 10)
        #expect(clamped.timing?.holdSeconds == 0)
        #expect(clamped.timing?.fadeOutSeconds == 10)
        #expect(clamped.validationError == nil)
    }

    @Test("Validation rejects out-of-range values with reasons")
    func validation() {
        var style = TextTitleStyle()
        style.fontSize = 1
        #expect(style.validationError != nil)
        style.fontSize = 48
        style.padding = 500
        #expect(style.validationError != nil)
        style.padding = 10
        style.timing = TitleTiming(flyInSeconds: -2)
        #expect(style.validationError != nil)
        style.timing = nil
        #expect(style.validationError == nil)
        #expect(TextTitleStyle.lowerThird.validationError == nil)
        #expect(TextTitleStyle.guestName.validationError == nil)
        #expect(TextTitleStyle.hostName.validationError == nil)
        #expect(TextTitleStyle.headline.validationError == nil)
    }

    // MARK: - TitleTiming state machine

    @Test("No timing configured: steady from t=0")
    func timingZeroFlyInNoHold() {
        let timing = TitleTiming(flyInSeconds: 0, holdSeconds: 0)
        #expect(!timing.isActive)
        #expect(timing.state(atElapsed: 0) == .steady)
        #expect(timing.state(atElapsed: 600) == .steady)
    }

    @Test("Fly-in ramps opacity and travel, then rests")
    func timingFlyIn() {
        let timing = TitleTiming(flyInSeconds: 1.0, flyInDirection: .bottom)
        let start = timing.state(atElapsed: 0)
        #expect(start.opacity == 0)
        #expect(start.travel == 1)
        #expect(!start.isExpired)
        let mid = timing.state(atElapsed: 0.5)
        #expect(mid.opacity > 0 && mid.opacity < 1)
        #expect(mid.travel > 0 && mid.travel < 1)
        // Ease-out cubic: the midpoint is already past linear.
        #expect(mid.opacity > 0.5)
        let end = timing.state(atElapsed: 1.0)
        #expect(end == .steady)
    }

    @Test("Hold then fade-out then expired; hold 0 never expires")
    func timingHoldFadeOut() {
        let timed = TitleTiming(flyInSeconds: 0.2, holdSeconds: 2, fadeOutSeconds: 0.4)
        #expect(timed.state(atElapsed: 1.0) == .steady)          // holding
        let fading = timed.state(atElapsed: 2.4)                 // mid fade-out
        #expect(fading.opacity > 0 && fading.opacity < 1)
        #expect(fading.travel == 0)
        #expect(timed.state(atElapsed: 2.8).isExpired)           // done
        #expect(timed.state(atElapsed: 60).isExpired)

        let holdForever = TitleTiming(flyInSeconds: 0.2, holdSeconds: 0, fadeOutSeconds: 0.4)
        #expect(holdForever.state(atElapsed: 3600) == .steady)
    }

    @Test("Zero fade-out expires exactly at hold end")
    func timingZeroFadeOut() {
        let timing = TitleTiming(flyInSeconds: 0, holdSeconds: 1, fadeOutSeconds: 0)
        #expect(timing.state(atElapsed: 0.5) == .steady)
        #expect(timing.state(atElapsed: 1.0).isExpired)
    }

    @Test("Negative elapsed clamps to zero")
    func timingNegativeElapsed() {
        let timing = TitleTiming(flyInSeconds: 1)
        #expect(timing.state(atElapsed: -5) == timing.state(atElapsed: 0))
    }

    @Test("Additive decode: timing with partial fields keeps loading")
    func timingAdditiveDecode() throws {
        let timing = try JSONDecoder().decode(
            TitleTiming.self, from: Data(#"{"holdSeconds": 5}"#.utf8))
        #expect(timing.flyInSeconds == 0.4)
        #expect(timing.flyInDirection == .bottom)
        #expect(timing.holdSeconds == 5)
        #expect(timing.fadeOutSeconds == 0.4)
    }

    // MARK: - TitleTemplate token resolution

    @Test("Tokens resolve against the name context, case-insensitively")
    func tokenResolution() {
        let names = ["host": "Joe", "guest": "Ada"]
        #expect(TitleTemplate.resolve("{host} live with {guest}", with: names) == "Joe live with Ada")
        #expect(TitleTemplate.resolve("{HOST}", with: names) == "Joe")
        #expect(TitleTemplate.resolve("Plain text", with: names) == "Plain text")
    }

    @Test("Unknown or empty-valued tokens stay literal — the honest preview")
    func tokenFallbackLiteral() {
        #expect(TitleTemplate.resolve("{guest}", with: [:]) == "{guest}")
        #expect(TitleTemplate.resolve("{guest}", with: ["guest": ""]) == "{guest}")
        #expect(TitleTemplate.resolve("{unknown}", with: ["host": "Joe"]) == "{unknown}")
        #expect(TitleTemplate.resolve("a { b } c", with: ["b": "x"]) == "a x c")
    }

    @Test("containsToken spots token-shaped braces only")
    func tokenDetection() {
        #expect(TitleTemplate.containsToken("Hello {guest}"))
        #expect(!TitleTemplate.containsToken("Hello world"))
    }

    // MARK: - Deterministic font fallback

    @Test("A requested font that exists resolves to itself")
    func fontFallbackKeepsValid() {
        #expect(TitleFontFallback.resolvedPostScriptName(for: "HelveticaNeue") == "HelveticaNeue")
    }

    @Test("A missing font falls through the pinned chain deterministically")
    func fontFallbackChain() {
        let bogus = "NoSuchFont-G02Bogus-123"
        #expect(!TitleFontFallback.fontExists(bogus))
        let resolved = TitleFontFallback.resolvedPostScriptName(for: bogus)
        // First-available chain member wins — deterministic across calls and
        // machines (the chain head exists on every stock install).
        #expect(TitleFontFallback.chain.contains(resolved))
        #expect(resolved == TitleFontFallback.chain.first { TitleFontFallback.fontExists($0) })
        #expect(resolved == TitleFontFallback.resolvedPostScriptName(for: bogus))
        // Nil = the documented default.
        #expect(TitleFontFallback.resolvedPostScriptName(for: nil)
                == TitleFontFallback.resolvedPostScriptName(for: nil))
    }

    @Test("makeFont produces a usable font at the requested size")
    func makeFont() {
        let font = TitleFontFallback.makeFont(requested: "NoSuchFont-G02Bogus-123", size: 44)
        #expect(abs(CTFontGetSize(font) - 44) < 0.001)
        let resolved = CTFontCopyPostScriptName(font) as String
        #expect(!resolved.isEmpty)
    }

    // MARK: - Measurement and fit

    @Test("Empty text measures to zero")
    func measureEmpty() {
        let font = TitleFontFallback.makeFont(requested: nil, size: 48)
        #expect(TextMeasurement.measuredSize(text: "", font: font, maxWidth: 500,
                                             alignment: .leading, wraps: true) == .zero)
    }

    @Test("Wrapping at a narrow width trades width for height")
    func measureWrap() {
        let font = TitleFontFallback.makeFont(requested: nil, size: 48)
        let text = "A long lower third headline that wraps onto multiple lines"
        let wide = TextMeasurement.measuredSize(text: text, font: font,
                                                maxWidth: .greatestFiniteMagnitude,
                                                alignment: .leading, wraps: false)
        let narrow = TextMeasurement.measuredSize(text: text, font: font, maxWidth: 300,
                                                  alignment: .leading, wraps: true)
        #expect(wide.width > 0 && wide.height > 0)
        #expect(narrow.width <= 301)        // fits the constraint (ceil slack)
        #expect(narrow.height > wide.height) // more lines
    }

    @Test("Scale-down factor: 1 when it fits, shrunk and floored otherwise")
    func scaleDownFactor() {
        let box = CGSize(width: 200, height: 100)
        #expect(TextMeasurement.scaleDownFactor(
            measured: CGSize(width: 100, height: 50), box: box) == 1)
        #expect(TextMeasurement.scaleDownFactor(
            measured: CGSize(width: 400, height: 100), box: box) == 0.5)
        // Both dimensions must fit — the tighter one wins.
        #expect(TextMeasurement.scaleDownFactor(
            measured: CGSize(width: 400, height: 400), box: box) == 0.25)
        // The floor keeps pathological input legible.
        #expect(TextMeasurement.scaleDownFactor(
            measured: CGSize(width: 100_000, height: 100_000), box: box) == 0.25)
        #expect(TextMeasurement.scaleDownFactor(measured: .zero, box: box) == 1)
    }

    @Test("Unicode and emoji measure to a non-empty box (fallback cascade active)")
    func measureUnicodeEmoji() {
        let font = TitleFontFallback.makeFont(requested: "HelveticaNeue", size: 48)
        let size = TextMeasurement.measuredSize(text: "Grüße, 世界 📡", font: font,
                                                maxWidth: 800, alignment: .leading,
                                                wraps: true)
        #expect(size.width > 0)
        #expect(size.height > 0)
    }
}
