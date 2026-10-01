import AppKit
import CoreVideo
import os
import StreamCore
import SwiftUI
import WebKit

private let browserOverlayHostLog = Logger(subsystem: "com.joeblau.StreamMac", category: "browser-overlay-host")

/// G08 (issue #115): process-wide seam through which web widget hosts reach
/// the P03 asset library (`AssetLibraryStore`) without the pool owning the
/// store. WIRED exactly once, where the asset library is mounted.
///
/// ── ORCHESTRATOR HOOK: asset-library wiring ───────────────────────────────
/// P03's store is not yet mounted in the app (see `AssetLibraryPanelView`'s
/// header: "create one @StateObject AssetLibraryStore() in StreamMacApp").
/// Wherever it lands (StreamMacApp / dispatcher), add:
///
/// ```swift
/// BrowserOverlayAssetResolver.access = { rawID in
///     guard let uuid = UUID(uuidString: rawID) else { return nil }
///     return assetLibrary.access(for: AssetID(uuid))
/// }
/// BrowserOverlayAssetResolver.noteUsage = { rawID, site in
///     guard let uuid = UUID(uuidString: rawID) else { return }
///     assetLibrary.noteUsage(of: AssetID(uuid), from: site)
/// }
/// ```
///
/// Until wired, a local-HTML widget host reports a clear failure state
/// (`assetLibraryUnavailable`) instead of silently rendering nothing — URL
/// widgets and bundled fixtures are unaffected. MainActor-isolated: the host
/// and the wiring site both run on the main actor.
@MainActor
enum BrowserOverlayAssetResolver {
    /// Maps a persisted asset identifier to a scoped, readable URL. The
    /// returned token holds the security-scope grant; the host retains it for
    /// the widget's lifetime so subresource loads keep their access.
    static var access: (@MainActor (String) -> ResolvedAssetAccess?)?
    /// Records a usage site ("Used by" list) for a widget's local HTML asset.
    static var noteUsage: (@MainActor (String, String) -> Void)?
}

/// G08: the per-widget lifecycle state the inspector badges. Mirrors the
/// pool's capture-state semantics: `ready` = frames flowing, `failed` =
/// terminal navigation/asset error (demand survives; the renderer paints
/// the documented nothing fallback), `loading` = navigation in flight.
enum BrowserOverlayLoadState: Equatable, Sendable {
    case idle
    case loading
    case ready
    case failed(String)

    /// Short badge label for the inspector.
    var badge: String {
        switch self {
        case .idle: return "Off"
        case .loading: return "Loading…"
        case .ready: return "Live"
        case .failed: return "Error"
        }
    }

    var failureMessage: String? {
        guard case .failed(let message) = self else { return nil }
        return message
    }
}

/// The webview the overlay hosts. Hit-testing is an explicit, per-widget
/// opt-in (`allowsInteraction`): a click-through overlay hit-tests to
/// NOTHING (studio input below the layer is never swallowed); a deliberate-
/// interaction widget hit-tests normally while its hosting window is in
/// interaction mode.
private final class BrowserWidgetWebView: WKWebView {
    var allowsHitTesting = false
    override func hitTest(_ point: NSPoint) -> NSView? {
        allowsHitTesting ? super.hitTest(point) : nil
    }
}

/// The hidden-but-unoccluded hosting window one widget lives in. WebKit
/// throttles OCCLUDED windows (the G07 finding), so "offscreen" means
/// invisible, not absent: the window is ordered in at near-zero alpha on a
/// high window level (so studio windows can't occlude it) with mouse events
/// ignored. `sharingType = .none` keeps the widget OUT of the studio's own
/// display captures — a screen source capturing the display never loops the
/// overlay back into itself.
private final class WebOverlayHostingWindow: NSWindow {
    init(pixelSize: CGSize) {
        super.init(contentRect: NSRect(origin: .zero, size: pixelSize),
                   styleMask: [.borderless],
                   backing: .buffered,
                   defer: true)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        sharingType = .none
        collectionBehavior = [.canJoinAllSpaces, .stationary]
        level = .statusBar
        title = "Stream Browser Widget"
        if let screen = NSScreen.main {
            setFrameOrigin(NSPoint(x: screen.frame.minX, y: screen.frame.minY))
        }
    }

    /// Hidden capture mode: invisible, click-through, occlusion-proof.
    func enterHiddenMode() {
        alphaValue = 0.01
        ignoresMouseEvents = true
        styleMask = [.borderless]
        orderFrontRegardless()
    }

