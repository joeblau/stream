import Foundation
import StreamCore

// MARK: - Stable identifiers
//
// Every entity in a scene document carries a UUID-backed identifier. IDs are
// persisted as plain UUID strings and never derived from display names, so
// renames never break references (layer → source definition, layer → group,
// nested scene → scene).

/// Phantom-typed UUID wrapper: one encoding, one implementation, distinct
/// types per entity so a `SceneID` can never be passed where a `LayerID`
/// belongs. Encodes as a bare UUID string for a stable, diff-friendly wire
/// format.
struct GraphID<Tag>: Hashable, Codable, Sendable, CustomStringConvertible {
    var rawValue: UUID

    init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UUID.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var description: String { rawValue.uuidString }
}

enum ProjectTag {}
enum SceneTag {}
enum SourceDefinitionTag {}
enum LayerTag {}
enum GroupTag {}
enum CanvasTag {}
/// E01 (issue #101): reusable effect presets (`SourceEffectPreset`).
enum EffectPresetTag {}

typealias ProjectID = GraphID<ProjectTag>
typealias SceneID = GraphID<SceneTag>
typealias SourceDefinitionID = GraphID<SourceDefinitionTag>
typealias LayerID = GraphID<LayerTag>
typealias GroupID = GraphID<GroupTag>
typealias CanvasID = GraphID<CanvasTag>
typealias EffectPresetID = GraphID<EffectPresetTag>

// MARK: - Geometry
//
// Transforms are normalized to the scene's canvas (0...1, origin top-left) so
// a graph renders identically at any encode resolution.

/// Normalized point in canvas space.
struct GraphPoint: Hashable, Codable, Sendable {
    var x: Double
    var y: Double
}

/// Normalized size as a fraction of the canvas.
struct GraphSize: Hashable, Codable, Sendable {
    var width: Double
    var height: Double
}

/// Which point of a layer `position` refers to.
enum LayerAnchor: String, Codable, CaseIterable, Sendable {
    case topLeft, topRight, bottomLeft, bottomRight, center
}

/// Placement of one layer on the canvas. For a camera PIP layer, `size.width`
/// is the classic PIP scale (fraction of frame width, 0.10...0.40); renderers
/// aspect-fit the source, so `size.height` is nominal there.
struct LayerTransform: Hashable, Codable, Sendable {
    var position: GraphPoint
    var size: GraphSize
    var anchor: LayerAnchor
    var rotationDegrees: Double

    init(position: GraphPoint,
         size: GraphSize,
         anchor: LayerAnchor,
         rotationDegrees: Double = 0) {
        self.position = position
        self.size = size
        self.anchor = anchor
        self.rotationDegrees = rotationDegrees
    }

    /// Covers the whole canvas.
    static let fullscreen = LayerTransform(
        position: GraphPoint(x: 0, y: 0),
        size: GraphSize(width: 1, height: 1),
        anchor: .topLeft)

    /// A PIP box anchored in the given corner (margin is applied by the
    /// renderer, matching the compositor's existing inset behavior).
    init(pipCorner: PIPCorner, scale: Double) {
        switch pipCorner {
        case .topLeft:
            anchor = .topLeft
            position = GraphPoint(x: 0, y: 0)
        case .topRight:
            anchor = .topRight
            position = GraphPoint(x: 1, y: 0)
        case .bottomLeft:
            anchor = .bottomLeft
            position = GraphPoint(x: 0, y: 1)
        case .bottomRight:
            anchor = .bottomRight
            position = GraphPoint(x: 1, y: 1)
        }
        size = GraphSize(width: scale, height: scale)
        rotationDegrees = 0
    }
}

extension PIPCorner {
    /// The canvas corner a layer anchor maps to (`.center` has no PIP
    /// equivalent and falls back to the default corner).
    init(anchor: LayerAnchor) {
        switch anchor {
        case .topLeft: self = .topLeft
        case .topRight: self = .topRight
        case .bottomLeft: self = .bottomLeft
        case .bottomRight, .center: self = .bottomRight
        }
    }
}

// MARK: - Effects

struct BorderEffectPayload: Hashable, Codable, Sendable {
    var width: Double
    var colorHex: String
}

struct ChromaKeyEffectPayload: Hashable, Codable, Sendable {
    var colorHex: String
    var tolerance: Double
}

/// Per-layer visual effects. Wire format is a `kind` discriminator plus a
/// typed payload, so new effects are additive and older documents keep
/// decoding. Renderers that don't know an effect simply ignore it.
enum LayerEffect: Hashable, Sendable {
    case opacity(Double)
    case cornerRadius(Double)
    case border(BorderEffectPayload)
    case chromaKey(ChromaKeyEffectPayload)
}

extension LayerEffect: Codable {
    private enum Kind: String, Codable {
        case opacity, cornerRadius, border, chromaKey
    }
    private enum CodingKeys: String, CodingKey {
        case kind, payload
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .opacity:
            self = .opacity(try container.decode(Double.self, forKey: .payload))
        case .cornerRadius:
            self = .cornerRadius(try container.decode(Double.self, forKey: .payload))
        case .border:
            self = .border(try container.decode(BorderEffectPayload.self, forKey: .payload))
        case .chromaKey:
            self = .chromaKey(try container.decode(ChromaKeyEffectPayload.self, forKey: .payload))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .opacity(let value):
            try container.encode(Kind.opacity, forKey: .kind)
            try container.encode(value, forKey: .payload)
        case .cornerRadius(let value):
            try container.encode(Kind.cornerRadius, forKey: .kind)
            try container.encode(value, forKey: .payload)
        case .border(let payload):
            try container.encode(Kind.border, forKey: .kind)
            try container.encode(payload, forKey: .payload)
        case .chromaKey(let payload):
            try container.encode(Kind.chromaKey, forKey: .kind)
            try container.encode(payload, forKey: .payload)
        }
    }
}

// MARK: - Audio binding

/// How a layer contributes to the outgoing audio mix.
struct AudioBinding: Hashable, Codable, Sendable {
    var isMuted: Bool
    /// Linear gain, 0...1.
    var volume: Double

    static let `default` = AudioBinding(isMuted: false, volume: 1)
}

// MARK: - Layer payloads
//
// One typed payload per layer kind. Camera/screen render through the capture
// pipeline (S03), text/shape are generated by the compositor (S07), and
// `.scene` nests another scene's layer stack recursively (S06); the rest are
// model-only until the composition engine grows source support, but they
// persist and round-trip now.

struct CameraSourcePayload: Hashable, Codable, Sendable {
    /// Stable capture-device identifier; nil = system default camera.
    var deviceID: String? = nil
}

struct ScreenSourcePayload: Hashable, Codable, Sendable {
    enum Target: String, Codable, CaseIterable, Sendable {
        case display, window, application
    }
    var target: Target = .display
    /// Restorable identifier of the specific display/window/app;
    /// nil = ask through the system content picker on first use.
    /// - display: decimal `CGDirectDisplayID` string;
    /// - window: decimal `CGWindowID` string (volatile — see `windowTitle`);
    /// - application: the app's bundle identifier.
    var targetIdentifier: String? = nil
    /// C02 (issue #77): the owning app's bundle identifier for window
    /// targets. A `CGWindowID` is volatile — it changes every time the app
    /// relaunches or recreates the window — so relinking matches the owning
    /// app (this) plus `windowTitle` instead. C10 owns full relinking.
    var applicationBundleID: String? = nil
    /// C02: the window title persisted alongside `targetIdentifier`; the
    /// second half of the window relink key (owning app + title).
    var windowTitle: String? = nil
    /// C03 (issue #78): per-source capture privacy (cursor/audio overrides
    /// and app/window exclusions). Part of the payload identity, so editing
    /// it re-keys the capture pool and restarts the capture with the new
    /// filter — exclusions apply deliberately, never mid-frame.
    var privacy: CapturePrivacyOptions = CapturePrivacyOptions()
    /// C04 (issue #104): a user-drawn capture region on a display target.
    /// Part of the payload identity, so editing it re-keys the capture
    /// deliberately, exactly like privacy edits.
    var region: CaptureRegion? = nil
    /// C04: follow-the-cursor zoom on a display/region capture.
    var zoom: ScreenZoomOptions = ScreenZoomOptions()
    /// C04: opt-in frontmost-app tracking on a display/region capture.
    var appTracking: ActiveAppTrackingOptions = ActiveAppTrackingOptions()

    init(target: Target = .display,
         targetIdentifier: String? = nil,
         applicationBundleID: String? = nil,
         windowTitle: String? = nil,
         privacy: CapturePrivacyOptions = CapturePrivacyOptions(),
         region: CaptureRegion? = nil,
         zoom: ScreenZoomOptions = ScreenZoomOptions(),
         appTracking: ActiveAppTrackingOptions = ActiveAppTrackingOptions()) {
        self.target = target
        self.targetIdentifier = targetIdentifier
        self.applicationBundleID = applicationBundleID
        self.windowTitle = windowTitle
        self.privacy = privacy
        self.region = region
        self.zoom = zoom
        self.appTracking = appTracking
    }

    /// The C02 relink fields were added after v2 shipped; decode every field
    /// with a default so older persisted documents keep loading (additive
    /// wire change, same pattern as `LayerNode.isLocked`). C03's `privacy`
    /// and C04's `region`/`zoom`/`appTracking` follow the same pattern.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        target = try container.decodeIfPresent(Target.self, forKey: .target) ?? .display
        targetIdentifier = try container.decodeIfPresent(String.self, forKey: .targetIdentifier)
        applicationBundleID = try container.decodeIfPresent(String.self, forKey: .applicationBundleID)
        windowTitle = try container.decodeIfPresent(String.self, forKey: .windowTitle)
        privacy = try container.decodeIfPresent(CapturePrivacyOptions.self, forKey: .privacy)
            ?? CapturePrivacyOptions()
        region = try container.decodeIfPresent(CaptureRegion.self, forKey: .region)
        zoom = try container.decodeIfPresent(ScreenZoomOptions.self, forKey: .zoom)
            ?? ScreenZoomOptions()
        appTracking = try container.decodeIfPresent(ActiveAppTrackingOptions.self, forKey: .appTracking)
            ?? ActiveAppTrackingOptions()
    }

    /// C04: true when this payload carries any region/zoom/tracking
    /// configuration (drives the source-row indicator and decides whether a
    /// display capture builds the dynamics runtime).
    var hasRegionDynamics: Bool {
        region != nil || zoom.isEnabled || appTracking.isEnabled
    }
}

