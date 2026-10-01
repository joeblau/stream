import Foundation

/// G07 (issue #114): the persisted configuration model for a browser-overlay
/// widget source — the Streamlabs/StreamElements-style HTML widget a
/// `WebSourcePayload` layer renders through the WKWebView prototype seam
/// (`BrowserOverlayPrototype` in the StreamMac app target).
///
/// This type is deliberately pure value logic in StreamCore (no WebKit): the
/// prototype, its measurement harness, and the eventual G08 implementation
/// share one normalization/validation contract, and StreamCoreTests pins it.
/// Rendering decisions the G07 measurements gate are documented here as
/// capability notes so the UI can never promise what the prototype disproved.
public struct BrowserOverlayConfiguration: Hashable, Codable, Sendable {
    /// Widget location. `nil` = no widget configured (renders nothing).
    public var urlString: String?
    /// Snapshot-capture cadence the producer aims for. Clamped to
    /// `Self.targetFPSRange` — the G07 measurements show CPU cost scales
    /// linearly with this value, so 60 fps is the documented ceiling, not a
    /// promise of hardware-efficient live textures.
    public var targetFPS: Int
    /// Offscreen web-view pixel size the widget rasterizes at.
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// Overlay widgets are click-through by default (the layer above the
    /// program output must never swallow studio input); interaction arrives
    /// programmatically via `evaluateJavaScript` alert triggers.
    public var allowsInteraction: Bool
    /// Where the widget's audio enters the program mix.
    public var audioRoute: BrowserWidgetAudioRoute

    public init(urlString: String? = nil,
                targetFPS: Int = 30,
                pixelWidth: Int = 1280,
                pixelHeight: Int = 720,
                allowsInteraction: Bool = false,
                audioRoute: BrowserWidgetAudioRoute = .muted) {
        self.urlString = urlString
        self.targetFPS = targetFPS
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.allowsInteraction = allowsInteraction
        self.audioRoute = audioRoute
    }

    /// The supported cadence window. Below 1 fps a widget is a static image;
    /// above 60 the snapshot read-back dominates the render budget.
    public static let targetFPSRange = 1...60
    /// Min/max offscreen raster size, in pixels, per dimension.
    public static let pixelSizeRange = 16...3840

    /// Returns a copy with every field clamped into its supported range and
    /// the URL scheme validated. An unsupported scheme (anything but
    /// http/https/file, or a malformed string) clears `urlString` to nil —
    /// fail closed: the layer then renders the documented nothing fallback
    /// rather than navigating to an unexpected location.
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

    /// The resolved widget URL, post-normalization.
    public var widgetURL: URL? {
        urlString.flatMap(URL.init(string:))
    }
}

/// G07 (issue #114): where a browser widget's audio reaches the program mix.
/// The G07 prototype established (see the issue comment for the measurement
/// notes) what each route can and cannot promise under the app sandbox:
public enum BrowserWidgetAudioRoute: String, Hashable, Codable, Sendable, CaseIterable {
    /// Widget media never plays sound. The default, and the only mode with
    /// zero capture risk — alert widgets that ship their own audio are muted
    /// in-page, so nothing reaches the system output or any capture.
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
    /// The widget runs in a dedicated helper app with its own bundle ID, so
    /// the existing A06 per-app ScreenCaptureKit path captures exactly its
    /// audio with an independent mixer channel — and the A06 system mix
    /// already excludes every app carrying its own per-app source, so
    /// helper + system mix can never double up. This is the route G08 is
    /// gated on for widgets with independent audio control.
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