    /// Deliberate interaction mode: the widget surfaces as a real floating
    /// panel the operator can click/dismiss content in. Still excluded from
    /// display captures (`sharingType` never changes).
    func enterInteractionMode() {
        alphaValue = 1
        ignoresMouseEvents = false
        styleMask = [.titled, .resizable]
        orderFrontRegardless()
    }

    override var canBecomeKey: Bool { !ignoresMouseEvents }
    override var canBecomeMain: Bool { false }
}

// MARK: - Production widget host

/// G08 (issue #115): the production browser-overlay capture host — one
/// instance per demanded web source, owned by `CaptureSourcePool`.
///
/// Evolves the G07 prototype into the supported in-app path: the webview
/// loads the widget (remote URL, bundled fixture, or a P03 local-HTML asset)
/// with a transparent page background in a hidden-but-unoccluded window, and
/// a bounded snapshot clock (`takeSnapshot`, in-flight cap 2, latest-wins
/// `BrowserOverlayFrameStore`) feeds the renderer's `.web` branch. The
/// composition tick is never gated on WebKit: a stalled widget keeps its
/// last frame until the store's freshness window lapses, then paints the
/// documented nothing fallback.
///
/// Bounded capture (acceptance): the fps target is clamped to
/// `BrowserOverlayConfiguration.targetFPSRange` (1–60; 60 is the documented
/// DOM-light ceiling) and snapshot requests shed at the in-flight cap rather
/// than queueing on the WebContent process.
///
/// Loading/error state (acceptance): `loadState` runs
/// idle → loading → ready / failed(message), with a navigation timeout, a
/// fail-closed scheme check on every main-frame navigation, and asset-
/// resolution errors for local HTML.
///
/// Audio (G07 decision, unchanged): `.muted` (default) blocks audio autoplay
/// AND force-mutes media elements in-page — the audio-widget fixture's
/// `window.__widgetAudioState` reads `suspended`/`running` as the evidence
/// hook. `.systemMix` lets the WebContent process play to the system output
/// (A06 system-mix captures it; no independent channel). `.helperApp` is the
/// only independent-gain route and the helper target is NOT implemented in
/// G08 (follow-up: a small `StreamWidgetHelper` app target in project.yml
/// hosting one WKWebView, captured via the existing A06 per-app path);
/// until it ships the host runs helper-routed widgets with systemMix
/// behavior and publishes `routeWarning`.
@MainActor
final class BrowserOverlayHost: NSObject, ObservableObject {
    /// The frame-store key this host publishes under — fixed at creation,
    /// derived from the payload (`WebSourcePayload.browserOverlayStoreKey`),
    /// so the renderer's read key never needs I/O.
    let storeKey: String
    /// The normalized configuration this host runs. Re-keyed by the pool on
    /// any payload edit (the C03 deliberate re-key pattern), so a host never
    /// mutates its configuration mid-run.
    let configuration: BrowserOverlayConfiguration

    @Published private(set) var loadState: BrowserOverlayLoadState = .idle
    @Published private(set) var metrics = BrowserOverlayMetrics()
    /// True while the hosting window is occluded and WebKit is throttling —
    /// surfaced in the inspector so a stalled widget has a visible cause.
    @Published private(set) var isOccluded = false
    /// Non-nil when the configured audio route can't be fully honored
    /// (helperApp without the helper target).
    @Published private(set) var routeWarning: String?

    /// The hosted webview — the inspector embeds it for deliberate
    /// interaction mode; nothing else touches it.
    private let webView: BrowserWidgetWebView
    private let window: WebOverlayHostingWindow
    /// The P03 access token holding the local HTML asset's security-scope
    /// grant for the widget's lifetime (nil for remote widgets).
    private var assetAccess: ResolvedAssetAccess?
    private var snapshotTimer: Timer?
    private var navigationTimeout: Timer?
    private var pixelBufferPool: CVPixelBufferPool?
    private var completions: [CFAbsoluteTime] = []
    private var totalLatencyMs = 0.0
    private var inFlight = 0
    private var occlusionObserver: NSObjectProtocol?
    private let signposter = OSSignposter(subsystem: "com.joeblau.StreamMac",
                                          category: "browser-overlay")

