import Foundation

/// G07 (issue #114) / G08 (issue #115): the persisted configuration model
/// for a browser-overlay widget source — the Streamlabs/StreamElements-style
/// HTML widget a `WebSourcePayload` layer renders through the WKWebView
/// snapshot seam (`BrowserOverlayHost` in the StreamMac app target).
///
/// This type is deliberately pure value logic in StreamCore (no WebKit): the
/// G07 measurement harness, the production capture host, and the inspector
/// share one normalization/validation contract, and StreamCoreTests pins it.
/// Rendering decisions the G07 measurements gate are documented here as
/// capability notes so the UI can never promise what the prototype disproved.
public struct BrowserOverlayConfiguration: Hashable, Codable, Sendable {
    /// Widget location. `nil` = no remote widget configured. Mutually
    /// exclusive with `localHTMLAssetIdentifier` — `normalized()` keeps the
    /// local HTML asset when both are set (the deliberate, sandbox-friendly
    /// choice wins over the URL string).
    public var urlString: String?
    /// G08: the P03 asset-library identifier of a local HTML file (alert
    /// fixtures, exported widget HTML). The asset carries the sandbox access
    /// grant (project copy or security-scoped bookmark), which an arbitrary
    /// `file://` URL string cannot — so local HTML is an ASSET reference,
    /// never a persisted path.
    public var localHTMLAssetIdentifier: String?
    /// Snapshot-capture cadence the producer aims for. Clamped to
    /// `Self.targetFPSRange` — the G07 measurements show CPU cost scales
    /// linearly with this value, so 60 fps is the documented ceiling (DOM-
    /// light widgets only), not a promise of hardware-efficient live textures.
    public var targetFPS: Int
    /// Offscreen web-view pixel size the widget rasterizes at.
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// Overlay widgets are click-through by default (the layer above the
    /// program output must never swallow studio input); interaction arrives
    /// programmatically via `evaluateJavaScript` alert triggers. Setting this
    /// true is the DELIBERATE interaction opt-in: the inspector preview then
    /// hit-tests the widget's webview so the operator can click/dismiss
    /// widgets manually.
    public var allowsInteraction: Bool
    /// Where the widget's audio enters the program mix.
    public var audioRoute: BrowserWidgetAudioRoute
    /// G08: CSS injected into the widget page at document end (appended
    /// `<style>` element, main frame only), re-applied on every navigation.
    /// Bounded to `Self.cssOverridesLimit` bytes of UTF-8 — enough for theme
    /// overrides, never an unbounded payload. Empty = no injection.
    public var cssOverrides: String
    /// G08: what the capture host does when a scene containing this widget
    /// enters program.
    public var sceneEntryRefresh: BrowserOverlaySceneEntryRefresh

    public init(urlString: String? = nil,
                localHTMLAssetIdentifier: String? = nil,
                targetFPS: Int = 30,
                pixelWidth: Int = 1280,
                pixelHeight: Int = 720,
                allowsInteraction: Bool = false,
                audioRoute: BrowserWidgetAudioRoute = .muted,
                cssOverrides: String = "",
                sceneEntryRefresh: BrowserOverlaySceneEntryRefresh = .reload) {
        self.urlString = urlString
        self.localHTMLAssetIdentifier = localHTMLAssetIdentifier
        self.targetFPS = targetFPS
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.allowsInteraction = allowsInteraction
        self.audioRoute = audioRoute
        self.cssOverrides = cssOverrides
        self.sceneEntryRefresh = sceneEntryRefresh
    }

    /// The supported cadence window. Below 1 fps a widget is a static image;
    /// above 60 the snapshot read-back dominates the render budget.
    public static let targetFPSRange = 1...60
    /// Min/max offscreen raster size, in pixels, per dimension.
    public static let pixelSizeRange = 16...3840
    /// G08: the CSS override payload bound (16 KiB of UTF-8). Widget theming
    /// never needs more; the bound keeps a pasted document from turning the
    /// scene file into an unbounded blob and the injection script small.
    public static let cssOverridesLimit = 16_384

    /// True when the configuration names something to render (a supported
    /// remote URL or a local HTML asset).
    public var hasWidgetContent: Bool {
        if localHTMLAssetIdentifier != nil { return true }
        return urlString.map(Self.isSupportedWidgetURLString) ?? false
    }

    /// Returns a copy with every field clamped into its supported range and
    /// the URL scheme validated. An unsupported scheme (anything but
    /// http/https/file, or a malformed string) clears `urlString` to nil —
    /// fail closed: the layer then renders the documented nothing fallback
    /// rather than navigating to an unexpected location. A local HTML asset
    /// set alongside a URL WINS (the URL clears) — the asset is the
    /// sandbox-safe local path. CSS overrides truncate at the byte bound.
    public func normalized() -> BrowserOverlayConfiguration {
        var copy = self
        copy.targetFPS = min(Self.targetFPSRange.upperBound,
                             max(Self.targetFPSRange.lowerBound, targetFPS))
        copy.pixelWidth = min(Self.pixelSizeRange.upperBound,
                              max(Self.pixelSizeRange.lowerBound, pixelWidth))
        copy.pixelHeight = min(Self.pixelSizeRange.upperBound,
                               max(Self.pixelSizeRange.lowerBound, pixelHeight))
        if let urlString, !Self.isSupportedWidgetURLString(urlString) {
            copy.urlString = nil
        }
        if copy.localHTMLAssetIdentifier != nil {
            copy.urlString = nil
        }
        if copy.cssOverrides.utf8.count > Self.cssOverridesLimit {
            // `decoding:as:` repairs a truncated multi-byte scalar, then back
            // off to the last complete rule terminator when one is near.
            var truncated = String(decoding: cssOverrides.utf8.prefix(Self.cssOverridesLimit),
                                   as: UTF8.self)
            while !truncated.isEmpty, !truncated.hasSuffix("}"), truncated.count > Self.cssOverridesLimit / 2 {
                truncated.removeLast()
            }
            copy.cssOverrides = truncated
        }
        return copy
    }

