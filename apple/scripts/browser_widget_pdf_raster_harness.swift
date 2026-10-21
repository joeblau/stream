import AppKit
import CoreGraphics
import Foundation
import WebKit

private func require(_ value: Bool, _ message: String) { precondition(value, message) }
@MainActor private final class Navigation: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    func load(_ view: WKWebView, html: String) async throws {
        try await withCheckedThrowingContinuation { continuation = $0; view.loadHTMLString(html, baseURL: nil) }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { continuation?.resume(); continuation = nil }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { continuation?.resume(throwing: error); continuation = nil }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { continuation?.resume(throwing: error); continuation = nil }
}
@MainActor private final class Results { var current = true; var release: (@MainActor @Sendable () -> Void)?; var values: [Result<CGImage, BrowserWidgetRasterizer.Failure>] = []; var checks = 0 }
private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
    let data = image.dataProvider!.data! as Data, at = y * image.bytesPerRow + x * 4
    return Array(data[at..<at + 4])
}
private func pdf(width: Int, height: Int, pages: Int = 1) -> Data {
    let result = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: width, height: height)
    let context = CGContext(consumer: CGDataConsumer(data: result)!, mediaBox: &box, nil)!
    for _ in 0..<pages { context.beginPDFPage(nil); context.endPDFPage() }
    context.closePDF(); return result as Data
}
@main @MainActor struct BrowserWidgetPDFRasterHarness {
    static func main() {
        setbuf(stdout, nil)
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        Task { do { try await run(); exit(0) } catch { print("FAIL: \(error)"); exit(1) } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { print("FAIL: bounded PDF raster deadline"); exit(2) }
        app.run()
    }
    static func capture(_ view: WKWebView) async throws -> CGImage {
        let result = await withCheckedContinuation { continuation in
            BrowserWidgetRasterizer.capture(view, width: Int(view.bounds.width), height: Int(view.bounds.height), isCurrent: { true }) { continuation.resume(returning: $0) }
        }
        return try result.get()
    }
    static func run() async throws {
        for data in [Data("not-a-PDF".utf8), Data(repeating: 0, count: BrowserWidgetRasterizer.maximumPDFBytes + 1),
                     pdf(width: 480, height: 270, pages: 2), pdf(width: 100_000, height: 100_000)] {
            guard case .failure = BrowserWidgetRasterizer.rasterize(data, width: 480, height: 270) else { preconditionFailure("Malformed/oversized/wrong-box PDF admitted") }
        }
        require(!BrowserWidgetRasterizer.validDimensions(Int.max, Int.max), "Overflowing dimensions admitted")
        require(!BrowserWidgetRasterizer.validDimensions(0, 270), "Empty dimensions admitted")
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent(); config.mediaTypesRequiringUserActionForPlayback = .all
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 480, height: 270), configuration: config)
        view.underPageBackgroundColor = .clear
        let window = NSWindow(contentRect: view.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view; window.orderOut(nil)
        let delegate = Navigation(); view.navigationDelegate = delegate
        let html = "<style>html,body{margin:0;background:transparent}div{position:absolute;top:20px;width:80px;height:80px}#red{left:20px;background:red}#green{left:200px;background:rgba(0,255,0,.5)}#white{left:360px;background:white}canvas{position:absolute;left:20px;top:130px}#media{left:200px;top:130px;background:blue}@media print{#media{background:yellow}}</style><div id=red></div><div id=green></div><div id=white></div><canvas id=canvas width=80 height=80></canvas><div id=media></div>"
        try await delegate.load(view, html: html)
        try await Task.sleep(for: .milliseconds(100))
        let image = try await capture(view)
        require(image.width == 480 && image.height == 270, "PDF raster changed requested viewport")
        require(pixel(image, 470, 260) == [0, 0, 0, 0], "Transparent corner flattened")
        require(pixel(image, 240, 40) == [0, 128, 0, 128], "Half-transparent green lost premultiplied alpha")
        require(pixel(image, 40, 40) == [0, 0, 255, 255], "Opaque red changed")
        require(pixel(image, 400, 40) == [255, 255, 255, 255], "Opaque white became transparent")
        require(pixel(image, 240, 150) == [255, 0, 0, 255], "PDF incorrectly applied print CSS instead of screen CSS")
        for color in ["#00ffff", "#ff8000", "#00ffff", "#ff8000"] {
            _ = try await view.evaluateJavaScript("(()=>{const c=canvas.getContext('2d');c.fillStyle='\(color)';c.fillRect(0,0,80,80);})()")
            let changed = try await capture(view)
            require(pixel(changed, 40, 150) == (color == "#00ffff" ? [255, 255, 0, 255] : [0, 128, 255, 255]), "PDF retained stale script-updated canvas pixels")
        }
        let held = Results()
        let contenders = (0..<8).map { index in WKWebView(frame: CGRect(x: 0, y: 0,
            width: index == 0 ? 3840 : 1920, height: index == 0 ? 3840 : 1080), configuration: config) }
        for contender in contenders { contender.navigationDelegate = delegate; try await delegate.load(contender, html: html) }
        let queuedLarge = WKWebView(frame: contenders[0].frame, configuration: config), queued = Results()
        queuedLarge.navigationDelegate = delegate; try await delegate.load(queuedLarge, html: html)
        BrowserWidgetRasterizer.validationHoldResult = { view, release in
            guard view === contenders[0], held.release == nil else { return false }
            held.release = release; return true
        }
        BrowserWidgetRasterizer.capture(contenders[0], width: 3840, height: 3840, isCurrent: { held.current }) { held.values.append($0) }
        while held.release == nil { try await Task.sleep(for: .milliseconds(10)) }
        let second = Results()
        BrowserWidgetRasterizer.capture(contenders[0], width: 3840, height: 3840, isCurrent: { true }) { second.values.append($0) }
        guard second.values.count == 1, case .failure(.busy) = second.values[0] else { preconditionFailure("One held view obtained a second physical reservation") }
        BrowserWidgetRasterizer.capture(queuedLarge, width: 3840, height: 3840, isCurrent: { queued.current }) { queued.values.append($0) }
        for _ in 0..<12 {
            let round = Results()
            for contender in contenders.dropFirst() {
                BrowserWidgetRasterizer.capture(contender, width: 1920, height: 1080, isCurrent: { true }) { round.values.append($0) }
            }
            let outstanding = BrowserWidgetRasterizer.validationOutstanding
            require(outstanding.jobs == 8 && outstanding.pixels == 3840 * 3840 + 7 * 1920 * 1080 && outstanding.waiting == 1,
                "Held maximum viewport or queued maximum viewport blocked healthy HD admission")
            while round.values.count < 7 { try await Task.sleep(for: .milliseconds(10)) }
            require(round.values.allSatisfy { if case .success = $0 { true } else { false } },
                "A held callback starved a healthy HD client")
        }
        BrowserWidgetRasterizer.validationHoldResult = nil
        held.current = false; queued.current = false; held.release?(); held.release = nil
        require(held.values.count == 1, "Held actual raster reservation was not returned")
        guard case .failure(.stale) = held.values[0] else { preconditionFailure("Authority retired during a held result returned pixels") }
        require(queued.values.count == 1, "Queued maximum viewport did not retire")
        guard case .failure(.stale) = queued.values[0] else { preconditionFailure("Retired queued intent ran") }
        require(BrowserWidgetRasterizer.validationOutstanding.jobs == 0 && BrowserWidgetRasterizer.validationOutstanding.pixels == 0,
            "Physical jobs/pixels were leaked or recycled before actual completion")
        for retireAfter in [1, 2] {
            let fence = Results()
            let stale = await withCheckedContinuation { continuation in
                BrowserWidgetRasterizer.capture(view, width: 480, height: 270, isCurrent: {
                    fence.checks += 1; return fence.checks <= retireAfter
                }) { continuation.resume(returning: $0) }
            }
            guard case .failure(.stale) = stale else { preconditionFailure("Retired callback returned an image") }
            require(fence.checks == retireAfter + 1, "Expected actual PDF/raster callback retirement boundary")
        }
        var latency: [[String: Any]] = []
        for size in [CGSize(width: 480, height: 270), CGSize(width: 1920, height: 1080)] {
            window.setContentSize(size); view.frame.size = size
            var samples: [Double] = []
            for _ in 0..<20 {
                let start = ProcessInfo.processInfo.systemUptime
                let frame = try await capture(view)
                require(frame.width == Int(size.width) && frame.height == Int(size.height), "Repeated PDF raster dimensions changed")
                require(pixel(frame, frame.width - 10, frame.height - 10) == [0, 0, 0, 0], "Repeated raster alpha changed")
                samples.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            }
            latency.append(["width": Int(size.width), "height": Int(size.height), "samples": samples,
                "meanMS": samples.reduce(0,+)/Double(samples.count), "maximumMS": samples.max()!])
        }
        print(String(decoding: try JSONSerialization.data(withJSONObject: latency, options: [.prettyPrinted,.sortedKeys]), as: UTF8.self))
        print("PASS: actual public PDF alpha/screen-CSS/current-canvas raster; malformed/oversized/wrong-page/overflow refusals; eight-job/one-per-view/aggregate-pixel bound; held maximum3840² callback + queued maximum3840² intent do not starve7healthy HD clients; stale PDF/completed-raster/queued callbacks fenced; repeated480p/1080p sizes and alpha")
        print("SCOPE: owned silent HTML and local WebKit/CoreGraphics; representative media and eight-host progress have separate fixtures; arbitrary complex/high-resolution widgets and long-duration load remain unqualified; no permission request or independent audio activation")
        window.close()
    }
}
