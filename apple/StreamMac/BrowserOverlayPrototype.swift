import AppKit
import CoreAudio
import CoreVideo
import os
import os.lock
import ScreenCaptureKit
import SwiftUI
import WebKit

private let browserOverlayLog = Logger(subsystem: "com.joeblau.StreamMac", category: "browser-overlay-prototype")

// MARK: - Prototype gate

/// G07 (issue #114): the explicit opt-in flag for the browser-overlay
/// prototype seam. NOTHING in the studio enables this: set the
/// `prototype.browserOverlay.enabled` default (or pass
/// `-prototype.browserOverlay.enabled YES` on launch) to make the
/// `SceneRenderer` `.web` branch consult `BrowserOverlayFrameStore`.
/// When disabled — the shipping state — `.web` layers render exactly the
/// documented nothing fallback they always have.
///
/// G08 (issue #115) NOTE: the production path is `BrowserOverlayHost`
/// (capture-pool-driven per demanded web payload); this flag still gates the
/// renderer branch until orchestrator hook 2 in `WebOverlayIntegration.swift`
/// replaces the guard with the unconditional `browserOverlayStoreKey` read.
enum BrowserOverlayPrototypeFlag {
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "prototype.browserOverlay.enabled")
    }
}

// MARK: - Frame store (renderer seam)

/// The prototype half of the C01 read path: one lock-protected latest-frame
/// holder per widget, keyed by the widget URL string a `.web` payload
/// carries. Mirrors `LatestScreenFrame` / `ProjectOverlayStore`: the producer
/// (`BrowserOverlayPrototype`, main actor, its own snapshot clock) stores;
/// the `SceneRenderer` (engine actor, render tick) pulls the LATEST frame —
/// the composition cadence is never gated on the webview, and a stalled
/// widget simply keeps its last frame until the freshness window lapses.
final class BrowserOverlayFrameStore: @unchecked Sendable {
    static let shared = BrowserOverlayFrameStore()

    private struct Entry {
        var buffer: CVPixelBuffer
        var storedAt: CFAbsoluteTime
    }

    private var lock = os_unfair_lock_s()
    private var frames: [String: Entry] = [:]

    /// Frames older than this are treated as stale (widget stopped producing)
    /// and the layer falls back to painting nothing.
    static let freshnessWindow: CFAbsoluteTime = 2.0

    func store(_ buffer: CVPixelBuffer, for key: String) {
        os_unfair_lock_lock(&lock)
        frames[key] = Entry(buffer: buffer, storedAt: CFAbsoluteTimeGetCurrent())
        os_unfair_lock_unlock(&lock)
    }

    func latest(for key: String) -> CVPixelBuffer? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard let entry = frames[key],
              CFAbsoluteTimeGetCurrent() - entry.storedAt < Self.freshnessWindow else { return nil }
        return entry.buffer
    }

    func clear(_ key: String) {
        os_unfair_lock_lock(&lock)
        frames[key] = nil
        os_unfair_lock_unlock(&lock)
    }
}

// MARK: - Metrics

/// One frame-capture run's counters. `achievedFPS` is the MEASURED snapshot
/// completion rate over the trailing window — never the timer's request rate
/// (the request rate is what you asked for; this is what WebKit delivered).
struct BrowserOverlayMetrics: Sendable {
    var requested = 0
    var succeeded = 0
    var failed = 0
    /// Requests shed because the WebContent snapshot queue was already at the
    /// in-flight cap — the direct measure of WebKit not keeping up with the
    /// requested cadence.
    var dropped = 0
    /// Wall time of the last `takeSnapshot` round trip, milliseconds.
    var lastLatencyMs = 0.0
    /// Mean round-trip latency of all completed snapshots, milliseconds.
    var averageLatencyMs = 0.0
    /// Measured completions per second over the trailing 2 s window.
    var achievedFPS = 0.0
    var startedAt: Date?

    var droppedRatio: Double {
        requested + dropped == 0 ? 0 : Double(dropped) / Double(requested + dropped)
    }
}

