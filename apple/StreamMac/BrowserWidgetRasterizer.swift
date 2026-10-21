import AppKit
import CoreGraphics
import Foundation
import WebKit

/// Public WebKit PDF snapshots preserve alpha on macOS 14+, unlike the measured
/// WKSnapshotConfiguration path. Page coordinates remain CSS pixels. At most
/// eight physical jobs (one per view) and eight latest-per-view capture intents
/// are retained. One maximum legacy viewport plus seven HD peers bound pixels;
/// helper IPC retains its narrower two-frame cap. Rendering runs off MainActor.
enum BrowserWidgetRasterizer {
    enum Failure: Error, Sendable { case busy, dimensions, document, stale, raster }
    static let maximumPDFBytes = 16 * 1_024 * 1_024
    static let maximumDimension = 3_840
    private static let queue = DispatchQueue(label: "stream.browser.pdf-raster", qos: .userInitiated)
    @MainActor private struct Job {
        let view: WKWebView, width: Int, height: Int
        let isCurrent: @MainActor @Sendable () -> Bool
        let completion: @MainActor @Sendable (Result<CGImage, Failure>) -> Void
    }
    private static let maximumJobs = 8
    // A stalled largest supported legacy view must still leave room for seven
    // HD peers. A smaller aggregate cap would admit it but starve healthy views.
    private static let maximumPixels = maximumDimension * maximumDimension + 7 * 1_920 * 1_080
    @MainActor private static var pending = 0
    @MainActor private static var activeViews: Set<ObjectIdentifier> = []
    @MainActor private static var activePixels = 0
    @MainActor private static var waiting: [Job] = []
    #if STREAM_NATIVE_VALIDATION
    @MainActor static var validationHoldResult: ((WKWebView, @escaping @MainActor @Sendable () -> Void) -> Bool)?
    @MainActor static var validationOutstanding: (jobs: Int, pixels: Int, waiting: Int) { (pending, activePixels, waiting.count) }
    #endif
    @MainActor private static func canStart(_ job: Job) -> Bool {
        pending < maximumJobs && activePixels + job.width * job.height <= maximumPixels
    }

    @MainActor static func capture(_ view: WKWebView, width: Int, height: Int,
        isCurrent: @escaping @MainActor @Sendable () -> Bool,
        completion: @escaping @MainActor @Sendable (Result<CGImage, Failure>) -> Void) {
        guard validDimensions(width, height), view.bounds.width == CGFloat(width), view.bounds.height == CGFloat(height) else {
            completion(.failure(.dimensions)); return
        }
        guard isCurrent() else { completion(.failure(.stale)); return }
        let job = Job(view: view, width: width, height: height, isCurrent: isCurrent, completion: completion)
        guard !activeViews.contains(ObjectIdentifier(view)) else { completion(.failure(.busy)); return }
        if canStart(job) && waiting.isEmpty { start(job); return }
        if let previous = waiting.firstIndex(where: { $0.view === view }) {
            let old = waiting.remove(at: previous); old.completion(.failure(.busy))
        }
        guard waiting.count < 8 else { completion(.failure(.busy)); return }
        waiting.append(job)
        drain()
    }
    @MainActor private static func start(_ job: Job) {
        pending += 1; activeViews.insert(ObjectIdentifier(job.view)); activePixels += job.width * job.height
        let view = job.view, width = job.width, height = job.height
        let configuration = WKPDFConfiguration()
        configuration.rect = CGRect(x: 0, y: 0, width: width, height: height)
        configuration.allowTransparentBackground = true
        view.createPDF(configuration: configuration) { result in
            guard job.isCurrent() else { finish(job, .failure(.stale)); return }
            guard case .success(let data) = result, !data.isEmpty, data.count <= maximumPDFBytes else {
                finish(job, .failure(.document)); return
            }
            queue.async {
                let image = rasterize(data, width: width, height: height)
                Task { @MainActor in
                    finish(job, image)
                }
            }
        }
    }

    @MainActor private static func finish(_ job: Job, _ result: Result<CGImage, Failure>) {
        #if STREAM_NATIVE_VALIDATION
        if validationHoldResult?(job.view, { complete(job, result) }) == true { return }
        #endif
        complete(job, result)
    }
    @MainActor private static func complete(_ job: Job, _ result: Result<CGImage, Failure>) {
        pending -= 1; activeViews.remove(ObjectIdentifier(job.view)); activePixels -= job.width * job.height
        drain()
        if case .failure(.stale) = result { job.completion(result) }
        else { job.completion(job.isCurrent() ? result : .failure(.stale)) }
    }

    @MainActor private static func drain() {
        // Scan at most eight retained intents. A larger waiting viewport must
        // not block healthy peers that fit the remaining physical/pixel budget.
        while !waiting.isEmpty {
            if let stale = waiting.firstIndex(where: { !$0.isCurrent() }) {
                let old = waiting.remove(at: stale); old.completion(.failure(.stale)); continue
            }
            guard let runnable = waiting.firstIndex(where: { canStart($0) }) else { return }
            let next = waiting.remove(at: runnable); start(next)
        }
    }

    static func validDimensions(_ width: Int, _ height: Int) -> Bool {
        (16...maximumDimension).contains(width) && (16...maximumDimension).contains(height)
    }

    /// No input-controlled destination allocation precedes the length, page
    /// count and exact media-box checks. Helper protocol applies its narrower
    /// 1920×1080 cap before reaching this shared legacy-compatible renderer.
    static func rasterize(_ data: Data, width: Int, height: Int) -> Result<CGImage, Failure> {
        guard validDimensions(width, height), !data.isEmpty, data.count <= maximumPDFBytes,
              let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider),
              document.numberOfPages == 1, let page = document.page(at: 1) else { return .failure(.document) }
        let box = page.getBoxRect(.mediaBox)
        guard box.origin.x == 0, box.origin.y == 0, box.width == CGFloat(width), box.height == CGFloat(height),
              page.rotationAngle == 0 else { return .failure(.dimensions) }
        guard let context = CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            return .failure(.raster)
        }
        context.clear(box); context.drawPDFPage(page)
        guard let image = context.makeImage() else { return .failure(.raster) }
        return .success(image)
    }
}