    /// True when `urlString` parses to a URL with a supported widget scheme.
    /// JavaScript/data schemes are rejected outright: a widget must never be
    /// an inline script payload.
    public static func isSupportedWidgetURLString(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https" || scheme == "file"
    }

    /// The resolved widget URL, post-normalization (remote widgets only —
    /// local HTML resolves through the asset library, which owns the
    /// security-scope grant).
    public var widgetURL: URL? {
        urlString.flatMap(URL.init(string:))
    }

    // MARK: - Codable (forward/backward compatible)

    /// Hand-rolled decoding so a document written by an older build (G07:
    /// no local HTML / CSS / scene-entry fields) decodes onto the current
    /// defaults instead of failing on missing keys.
    private enum CodingKeys: String, CodingKey {
        case urlString, localHTMLAssetIdentifier, targetFPS
        case pixelWidth, pixelHeight, allowsInteraction, audioRoute
        case cssOverrides, sceneEntryRefresh
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        urlString = try container.decodeIfPresent(String.self, forKey: .urlString)
        localHTMLAssetIdentifier = try container.decodeIfPresent(String.self, forKey: .localHTMLAssetIdentifier)
        targetFPS = try container.decodeIfPresent(Int.self, forKey: .targetFPS) ?? 30
        pixelWidth = try container.decodeIfPresent(Int.self, forKey: .pixelWidth) ?? 1280
        pixelHeight = try container.decodeIfPresent(Int.self, forKey: .pixelHeight) ?? 720
        allowsInteraction = try container.decodeIfPresent(Bool.self, forKey: .allowsInteraction) ?? false
        audioRoute = try container.decodeIfPresent(BrowserWidgetAudioRoute.self, forKey: .audioRoute) ?? .muted
        cssOverrides = try container.decodeIfPresent(String.self, forKey: .cssOverrides) ?? ""
        sceneEntryRefresh = try container.decodeIfPresent(BrowserOverlaySceneEntryRefresh.self,
                                                          forKey: .sceneEntryRefresh) ?? .reload
    }
}

/// G08 (issue #115): the widget's behavior when a scene containing it
/// becomes program.
public enum BrowserOverlaySceneEntryRefresh: String, Hashable, Codable, Sendable, CaseIterable {
    /// Reload the widget page on every scene entry (the default): alert
    /// boxes restart their queue/animation state instead of resuming a
    /// widget that kept running under another scene. A widget shared by the
    /// outgoing and incoming scene reloads TOO — scene entry is the signal,
    /// not demand changes (the capture itself never restarts across a Take).
    case reload
    /// Keep the page alive across scene entries: tickers, chat widgets, and
    /// anything whose value IS its accumulated session state.
    case keepAlive

    public var displayName: String {
        switch self {
        case .reload: return "Reload on Scene Entry"
        case .keepAlive: return "Keep Alive"
        }
    }
}

/// G07 (issue #114): where a browser widget's audio reaches the program mix.
/// The G07 prototype established (see the issue comment for the measurement
/// notes) what each route can and cannot promise under the app sandbox:
public enum BrowserWidgetAudioRoute: String, Hashable, Codable, Sendable, CaseIterable {
    /// Native WebKit media suspension prevents playback/resume. CSS/DOM
    /// animation continues, but video elements are also suspended. Default.
    case muted
    /// The widget runs inside the studio's own WKWebView; its audio plays
    /// from the WebKit WebContent process to the system output and reaches
    /// the program mix ONLY through the A06 system-mix app-audio capture.
    /// Constraints the G07 probe verified: the WebContent process is not an
    /// `SCRunningApplication`, so it can never be a PER-APP capture target
    /// (no independent gain/mute channel), and `excludesCurrentProcessAudio`
    /// does not exclude it (it is a child process, not the current process).
    /// Program output never double-captures: the monitor bus plays from the
    /// studio process itself, which IS excluded.
    case systemMix
    /// Reserved for the independently capturable helper route. Until its
    /// audio attribution and PCM path are verified, the native host suspends
    /// playback and reports unavailable; it never substitutes system mix.
    case helperApp

    /// Whether the route yields an independently gain/mute-controllable
    /// channel in the A01 mix engine.
    public var hasIndependentMixChannel: Bool {
        switch self {
        case .muted, .systemMix: return false
        case .helperApp: return true
        }
    }
}
