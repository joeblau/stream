import CoreGraphics
import CoreText
import Foundation

// MARK: - G02 (issue #110): text layers — layout, timing, fonts, templates
//
// The pure, platform-independent half of the macOS text-layer work: the value
// model the `TextSourcePayload` (LayerGraph, StreamMac) is built from, the
// CoreText measurement the renderer's auto-size/scale-down paths need, the
// timed-visibility state machine, the `{token}` title-template resolution,
// and the pinned font fallback chain. Everything here is a value type or a
// pure function over values, so the whole surface is unit-testable without
// the app (StreamCoreTests, iOS simulator).
//
// GEOMETRY UNITS follow the LayerGraph invariant: font size and padding are
// REFERENCE points/pixels on the 1080p canvas; the renderer scales them by
// the actual output height, so a text layer renders identically at any
// encode resolution.

/// Horizontal text alignment inside the text box.
public enum TextHorizontalAlignment: String, Codable, CaseIterable, Sendable {
    case leading, center, trailing

    public var displayName: String {
        switch self {
        case .leading: return "Leading"
        case .center: return "Center"
        case .trailing: return "Trailing"
        }
    }

    /// The CoreText paragraph alignment. `.left`/`.right` (not `.natural`)
    /// keep rendering script-independent and therefore deterministic.
    public var ctAlignment: CTTextAlignment {
        switch self {
        case .leading: return .left
        case .center: return .center
        case .trailing: return .right
        }
    }
}

/// Vertical placement of the measured text block inside a fixed box.
public enum TextVerticalAlignment: String, Codable, CaseIterable, Sendable {
    case top, center, bottom

    public var displayName: String {
        switch self {
        case .top: return "Top"
        case .center: return "Center"
        case .bottom: return "Bottom"
        }
    }
}

/// How the layer's raster size relates to the layer's transform rect.
public enum TextBoxSizing: String, Codable, CaseIterable, Sendable {
    /// The box hugs the measured text: width fits the text up to the
    /// transform's width (wrapping there when `wraps` is on; unbounded
    /// single-line when off), height fits the measured lines. The
    /// transform's `size.height` is nominal — exactly the PIP precedent
    /// where the source aspect derives the height.
    case auto
    /// The transform rect is authoritative: the text frame-sets into it
    /// (padding inset) and `overflow` decides what happens when it doesn't
    /// fit. The pre-G02 behavior.
    case fixed

    public var displayName: String {
        switch self {
        case .auto: return "Auto-Size to Text"
        case .fixed: return "Fixed Box"
        }
    }
}

/// What a FIXED box does with text that doesn't fit.
public enum TextOverflow: String, Codable, CaseIterable, Sendable {
    /// Clip at the box edge (the pre-G02 behavior).
    case clip
    /// Truncate the last visible line with an ellipsis.
    case ellipsis
    /// Shrink the font until the text fits (floor: 25% of the set size).
    case scaleDown

    public var displayName: String {
        switch self {
        case .clip: return "Clip"
        case .ellipsis: return "Ellipsis"
        case .scaleDown: return "Scale Down to Fit"
        }
    }
}

// MARK: - Timed / fly-in visibility

/// The direction a title flies in from (its resting position is the layer's
/// transform rect). `.none` = fade only.
public enum TitleFlyInDirection: String, Codable, CaseIterable, Sendable {
    case none, left, right, top, bottom

    public var displayName: String {
        switch self {
        case .none: return "Fade Only"
        case .left: return "From Left"
        case .right: return "From Right"
        case .top: return "From Top"
        case .bottom: return "From Bottom"
        }
    }
}

/// One timed-visibility sample: the multiplier and travel fraction the
/// renderer applies to the placed title image for a given elapsed time.
public struct TitleTimingState: Equatable, Sendable {
    /// Alpha multiplier, 0...1.
    public var opacity: Double
    /// 0 = at rest; 1 = fully offset in the fly-in direction. Non-zero only
    /// during fly-in.
    public var travel: Double
    /// True once the hold + fade-out completed: the title paints nothing
    /// until it re-appears (hide/show replays the timing).
    public var isExpired: Bool

    public init(opacity: Double, travel: Double, isExpired: Bool) {
        self.opacity = opacity
        self.travel = travel
        self.isExpired = isExpired
    }

    public static let steady = TitleTimingState(opacity: 1, travel: 0, isExpired: false)
}