/// Result of sampling a snapshot at fixed probe points — the alpha-correctness
/// evidence for transparent widget compositing.
struct BrowserOverlayAlphaReport: Sendable {
    struct Probe: Sendable {
        /// Normalized 0...1 sample location (top-left origin).
        var x: Double
        var y: Double
        var label: String
        /// Measured alpha 0...1 at that point.
        var alpha: Double
        var red: Double
        var green: Double
        var blue: Double
    }

    var probes: [Probe] = []

    /// Fully transparent where the fixture says the page background shows.
    var transparentRegionsClear: Bool {
        probes.filter { $0.label.hasPrefix("transparent") }.allSatisfy { $0.alpha < 0.02 }
    }

    /// Semi/opaque widget pixels carry a nonzero alpha channel (not flattened
    /// to black, not forced opaque).
    var widgetRegionsPreserveAlpha: Bool {
        probes.filter { $0.label.hasPrefix("widget") }.allSatisfy { $0.alpha > 0.5 }
    }
}

// MARK: - Prototype host

/// G07 (issue #114) EXPERIMENTAL PROTOTYPE — not wired into the studio UI.
///
/// G08 (issue #115) NOTE: the production runtime is `BrowserOverlayHost`
/// (per-widget lifecycle, load/error state, CSS overrides, deliberate
/// interaction mode, in-page mute) driven by `CaptureSourcePool`. This
/// prototype remains the measurement harness's entry point
/// (`scripts/run_g07_browser_overlay_harness.zsh` compiles this file
/// standalone) and owns the shared renderer seam (`BrowserOverlayFrameStore`,
/// `BrowserOverlayMetrics`) the production host publishes into.
///
/// Hosts one WKWebView as a browser-overlay frame source: the webview loads a
/// bundled fixture or widget URL with a transparent page background, and a
/// timer-driven `takeSnapshot` loop converts each snapshot into a pooled BGRA
/// `CVPixelBuffer` published to `BrowserOverlayFrameStore` — the seam the
/// (flag-gated) `SceneRenderer` `.web` branch pulls from, exactly like the
/// pool's latest-screen-frame holders.
///
/// **Transparency on the macOS 14 deployment target.** Verified against the
/// G07 fixtures: `underPageBackgroundColor = .clear` (macOS 12+) makes the
/// page's own backdrop transparent, and the long-standing `drawsBackground`
/// KVC toggle (still the only switch that keeps the webview's backing store
/// alpha) keeps transparent body regions at alpha 0 in snapshots. There is
/// NO public API for a hardware-efficient live texture of WKWebView content —
/// `takeSnapshot` is a CPU-readback bitmap per frame — which is exactly the
/// cost this prototype measures.
///
/// **Instrumentation.** Counters on `metrics` (published for the debug view),
/// plus `OSSignposter` intervals (`browser-overlay` / `snapshot`) so an
/// Instruments os_signpost run can attribute the render-thread cost per frame.
/// A WKWebView that never hit-tests: overlay widgets are click-through by
/// construction (macOS WKWebView has no `isUserInteractionEnabled` — that is
/// the iOS spelling). Programmatic interaction via `evaluateJavaScript` is
/// unaffected.
private final class ClickThroughWebView: WKWebView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
final class BrowserOverlayPrototype: ObservableObject {
    /// What the webview renders: a bundled fixture or a remote/local URL.
    enum Content {
        case fixture(name: String)
        case url(URL)

        /// The frame-store key the renderer's `.web` branch looks up. Fixture
        /// content keys itself `fixture:<name>`; URL content keys itself by
        /// the URL string — the same key a `WebSourcePayload` layer derives.
        var storeKey: String {
            switch self {
            case .fixture(let name): return "fixture:\(name)"
            case .url(let url): return url.absoluteString
            }
        }
    }

    let content: Content
    let targetFPS: Int
    let pixelSize: CGSize

    /// The hosted webview. The debug view (or measurement harness) places it
    /// in a window at `pixelSize` — WKWebView renders unreliably without a
    /// window, so "offscreen" means a window the user never sees, not no
    /// window at all.
    let webView: WKWebView