/// C04 (issue #104): a user-drawn capture region on a display target.
struct CaptureRegion: Hashable, Codable, Sendable {
    /// The region in display points, relative to the display's top-left.
    var rect: CGRect
    /// The display's point size when the region was drawn. Capture
    /// resolution changes rescale `rect` proportionally against the live
    /// size, so the region's RELATIVE geometry persists across scale/display
    /// changes; a region that no longer fits the display fails closed
    /// (error + black, never a silent re-point).
    var displaySize: CGSize
}

/// C04 (issue #104): follow-the-cursor zoom for display/region captures.
/// Applied live through `SCStream.updateConfiguration` — no capture restart
/// per cursor move; editing the options themselves re-keys the capture.
struct ScreenZoomOptions: Hashable, Codable, Sendable {
    var isEnabled: Bool = false
    /// 1.5...4.0; the crop is the base region shrunk by this factor.
    var zoomFactor: Double = 2.0
    /// true: the zoomed crop pans after the cursor (exponentially smoothed;
    /// a still cursor converges and stops emitting updates). false: a static
    /// centered zoom of the base region.
    var followsCursor: Bool = true
    /// true: holding ⌃ freezes panning mid-capture.
    var pauseWithControlKey: Bool = true
}

/// C04 (issue #104): opt-in frontmost-app tracking for display/region
/// captures. The region follows the frontmost app's main window, restricted
/// to `allowedBundleIDs`. Stream itself can never be allowed — switching
/// back to the studio leaves the region where it is and (display filters
/// always exclude studio windows) never captures its controls. An allowed
/// app the privacy options exclude fails closed (error + black), never a
/// silent re-point.
struct ActiveAppTrackingOptions: Hashable, Codable, Sendable {
    var isEnabled: Bool = false
    /// Only these apps may move the region.
    var allowedBundleIDs: [String] = []
}

/// C03 (issue #78): per-source capture privacy persisted on
/// `ScreenSourcePayload`. `nil` cursor/audio means "inherit the global
/// default from settings"; exclusions are additive on top of the global
/// default exclusion list (a source can always hide MORE than the default,
/// never less — that is what keeps global "never capture these apps" picks
/// trustworthy).
struct CapturePrivacyOptions: Hashable, Codable, Sendable {
    /// One specific window a display (or application) capture excludes.
    /// `windowID` is volatile — it changes when the owning app recreates the
    /// window — so filter resolution falls back to the owning app + title
    /// relink key, exactly like pinned window targets (C02).
    struct ExcludedWindow: Hashable, Codable, Sendable {
        /// Decimal `CGWindowID` string (volatile; see above).
        var windowID: String
        var applicationBundleID: String?
        var windowTitle: String?
    }

    /// nil = inherit `StreamSettings.captureShowsCursor`.
    var showsCursor: Bool? = nil
    /// nil = inherit `StreamSettings.captureIncludesAudio`.
    var capturesAudio: Bool? = nil
    /// Additional apps (bundle identifiers) this capture excludes, on top of
    /// the global `StreamSettings.captureExcludedBundleIDs`.
    var excludedBundleIDs: [String] = []
    /// Specific windows this capture excludes (display captures; for
    /// application targets, windows of the target app).
    var excludedWindows: [ExcludedWindow] = []

    /// True when any per-source option is set (drives the source-row
    /// privacy indicator).
    var hasOverrides: Bool {
        showsCursor != nil || capturesAudio != nil
            || !excludedBundleIDs.isEmpty || !excludedWindows.isEmpty
    }
}

/// C03: the privacy state one capture start actually applies — the source's
/// per-source overrides resolved against the global settings defaults.
struct EffectiveCapturePrivacy: Hashable, Sendable {
    var showsCursor: Bool
    var capturesAudio: Bool
    /// Global defaults ∪ per-source additions, deduplicated and sorted for
    /// deterministic equality.
    var excludedBundleIDs: [String]
    var excludedWindows: [CapturePrivacyOptions.ExcludedWindow]

    /// No privacy configuration at all (cursor shown, audio captured,
    /// nothing excluded beyond the studio's own windows, which
    /// `ScreenSourceCapture` always excludes on display captures).
    static let standard = EffectiveCapturePrivacy(
        showsCursor: true, capturesAudio: true,
        excludedBundleIDs: [], excludedWindows: [])

    /// True when anything deviates from a plain capture (drives the
    /// source-row privacy indicator).
    var isActive: Bool {
        !showsCursor || !capturesAudio
            || !excludedBundleIDs.isEmpty || !excludedWindows.isEmpty
    }
}

extension ScreenSourcePayload {
    /// Resolves this payload's per-source options against the applied global
    /// settings: cursor/audio inherit when unset; exclusions are the union
    /// of the global default list and the source's own additions.
    func effectivePrivacy(defaults: StreamSettings) -> EffectiveCapturePrivacy {
        EffectiveCapturePrivacy(
            showsCursor: privacy.showsCursor ?? defaults.captureShowsCursor,
            capturesAudio: privacy.capturesAudio ?? defaults.captureIncludesAudio,
            excludedBundleIDs: Array(Set(defaults.captureExcludedBundleIDs + privacy.excludedBundleIDs)).sorted(),
            excludedWindows: privacy.excludedWindows)
    }
}

/// G01 (issue #81): how an image layer scales its source into the transform
/// rect. Both modes preserve the source's pixel aspect (no stretch) and its
/// alpha (transparent margins stay transparent under `.fit`; a `.fill` crop
/// clips through the layer's alpha, never flattening it).
enum ImageContentMode: String, Codable, CaseIterable, Sendable {
    /// Aspect-FIT centered in the rect — the logo/bug default: the whole
    /// image shows, transparent padding fills the mismatch.
    case fit
    /// Aspect-FILL centered, cropped to the rect — full-bleed backgrounds.
    case fill

    var displayName: String {
        switch self {
        case .fit: return "Fit (Preserve Aspect)"
        case .fill: return "Fill (Crop)"
        }
    }
}

/// G01 (issue #81): a static image or logo layer — PNG/JPEG/HEIF/TIFF pixels
/// or a natively rendered vector/PDF page (format validation is the import
/// path's `ImageAssetValidator` gate). The persisted identity mirrors A02's
/// media sources: a SECURITY-SCOPED BOOKMARK is the self-contained access
/// grant (the layer renders even if the P03 asset library is unavailable),
/// and `assetIdentifier` registers the file in the P03 asset library
/// (`AssetLibraryStore`) for recoverable project references and usage
/// tracking. Alpha, color space, and pixel aspect ride the decoded CGImage
/// into the renderer untouched; the transform/contentMode own all scaling.
struct ImageSourcePayload: Hashable, Codable, Sendable {
    /// The P03 asset library registration (`AssetID` string); nil when the
    /// library wasn't wired at import time.
    var assetIdentifier: String? = nil
    /// Security-scoped bookmark for the picked file (the access grant).
    var bookmarkData: Data? = nil
    /// The picked file's display name (bookmarks don't round-trip one).
    var fileName: String? = nil
    /// How the image scales into the layer rect.
    var contentMode: ImageContentMode = .fit
    /// Pixel dimensions recorded at import (the renderer reads the decoded
    /// image's own size; these are the UI's aspect hint before first paint).
    var pixelWidth: Int? = nil
    var pixelHeight: Int? = nil

    init(assetIdentifier: String? = nil,
         bookmarkData: Data? = nil,
         fileName: String? = nil,
         contentMode: ImageContentMode = .fit,
         pixelWidth: Int? = nil,
         pixelHeight: Int? = nil) {
        self.assetIdentifier = assetIdentifier
        self.bookmarkData = bookmarkData
        self.fileName = fileName
        self.contentMode = contentMode
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    /// Every G01 field beyond `assetIdentifier` was added after v2 shipped;
    /// decode each with a default so older persisted documents keep loading
    /// (additive wire change, same pattern as `MediaSourcePayload`).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        assetIdentifier = try container.decodeIfPresent(String.self, forKey: .assetIdentifier)
        bookmarkData = try container.decodeIfPresent(Data.self, forKey: .bookmarkData)
        fileName = try container.decodeIfPresent(String.self, forKey: .fileName)
        contentMode = try container.decodeIfPresent(ImageContentMode.self, forKey: .contentMode) ?? .fit
        pixelWidth = try container.decodeIfPresent(Int.self, forKey: .pixelWidth)
        pixelHeight = try container.decodeIfPresent(Int.self, forKey: .pixelHeight)
    }

    /// The image cache/store identity: the P03 asset registration wins (it
    /// survives relink/replace — same asset, new file), then the bookmark
    /// bytes (self-contained layers), then "unconfigured".
    var cacheKey: String {
        if let assetIdentifier { return "asset/\(assetIdentifier)" }
        if let bookmarkData { return "bookmark/\(AssetContentHasher.sha256(of: bookmarkData))" }
        return "unconfigured"
    }

    /// True when the payload names an image to paint (a configured layer).
    var isConfigured: Bool {
        assetIdentifier != nil || bookmarkData != nil
    }
}