/// G02 (issue #110): a text layer's timed visibility — fly-in animation, an
/// optional hold window, and a fade-out. Renderer-side and
/// timestamp-parametrized: the model stores only durations, the renderer
/// anchors elapsed time to the first tick the layer paints after being absent
/// (so a hide → show replays the animation) and never touches the
/// `CompositionEngine` per-tick fade machinery (S09 stays the scene-edit
/// visibility seam; this is CONTENT — it stages, Takes, and undoes with the
/// layer's payload).
public struct TitleTiming: Hashable, Codable, Sendable {
    /// Fly-in duration in seconds, 0...10 (0 = appear instantly).
    public var flyInSeconds: Double
    public var flyInDirection: TitleFlyInDirection
    /// How long the title holds after fly-in, in seconds, 0...3600.
    /// 0 = stays until hidden (no fade-out ever runs).
    public var holdSeconds: Double
    /// Fade-out duration in seconds, 0...10 (only runs when hold > 0).
    public var fadeOutSeconds: Double

    public init(flyInSeconds: Double = 0.4,
                flyInDirection: TitleFlyInDirection = .bottom,
                holdSeconds: Double = 0,
                fadeOutSeconds: Double = 0.4) {
        self.flyInSeconds = flyInSeconds
        self.flyInDirection = flyInDirection
        self.holdSeconds = holdSeconds
        self.fadeOutSeconds = fadeOutSeconds
    }

    /// Decode every field with a default (the established additive-wire
    /// pattern).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        flyInSeconds = try container.decodeIfPresent(Double.self, forKey: .flyInSeconds) ?? 0.4
        flyInDirection = try container.decodeIfPresent(TitleFlyInDirection.self, forKey: .flyInDirection)
            ?? .bottom
        holdSeconds = try container.decodeIfPresent(Double.self, forKey: .holdSeconds) ?? 0
        fadeOutSeconds = try container.decodeIfPresent(Double.self, forKey: .fadeOutSeconds) ?? 0.4
    }

    /// True when the timing changes rendering at all (a zero fly-in with no
    /// hold is the steady state).
    public var isActive: Bool { flyInSeconds > 0 || holdSeconds > 0 }

    /// The visibility sample `elapsed` seconds after the title appeared.
    /// Fly-in eases out (cubic) with the alpha ramp; the fade-out is linear.
    public func state(atElapsed elapsed: Double) -> TitleTimingState {
        let flyIn = max(0, flyInSeconds)
        let hold = max(0, holdSeconds)
        let fadeOut = max(0, fadeOutSeconds)
        let t = max(0, elapsed)

        if flyIn > 0, t < flyIn {
            let eased = Self.easeOutCubic(t / flyIn)
            return TitleTimingState(opacity: eased, travel: 1 - eased, isExpired: false)
        }
        guard hold > 0 else { return .steady }
        let fadeStart = flyIn + hold
        if t < fadeStart { return .steady }
        guard fadeOut > 0 else {
            return TitleTimingState(opacity: 0, travel: 0, isExpired: true)
        }
        let fadeProgress = (t - fadeStart) / fadeOut
        guard fadeProgress < 1 else {
            return TitleTimingState(opacity: 0, travel: 0, isExpired: true)
        }
        return TitleTimingState(opacity: 1 - fadeProgress, travel: 0, isExpired: false)
    }

    /// Classic ease-out cubic: fast start, soft landing.
    public static func easeOutCubic(_ t: Double) -> Double {
        let clamped = min(1, max(0, t))
        let u = 1 - clamped
        return 1 - u * u * u
    }
}

// MARK: - Title templates ({host} / {guest} tokens)

/// G02 (issue #110): `{token}` substitution for automatic host/guest names.
/// A text layer's string may carry tokens — `{host}`, `{guest}`,
/// `{guest1}`…`{guest8}` — resolved at RENDER time against the live name
/// context (the StreamMac `TitleTokenStore`, fed by the guest workstream —
/// the documented seam: whoever owns guest sessions publishes names by token
/// key). Resolution rules: token keys match case-insensitively; a token with
/// no published (or an empty) name stays LITERAL in the output, so an
/// unconfigured template reads honestly in preview instead of vanishing.
public enum TitleTemplate {
    public static let hostToken = "host"
    public static let guestToken = "guest"

    /// The recognized guest tokens, in order (`{guest}` is the plain alias).
    public static let guestTokens: [String] = ["guest"] + (1...8).map { "guest\($0)" }