    @Published private(set) var metrics = BrowserOverlayMetrics()
    @Published private(set) var lastError: String?

    private var snapshotTimer: Timer?
    private var pixelBufferPool: CVPixelBufferPool?
    /// Trailing completion timestamps for the measured-fps window.
    private var completions: [CFAbsoluteTime] = []
    private var totalLatencyMs = 0.0
    /// Snapshots requested but not yet answered — takeSnapshot coalesces or
    /// drops under load, and the gap between requested and succeeded+failed is
    /// the direct evidence of that.
    private var inFlight = 0
    private let signposter = OSSignposter(subsystem: "com.joeblau.StreamMac",
                                          category: "browser-overlay")

    init(content: Content, targetFPS: Int = 30, pixelSize: CGSize = CGSize(width: 1280, height: 720)) {
        self.content = content
        self.targetFPS = max(1, min(60, targetFPS))
        self.pixelSize = pixelSize

        let configuration = WKWebViewConfiguration()
        // Widgets play their own media without a gesture (alert sounds); the
        // audio routing story is the probe's subject, not the page's problem.
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let webView = ClickThroughWebView(frame: CGRect(origin: .zero, size: pixelSize),
                                          configuration: configuration)
        // Transparency (macOS 14 verified): clear page backdrop + the
        // drawsBackground backing-store switch. Overlay widgets are
        // click-through by construction (the webview hit-tests to nothing) —
        // interaction is programmatic (evaluateJavaScript alert triggers),
        // never mouse hit-testing.
        webView.underPageBackgroundColor = .clear
        webView.setValue(false, forKey: "drawsBackground")
        self.webView = webView
    }