/// G02 (issue #110): a text/title layer — editable broadcast titles, lower
/// thirds, and host/guest name captions. The legacy four fields (text, font,
/// size, color) are the tip; the full style surface (alignment, background
/// bar, padding, auto vs fixed box, wrapping, overflow, timed/fly-in
/// visibility) is the StreamCore `TextTitleStyle` value model — same ranges,
/// same additive-wire rules. The string may carry `{host}`/`{guest}` tokens
/// resolved at render time (see `TitleTemplate`); the pinned font fallback
/// chain (`TitleFontFallback`) makes a reopened/exported document render
/// deterministically on a machine missing the requested font.
///
/// SEAM for G05 (ticker): builds on THIS payload and the generated-content
/// render path — a per-tick text provider keyed by layer ID (the
/// `TitleTokenStore` pattern) feeds dynamic strings without new layer kinds;
/// the raster cache already re-renders only when the resolved string
/// changes. G04 (issue #111) landed the first provider of that shape: the
/// `timer` field below turns the layer into a countdown/stopwatch/clock/
/// scheduled-start overlay, resolved per tick by the StreamMac
/// `TimerOverlayStore` (runtime state keyed by layer ID, shared by preview
/// and program — never in this payload, never undoable scene content).
struct TextSourcePayload: Hashable, Codable, Sendable {
    var text: String = ""
    var fontName: String? = nil
    var fontSize: Double = 48
    var colorHex: String = "#FFFFFF"
    // G02 style surface (see TextTitleStyle for ranges/semantics).
    var alignment: TextHorizontalAlignment = .leading
    var verticalAlignment: TextVerticalAlignment = .center
    var backgroundColorHex: String? = nil
    var padding: Double = 0
    var boxSizing: TextBoxSizing = .fixed
    var wraps: Bool = true
    var overflow: TextOverflow = .clip
    var timing: TitleTiming? = nil
    /// G04 (issue #111): when set, the layer renders a live timer string
    /// (resolved per tick) instead of the static `text`. Config is durable
    /// scene content (stages/Takes/undoes with the payload); transport state
    /// lives in the shared `DynamicOverlayStore` keyed by playback ID.
    var timer: TimerOverlayConfiguration? = nil
    var ticker: TickerOverlayConfiguration? = nil
    /// Accepted public message identity stages and Takes with its caption.
    var recordingChatMessageID: String? = nil
    var commentHeaderUTF16Length: Int? = nil
    var commentPageIndex = 0
    var commentAvatarKey: String? = nil

    init(text: String = "",
         fontName: String? = nil,
         fontSize: Double = 48,
         colorHex: String = "#FFFFFF",
         alignment: TextHorizontalAlignment = .leading,
         verticalAlignment: TextVerticalAlignment = .center,
         backgroundColorHex: String? = nil,
         padding: Double = 0,
         boxSizing: TextBoxSizing = .fixed,
         wraps: Bool = true,
         overflow: TextOverflow = .clip,
         timing: TitleTiming? = nil,
         timer: TimerOverlayConfiguration? = nil,
         ticker: TickerOverlayConfiguration? = nil) {
        self.text = text
        self.fontName = fontName
        self.fontSize = fontSize
        self.colorHex = colorHex
        self.alignment = alignment
        self.verticalAlignment = verticalAlignment
        self.backgroundColorHex = backgroundColorHex
        self.padding = padding
        self.boxSizing = boxSizing
        self.wraps = wraps
        self.overflow = overflow
        self.timing = timing
        self.timer = timer
        self.ticker = ticker
    }

    /// Every G02 field was added after v2 shipped; decode each with its
    /// default so pre-G02 documents keep loading (the established
    /// additive-wire pattern, same as `LayerNode.isLocked`).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
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
        timer = try container.decodeIfPresent(TimerOverlayConfiguration.self, forKey: .timer)
        ticker = try container.decodeIfPresent(TickerOverlayConfiguration.self, forKey: .ticker)
        recordingChatMessageID = try container.decodeIfPresent(String.self, forKey: .recordingChatMessageID)
        commentHeaderUTF16Length = try container.decodeIfPresent(Int.self, forKey: .commentHeaderUTF16Length)
        commentPageIndex = try container.decodeIfPresent(Int.self, forKey: .commentPageIndex) ?? 0
        commentAvatarKey = try container.decodeIfPresent(String.self, forKey: .commentAvatarKey)
    }

    /// The payload's styling fields as one `TextTitleStyle` value — what a
    /// preset/template captures and applies. Setting writes every styling
    /// field and leaves `text` untouched.
    var style: TextTitleStyle {
        get {
            var style = TextTitleStyle()
            style.fontName = fontName
            style.fontSize = fontSize
            style.colorHex = colorHex
            style.alignment = alignment
            style.verticalAlignment = verticalAlignment
            style.backgroundColorHex = backgroundColorHex
            style.padding = padding
            style.boxSizing = boxSizing
            style.wraps = wraps
            style.overflow = overflow
            style.timing = timing
            return style
        }
        set {
            fontName = newValue.fontName
            fontSize = newValue.fontSize
            colorHex = newValue.colorHex
            alignment = newValue.alignment
            verticalAlignment = newValue.verticalAlignment
            backgroundColorHex = newValue.backgroundColorHex
            padding = newValue.padding
            boxSizing = newValue.boxSizing
            wraps = newValue.wraps
            overflow = newValue.overflow
            timing = newValue.timing
        }
    }

    /// The style model owns the style ranges; the timer model owns the
    /// timer ranges.
    var validationError: String? {
        if timer != nil && ticker != nil { return "Choose either a timer or a ticker for this layer." }
        return style.validationError ?? timer?.validationError ?? ticker?.validationError
            ?? (ticker != nil ? TickerOverlayConfiguration.textValidationError(text) : nil)
    }

    func clamped() -> TextSourcePayload {
        var copy = self
        copy.style = style.clamped()
        copy.timer = timer?.clamped()
        copy.ticker = ticker?.clamped()
        return copy
    }
}

struct ShapeSourcePayload: Hashable, Codable, Sendable {
    enum ShapeKind: String, Codable, CaseIterable, Sendable {
        case rectangle, roundedRectangle, ellipse
    }
    var shape: ShapeKind = .rectangle
    var fillColorHex: String = "#FFFFFF"
}

/// A02 (issue #97): what a media source does when playback reaches the
/// trim-out point (or the file's natural end). The issue's
/// return-to-previous-scene / advance-the-rundown actions are scene-control
/// decisions that belong to S08; this enum is the seam for them.
enum MediaEndAction: String, Codable, CaseIterable, Sendable {
    /// Freeze on the last frame (the renderer keeps painting it).
    case hold
    /// Rewind to the trim-in point and clear the frame (black fallback).
    case stop

    var displayName: String {
        switch self {
        case .hold: return "Hold Last Frame"
        case .stop: return "Stop (Black)"
        }
    }
}

/// A02 (issue #97): a local video file (MP4/MOV/ProRes — anything
/// AVFoundation reads) as a named, reusable source. The app is sandboxed, so
/// the persisted identity is a SECURITY-SCOPED BOOKMARK created from the
/// user's file pick, not the raw URL. Transport position/play state is
/// session state and deliberately NOT here; the payload owns the durable
/// playback policy (loop, autoplay, end action, trim points).
struct MediaSourcePayload: Hashable, Codable, Sendable {
    var assetIdentifier: String? = nil
    /// Security-scoped bookmark for the picked video file (the access grant).
    var bookmarkData: Data? = nil
    /// The picked file's display name (bookmarks don't round-trip one).
    var fileName: String? = nil
    var loops: Bool = true
    /// Start playing as soon as the source is loaded (first reference).
    var autoplay: Bool = true
    var endAction: MediaEndAction = .hold
    /// Trim-in point in seconds (nil = file start).
    var trimInSeconds: Double? = nil
    /// Trim-out point in seconds (nil = natural end).
    var trimOutSeconds: Double? = nil

    init(assetIdentifier: String? = nil,
         bookmarkData: Data? = nil,
         fileName: String? = nil,
         loops: Bool = true,
         autoplay: Bool = true,
         endAction: MediaEndAction = .hold,
         trimInSeconds: Double? = nil,
         trimOutSeconds: Double? = nil) {
        self.assetIdentifier = assetIdentifier
        self.bookmarkData = bookmarkData
        self.fileName = fileName
        self.loops = loops
        self.autoplay = autoplay
        self.endAction = endAction
        self.trimInSeconds = trimInSeconds
        self.trimOutSeconds = trimOutSeconds
    }

    /// The A02 fields were added after v2 shipped; decode every field with a
    /// default so older persisted documents keep loading (additive wire
    /// change, same pattern as `LayerNode.isLocked`).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        assetIdentifier = try container.decodeIfPresent(String.self, forKey: .assetIdentifier)
        bookmarkData = try container.decodeIfPresent(Data.self, forKey: .bookmarkData)
        fileName = try container.decodeIfPresent(String.self, forKey: .fileName)
        loops = try container.decodeIfPresent(Bool.self, forKey: .loops) ?? true
        autoplay = try container.decodeIfPresent(Bool.self, forKey: .autoplay) ?? true
        endAction = try container.decodeIfPresent(MediaEndAction.self, forKey: .endAction) ?? .hold
        trimInSeconds = try container.decodeIfPresent(Double.self, forKey: .trimInSeconds)
        trimOutSeconds = try container.decodeIfPresent(Double.self, forKey: .trimOutSeconds)
    }
}

struct PDFSourcePayload: Hashable, Codable, Sendable {
    var assetIdentifier: String? = nil
    var page: Int = 0
}

struct WebSourcePayload: Hashable, Codable, Sendable {
    /// Remote widget URL (nil when the widget is a local HTML asset).
    var url: URL? = nil
    /// The full G08 widget configuration: viewport, fps, interaction,
    /// audio route, CSS overrides, scene-entry refresh, local HTML asset.
    /// `url` mirrors the effective remote widget URL for legacy documents
    /// and the URL editor. Frame identity uses the full normalized configuration.
    var configuration: BrowserOverlayConfiguration = BrowserOverlayConfiguration()