    /// Resolves every `{token}` in `template` against `names` (keys are
    /// matched lowercased). Unknown or empty-valued tokens stay literal.
    public static func resolve(_ template: String, with names: [String: String]) -> String {
        guard template.contains("{") else { return template }
        var result = ""
        result.reserveCapacity(template.count)
        var index = template.startIndex
        while index < template.endIndex {
            guard template[index] == "{",
                  let close = template[index...].firstIndex(of: "}") else {
                result.append(template[index])
                index = template.index(after: index)
                continue
            }
            let key = template[template.index(after: index)..<close]
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            if !key.isEmpty, let value = names[key], !value.isEmpty {
                result.append(value)
            } else {
                // Unknown/unset token: keep it literal (honest preview).
                result.append(contentsOf: template[index...close])
            }
            index = template.index(after: close)
        }
        return result
    }

    /// True when the string carries any token-shaped `{...}` at all.
    public static func containsToken(_ template: String) -> Bool {
        guard let open = template.firstIndex(of: "{") else { return false }
        return template[open...].contains("}")
    }
}

// MARK: - Deterministic font fallback

/// G02 (issue #110): the PINNED font fallback chain. Exported/persisted
/// documents store the requested font name; a machine without that font
/// resolves through this chain, first-available wins — the same answer on
/// every stock macOS/iOS install, so a reopened project never re-points at
/// a random system pick. Per-glyph coverage (CJK, emoji, symbols) rides the
/// same pinned chain attached to the font descriptor as its cascade list,
/// so Unicode and emoji render identically everywhere instead of through
/// the platform's implicit (version-dependent) cascade.
public enum TitleFontFallback {
    /// Ordered PostScript names, first-available wins when the requested
    /// font is missing. Helvetica Neue is the chain head on every stock
    /// macOS/iOS install; Apple Color Emoji guarantees color emoji;
    /// LastResort is the never-empty terminal.
    public static let chain: [String] = [
        "HelveticaNeue",
        "Helvetica",
        "AppleColorEmoji",
        "LastResort"
    ]

    /// The default when no font is requested (nil `fontName`).
    public static let defaultPostScriptName = "HelveticaNeue-Bold"

    /// True when `name` resolves to a real font — as a PostScript name OR a
    /// family name (users type either), matched case-insensitively against
    /// what CoreText actually instantiates.
    public static func fontExists(_ name: String) -> Bool {
        let font = CTFontCreateWithName(name as CFString, 12, nil)
        let postScript = CTFontCopyPostScriptName(font) as String
        let family = CTFontCopyFamilyName(font) as String
        return postScript.caseInsensitiveCompare(name) == .orderedSame
            || family.caseInsensitiveCompare(name) == .orderedSame
    }

    /// The deterministic primary font for a request: the requested name when
    /// it resolves, else the requested default when nil, else the first chain
    /// member that exists. The chain head always exists on a stock install.
    public static func resolvedPostScriptName(for requested: String?) -> String {
        guard let requested,
              !requested.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return fontExists(defaultPostScriptName) ? defaultPostScriptName : firstAvailableChainFont()
        }
        if fontExists(requested) { return requested }
        return firstAvailableChainFont()
    }

    private static func firstAvailableChainFont() -> String {
        for name in chain where fontExists(name) {
            return name
        }
        return chain[0]
    }

    /// Builds the render font: the deterministically resolved primary with
    /// the pinned chain attached as the per-glyph cascade list (covers
    /// glyphs the primary lacks — emoji within a Helvetica string, CJK, …).
    public static func makeFont(requested: String?, size: CGFloat) -> CTFont {
        let primary = resolvedPostScriptName(for: requested)
        let cascade = chain
            .filter { $0.caseInsensitiveCompare(primary) != .orderedSame }
            .map { CTFontDescriptorCreateWithNameAndSize($0 as CFString, 0) }
        let attributes: [CFString: Any] = [
            kCTFontNameAttribute: primary as CFString,
            kCTFontCascadeListAttribute: cascade
        ]
        let descriptor = CTFontDescriptorCreateWithAttributes(attributes as CFDictionary)
        return CTFontCreateWithFontDescriptor(descriptor, max(1, size), nil)
    }
}

// MARK: - Measurement and fit