    /// Navigation is given this long before the widget is declared failed —
    /// a hung remote widget must never sit in "loading" forever.
    private static let navigationTimeoutSeconds: TimeInterval = 30
    /// In-flight snapshot cap (the G07 measurement): beyond it, requests
    /// shed and the store keeps the freshest completed frame.
    private static let maxInFlightSnapshots = 2

    /// `configuration` is normalized by the caller (the payload shim); the
    /// store key must be the payload's `browserOverlayStoreKey`.
    init(configuration: BrowserOverlayConfiguration, storeKey: String) {
        self.configuration = configuration
        self.storeKey = storeKey

        let webConfiguration = WKWebViewConfiguration()
        // Audio policy at construction: muted widgets require a gesture for
        // ALL media (media elements stay silent and WebAudio contexts stay
        // suspended — the audio-widget fixture reads "suspended"); audible
        // routes let widget media autoplay.
        webConfiguration.mediaTypesRequiringUserActionForPlayback =
            configuration.audioRoute == .muted ? .all : []
        webView = BrowserWidgetWebView(
            frame: CGRect(origin: .zero,
                          size: CGSize(width: CGFloat(configuration.pixelWidth),
                                       height: CGFloat(configuration.pixelHeight))),
            configuration: webConfiguration)
        webView.underPageBackgroundColor = .clear
        // The backing-store alpha switch (macOS 14 verified in G07).
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsHitTesting = configuration.allowsInteraction

        window = WebOverlayHostingWindow(pixelSize: CGSize(width: CGFloat(configuration.pixelWidth),
                                                           height: CGFloat(configuration.pixelHeight)))
        window.contentView = webView
        super.init()
        webView.navigationDelegate = self

        routeWarning = configuration.audioRoute == .helperApp
            ? "Independent helper-app audio needs the StreamWidgetHelper target (G08 follow-up) — this widget plays through the system mix for now."
            : nil

        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: window,
            queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isOccluded = !self.window.occlusionState.contains(.visible)
                    if self.isOccluded {
                        // Re-assert visibility: a window manager shuffle can
                        // transiently occlude the hidden window, and WebKit
                        // throttles occluded pages.
                        self.window.orderFrontRegardless()
                    }
                }
            }
    }

    // MARK: - Lifecycle

    /// Loads the content and starts the bounded snapshot clock.
    func start() {
        stopCaptureClock()
        BrowserOverlayFrameStore.shared.clear(storeKey)
        metrics = BrowserOverlayMetrics(startedAt: Date())
        completions = []
        totalLatencyMs = 0
        inFlight = 0

        if configuration.allowsInteraction {
            window.enterInteractionMode()
        } else {
            window.enterHiddenMode()
        }

        if let assetID = configuration.localHTMLAssetIdentifier {
            loadLocalHTMLAsset(assetID)
        } else if let url = configuration.widgetURL {
            loadState = .loading
            armNavigationTimeout()
            webView.load(URLRequest(url: url))
        } else {
            loadState = .failed("No widget configured — set a URL or pick a local HTML asset.")
        }
        browserOverlayHostLog.info("Browser overlay host started (\(self.storeKey, privacy: .public) @ \(self.configuration.targetFPS) fps target)")
    }

    /// Halts capture and clears the frame store (last demand reference
    /// removed). The instance — window, webview, remembered page — survives,
    /// so a re-demanded widget restarts without rebuilding anything.
    func stop() {
        stopCaptureClock()
        navigationTimeout?.invalidate()
        navigationTimeout = nil
        BrowserOverlayFrameStore.shared.clear(storeKey)
        loadState = .idle
    }

    /// Full teardown (pool stopAll / source removal): closes the hosting
    /// window and releases the asset's security-scope grant.
    func dispose() {
        stop()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        window.close()
        assetAccess = nil
    }

    /// Halts the snapshot clock without clearing the frame store — the
    /// missing/hot-plug pattern (the renderer keeps the last frame until the
    /// freshness window lapses).
    func stopCaptureClock() {
        snapshotTimer?.invalidate()
        snapshotTimer = nil
    }

    /// Explicit reload (the inspector's Reload button): a fresh navigation,
    /// `reloadFromOrigin` for remote widgets so stale caches can't pin an
    /// old widget build.
    func reload() {
        guard loadState != .idle else { return }
        if configuration.localHTMLAssetIdentifier != nil {
            assetAccess = nil
            start()
        } else {
            loadState = .loading
            armNavigationTimeout()
            webView.reloadFromOrigin()
        }
    }

    /// The pool's scene-entry signal (StreamController hook): applies the
    /// widget's `sceneEntryRefresh` policy.
    func noteSceneEntry() {
        guard configuration.sceneEntryRefresh == .reload, loadState != .idle else { return }
        reload()
    }

    // MARK: - Programmatic interaction

    /// Evaluates a JavaScript expression in the widget page — the trigger
    /// channel a click-through overlay keeps (alert replays, config pushes).
    /// Returns the string value, if any.
    func evaluateTrigger(_ expression: String) async -> String? {
        let result = try? await webView.evaluateJavaScript(expression)
        return (result as? String) ?? result.map { String(describing: $0) }
    }

    /// The canned test trigger for the acceptance fixtures: restarts CSS
    /// animations (alert pop-ins replay) and reports the audio-widget state
    /// probe, so one button exercises the programmatic channel on every
    /// bundled fixture.
    func replayAlertAnimation() async -> String? {
        await evaluateTrigger("""
        (function() {
            document.querySelectorAll('*').forEach(function(e) {
                var a = getComputedStyle(e).animationName;
                if (a && a !== 'none') {
                    e.style.animation = 'none';
                    void e.offsetWidth;
                    e.style.animation = '';
                }
            });
            return window.__widgetAudioState || 'replayed';
        })();
        """)
    }

    // MARK: - Content loading

    private func loadLocalHTMLAsset(_ rawID: String) {
        guard let access = BrowserOverlayAssetResolver.access?(rawID) else {
            loadState = .failed(BrowserOverlayAssetResolver.access == nil
                ? "The asset library isn't available in this build."
                : "The local HTML asset can't be resolved — relink it in the Asset Library.")
            return
        }
        assetAccess = access
        BrowserOverlayAssetResolver.noteUsage?(rawID, "webOverlay/\(storeKey)")
        loadState = .loading
        armNavigationTimeout()
        webView.loadFileURL(access.url,
                            allowingReadAccessTo: access.url.deletingLastPathComponent())
    }

    // MARK: - Snapshot loop (bounded capture)

    private func startCaptureClock() {
        stopCaptureClock()
        let interval = 1 / Double(configuration.targetFPS)
        snapshotTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.snapshotTick() }
        }
    }

    private func snapshotTick() {
        guard inFlight < Self.maxInFlightSnapshots else {
            metrics.dropped += 1
            return
        }
        let state = signposter.beginInterval("snapshot")
        let requestedAt = CFAbsoluteTimeGetCurrent()
        metrics.requested += 1
        inFlight += 1
        webView.takeSnapshot(with: nil) { [weak self] image, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.inFlight -= 1
                self.signposter.endInterval("snapshot", state)
                let latency = (CFAbsoluteTimeGetCurrent() - requestedAt) * 1000
                guard let image,
                      let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                      let buffer = self.renderToPixelBuffer(cgImage) else {
                    self.metrics.failed += 1
                    if let error { browserOverlayHostLog.warning("widget snapshot failed: \(error.localizedDescription, privacy: .public)") }
                    return
                }
                self.metrics.succeeded += 1
                self.metrics.lastLatencyMs = latency
                self.totalLatencyMs += latency
                self.metrics.averageLatencyMs = self.totalLatencyMs / Double(self.metrics.succeeded)
                let now = CFAbsoluteTimeGetCurrent()
                self.completions.append(now)
                self.completions.removeAll { now - $0 > 2 }
                self.metrics.achievedFPS = Double(self.completions.count) / 2
                BrowserOverlayFrameStore.shared.store(buffer, for: self.storeKey)
            }
        }
    }

    /// Converts one snapshot into a pooled BGRA buffer (premultiplied alpha
    /// preserved — the renderer composites it like any source). Identical to
    /// the G07 prototype's measured path.
    private func renderToPixelBuffer(_ cgImage: CGImage) -> CVPixelBuffer? {
        let width = configuration.pixelWidth
        let height = configuration.pixelHeight
        if pixelBufferPool == nil {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
                kCVPixelBufferBytesPerRowAlignmentKey as String: 64
            ]
            var pool: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil,
                                          attributes as CFDictionary, &pool) == kCVReturnSuccess,
                  let pool else { return nil }
            pixelBufferPool = pool
        }
        guard let pool = pixelBufferPool else { return nil }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let context = CGContext(data: base,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                              | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    // MARK: - Injected scripts (CSS overrides, in-page mute)

    /// Re-applies the page-level injections after every navigation: the CSS
    /// override `<style>` element and, for the muted route, the force-mute
    /// script (belt-and-braces on top of the autoplay policy — a widget that
    /// un-mutes its own elements gets re-muted on every DOM change).
    private func applyPageInjections() {
        let css = configuration.cssOverrides
        if !css.isEmpty, let data = try? JSONEncoder().encode(css),
           let literal = String(data: data, encoding: .utf8) {
            webView.evaluateJavaScript("""
            (function() {
                var old = document.getElementById('__streamCSSOverrides');
                if (old) old.remove();
                var style = document.createElement('style');
                style.id = '__streamCSSOverrides';
                style.textContent = \(literal);
                (document.head || document.documentElement).appendChild(style);
            })();
            """) { _, _ in }
        }
        if configuration.audioRoute == .muted {
            webView.evaluateJavaScript("""
            (function() {
                function muteAll() {
                    document.querySelectorAll('audio,video').forEach(function(m) {
                        m.muted = true; m.volume = 0;
                    });
                }
                muteAll();
                if (!window.__streamMuteObserver) {
                    window.__streamMuteObserver = new MutationObserver(muteAll);
                    window.__streamMuteObserver.observe(document.documentElement,
                        { childList: true, subtree: true });
                }
            })();
            """) { _, _ in }
        }
    }

    // MARK: - Navigation timeout

    private func armNavigationTimeout() {
        navigationTimeout?.invalidate()
        navigationTimeout = Timer.scheduledTimer(
            withTimeInterval: Self.navigationTimeoutSeconds,
            repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.loadState == .loading else { return }
                    self.loadState = .failed("The widget didn't finish loading within \(Int(Self.navigationTimeoutSeconds)) s.")
                }
            }
    }
}