    private enum CodingKeys: String, CodingKey { case url, configuration }
    init(url: URL? = nil, configuration: BrowserOverlayConfiguration = BrowserOverlayConfiguration()) {
        self.url = url
        self.configuration = configuration
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decodeIfPresent(URL.self, forKey: .url)
        configuration = try c.decodeIfPresent(BrowserOverlayConfiguration.self,
                                              forKey: .configuration)
            ?? BrowserOverlayConfiguration(urlString: url?.absoluteString)
    }
}

enum GuestSourceRole: String, Hashable, Codable, Sendable {
    case camera, screen
}

struct GuestSourcePayload: Hashable, Codable, Sendable {
    /// Legacy display/link identity. It never authorizes incoming media.
    var sessionIdentifier: String? = nil
    /// Stable project identity; remote capabilities and generations stay runtime-only.
    var slotID: UUID? = nil
    var role: GuestSourceRole = .camera

    init(sessionIdentifier: String? = nil, slotID: UUID? = nil, role: GuestSourceRole = .camera) {
        self.sessionIdentifier = sessionIdentifier; self.slotID = slotID; self.role = role
    }

    private enum CodingKeys: String, CodingKey { case sessionIdentifier, slotID, role }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sessionIdentifier = try values.decodeIfPresent(String.self, forKey: .sessionIdentifier)
        slotID = try values.decodeIfPresent(UUID.self, forKey: .slotID)
        role = try values.decodeIfPresent(GuestSourceRole.self, forKey: .role) ?? .camera
    }
}

/// C09 (issue #163): a Syphon feed published by a local creative/titling
/// app (OBS, MadMapper, Resolume, VDMX, …). The persisted identity is the
/// server name + owning app name pair — what a relaunch of the same app
/// restores — so a saved source survives server app restarts. The server's
/// instance UUID is volatile (a new one per launch) and is deliberately NOT
/// part of the payload: matching by it would defeat C10 auto-recovery.
struct SyphonSourcePayload: Hashable, Codable, Sendable {
    /// `SyphonServerDescriptionNameKey` at registration; may be empty (some
    /// servers publish no name — the app name alone identifies them).
    var serverName: String = ""
    /// `SyphonServerDescriptionAppNameKey` at registration.
    var appName: String = ""

    /// The display title for source rows and discovery lists.
    var displayTitle: String {
        switch (serverName.isEmpty, appName.isEmpty) {
        case (false, false): return "\(appName) — \(serverName)"
        case (false, true): return serverName
        case (true, false): return appName
        case (true, true): return "Unnamed Syphon Server"
        }
    }
}

struct SceneReferencePayload: Hashable, Codable, Sendable {
    /// The scene this layer nests (cycles are rejected at edit time).
    var sceneID: SceneID
}

/// A06 (issue #118): an application-audio source — the audio of one running
/// app, or the whole-system mix, captured INDEPENDENTLY of any screen/video
/// scene. App-audio sources live in the project source registry only (never
/// as canvas layers: the payload is not renderable, so layer-add validation
/// rejects it), and their capture demand is "registered + enabled" rather
/// than "a visible layer references it".
///
/// Every field is part of the payload identity, so retargeting or toggling
/// `isEnabled` re-keys the capture pool and restarts/stops the capture
/// deliberately — exactly the C03 privacy-edit pattern.
struct AppAudioSourcePayload: Hashable, Codable, Sendable {
    enum Mode: String, Codable, CaseIterable, Sendable {
        /// One running application, pinned by bundle identifier.
        case application
        /// The whole-system mix (every app except the studio itself and the
        /// globally excluded apps). Per-app sources are excluded from this
        /// mix at capture time so system + per-app never double.
        case system
    }
    var mode: Mode = .application
    /// The target app's bundle identifier (application mode).
    var bundleID: String? = nil
    /// The app's display name at registration time, so the row reads
    /// sensibly after the app quits (the C10 missing state).
    var appName: String? = nil
    /// Whether the source captures. Demand = registered + enabled.
    var isEnabled: Bool = true

    init(mode: Mode = .application,
         bundleID: String? = nil,
         appName: String? = nil,
         isEnabled: Bool = true) {
        self.mode = mode
        self.bundleID = bundleID
        self.appName = appName
        self.isEnabled = isEnabled
    }

    /// Decode every field with a default so documents written before later
    /// A06 refinements keep loading (the established additive-wire pattern).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decodeIfPresent(Mode.self, forKey: .mode) ?? .application
        bundleID = try container.decodeIfPresent(String.self, forKey: .bundleID)
        appName = try container.decodeIfPresent(String.self, forKey: .appName)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }

    /// The synthetic channel key for the system mix (it has no bundle ID).
    static let systemMixChannelID = "stream.system-mix"

    /// The `AudioChannelID.application(bundleID:)` key this source feeds.
    var channelBundleID: String {
        switch mode {
        case .system: return Self.systemMixChannelID
        case .application: return bundleID ?? "unconfigured"
        }
    }

    /// The display title for source rows and the mixer strip fallback.
    var displayTitle: String {
        switch mode {
        case .system: return "System Audio"
        case .application: return appName ?? bundleID ?? "Unconfigured App"
        }
    }
}

/// The typed content of one layer. Encoded as a `kind` discriminator string
/// plus a per-kind payload object, decoupled from Swift case names, so the
/// format grows (new kinds) without breaking older persisted documents.
enum LayerPayload: Hashable, Sendable {
    case camera(CameraSourcePayload)
    case screen(ScreenSourcePayload)
    case image(ImageSourcePayload)
    case text(TextSourcePayload)
    case shape(ShapeSourcePayload)
    case media(MediaSourcePayload)
    case pdf(PDFSourcePayload)
    case web(WebSourcePayload)
    case guest(GuestSourcePayload)
    case syphon(SyphonSourcePayload)
    case scene(SceneReferencePayload)
    /// A06 (issue #118): app/system audio-only capture. Registry-source only
    /// — never a renderable canvas layer.
    case appAudio(AppAudioSourcePayload)

    /// Stable discriminator used on the wire.
    var kind: String {
        switch self {
        case .camera: return "camera"
        case .screen: return "screen"
        case .image: return "image"
        case .text: return "text"
        case .shape: return "shape"
        case .media: return "media"
        case .pdf: return "pdf"
        case .web: return "web"
        case .guest: return "guest"
        case .syphon: return "syphon"
        case .scene: return "scene"
        case .appAudio: return "appAudio"
        }
    }

    var isCamera: Bool {
        if case .camera = self { return true }
        return false
    }

    var isScreen: Bool {
        if case .screen = self { return true }
        return false
    }

    var isSyphon: Bool {
        if case .syphon = self { return true }
        return false
    }

    var isMedia: Bool {
        if case .media = self { return true }
        return false
    }

    var isPDF: Bool {
        if case .pdf = self { return true }
        return false
    }

    /// G01 (issue #81): a static image/logo layer.
    var isImage: Bool {
        if case .image = self { return true }
        return false
    }

    /// A06 (issue #118): an app/system audio-only registry source.
    var isAppAudio: Bool {
        if case .appAudio = self { return true }
        return false
    }

    var isText: Bool {
        if case .text = self { return true }
        return false
    }

    var isShape: Bool {
        if case .shape = self { return true }
        return false
    }

    var isScene: Bool {
        if case .scene = self { return true }
        return false
    }

    /// True when the current render path can actually paint this kind:
    /// camera/screen through the capture pipeline (S03), solid-color shapes
    /// and text generated directly by `SceneRenderer` (S07), nested
    /// scenes rendered recursively (S06), media (A02, issue #97: video
    /// file playout pulled per tick from the pool's playback engines), and
    /// image layers (G01, issue #81: decoded ImageIO assets composited with
    /// alpha through the image store). The rest are model-only until the
    /// composition engine grows source support. UI must mark non-renderable
    /// kinds rather than implying they show on output.
    var isRenderable: Bool {
        isCamera || isScreen || isText || isShape || isScene || isSyphon || isMedia || isImage || isPDF || isWeb
    }

    /// Short human name for layer-panel rows and add-layer menus.
    var displayName: String {
        switch self {
        case .camera: return "Camera"
        case .screen: return "Screen"
        case .image: return "Image"
        case .text: return "Text"
        case .shape: return "Shape"
        case .media: return "Media"
        case .pdf: return "PDF"
        case .web: return "Web"
        case .guest: return "Guest"
        case .syphon: return "Syphon"
        case .scene: return "Scene"
        case .appAudio: return "App Audio"
        }
    }

    /// SF Symbol for the layer panel's type icon.
    var systemImage: String {
        switch self {
        case .camera: return "camera.fill"
        case .screen: return "display"
        case .image: return "photo"
        case .text: return "textformat"
        case .shape: return "rectangle.fill"
        case .media: return "film"
        case .pdf: return "doc.fill"
        case .web: return "globe"
        case .guest: return "person.2.fill"
        case .syphon: return "app.connected.to.app.below.fill"
        case .scene: return "rectangle.on.rectangle"
        case .appAudio: return "speaker.wave.2.fill"
        }
    }
}