/// G02 (issue #110): CoreText measurement for the auto-size and scale-down
/// paths. Pure functions over values — the renderer (StreamMac) feeds its
/// resolved font in, and the tests exercise the same code on the simulator.
public enum TextMeasurement {
    /// The paragraph style for a measurement/draw pass: horizontal alignment
    /// plus the line-break mode the wrapping/overflow configuration implies.
    public static func paragraphStyle(alignment: TextHorizontalAlignment,
                                      wraps: Bool,
                                      overflow: TextOverflow) -> CTParagraphStyle {
        var ctAlignment = alignment.ctAlignment
        // Truncation applies to the LAST visible line of a wrapped block too
        // (CoreText clips everything past the frame except the final line's
        // ellipsis) — exactly the fixed-box "ellipsis" semantics.
        var lineBreakMode: CTLineBreakMode = overflow == .ellipsis
            ? .byTruncatingTail
            : (wraps ? .byWordWrapping : .byClipping)
        var settings: [CTParagraphStyleSetting] = [
            CTParagraphStyleSetting(spec: .alignment,
                                    valueSize: MemoryLayout<CTTextAlignment>.size,
                                    value: &ctAlignment),
            CTParagraphStyleSetting(spec: .lineBreakMode,
                                    valueSize: MemoryLayout<CTLineBreakMode>.size,
                                    value: &lineBreakMode)
        ]
        return CTParagraphStyleCreate(&settings, settings.count)
    }

    /// The size the text measures to inside `maxWidth` (pass
    /// `.greatestFiniteMagnitude` for an unwrapped single line). Height
    /// always fits the measured lines.
    public static func measuredSize(text: String,
                                    font: CTFont,
                                    maxWidth: CGFloat,
                                    alignment: TextHorizontalAlignment,
                                    wraps: Bool,
                                    overflow: TextOverflow = .clip) -> CGSize {
        guard !text.isEmpty else { return .zero }
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTParagraphStyleAttributeName: paragraphStyle(alignment: alignment,
                                                           wraps: wraps,
                                                           overflow: overflow)
        ]
        guard let attributed = CFAttributedStringCreate(nil, text as CFString,
                                                        attributes as CFDictionary)
        else { return .zero }
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let constraint = CGSize(width: max(1, maxWidth),
                                height: .greatestFiniteMagnitude)
        let measured = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0), nil, constraint, nil)
        return CGSize(width: ceil(measured.width), height: ceil(measured.height))
    }

    /// The font-size multiplier a scale-down overflow applies so text
    /// (measured at the CURRENT font size) fits `box` in both dimensions.
    /// 1 = already fits; floored at 0.25 so pathological input stays legible
    /// instead of rasterizing at sub-pixel sizes.
    public static func scaleDownFactor(measured: CGSize, box: CGSize) -> Double {
        guard measured.width > 0, measured.height > 0,
              box.width > 0, box.height > 0 else { return 1 }
        let factor = min(1, Double(box.width / measured.width),
                         Double(box.height / measured.height))
        return max(0.25, factor)
    }
}

// MARK: - The reusable title style value + templates

/// G02 (issue #110): every styling field of a text layer EXCEPT the string
/// itself — the value a named preset or template captures and a text layer
/// applies wholesale (applying copies the VALUE; later preset edits never
/// re-point existing users, the E01/G03 preset precedent).
public struct TextTitleStyle: Hashable, Codable, Sendable {
    /// PostScript or family name; nil/unknown resolves through
    /// `TitleFontFallback` deterministically.
    public var fontName: String? = nil
    /// Points on the 1080p reference canvas, 4...400 (scales with output).
    public var fontSize: Double = 48
    /// `#RRGGBB` / `#RRGGBBAA`.
    public var colorHex: String = "#FFFFFF"
    public var alignment: TextHorizontalAlignment = .leading
    public var verticalAlignment: TextVerticalAlignment = .center
    /// Background bar behind the text (the layer's whole raster, padding
    /// included). Nil = transparent.
    public var backgroundColorHex: String? = nil
    /// Uniform inset between the box edge and the text frame, in reference
    /// pixels, 0...200.
    public var padding: Double = 0
    public var boxSizing: TextBoxSizing = .fixed
    public var wraps: Bool = true
    public var overflow: TextOverflow = .clip
    /// Timed/fly-in visibility; nil = always steady.
    public var timing: TitleTiming? = nil

    public init() {}