    /// Loads the content and starts the snapshot clock.
    func start() {
        stop()
        switch content {
        case .fixture(let name):
            guard let url = BrowserOverlayPrototype.fixtureURL(name: name) else {
                lastError = "Fixture \(name).html is not in BrowserFixtures."
                return
            }
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        case .url(let url):
            webView.load(URLRequest(url: url))
        }
        metrics = BrowserOverlayMetrics(startedAt: Date())
        completions = []
        totalLatencyMs = 0
        inFlight = 0
        snapshotTimer = Timer.scheduledTimer(withTimeInterval: 1 / Double(targetFPS),
                                             repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.snapshotTick() }
        }
        browserOverlayLog.info("Browser overlay prototype started (\(self.content.storeKey, privacy: .public) @ \(self.targetFPS) fps target)")
    }

    func stop() {
        snapshotTimer?.invalidate()
        snapshotTimer = nil
        BrowserOverlayFrameStore.shared.clear(content.storeKey)
    }

    /// Halts the snapshot clock without clearing the frame store — the
    /// harness's alpha-correctness phase pauses the capture flood so probe
    /// snapshots don't queue behind the measurement backlog (alpha verdicts
    /// must measure the page, not queue pressure).
    func pauseCapture() {
        snapshotTimer?.invalidate()
        snapshotTimer = nil
    }

    /// The bundled-fixture lookup, shared by the app and the harness.
    nonisolated static func fixtureURL(name: String, bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: name, withExtension: "html", subdirectory: "BrowserFixtures")
            ?? bundle.url(forResource: name, withExtension: "html")
    }

    // MARK: - Snapshot loop

    /// In-flight cap: takeSnapshot queues on the WebContent process, and an
    /// unbounded request rate builds a backlog thousands deep (measured in
    /// the G07 harness) that turns every later snapshot into minutes of
    /// queueing delay. Latest-wins like every other source: when the webview
    /// can't keep up, REQUESTS drop — the store keeps the freshest completed
    /// frame and the composition tick is never gated on WebKit.
    private static let maxInFlightSnapshots = 2

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
                    self.lastError = error?.localizedDescription ?? "snapshot decode failed"
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
                BrowserOverlayFrameStore.shared.store(buffer, for: self.content.storeKey)
            }
        }
    }

    /// Converts one snapshot into a pooled BGRA buffer (premultiplied alpha
    /// preserved — the renderer composites it like any source). The pool is
    /// created lazily at the webview's pixel size.
    private func renderToPixelBuffer(_ cgImage: CGImage) -> CVPixelBuffer? {
        let width = Int(pixelSize.width)
        let height = Int(pixelSize.height)
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
        // Clear to zero alpha first: pixels the draw leaves untouched must be
        // transparent, never stale pool garbage.
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    // MARK: - Measurement entry points (debug view + harness)

    /// Takes one fresh snapshot and samples fixed probe points for the
    /// alpha-correctness report. Probe geometry is valid for ALL G07 fixtures:
    /// the corners and left edge are page background in every fixture (the
    /// alert cards are centered, the glow halo's spinning reach stops ~340 px
    /// from the corners, the ticker bar covers only the bottom 60 px), and
    /// the widget probe sits at canvas center.
    func measureAlpha() async -> BrowserOverlayAlphaReport {
        guard let cgImage = await freshSnapshotCGImage(),
              let data = cgImage.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else {
            return BrowserOverlayAlphaReport()
        }
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = cgImage.bytesPerRow
        let points: [(Double, Double, String)] = [
            (0.02, 0.02, "transparent.top-left"),
            (0.98, 0.02, "transparent.top-right"),
            (0.02, 0.90, "transparent.bottom-left"),
            (0.02, 0.50, "transparent.mid-left"),
            (0.50, 0.50, "widget.center")
        ]
        var report = BrowserOverlayAlphaReport()
        for (fx, fy, label) in points {
            let x = min(width - 1, max(0, Int(fx * Double(width))))
            let y = min(height - 1, max(0, Int(fy * Double(height))))
            let offset = y * bytesPerRow + x * 4
            // CGImage from NSImage is RGBA-premultiplied on this path.
            let alpha = Double(bytes[offset + 3]) / 255
            report.probes.append(.init(x: fx, y: fy, label: label,
                                       alpha: alpha,
                                       red: Double(bytes[offset]) / 255,
                                       green: Double(bytes[offset + 1]) / 255,
                                       blue: Double(bytes[offset + 2]) / 255))
        }
        return report
    }

    /// Round-trip latency of `evaluateJavaScript` — the programmatic
    /// interaction channel a click-through overlay keeps (alert triggers,
    /// config pushes). Returns milliseconds, one sample per iteration.
    func measureJavaScriptLatency(iterations: Int) async -> [Double] {
        var samples: [Double] = []
        for _ in 0..<iterations {
            let start = CFAbsoluteTimeGetCurrent()
            _ = try? await webView.evaluateJavaScript("1+1")
            samples.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
        }
        return samples
    }

    /// Evaluates a fixture probe expression (e.g. `window.__widgetAudioState`)
    /// and returns its string value, if any.
    func evaluateProbe(_ expression: String) async -> String? {
        let result = try? await webView.evaluateJavaScript(expression)
        return result as? String
    }

    private func freshSnapshotCGImage() async -> CGImage? {
        await withCheckedContinuation { continuation in
            webView.takeSnapshot(with: nil) { image, _ in
                MainActor.assumeIsolated {
                    continuation.resume(returning: image?.cgImage(forProposedRect: nil,
                                                                  context: nil, hints: nil))
                }
            }
        }
    }
}

// MARK: - Widget audio routing probe (A06/A01 cross-reference)

/// G07 (issue #114): runtime evidence for the widget-audio routing decision.
/// The question: can WKWebView media audio be captured as its own channel?
/// The probe answers with the SAME ScreenCaptureKit surface the A06
/// app-audio capture uses, plus the macOS 14.2+ Core Audio process-object
/// list — the only two public process-grained capture surfaces.
enum WidgetAudioRouteProbe {
    struct Report: Sendable {
        /// Whether SCShareableContent resolved (i.e. Screen Recording is
        /// granted to this process). When false, per-app/system-mix capture
        /// cannot run at all — the A06 repair guidance applies.
        var shareableContentAvailable = false
        var shareableContentError: String?
        /// Bundle IDs ScreenCaptureKit offered as capture targets.
        var capturableBundleIDs: [String] = []
        /// Whether ANY WebKit content/networking process showed up as a
        /// capturable app (expected: never — they are not UI applications).
        var webKitProcessVisibleToScreenCaptureKit = false
        /// Bundle IDs Core Audio reported as live audio process objects
        /// (macOS 14.2+; empty on older systems or when nothing plays).
        var audioProcessBundleIDs: [String] = []
        /// Whether a WebKit process appeared in the Core Audio list (i.e.
        /// the process-tap surface can SEE widget audio when it plays).
        var webKitProcessVisibleToCoreAudio = false
    }