extension LayerPayload: Codable {
    private enum Kind: String, Codable {
        case camera, screen, image, text, shape, media, pdf, web, guest, syphon, scene, appAudio
    }
    private enum CodingKeys: String, CodingKey {
        case kind, payload
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .camera:
            self = .camera(try container.decode(CameraSourcePayload.self, forKey: .payload))
        case .screen:
            self = .screen(try container.decode(ScreenSourcePayload.self, forKey: .payload))
        case .image:
            self = .image(try container.decode(ImageSourcePayload.self, forKey: .payload))
        case .text:
            self = .text(try container.decode(TextSourcePayload.self, forKey: .payload))
        case .shape:
            self = .shape(try container.decode(ShapeSourcePayload.self, forKey: .payload))
        case .media:
            self = .media(try container.decode(MediaSourcePayload.self, forKey: .payload))
        case .pdf:
            self = .pdf(try container.decode(PDFSourcePayload.self, forKey: .payload))
        case .web:
            self = .web(try container.decode(WebSourcePayload.self, forKey: .payload))
        case .guest:
            self = .guest(try container.decode(GuestSourcePayload.self, forKey: .payload))
        case .syphon:
            self = .syphon(try container.decode(SyphonSourcePayload.self, forKey: .payload))
        case .scene:
            self = .scene(try container.decode(SceneReferencePayload.self, forKey: .payload))
        case .appAudio:
            self = .appAudio(try container.decode(AppAudioSourcePayload.self, forKey: .payload))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .camera(let payload):
            try container.encode(Kind.camera, forKey: .kind)
            try container.encode(payload, forKey: .payload)
        case .screen(let payload):
            try container.encode(Kind.screen, forKey: .kind)
            try container.encode(payload, forKey: .payload)
        case .image(let payload):
            try container.encode(Kind.image, forKey: .kind)
            try container.encode(payload, forKey: .payload)
        case .text(let payload):
            try container.encode(Kind.text, forKey: .kind)
            try container.encode(payload, forKey: .payload)
        case .shape(let payload):
            try container.encode(Kind.shape, forKey: .kind)
            try container.encode(payload, forKey: .payload)
        case .media(let payload):
            try container.encode(Kind.media, forKey: .kind)
            try container.encode(payload, forKey: .payload)
        case .pdf(let payload):
            try container.encode(Kind.pdf, forKey: .kind)
            try container.encode(payload, forKey: .payload)
        case .web(let payload):
            try container.encode(Kind.web, forKey: .kind)
            try container.encode(payload, forKey: .payload)
        case .guest(let payload):
            try container.encode(Kind.guest, forKey: .kind)
            try container.encode(payload, forKey: .payload)
        case .syphon(let payload):
            try container.encode(Kind.syphon, forKey: .kind)
            try container.encode(payload, forKey: .payload)
        case .scene(let payload):
            try container.encode(Kind.scene, forKey: .kind)
            try container.encode(payload, forKey: .payload)
        case .appAudio(let payload):
            try container.encode(Kind.appAudio, forKey: .kind)
            try container.encode(payload, forKey: .payload)
        }
    }
}

// MARK: - Graph nodes

/// One source instance on a scene's canvas: a typed payload plus placement,
/// visibility, effects, and an audio binding. `sourceID` binds the layer to a
/// project-level `SourceDefinition` when it instantiates one; the inline
/// `payload` stays the render authority so a scene document is self-contained.
struct LayerNode: Identifiable, Hashable, Codable, Sendable {
    var id: LayerID
    var name: String
    var sourceID: SourceDefinitionID?
    var payload: LayerPayload
    var transform: LayerTransform
    var isVisible: Bool
    var effects: [LayerEffect]
    var audio: AudioBinding
    var groupID: GroupID?
    /// S03: a locked layer rejects every edit (visibility, transform,
    /// effects, audio, rename, move, remove) through the dispatcher until
    /// unlocked. Combined with its group's lock for the EFFECTIVE lock.
    var isLocked: Bool
    /// E01 (issue #101): the layer's framing/picture-adjustment OVERRIDES.
    /// Nil = inherit the bound source's `SourceDefinition.effectDefaults`
    /// (identity when unbound/unset). A complete value, not a patch — an
    /// override replaces the source defaults wholesale. Staged scene content:
    /// edits stage, Take, revert, and undo like the transform.
    var effectOverrides: SourceEffects?
    /// G03 (issue #106): the layer's styling — shape mask, border, shadow,
    /// opacity, perspective. `.identity` = unstyled. Staged scene content
    /// exactly like the transform; on overlays it is project-level content
    /// through the S07 overlay commands. Non-destructive and
    /// alpha-preserving (see LayerStyle.swift).
    var style: LayerStyle
    /// Explicit cross-scene motion identity; duplication preserves this value.
    /// Multiple visible copies with one identity are ambiguous and fall back.
    var motionID: UUID

    init(id: LayerID = LayerID(),
         name: String,
         sourceID: SourceDefinitionID? = nil,
         payload: LayerPayload,
         transform: LayerTransform,
         isVisible: Bool = true,
         effects: [LayerEffect] = [],
         audio: AudioBinding = .default,
         groupID: GroupID? = nil,
         isLocked: Bool = false,
         effectOverrides: SourceEffects? = nil,
         style: LayerStyle = .identity,
         motionID: UUID = UUID()) {
        self.id = id
        self.name = name
        self.sourceID = sourceID
        self.payload = payload
        self.transform = transform
        self.isVisible = isVisible
        self.effects = effects
        self.audio = audio
        self.groupID = groupID
        self.isLocked = isLocked
        self.effectOverrides = effectOverrides
        self.style = style
        self.motionID = motionID
    }

    /// `isLocked` was added after v2 shipped; decode it with a default so
    /// older persisted documents keep loading (additive wire change).
    /// E01's `effectOverrides` and G03's `style` follow the same pattern.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(LayerID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        sourceID = try container.decodeIfPresent(SourceDefinitionID.self, forKey: .sourceID)
        payload = try container.decode(LayerPayload.self, forKey: .payload)
        transform = try container.decode(LayerTransform.self, forKey: .transform)
        isVisible = try container.decode(Bool.self, forKey: .isVisible)
        effects = try container.decode([LayerEffect].self, forKey: .effects)
        audio = try container.decode(AudioBinding.self, forKey: .audio)
        groupID = try container.decodeIfPresent(GroupID.self, forKey: .groupID)
        isLocked = try container.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false
        effectOverrides = try container.decodeIfPresent(SourceEffects.self, forKey: .effectOverrides)
        style = try container.decodeIfPresent(LayerStyle.self, forKey: .style) ?? .identity
        motionID = try container.decodeIfPresent(UUID.self, forKey: .motionID) ?? id.rawValue
    }
}

extension LayerNode {
    /// A camera layer covering the whole canvas.
    static func fullscreenCamera(sourceID: SourceDefinitionID? = nil) -> LayerNode {
        LayerNode(name: "Camera",
                  sourceID: sourceID,
                  payload: .camera(CameraSourcePayload()),
                  transform: .fullscreen)
    }

    /// A screen layer covering the whole canvas.
    static func fullscreenScreen(sourceID: SourceDefinitionID? = nil) -> LayerNode {
        LayerNode(name: "Screen",
                  sourceID: sourceID,
                  payload: .screen(ScreenSourcePayload()),
                  transform: .fullscreen)
    }

    /// A camera PIP layer in the given corner; `scale` is the fraction of
    /// frame width (0.10...0.40), exactly the classic PIP scale.
    static func cameraPIP(corner: PIPCorner,
                          scale: Double,
                          sourceID: SourceDefinitionID? = nil) -> LayerNode {
        LayerNode(name: "Camera PIP",
                  sourceID: sourceID,
                  payload: .camera(CameraSourcePayload()),
                  transform: LayerTransform(pipCorner: corner, scale: scale))
    }
}

/// A named grouping of layers (folders in the layer list). Membership is a
/// `groupID` on each `LayerNode`, keeping the graph itself flat and ordered.
struct LayerGroup: Identifiable, Hashable, Codable, Sendable {
    var id: GroupID
    var name: String
    var isCollapsed: Bool
    /// S03: a locked group effectively locks every member (effective lock =
    /// `member.isLocked || group.isLocked`), enforced non-destructively by
    /// dispatcher rejection — member lock states survive group unlock.
    var isLocked: Bool

    init(id: GroupID = GroupID(), name: String, isCollapsed: Bool = false, isLocked: Bool = false) {
        self.id = id
        self.name = name
        self.isCollapsed = isCollapsed
        self.isLocked = isLocked
    }

    /// `isLocked` was added after v2 shipped; decode it with a default so
    /// older persisted documents keep loading (additive wire change).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(GroupID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        isCollapsed = try container.decode(Bool.self, forKey: .isCollapsed)
        isLocked = try container.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false
    }
}

/// The output surface a scene composes onto. Transforms are normalized, so
/// `referenceSize` only fixes the aspect/intended resolution.
struct Canvas: Identifiable, Hashable, Codable, Sendable {
    var id: CanvasID
    var name: String
    var referenceSize: GraphSize

    init(id: CanvasID = CanvasID(),
         name: String = "1080p",
         referenceSize: GraphSize = GraphSize(width: 1920, height: 1080)) {
        self.id = id
        self.name = name
        self.referenceSize = referenceSize
    }
}

/// A reusable, project-level source (one camera, one display capture, ...)
/// that layers across scenes can instantiate by `sourceID`.
struct SourceDefinition: Identifiable, Hashable, Codable, Sendable {
    var id: SourceDefinitionID
    var name: String
    var payload: LayerPayload
    /// E01 (issue #101): the source's framing/picture-adjustment DEFAULTS,
    /// applied to every bound layer that carries no `effectOverrides` of its
    /// own. Nil = identity. Project-level: edits apply immediately to staged
    /// AND program compositions (the S07 overlay-edit precedent). Optional,
    /// so the synthesized decoder treats it as additive (`decodeIfPresent`)
    /// and pre-E01 documents keep loading.
    var effectDefaults: SourceEffects? = nil

    init(id: SourceDefinitionID = SourceDefinitionID(), name: String, payload: LayerPayload,
         effectDefaults: SourceEffects? = nil) {
        self.id = id
        self.name = name
        self.payload = payload
        self.effectDefaults = effectDefaults
    }
}