// MARK: - WKNavigationDelegate (loading/error state)

extension BrowserOverlayHost: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView,
                             decidePolicyFor navigationAction: WKNavigationAction,
                             decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        let urlString = navigationAction.request.url?.absoluteString ?? ""
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? false
        Task { @MainActor in
            // Fail closed on the main frame: a widget page must never
            // navigate the overlay to a javascript:/data: payload.
            if isMainFrame, !urlString.isEmpty, urlString != "about:blank",
               !BrowserOverlayConfiguration.isSupportedWidgetURLString(urlString) {
                self.loadState = .failed("Blocked navigation to an unsupported scheme.")
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            self.navigationTimeout?.invalidate()
            self.navigationTimeout = nil
            self.applyPageInjections()
            self.loadState = .ready
            // The snapshot clock runs only while the page is alive — a failed
            // or unconfigured widget captures nothing.
            self.startCaptureClock()
        }
    }

    nonisolated func webView(_ webView: WKWebView,
                             didFailProvisionalNavigation navigation: WKNavigation!,
                             withError error: Error) {
        Task { @MainActor in
            self.navigationTimeout?.invalidate()
            self.loadState = .failed(error.localizedDescription)
        }
    }

    nonisolated func webView(_ webView: WKWebView,
                             didFail navigation: WKNavigation!,
                             withError error: Error) {
        Task { @MainActor in
            self.navigationTimeout?.invalidate()
            self.loadState = .failed(error.localizedDescription)
        }
    }
}

// MARK: - Acceptance fixtures

extension BrowserOverlayHost {
    /// The bundled acceptance fixtures (G07's set, reused): alert-follow,
    /// alert-glow, ticker, audio-widget. Each maps to a ready-to-apply widget
    /// configuration pointing at the bundle's copy — the inspector's test
    /// buttons write these straight onto the selected layer.
    static let acceptanceFixtures = ["alert-follow", "alert-glow", "ticker", "audio-widget"]

    /// The widget configuration loading one bundled fixture, or nil when the
    /// fixture isn't in the bundle.
    static func fixtureConfiguration(name: String,
                                     bundle: Bundle = .main) -> BrowserOverlayConfiguration? {
        guard let url = bundle.url(forResource: name, withExtension: "html",
                                   subdirectory: "BrowserFixtures")
                ?? bundle.url(forResource: name, withExtension: "html")
        else { return nil }
        return BrowserOverlayConfiguration(urlString: url.absoluteString).normalized()
    }
}