    /// Decode every field with a default (the established additive-wire
    /// pattern), so presets written by any version keep loading.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fontName = try container.decodeIfPresent(String.self, forKey: .fontName)
        fontSize = try container.decodeIfPresent(Double.self, forKey: .fontSize) ?? 48
        colorHex = try container.decodeIfPresent(String.self, forKey: .colorHex) ?? "#FFFFFF"
        alignment = try container.decodeIfPresent(TextHorizontalAlignment.self, forKey: .alignment)
            ?? .leading
        verticalAlignment = try container.decodeIfPresent(TextVerticalAlignment.self,
                                                          forKey: .verticalAlignment) ?? .center
        backgroundColorHex = try container.decodeIfPresent(String.self, forKey: .backgroundColorHex)
        padding = try container.decodeIfPresent(Double.self, forKey: .padding) ?? 0
        boxSizing = try container.decodeIfPresent(TextBoxSizing.self, forKey: .boxSizing) ?? .fixed
        wraps = try container.decodeIfPresent(Bool.self, forKey: .wraps) ?? true
        overflow = try container.decodeIfPresent(TextOverflow.self, forKey: .overflow) ?? .clip
        timing = try container.decodeIfPresent(TitleTiming.self, forKey: .timing)
    }

    /// The value with every field clamped to its documented range (the
    /// dispatcher rejects out-of-range input via `validationError`; the UI
    /// clamps its sliders to the same ranges).
    public func clamped() -> TextTitleStyle {
        var copy = self
        copy.fontSize = min(400, max(4, fontSize))
        copy.padding = min(200, max(0, padding))
        if var timing = copy.timing {
            timing.flyInSeconds = min(10, max(0, timing.flyInSeconds))
            timing.holdSeconds = min(3600, max(0, timing.holdSeconds))
            timing.fadeOutSeconds = min(10, max(0, timing.fadeOutSeconds))
            copy.timing = timing
        }
        return copy
    }

    /// The rejection reason for an out-of-range value, or nil (guards
    /// automation input, like `LayerStyle.validationError`).
    public var validationError: String? {
        guard fontSize.isFinite, padding.isFinite else {
            return "Text style values must be finite numbers."
        }
        if !(4...400).contains(fontSize) {
            return "Font size must be between 4 and 400."
        }
        if !(0...200).contains(padding) {
            return "Text padding must be between 0 and 200."
        }
        if let timing {
            guard timing.flyInSeconds.isFinite, timing.holdSeconds.isFinite,
                  timing.fadeOutSeconds.isFinite else {
                return "Title timing values must be finite numbers."
            }
            if !(0...10).contains(timing.flyInSeconds)
                || !(0...10).contains(timing.fadeOutSeconds) {
                return "Fly-in and fade-out durations must be between 0 and 10 seconds."
            }
            if !(0...3600).contains(timing.holdSeconds) {
                return "Hold duration must be between 0 and 3600 seconds."
            }
        }
        return nil
    }
}

extension TextTitleStyle {
    /// The plain default (today's behavior): white 48 pt text, fixed box,
    /// wrapped, clipped, centered vertically.
    public static let plain = TextTitleStyle()

    /// The classic broadcast lower third: bold white text on a translucent
    /// black bar, auto-sized, padded, flying in from the left.
    public static var lowerThird: TextTitleStyle {
        var style = TextTitleStyle()
        style.fontName = "HelveticaNeue-Bold"
        style.fontSize = 44
        style.alignment = .leading
        style.backgroundColorHex = "#000000B3"
        style.padding = 24
        style.boxSizing = .auto
        style.wraps = true
        style.overflow = .ellipsis
        style.timing = TitleTiming(flyInSeconds: 0.4, flyInDirection: .left)
        return style
    }

    /// A name caption for a remote guest — the lower-third bar with the
    /// accent background; pair the text with the `{guest}` token so the name
    /// follows the guest workstream's published names.
    public static var guestName: TextTitleStyle {
        var style = lowerThird
        style.fontSize = 40
        style.backgroundColorHex = "#1F4FD8CC"
        return style
    }

    /// A name caption for the host; pair the text with the `{host}` token.
    public static var hostName: TextTitleStyle {
        var style = lowerThird
        style.fontSize = 40
        style.backgroundColorHex = "#5A1FB3CC"
        return style
    }

    /// A centered headline/title card: large bold centered text, no bar,
    /// fade-only fly-in.
    public static var headline: TextTitleStyle {
        var style = TextTitleStyle()
        style.fontName = "HelveticaNeue-Bold"
        style.fontSize = 96
        style.alignment = .center
        style.boxSizing = .auto
        style.wraps = true
        style.overflow = .scaleDown
        style.timing = TitleTiming(flyInSeconds: 0.5, flyInDirection: .none)
        return style
    }
}