// MARK: - Backgrounds and project overlays (S07)
//
// S07 (issue #74) adds the two scopes around a scene's own layers:
// - an explicit BACKGROUND: per scene (`Scene.background`), falling back to
//   the project default (`SceneDocument.defaultBackground`), falling back to
//   the documented implicit black canvas;
// - PROJECT-WIDE OVERLAYS: layers stored once at document level
//   (`SceneDocument.overlays`) that composite above EVERY scene's layers
//   without being duplicated into each scene, with per-scene visibility
//   overrides (`Scene.hiddenOverlayIDs`).
//
// Deterministic compositing order (back to front): background → scene layers
// → project overlays.

/// What a scene composites onto before its first layer. Wire format is a
/// `kind` discriminator so new background kinds are additive.
enum SceneBackground: Hashable, Sendable {
    case solid(colorHex: String)
    case gradient(topColorHex: String, bottomColorHex: String)
    /// G01 (issue #81): an image background composites through the same
    /// image store as image layers (aspect-FILL covering the canvas); an
    /// unresolved/missing asset paints the documented black fallback.
    case image(ImageSourcePayload)

    /// Short human name for background pickers.
    var displayName: String {
        switch self {
        case .solid: return "Solid Color"
        case .gradient: return "Gradient"
        case .image: return "Image"
        }
    }
}

extension SceneBackground: Codable {
    private enum Kind: String, Codable {
        case solid, gradient, image
    }
    private enum CodingKeys: String, CodingKey {
        case kind, colorHex, topColorHex, bottomColorHex, payload
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .solid:
            self = .solid(colorHex: try container.decode(String.self, forKey: .colorHex))
        case .gradient:
            self = .gradient(topColorHex: try container.decode(String.self, forKey: .topColorHex),
                             bottomColorHex: try container.decode(String.self, forKey: .bottomColorHex))
        case .image:
            self = .image(try container.decode(ImageSourcePayload.self, forKey: .payload))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .solid(let colorHex):
            try container.encode(Kind.solid, forKey: .kind)
            try container.encode(colorHex, forKey: .colorHex)
        case .gradient(let topColorHex, let bottomColorHex):
            try container.encode(Kind.gradient, forKey: .kind)
            try container.encode(topColorHex, forKey: .topColorHex)
            try container.encode(bottomColorHex, forKey: .bottomColorHex)
        case .image(let payload):
            try container.encode(Kind.image, forKey: .kind)
            try container.encode(payload, forKey: .payload)
        }
    }
}

/// The project-level composition context every scene renders inside (S07):
/// the shared overlays painted above scene layers and the default background
/// painted behind them. A plain value snapshot is what the composition engine
/// reads each tick (via `ProjectOverlayStore`), so a mid-tick overlay edit can
/// never tear a frame.
struct OverlayContext: Hashable, Sendable {
    /// Back-to-front, exactly like `Scene.layers`.
    var overlays: [LayerNode] = []
    var defaultBackground: SceneBackground? = nil
    /// S09 (issue #100): the project default transition, read by the program
    /// engine when an incoming scene carries no per-scene override. Riding
    /// this existing per-tick snapshot keeps the default live-configurable
    /// without a new engine seam.
    var defaultTransition: SceneTransition = .default

    static let empty = OverlayContext()

    /// The overlays that paint for `scene`, back-to-front: visible and not
    /// hidden by the scene's per-scene override. Locks never affect rendering
    /// (they gate edits only), same as scene layers.
    func overlays(for scene: Scene) -> [LayerNode] {
        overlays.filter { $0.isVisible && !scene.hiddenOverlayIDs.contains($0.id) }
    }

    /// The background `scene` composites onto: its own override, else the
    /// project default. Nil = the documented implicit black canvas.
    func background(for scene: Scene) -> SceneBackground? {
        scene.background ?? defaultBackground
    }
}

/// Shared `#RRGGBB` / `#RRGGBBAA` parsing and formatting for the `colorHex`
/// fields on text, shape, effect, and background payloads. Unparseable values
/// read as opaque white (the payloads' own defaults), never crash.
enum HexColor {
    static func components(_ hex: String) -> (red: Double, green: Double, blue: Double, alpha: Double) {
        var string = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if string.hasPrefix("#") { string.removeFirst() }
        var value: UInt64 = 0
        guard Scanner(string: string).scanHexInt64(&value) else { return (1, 1, 1, 1) }
        switch string.count {
        case 6:
            return (Double((value >> 16) & 0xFF) / 255,
                    Double((value >> 8) & 0xFF) / 255,
                    Double(value & 0xFF) / 255, 1)
        case 8:
            return (Double((value >> 24) & 0xFF) / 255,
                    Double((value >> 16) & 0xFF) / 255,
                    Double((value >> 8) & 0xFF) / 255,
                    Double(value & 0xFF) / 255)
        default:
            return (1, 1, 1, 1)
        }
    }

    static func string(red: Double, green: Double, blue: Double) -> String {
        let clamp: (Double) -> Int = { min(255, max(0, Int(($0 * 255).rounded()))) }
        return String(format: "#%02X%02X%02X", clamp(red), clamp(green), clamp(blue))
    }
}

// MARK: - Scene sounds (A03, issue #98)

/// When a scene-sound binding fires. Enter/exit are one-shot stingers (they
/// play through to the end even across a following scene change); `continue`
/// is an ambient bed that loops while the scene is on program.
enum SceneSoundRule: String, Codable, CaseIterable, Sendable {
    case enter
    case exit
    case `continue`

    var displayName: String {
        switch self {
        case .enter: return "On Enter (Stinger)"
        case .exit: return "On Exit (Stinger)"
        case .continue: return "Continue (Ambient Bed)"
        }
    }
}

/// A03 (issue #98): one sound bound to a scene — an enter/exit stinger or a
/// looping ambient bed. Scene CONTENT: bindings stage, Take, revert, and undo
/// exactly like layers, and the Take path (W05 dispatcher →
/// `SoundboardController.syncProgramScene`) fires the rules as the scene
/// enters/leaves program. The binding carries its own security-scoped
/// bookmark (self-contained, the soundboard pattern), and its `id` doubles as
/// the `.media(id)` mix-channel identity, so a relinked clip keeps its
/// channel (and level) — hardware triggers route through the studio engine
/// and are audible in the broadcast, as the issue requires.
struct SceneSoundBinding: Identifiable, Hashable, Codable, Sendable {
    /// Stable identity — also the `.media(id)` mix-channel key.
    var id: SourceDefinitionID
    var rule: SceneSoundRule
    var name: String
    /// Security-scoped bookmark for the picked audio file (the access grant).
    var bookmarkData: Data?
    /// The picked file's display name (bookmarks don't round-trip one).
    var fileName: String?
    /// Linear program gain, 0...2 (1 = unity).
    var volume: Double

    init(id: SourceDefinitionID = SourceDefinitionID(),
         rule: SceneSoundRule = .enter,
         name: String,
         bookmarkData: Data? = nil,
         fileName: String? = nil,
         volume: Double = 1) {
        self.id = id
        self.rule = rule
        self.name = name
        self.bookmarkData = bookmarkData
        self.fileName = fileName
        self.volume = volume
    }

    /// Decode every field with a default so documents written before later
    /// A03 refinements keep loading (the established additive-wire pattern).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(SourceDefinitionID.self, forKey: .id) ?? SourceDefinitionID()
        rule = try container.decodeIfPresent(SceneSoundRule.self, forKey: .rule) ?? .enter
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Sound"
        bookmarkData = try container.decodeIfPresent(Data.self, forKey: .bookmarkData)
        fileName = try container.decodeIfPresent(String.self, forKey: .fileName)
        volume = try container.decodeIfPresent(Double.self, forKey: .volume) ?? 1
    }

    /// Builds a binding from a user-picked audio file (nil when the bookmark
    /// can't be created).
    static func make(pickedFile url: URL, rule: SceneSoundRule) -> SceneSoundBinding? {
        guard let payload = MediaSourceFactory.payload(forPickedFile: url) else { return nil }
        return SceneSoundBinding(rule: rule,
                                 name: url.deletingPathExtension().lastPathComponent,
                                 bookmarkData: payload.bookmarkData,
                                 fileName: payload.fileName)
    }
}

// MARK: - Scene audio snapshots and media behavior (S08, issue #99)

/// S08 (issue #99): one channel's captured mixer state inside a scene audio
/// snapshot. Keyed by `AudioChannelID.label` (the A04 mixer-document key),
/// so a capture survives channel re-registration and engine restarts exactly
/// like the mixer document itself.
struct SceneAudioChannelState: Hashable, Codable, Sendable {
    /// Linear fader gain, 0...2 (1 = unity).
    var volume: Double
    var isMuted: Bool

    init(volume: Double, isMuted: Bool) {
        self.volume = volume
        self.isMuted = isMuted
    }

    /// Decode every field with a default (the established additive-wire
    /// pattern), so a snapshot written by a later app version never strands
    /// the whole scene document.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        volume = try container.decodeIfPresent(Double.self, forKey: .volume) ?? 1
        isMuted = try container.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
    }
}

/// S08 (issue #99): a scene's opt-in audio snapshot — the mixer state the
/// scene restores when it becomes PROGRAM (Take). Nil on the scene is the
/// explicit inherit-current option: the live mix persists across the Take
/// untouched. Only channels present in `channelGains` are touched on
/// restore — the global mixer state of every channel the scene doesn't name
/// survives scene changes. Scene-bound capture channels are deliberately
/// excluded: their program levels are the scene's per-layer S05
/// `AudioBinding`s, already scene content.
struct SceneAudioSnapshot: Hashable, Codable, Sendable {
    var channelGains: [String: SceneAudioChannelState]

    init(channelGains: [String: SceneAudioChannelState] = [:]) {
        self.channelGains = channelGains
    }

