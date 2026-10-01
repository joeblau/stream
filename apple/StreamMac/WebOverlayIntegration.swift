import Foundation
import StreamCore

/// G08 (issue #115): the browser-overlay integration seam — every G08-owned
/// component (capture pool, command dispatcher, inspector section) reads and
/// writes a web layer's widget settings through THIS file, so the one change
/// G08 cannot make itself (expanding `WebSourcePayload` inside the G01-owned
/// `LayerGraph.swift`) is a single mechanical edit for the orchestrator.
///
/// ── ORCHESTRATOR HOOK 1 of 3: `WebSourcePayload` expansion ────────────────
/// In `apple/StreamMac/LayerGraph.swift`, replace the current minimal
/// `struct WebSourcePayload { var url: URL? = nil }` with:
///
/// ```swift
/// struct WebSourcePayload: Hashable, Codable, Sendable {
///     /// Remote widget URL (nil when the widget is a local HTML asset).
///     var url: URL? = nil
///     /// The full G08 widget configuration: viewport, fps, interaction,
///     /// audio route, CSS overrides, scene-entry refresh, local HTML asset.
///     /// `url` above is kept as the renderer's frame-store key source for
///     /// remote widgets; `configuration.urlString` mirrors it on write
///     /// (see `WebSourcePayload.browserOverlay` below).
///     var configuration: BrowserOverlayConfiguration = BrowserOverlayConfiguration()
///
///     private enum CodingKeys: String, CodingKey { case url, configuration }
///     init(from decoder: Decoder) throws {
///         let c = try decoder.container(keyedBy: CodingKeys.self)
///         url = try c.decodeIfPresent(URL.self, forKey: .url)
///         configuration = try c.decodeIfPresent(BrowserOverlayConfiguration.self,
///                                               forKey: .configuration)
///             ?? BrowserOverlayConfiguration(urlString: url?.absoluteString)
///     }
/// }
/// ```
///
/// Then simplify the shim below to `configuration` pass-through (the two
/// lines marked TODAY-SHIM become `get { configuration }` /
/// `set { configuration = newValue.normalized(); url = configuration.widgetURL }`).
/// LayerPayload Codable and every G08 consumer keep compiling unchanged —
/// they never touch payload fields directly, only `browserOverlay`.
///
/// ── ORCHESTRATOR HOOK 2 of 3: renderer ungating ───────────────────────────
/// In `apple/StreamMac/SceneRenderer.swift` (the G01-owned `.web` branch,
/// currently gated on `BrowserOverlayPrototypeFlag.isEnabled`), replace the
/// flag-gated guard with the production read:
///
/// ```swift
/// guard let key = web.browserOverlayStoreKey,
///       let buffer = BrowserOverlayFrameStore.shared.latest(for: key) else { return nil }
/// ```
///
/// (dropping the prototype flag and switching the key to
/// `browserOverlayStoreKey`, which covers local-HTML widgets too). The
/// documented nothing-fallback behavior is unchanged: no fresh frame paints
/// nothing.
///
/// ── ORCHESTRATOR HOOK 3 of 3: scene-entry refresh signal ──────────────────
/// In `apple/StreamMac/StreamController.swift`, `publishSceneToProgram(_:)`,
/// add one line after the engine update:
///
/// ```swift
/// capturePool.noteWebWidgetSceneEntries(program: scene)
/// ```
///
/// The pool method (implemented in CaptureSourcePool.swift, G08-owned) diffs
/// the program scene's web keys and applies each widget's
/// `sceneEntryRefresh` policy.
extension WebSourcePayload {
    /// The widget configuration this layer carries. All G08 surfaces bind
    /// through here. TODAY-SHIM (until orchestrator hook 1 lands): the
    /// persisted payload holds only `url`, so the getter derives a default
    /// configuration around it and the setter persists the URL half —
    /// viewport/fps/CSS/refresh-policy edits apply to the LIVE host (the
    /// capture pool re-reads the configuration on every demand reconcile)
    /// but do not survive a project reload until the payload expands.
    var browserOverlay: BrowserOverlayConfiguration {
        get {
            BrowserOverlayConfiguration(urlString: url?.absoluteString).normalized()
        }
        set {
            url = newValue.normalized().widgetURL
        }
    }

    /// The `BrowserOverlayFrameStore` key BOTH sides derive deterministically
    /// (no I/O, no shared state): the capture host writes under it, the
    /// renderer's `.web` branch reads under it. Remote widgets key by URL
    /// string (the G07 renderer contract, unchanged); local-HTML widgets key
    /// by asset identifier so a security-scoped re-resolution never re-keys
    /// the frame stream mid-session.
    var browserOverlayStoreKey: String? {
        // TODAY-SHIM: after orchestrator hook 1, becomes
        // `configuration.localHTMLAssetIdentifier.map { "webasset:\($0)" }
        //  ?? url?.absoluteString`.
        url?.absoluteString
    }

    /// A copy with the widget configuration normalized (fps/viewport clamped,
    /// unsupported URL schemes failed closed, CSS bounded).
    var normalizedWebPayload: WebSourcePayload {
        var copy = self
        copy.browserOverlay = browserOverlay
        return copy
    }
}

extension LayerPayload {
    /// True for browser-overlay widget layers — the dispatcher's target
    /// check for `.setLayerWeb` / `.setOverlayWeb`.
    var isWeb: Bool {
        if case .web = self { return true }
        return false
    }
}