    /// Gathers the report. Safe to call without any capture running: both
    /// surfaces are read-only enumerations.
    static func probe() async -> Report {
        var report = Report()
        do {
            let content = try await SCShareableContent.current
            report.shareableContentAvailable = true
            report.capturableBundleIDs = content.applications.map(\.bundleIdentifier).sorted()
            report.webKitProcessVisibleToScreenCaptureKit = content.applications.contains {
                $0.bundleIdentifier.hasPrefix("com.apple.WebKit")
            }
        } catch {
            report.shareableContentError = error.localizedDescription
        }
        if #available(macOS 14.2, *) {
            report.audioProcessBundleIDs = liveAudioProcessBundleIDs()
            report.webKitProcessVisibleToCoreAudio = report.audioProcessBundleIDs.contains {
                $0.hasPrefix("com.apple.WebKit")
            }
        }
        return report
    }

    /// The macOS 14.2+ Core Audio process-object list — what
    /// `CATapDescription(stereoMixdownOfProcesses:)` could tap. The catch the
    /// G08 decision must record: these objects key on PID, and WKWebView
    /// exposes NO public API for its WebContent process PID, so a tap cannot
    /// be reliably aimed at the widget's process from the host app.
    @available(macOS 14.2, *)
    private static func liveAudioProcessBundleIDs() -> [String] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.stride)
        guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var bundleAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyBundleID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var bundleID: Unmanaged<CFString>?
            var bundleSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.stride)
            guard AudioObjectGetPropertyData(id, &bundleAddress, 0, nil,
                                             &bundleSize, &bundleID) == noErr,
                  let value = bundleID?.takeUnretainedValue() else { return nil }
            return value as String
        }.sorted()
    }
}

// MARK: - Debug view (prototype instrumentation surface)

/// The G07 debug surface: hosts the prototype webview at its real pixel size
/// and shows the live capture counters. Nothing in the studio presents this
/// view — the G08 hook description (issue #115) names where it would mount.
struct BrowserOverlayPrototypeView: View {
    @StateObject private var prototype: BrowserOverlayPrototype

    init(content: BrowserOverlayPrototype.Content,
         targetFPS: Int = 30,
         pixelSize: CGSize = CGSize(width: 1280, height: 720)) {
        _prototype = StateObject(wrappedValue: BrowserOverlayPrototype(content: content,
                                                                       targetFPS: targetFPS,
                                                                       pixelSize: pixelSize))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            BrowserOverlayWebViewRepresentable(webView: prototype.webView)
                .frame(width: prototype.pixelSize.width / 2,
                       height: prototype.pixelSize.height / 2)
                .border(Color.gray.opacity(0.4))
            GroupBox("G07 prototype metrics") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("requested \(prototype.metrics.requested) · ok \(prototype.metrics.succeeded) · failed \(prototype.metrics.failed)")
                    Text(String(format: "achieved %.1f fps (target %d)",
                                prototype.metrics.achievedFPS, prototype.targetFPS))
                    Text(String(format: "snapshot latency avg %.1f ms · last %.1f ms",
                                prototype.metrics.averageLatencyMs, prototype.metrics.lastLatencyMs))
                    if let error = prototype.lastError {
                        Text(error).foregroundStyle(.red)
                    }
                }
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
        .onAppear { prototype.start() }
        .onDisappear { prototype.stop() }
    }
}

/// Hosts the prototype's WKWebView inside SwiftUI at its true pixel size
/// (the view renders half-scale on screen via the frame above; the webview
/// itself stays full-size so snapshots measure the real raster).
private struct BrowserOverlayWebViewRepresentable: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