    /// Decode with a default so a partial snapshot never strands the scene.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        channelGains = try container.decodeIfPresent([String: SceneAudioChannelState].self,
                                                     forKey: .channelGains) ?? [:]
    }
}

/// S08 (issue #99): what a scene's media sources do when the scene ENTERS
/// program (Take).
enum SceneMediaEntryBehavior: String, Codable, CaseIterable, Sendable {
    /// Leave playout where it is — a Take between scenes sharing a source
    /// never restarts it (the standing A02 guarantee). The default.
    case `continue`
    /// Play: resume from the held position, or start a source that never
    /// played (a play after ENDED restarts from trim-in, the A02 rule).
    case resume
    /// Rewind to the trim-in point and play — restarts even a source the
    /// outgoing scene shared (the documented play-from-start exception).
    case restartFromStart

    var displayName: String {
        switch self {
        case .continue: return "Continue (No Restart)"
        case .resume: return "Resume / Play"
        case .restartFromStart: return "Restart from Start"
        }
    }
}

/// S08 (issue #99): what a scene's media sources do when the scene LEAVES
/// program. Sources shared with the entering scene are exempt — the entering
/// scene's entry policy governs them.
enum SceneMediaExitBehavior: String, Codable, CaseIterable, Sendable {
    /// No scene-level intervention; the A02 demand model still parks a
    /// source nothing references anymore. The default.
    case keepPlaying
    /// Pause mid-file — the position (and the held last frame) survives.
    case pause
    /// Rewind to the trim-in point and clear the frame (black fallback).
    case stop

    var displayName: String {
        switch self {
        case .keepPlaying: return "Keep Playing"
        case .pause: return "Pause"
        case .stop: return "Stop (Rewind)"
        }
    }
}

/// S08 (issue #99): the scene's media entry/exit policy. Scene content —
/// staged, Taken, reverted, and undone like layers and sound bindings.
struct SceneMediaBehavior: Hashable, Codable, Sendable {
    var entry: SceneMediaEntryBehavior
    var exit: SceneMediaExitBehavior

    static let `default` = SceneMediaBehavior()

    init(entry: SceneMediaEntryBehavior = .continue,
         exit: SceneMediaExitBehavior = .keepPlaying) {
        self.entry = entry
        self.exit = exit
    }

    /// Decode every field with a default (the established additive-wire
    /// pattern), so a document holding only one of the two policies keeps
    /// loading.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entry = try container.decodeIfPresent(SceneMediaEntryBehavior.self, forKey: .entry) ?? .continue
        exit = try container.decodeIfPresent(SceneMediaExitBehavior.self, forKey: .exit) ?? .keepPlaying
    }
}

// MARK: - Scene

/// One switchable scene: an ordered layer graph on a canvas. `layers` is
/// back-to-front — index 0 paints first, the last layer is on top.
struct Scene: Identifiable, Hashable, Codable, Sendable {
    var id: SceneID
    var name: String
    var canvas: Canvas
    var groups: [LayerGroup]
    var layers: [LayerNode] {
        didSet { pruneSecondaryPlacements() }
    }
    /// S07: the explicit background this scene composites onto. Nil inherits
    /// the project default (`SceneDocument.defaultBackground`); when that is
    /// also unset the documented fallback remains the implicit black canvas.
    var background: SceneBackground?
    /// S07: per-scene visibility overrides for project-wide overlays — the
    /// stable LayerIDs of `SceneDocument.overlays` entries this scene hides.
    /// Scene-local content, so overrides stage and Take like any scene edit.
    var hiddenOverlayIDs: Set<LayerID>
    /// A03 (issue #98): the scene's bound sounds (enter/exit stingers,
    /// continue ambient beds). Scene content — staged, Taken, reverted, and
    /// undone like layers; the Take path fires their rules.
    var soundBindings: [SceneSoundBinding]
    /// S08 (issue #99): the opt-in audio snapshot restored when this scene
    /// becomes program. Nil = inherit the current mix (audio persists
    /// globally across the Take).
    var audioSnapshot: SceneAudioSnapshot?
    /// S08 (issue #99): what the scene's media sources do on program
    /// entry/exit.
    var mediaBehavior: SceneMediaBehavior
    /// S09 (issue #100): the transition a Take INTO this scene renders
    /// (dissolve/wipe/stinger/…). Nil = inherit the project default
    /// (`SceneDocument.defaultTransition`). Scene content: it stages, Takes,
    /// reverts, and undoes like any scene edit.
    var transition: SceneTransition?
    /// #178: geometry/visibility for the second canvas, staged with the scene.
    var secondaryCanvas: SecondaryCanvasLayout?

    init(id: SceneID = SceneID(),
         name: String,
         canvas: Canvas = Canvas(),
         groups: [LayerGroup] = [],
         layers: [LayerNode],
         background: SceneBackground? = nil,
         hiddenOverlayIDs: Set<LayerID> = [],
         soundBindings: [SceneSoundBinding] = [],
         audioSnapshot: SceneAudioSnapshot? = nil,
         mediaBehavior: SceneMediaBehavior = .default,
         transition: SceneTransition? = nil,
         secondaryCanvas: SecondaryCanvasLayout? = nil) {
        self.id = id
        self.name = name
        self.canvas = canvas
        self.groups = groups
        self.layers = layers
        self.background = background
        self.hiddenOverlayIDs = hiddenOverlayIDs
        self.soundBindings = soundBindings
        self.audioSnapshot = audioSnapshot
        self.mediaBehavior = mediaBehavior
        self.transition = transition
        self.secondaryCanvas = secondaryCanvas
        pruneSecondaryPlacements()
    }

    /// `background`/`hiddenOverlayIDs` were added after v2 shipped; decode
    /// them with defaults so older persisted documents keep loading
    /// (additive wire change, same pattern as `LayerNode.isLocked`).
    /// A03's `soundBindings` and S08's `audioSnapshot`/`mediaBehavior`
    /// follow the same pattern, as does S09's `transition`.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(SceneID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        canvas = try container.decode(Canvas.self, forKey: .canvas)
        groups = try container.decode([LayerGroup].self, forKey: .groups)
        layers = try container.decode([LayerNode].self, forKey: .layers)
        background = try container.decodeIfPresent(SceneBackground.self, forKey: .background)
        hiddenOverlayIDs = try container.decodeIfPresent(Set<LayerID>.self, forKey: .hiddenOverlayIDs) ?? []
        soundBindings = try container.decodeIfPresent([SceneSoundBinding].self, forKey: .soundBindings) ?? []
        audioSnapshot = try container.decodeIfPresent(SceneAudioSnapshot.self, forKey: .audioSnapshot)
        mediaBehavior = try container.decodeIfPresent(SceneMediaBehavior.self, forKey: .mediaBehavior) ?? .default
        transition = try container.decodeIfPresent(SceneTransition.self, forKey: .transition)
        secondaryCanvas = try container.decodeIfPresent(SecondaryCanvasLayout.self, forKey: .secondaryCanvas)
        pruneSecondaryPlacements()
    }

    private mutating func pruneSecondaryPlacements() {
        guard let placements = secondaryCanvas?.placements, !placements.isEmpty else { return }
        let known = Set(layers.map(\.id))
        secondaryCanvas?.placements = placements.filter { known.contains($0.key) }
    }
}

// MARK: - Scene layer-panel helpers (S03)

extension Scene {
    /// The layers in display order for the layer panel: front (top of the
    /// list, paints last) to back. The stored `layers` array is the reverse
    /// (back-to-front render order).
    var frontToBackLayers: [LayerNode] {
        layers.reversed()
    }

    /// The group a layer belongs to, if the membership resolves.
    func group(for layer: LayerNode) -> LayerGroup? {
        guard let groupID = layer.groupID else { return nil }
        return groups.first(where: { $0.id == groupID })
    }

    func group(withID id: GroupID) -> LayerGroup? {
        groups.first(where: { $0.id == id })
    }

    /// Members of a group in render (back-to-front) order.
    func members(of groupID: GroupID) -> [LayerNode] {
        layers.filter { $0.groupID == groupID }
    }

    /// The EFFECTIVE lock the dispatcher enforces (S03): a layer is
    /// uneditable when it is locked itself or its group is locked.
    func isEffectivelyLocked(_ layer: LayerNode) -> Bool {
        layer.isLocked || (group(for: layer)?.isLocked ?? false)
    }
}

extension Scene {
    /// Camera solo: one fullscreen camera layer.
    static func cameraSolo(name: String,
                           id: SceneID = SceneID(),
                           cameraSourceID: SourceDefinitionID? = nil) -> Scene {        Scene(id: id, name: name,
              layers: [.fullscreenCamera(sourceID: cameraSourceID)])
    }

    /// Screen solo: one fullscreen screen layer.
    static func screenSolo(name: String,
                           id: SceneID = SceneID(),
                           screenSourceID: SourceDefinitionID? = nil) -> Scene {
        Scene(id: id, name: name,
              layers: [.fullscreenScreen(sourceID: screenSourceID)])
    }

    /// Screen with a camera PIP: fullscreen screen at the back, camera PIP
    /// on top preserving corner and scale.
    static func screenPlusCam(name: String,
                              id: SceneID = SceneID(),
                              corner: PIPCorner = .bottomRight,
                              scale: Double = 0.28,
                              screenSourceID: SourceDefinitionID? = nil,
                              cameraSourceID: SourceDefinitionID? = nil) -> Scene {
        Scene(id: id, name: name,
              layers: [.fullscreenScreen(sourceID: screenSourceID),
                       .cameraPIP(corner: corner, scale: scale, sourceID: cameraSourceID)])
    }
}

// MARK: - Document

/// The versioned, persisted scene document (v2): the project, its reusable
/// source registry, every scene's layer graph, and the current selection.
/// `version` drives migration; `SceneDocument.currentVersion` is what
/// `SceneStore` writes.
///
/// S07: `overlays` and `defaultBackground` are PROJECT-level content, stored
/// once here — shared branding survives scene changes and exports once with
/// the project instead of being duplicated into every scene's layer stack.
struct SceneDocument: Hashable, Codable, Sendable {
    static let currentVersion = 2

    var version: Int
    var projectID: ProjectID
    var projectName: String
    var sources: [SourceDefinition]
    var scenes: [Scene]
    var selectedID: SceneID
    /// S07: project-wide overlays, back-to-front exactly like `Scene.layers`.
    /// Composited above EVERY scene's layers; a scene hides individual
    /// overlays via its `hiddenOverlayIDs`.
    var overlays: [LayerNode]
    /// S07: the project default background, used by every scene whose own
    /// `background` is nil. Nil = the documented implicit black canvas.
    var defaultBackground: SceneBackground?
    /// S09 (issue #100): the project default transition, used by every Take
    /// into a scene whose own `transition` is nil. Defaults to cut, so
    /// upgraded installs keep the pre-S09 Take behavior.
    var defaultTransition: SceneTransition
    /// E01 (issue #101): reusable named framing/picture-adjustment presets,
    /// stored once at project level and applied by writing their value as a
    /// layer override or a source default.
    var effectPresets: [SourceEffectPreset]
    /// G03 (issue #106): reusable named layer-STYLING presets (masks,
    /// borders, shadows, opacity, perspective), stored once at project level
    /// and applied by writing their value as a layer's/overlay's style.
    var stylePresets: [LayerStylePreset]
    /// G02 (issue #110): reusable named TITLE-style presets (font, size,
    /// color, alignment, background, padding, box, wrapping, overflow,
    /// timing — everything but the string), stored once at project level
    /// and applied by writing their value onto a text layer's payload.
    var textStylePresets: [TextStylePreset]

    init(version: Int = SceneDocument.currentVersion,
         projectID: ProjectID = ProjectID(),
         projectName: String = "Stream Project",
         sources: [SourceDefinition],
         scenes: [Scene],
         selectedID: SceneID,
         overlays: [LayerNode] = [],
         defaultBackground: SceneBackground? = nil,
         defaultTransition: SceneTransition = .default,
         effectPresets: [SourceEffectPreset] = [],
         stylePresets: [LayerStylePreset] = [],
         textStylePresets: [TextStylePreset] = []) {
        self.version = version
        self.projectID = projectID
        self.projectName = projectName
        self.sources = sources
        self.scenes = scenes
        self.selectedID = selectedID
        self.overlays = overlays
        self.defaultBackground = defaultBackground
        self.defaultTransition = defaultTransition
        self.effectPresets = effectPresets
        self.stylePresets = stylePresets
        self.textStylePresets = textStylePresets
    }

    /// `overlays`/`defaultBackground` were added within v2; decode them with
    /// defaults so pre-S07 v2 documents keep loading (additive wire change).
    /// S09's `defaultTransition`, E01's `effectPresets`, G03's
    /// `stylePresets`, and G02's `textStylePresets` follow the same pattern.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        projectID = try container.decode(ProjectID.self, forKey: .projectID)
        projectName = try container.decode(String.self, forKey: .projectName)
        sources = try container.decode([SourceDefinition].self, forKey: .sources)
        scenes = try container.decode([Scene].self, forKey: .scenes)
        selectedID = try container.decode(SceneID.self, forKey: .selectedID)
        overlays = try container.decodeIfPresent([LayerNode].self, forKey: .overlays) ?? []
        defaultBackground = try container.decodeIfPresent(SceneBackground.self, forKey: .defaultBackground)
        defaultTransition = try container.decodeIfPresent(SceneTransition.self, forKey: .defaultTransition) ?? .default
        effectPresets = try container.decodeIfPresent([SourceEffectPreset].self, forKey: .effectPresets) ?? []
        stylePresets = try container.decodeIfPresent([LayerStylePreset].self, forKey: .stylePresets) ?? []
        textStylePresets = try container.decodeIfPresent([TextStylePreset].self, forKey: .textStylePresets) ?? []
    }

    /// The S07 render context the engine composites every scene inside.
    var overlayContext: OverlayContext {
        OverlayContext(overlays: overlays, defaultBackground: defaultBackground,
                       defaultTransition: defaultTransition)
    }
}

// MARK: - Nested scenes (S06, issue #96)
//
// A `.scene` layer payload references another scene by ID and renders that
// scene's layer stack recursively inside the reference layer's transform.
// References are LIVE: resolution happens against the shared scene registry
// at render/demand time, never against a copy, so editing (and Taking) the
// referenced scene updates every nesting site. Cycles are rejected at edit
// time (StudioCommandDispatcher validation) and defended against here — every
// walker below is cycle-guarded per path and depth-capped, so even a corrupt
// or hand-edited document costs only a bounded amount of work.

/// Cycle-safe, depth-capped graph walks over the scene-reference graph.
enum SceneGraph {
    /// The maximum depth of a nested-scene chain the studio allows (and the
    /// bound the renderer and flatten walkers enforce defensively, beyond the
    /// edit-time check). Eight levels of nesting is far past any real
    /// branded-layout composition; the cap exists so a bad document degrades
    /// to "renders/expands nothing deeper" instead of runaway recursion.
    static let maxNestingDepth = 8

    /// ID → scene lookup for the walkers below.
    static func index(_ scenes: [Scene]) -> [SceneID: Scene] {
        Dictionary(scenes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// The visible layers of `scene` with every visible `.scene` reference
    /// expanded into the referenced scene's visible layers (recursively).
    /// The reference layer itself contributes nothing — its payload has no
    /// pixels of its own. Cycle-guarded per path (a diamond reference renders
    /// twice, a loop stops at the revisit) and depth-capped. This is the S05
    /// capture-demand seam: StreamController flattens program + staged
    /// through here so a camera used ONLY inside a nested scene still demands
    /// its capture.
    static func flattenedVisibleLayers(of scene: Scene, in scenes: [SceneID: Scene]) -> [LayerNode] {
        flatten(scene, in: scenes, visited: [scene.id], depth: 0)
    }

    private static func flatten(_ scene: Scene, in scenes: [SceneID: Scene],
                                visited: Set<SceneID>, depth: Int) -> [LayerNode] {
        guard depth <= maxNestingDepth else { return [] }
        var layers: [LayerNode] = []
        for layer in scene.layers where layer.isVisible {
            if case .scene(let reference) = layer.payload {
                guard !visited.contains(reference.sceneID),
                      let child = scenes[reference.sceneID] else { continue }
                layers.append(contentsOf: flatten(child, in: scenes,
                                                  visited: visited.union([reference.sceneID]),
                                                  depth: depth + 1))
            } else {
                layers.append(layer)
            }
        }
        return layers
    }

    /// True when making `container` reference `target` would close a loop:
    /// `target` IS `container`, or `target`'s existing reference chains can
    /// already reach `container`.
    static func wouldCreateCycle(container: SceneID, referencing target: SceneID,
                                 in scenes: [SceneID: Scene]) -> Bool {
        guard target != container else { return true }
        return reaches(from: target, to: container, in: scenes, visited: [], depth: 0)
    }

    private static func reaches(from: SceneID, to: SceneID, in scenes: [SceneID: Scene],
                                visited: Set<SceneID>, depth: Int) -> Bool {
        guard depth <= maxNestingDepth, !visited.contains(from),
              let scene = scenes[from] else { return false }
        let visited = visited.union([from])
        for layer in scene.layers {
            guard case .scene(let reference) = layer.payload else { continue }
            if reference.sceneID == to { return true }
            if reaches(from: reference.sceneID, to: to, in: scenes,
                       visited: visited, depth: depth + 1) { return true }
        }
        return false
    }

    /// The deepest reference chain at or BELOW a scene, counting scenes: 1
    /// when it nests nothing, 2 when it nests a leaf scene, etc.
    /// Cycle-guarded and capped for corrupt documents.
    static func subtreeDepth(of id: SceneID, in scenes: [SceneID: Scene]) -> Int {
        subtreeDepth(of: id, in: scenes, visited: [], depth: 0)
    }

    private static func subtreeDepth(of id: SceneID, in scenes: [SceneID: Scene],
                                     visited: Set<SceneID>, depth: Int) -> Int {
        guard depth < maxNestingDepth, !visited.contains(id),
              let scene = scenes[id] else { return 0 }
        let visited = visited.union([id])
        var deepest = 0
        for layer in scene.layers {
            guard case .scene(let reference) = layer.payload else { continue }
            deepest = max(deepest, subtreeDepth(of: reference.sceneID, in: scenes,
                                                visited: visited, depth: depth + 1))
        }
        return 1 + deepest
    }

    /// The deepest chain of referencing scenes strictly ABOVE a scene: 0 when
    /// nothing nests it, 1 when one level of scenes nests it, etc.
    /// Cycle-guarded and capped for corrupt documents.
    static func ancestorDepth(of id: SceneID, in scenes: [SceneID: Scene]) -> Int {
        ancestorDepth(of: id, in: scenes, visited: [], depth: 0)
    }

    private static func ancestorDepth(of id: SceneID, in scenes: [SceneID: Scene],
                                      visited: Set<SceneID>, depth: Int) -> Int {
        guard depth < maxNestingDepth, !visited.contains(id) else { return 0 }
        let visited = visited.union([id])
        var deepest = 0
        for (candidateID, scene) in scenes where candidateID != id {
            let references = scene.layers.contains {
                if case .scene(let reference) = $0.payload {
                    return reference.sceneID == id
                }
                return false
            }
            if references {
                deepest = max(deepest, 1 + ancestorDepth(of: candidateID, in: scenes,
                                                         visited: visited, depth: depth + 1))
            }
        }
        return deepest
    }
}
