import AppKit
import Combine
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import os.lock
import StreamCore
import SwiftUI
import UniformTypeIdentifiers

/// G01 (issue #81): image and logo layers — import-time format probing, the
/// decoded-image hand-off into the render engines, and the P03 asset-library
/// registration seam.
///
/// **Format gating.** `ImageAssetClassifier` probes a picked/dropped file with
/// ImageIO and validates it through StreamCore's `ImageAssetValidator`
/// (PNG/JPEG/HEIF/TIFF raster + PDF vector) BEFORE a payload ever reaches a
/// scene — an unsupported or undecodable file is an explicit error at import
/// time, never a surprise on program.
///
/// **Decode.** `ImageLayerDecoder` turns a URL into a `CGImage` with the
/// file's alpha, embedded color space, and pixel aspect untouched: rasters
/// decode as stored (bounded by a generous pixel ceiling so a pathological
/// file can't allocate unbounded memory on the render tick); PDF rasterizes
/// at 4× the media box, so a vector logo stays crisp at any layer size.
///
/// **Hand-off.** `ImageLayerImageStore` is the process-wide, lock-protected
/// value snapshot every `SceneRenderer` reads (the `TitleTokenStore` /
/// `ProjectOverlayStore` pattern — a mid-tick publish can never tear a
/// frame). Images enter it two ways: the `ImageLayerCoordinator` publishes
/// library-registered assets (decoding off the main actor through
/// `AssetLibraryStore.access(for:)`, which holds the security-scope grant),
/// and the store itself decodes SELF-CONTAINED payloads on demand — a payload
/// carrying its own bookmark (A02's pattern) resolves and decodes on the
/// engine actor, so an image layer renders even when the asset library is
/// absent. A payload that resolves nowhere returns nil — the renderer's
/// documented paint-nothing fallback (never black, never crash).
///
/// **Environment injection the orchestrator must wire.** The coordinator
/// works standalone (self-contained bookmarks carry the render path), but
/// P03 registration/usage tracking needs the ONE shared
/// `AssetLibraryStore`: create it in `StreamMacApp` next to `dispatcher`
/// (the hook `AssetLibraryPanelView` documents), inject it as an
/// `.environmentObject`, and attach it to the coordinator
/// (`ImageLayerSectionView` attaches automatically when the store is in the
/// environment). Until then, imports skip library registration and the
/// payload's own bookmark keeps the layer recoverable.

/// The import-time probe of one picked image file: everything the payload
/// and the decoder need except the pixels.
struct ProbedImageAsset: Sendable {
    let flavor: ImageAssetFlavor
    let pixelWidth: Int
    let pixelHeight: Int
    /// The container's UTI (e.g. `public.png`) — decode dispatch and
    /// diagnostics.
    let typeIdentifier: String
}

/// G01: the picked-file probe + payload factory (the `MediaOverlayClassifier`
/// / `MediaSourceFactory` precedent). All probes run while the caller holds
/// the pick's security-scoped access.
enum ImageAssetClassifier {

    /// The UTTypes the file sheets and Finder drop targets advertise.
    static var allowedContentTypes: [UTType] {
        [.png, .jpeg, .heic, .tiff, .pdf]
    }

    /// Probes and validates a picked file: supported type (PNG/JPEG/HEIF/
    /// TIFF/PDF) that actually decodes. The failure reasons are user-facing
    /// (the section view and drop handler show them verbatim). PDFs probe
    /// through CGPDFDocument — the same native vector path the decoder uses
    /// (the "pixel" size of a vector page is its media box in points, the
    /// UI's aspect hint).
    static func probe(url: URL) -> Result<ProbedImageAsset, ImageAssetFormatError> {
        let extensionType = UTType(filenameExtension: url.pathExtension.lowercased())
        if extensionType?.identifier == "com.adobe.pdf" {
            return probePDF(url: url)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return .failure(ImageAssetFormatError("The image file could not be opened."))
        }
        let typeIdentifier = (CGImageSourceGetType(source) as String?)
            ?? extensionType?.identifier
        let imageCount = CGImageSourceGetCount(source)
        let flavor: ImageAssetFlavor
        switch ImageAssetValidator.validate(typeIdentifier: typeIdentifier, imageCount: imageCount) {
        case .failure(let error): return .failure(error)
        case .success(let validated): flavor = validated
        }
        let first = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        let width = (first?[kCGImagePropertyPixelWidth as String] as? Int) ?? 0
        let height = (first?[kCGImagePropertyPixelHeight as String] as? Int) ?? 0
        guard width > 0, height > 0 else {
            return .failure(ImageAssetFormatError("The image file declares no pixel dimensions."))
        }
        return .success(ProbedImageAsset(flavor: flavor,
                                         pixelWidth: width,
                                         pixelHeight: height,
                                         typeIdentifier: typeIdentifier ?? "unknown"))
    }

    /// The PDF probe: the document must open and have at least one page with
    /// a non-empty media box.
    private static func probePDF(url: URL) -> Result<ProbedImageAsset, ImageAssetFormatError> {
        guard let document = CGPDFDocument(url as CFURL) else {
            return .failure(ImageAssetFormatError("The PDF file could not be opened."))
        }
        switch ImageAssetValidator.validate(typeIdentifier: "com.adobe.pdf",
                                            imageCount: document.numberOfPages) {
        case .failure(let error): return .failure(error)
        case .success: break
        }
        guard let page = document.page(at: 1) else {
            return .failure(ImageAssetFormatError("The PDF has no pages to render."))
        }
        let box = page.getBoxRect(.mediaBox)
        guard box.width > 0, box.height > 0 else {
            return .failure(ImageAssetFormatError("The PDF's first page has an empty media box."))
        }
        return .success(ProbedImageAsset(flavor: .vector,
                                         pixelWidth: Int(box.width.rounded()),
                                         pixelHeight: Int(box.height.rounded()),
                                         typeIdentifier: "com.adobe.pdf"))
    }

    /// Builds a layer payload for a probed file: the security-scoped bookmark
    /// is the self-contained access grant (A02's pattern — the raw URL alone
    /// would not reopen across launches), `fileName` survives the bookmark,
    /// and the pixel dimensions are the UI's aspect hint. Nil only when no
    /// bookmark could be created at all.
    static func payload(forPickedFile url: URL,
                        probed: ProbedImageAsset) -> ImageSourcePayload? {
        guard let bookmark = AssetBookmarkCodec.makeBookmark(for: url) else { return nil }
        return ImageSourcePayload(bookmarkData: bookmark,
                                  fileName: url.lastPathComponent,
                                  pixelWidth: probed.pixelWidth,
                                  pixelHeight: probed.pixelHeight)
    }
}

/// G01: the decode step — URL to `CGImage` with alpha, color space, and
/// pixel aspect preserved. Stateless and thread-safe; the caller holds (or
/// the decoder starts) the security-scope grant.
enum ImageLayerDecoder {
    /// Raster decode ceiling (pixels per side): beyond it the image decodes
    /// through the thumbnail path at the ceiling instead of allocating an
    /// unbounded bitmap on the render tick. 12K per side is far past any
    /// realistic overlay/logo asset.
    static let maximumRasterPixelSize = 12_000
    /// PDFs are vector: rasterize at 4× the 72-dpi media box so a logo stays
    /// crisp scaled up to full-frame 4K.
    static let vectorRasterizationDPI = 288.0

    /// Decodes the first image/page of `url`. Nil when the file no longer
    /// decodes (moved mid-session, revoked grant) — the caller treats nil as
    /// the documented paint-nothing fallback.
    static func decode(url: URL, flavor: ImageAssetFlavor) -> CGImage? {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        switch flavor {
        case .vector:
            return decodePDFPage(url: url)
        case .raster:
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
            let width = (properties?[kCGImagePropertyPixelWidth as String] as? Int) ?? 0
            let height = (properties?[kCGImagePropertyPixelHeight as String] as? Int) ?? 0
            guard max(width, height) > maximumRasterPixelSize else {
                return CGImageSourceCreateImageAtIndex(source, 0, nil)
            }
            // Oversized raster: decode a bounded thumbnail (alpha and color
            // space preserved) rather than an unbounded bitmap.
            return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumRasterPixelSize,
                kCGImageSourceCreateThumbnailWithTransform: false
            ] as CFDictionary)
        }
    }

    /// Rasterizes a PDF's first page at `vectorRasterizationDPI` into a
    /// transparent-backed bitmap (CGPDFDocument is the native vector render
    /// path — a vector logo stays crisp at any layer size, and the cleared
    /// background keeps page transparency intact). Bounded to the raster
    /// ceiling so a poster-sized page can't allocate an unbounded bitmap.
    private static func decodePDFPage(url: URL) -> CGImage? {
        guard let document = CGPDFDocument(url as CFURL),
              let page = document.page(at: 1) else { return nil }
        let box = page.getBoxRect(.mediaBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let scale = vectorRasterizationDPI / 72.0
        let pixelWidth = min(Int((box.width * scale).rounded(.up)), maximumRasterPixelSize)
        let pixelHeight = min(Int((box.height * scale).rounded(.up)), maximumRasterPixelSize)
        guard pixelWidth > 0, pixelHeight > 0,
              let context = CGContext(data: nil,
                                      width: pixelWidth,
                                      height: pixelHeight,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let rect = CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight)
        context.clear(rect)
        context.scaleBy(x: CGFloat(pixelWidth) / box.width,
                        y: CGFloat(pixelHeight) / box.height)
        context.drawPDFPage(page)
        return context.makeImage()
    }
}

/// G01: the process-wide decoded-image store the renderers read each tick
/// (the `TitleTokenStore` pattern): lock-protected value snapshots, so a
/// mid-tick publish never tears a frame. Library-registered assets are
/// PUBLISHED by the `ImageLayerCoordinator` (keyed by the payload's
/// `cacheKey`); payloads carrying their own bookmark decode on demand on the
/// caller's actor and cache by the same key.
final class ImageLayerImageStore: @unchecked Sendable {
    static let shared = ImageLayerImageStore()

    private var lock = os_unfair_lock_s()
    /// The one image per payload cache key. `CIImage` is immutable and
    /// thread-safe; the renderer's Metal-backed context bakes it on first
    /// paint.
    private var images: [String: CIImage] = [:]
    /// Bounded like the renderer's generated cache: a replace/relink churns
    /// keys, so the store clears itself past the cap rather than growing
    /// without bound.
    private let cacheLimit = 64

    /// Publishes (or replaces) the decoded image for a payload cache key.
    /// Nil removes the entry — an asset that stopped resolving must fall
    /// back to paint-nothing, not keep showing stale pixels.
    func publish(_ image: CIImage?, forKey key: String) {
        os_unfair_lock_lock(&lock)
        if images.count >= cacheLimit {
            images.removeAll()
        }
        images[key] = image
        os_unfair_lock_unlock(&lock)
    }

    /// The decoded image for a payload: the published library/coordinator
    /// image (keyed by `payload.cacheKey`) wins; otherwise the payload's own
    /// bookmark decodes on demand and caches under the BOOKMARK key (never
    /// the asset key, so a stale self-contained decode can't clobber a
    /// library replace's republish). Nil — paint nothing — when neither
    /// resolves.
    func image(for payload: ImageSourcePayload) -> CIImage? {
        os_unfair_lock_lock(&lock)
        if let image = images[payload.cacheKey] {
            os_unfair_lock_unlock(&lock)
            return image
        }
        os_unfair_lock_unlock(&lock)

        // Self-contained fallback (A02's pattern): the payload's own
        // security-scoped bookmark. Covers layers imported before the asset
        // library was wired and library copies whose registry is unavailable.
        guard let bookmark = payload.bookmarkData,
              let resolved = AssetBookmarkCodec.resolve(bookmark),
              let probed = try? Self.probeSync(url: resolved.url),
              let cgImage = ImageLayerDecoder.decode(url: resolved.url, flavor: probed.flavor)
        else { return nil }
        let image = CIImage(cgImage: cgImage)
        publish(image, forKey: "bookmark/\(AssetContentHasher.sha256(of: bookmark))")
        return image
    }

    /// Synchronous probe for the on-demand decode path (the classifier's
    /// logic without the error surface — any failure is just "no image").
    private static func probeSync(url: URL) throws -> ProbedImageAsset {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        switch ImageAssetClassifier.probe(url: url) {
        case .success(let probed): return probed
        case .failure(let error): throw error
        }
    }
}

/// G01: the main-actor coordinator binding image layers to the P03 asset
/// library. Holds the (orchestrator-injected) shared `AssetLibraryStore`,
/// imports picked files into it, records namespaced usage
/// ("imageLayer/<layer-uuid>"), and publishes decoded images for
/// library-registered payloads into `ImageLayerImageStore` — decoding off
/// the main actor, holding each asset's security-scope grant for the read.
@MainActor
final class ImageLayerCoordinator: ObservableObject {
    /// The shared P03 store once wired; nil means "library unavailable —
    /// image layers still render through self-contained bookmarks, imports
    /// just skip registration".
    @Published private(set) var assetLibrary: AssetLibraryStore?
    private var cancellables: Set<AnyCancellable> = []

    /// Nonisolated so a SwiftUI view (`@StateObject` in `MainWindowView`)
    /// can create the coordinator from a non-isolated context; all state has
    /// inline defaults and every mutation is main-actor.
    nonisolated init() {}

    /// Attaches the shared asset library (the orchestrator's injection point)
    /// and republishes decodes whenever the registry changes (relink/replace
    /// re-points an asset's file — every layer bound to it follows on the
    /// next tick). Availability probes re-forward as view invalidations so
    /// the section's missing badges stay live.
    func attach(assetLibrary: AssetLibraryStore) {
        guard self.assetLibrary !== assetLibrary else { return }
        self.assetLibrary = assetLibrary
        cancellables.removeAll()
        assetLibrary.$assets
            .sink { [weak self] _ in
                self?.republishLibraryImages()
            }
            .store(in: &cancellables)
        assetLibrary.$availability
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    /// Imports a picked/dropped image file: validates the format (explicit
    /// rejection before any scene sees the payload), registers the file as a
    /// library asset (copy mode — the project owns the bytes, the recoverable
    /// reference the issue requires) when the library is wired, and publishes
    /// the decode so the layer paints on the next tick. The payload carries
    /// its own bookmark regardless, so a library-less import still renders.
    func importImage(at url: URL) async -> Result<ImageSourcePayload, ImageAssetFormatError> {
        let accessing = url.startAccessingSecurityScopedResource()
        let probed: ProbedImageAsset
        switch ImageAssetClassifier.probe(url: url) {
        case .failure(let error):
            if accessing { url.stopAccessingSecurityScopedResource() }
            return .failure(error)
        case .success(let value): probed = value
        }
        guard var payload = ImageAssetClassifier.payload(forPickedFile: url, probed: probed) else {
            if accessing { url.stopAccessingSecurityScopedResource() }
            return .failure(ImageAssetFormatError("Access to the picked file couldn't be persisted."))
        }
        if accessing { url.stopAccessingSecurityScopedResource() }

        if let asset = await assetLibrary?.importFile(at: url, mode: .copy) {
            payload.assetIdentifier = asset.id.rawValue.uuidString
        }
        publishDecode(forKey: payload.cacheKey, url: url, flavor: probed.flavor)
        return .success(payload)
    }

    /// Records that `layerID`'s payload references its library asset (the
    /// namespaced usage seam — "imageLayer/<layer-uuid>").
    func noteUsage(of payload: ImageSourcePayload, from layerID: LayerID) {
        guard let assetIdentifier = payload.assetIdentifier,
              let uuid = UUID(uuidString: assetIdentifier) else { return }
        assetLibrary?.noteUsage(of: AssetID(uuid), from: Self.usageSite(for: layerID))
    }

    /// Drops the usage edge when a layer's image is replaced/removed.
    func removeUsage(of payload: ImageSourcePayload, from layerID: LayerID) {
        guard let assetIdentifier = payload.assetIdentifier,
              let uuid = UUID(uuidString: assetIdentifier) else { return }
        assetLibrary?.removeUsage(of: AssetID(uuid), from: Self.usageSite(for: layerID))
    }

    /// The namespaced usage site key for one image layer.
    static func usageSite(for layerID: LayerID) -> String {
        "imageLayer/\(layerID.rawValue.uuidString)"
    }

    /// The availability of a payload's library asset (nil when the payload
    /// isn't library-registered — self-contained layers have no missing
    /// state of their own; the paint-nothing fallback covers them).
    func availability(of payload: ImageSourcePayload) -> AssetAvailability? {
        guard let assetIdentifier = payload.assetIdentifier,
              let uuid = UUID(uuidString: assetIdentifier) else { return nil }
        return assetLibrary?.availability(of: AssetID(uuid))
    }

    /// Ensures a library-registered payload has a published decode (called
    /// when an image layer's section appears and on import). Self-contained
    /// payloads need nothing — the store decodes them on demand.
    func ensurePublished(_ payload: ImageSourcePayload) {
        guard let assetIdentifier = payload.assetIdentifier,
              let uuid = UUID(uuidString: assetIdentifier),
              let access = assetLibrary?.access(for: AssetID(uuid)) else { return }
        publishDecode(forKey: payload.cacheKey, url: access.url,
                      flavor: flavorHint(for: access.url) ?? .raster,
                      holding: access)
    }

    /// Re-decodes and republishes every image asset in the library (registry
    /// change: import/relink/replace/remove). Decode happens off the main
    /// actor; the publish is a value snapshot.
    private func republishLibraryImages() {
        guard let assetLibrary else { return }
        // PDF registers as `.document` in the P03 kind inference; the flavor
        // hint below filters to the G01-supported extensions.
        let candidates = assetLibrary.assets.filter { $0.kind == .image || $0.kind == .document }
        for asset in candidates {
            let key = "asset/\(asset.id.rawValue.uuidString)"
            guard let access = assetLibrary.access(for: asset.id),
                  let flavor = flavorHint(for: access.url) else {
                // Unresolvable or unsupported: clear any stale pixels so
                // bound layers fall back to paint-nothing honestly.
                ImageLayerImageStore.shared.publish(nil, forKey: key)
                continue
            }
            publishDecode(forKey: key, url: access.url, flavor: flavor, holding: access)
        }
    }

    /// Decodes off the main actor and publishes the result. The
    /// `ResolvedAssetAccess` token (when the URL came from the library) is
    /// captured by the task, holding the security-scope grant until the read
    /// finishes — releasing it earlier would strand linked assets.
    private nonisolated func publishDecode(forKey key: String, url: URL,
                                           flavor: ImageAssetFlavor,
                                           holding access: ResolvedAssetAccess? = nil) {
        Task.detached(priority: .utility) {
            let image = ImageLayerDecoder.decode(url: url, flavor: flavor)
                .map { CIImage(cgImage: $0) }
            ImageLayerImageStore.shared.publish(image, forKey: key)
            withExtendedLifetime(access) {}
        }
    }

    /// The decode flavor from a file's extension when no probe ran (library
    /// republish): PDF is the only vector path.
    private func flavorHint(for url: URL) -> ImageAssetFlavor? {
        let ext = url.pathExtension.lowercased()
        guard ImageAssetValidator.isSupportedExtension(ext) else { return nil }
        return ext == "pdf" ? .vector : .raster
    }
}

// MARK: - SwiftUI environment seam (orchestrator wiring)

/// Optional environment injection for the ONE shared P03 asset library.
/// Optional (default nil) so G01 views work before the orchestrator wires
/// the store — the panel's documented hook is `.environmentObject` (for
/// `AssetLibraryPanelView`) PLUS this key (for the image layer views, which
/// must not hard-require it). On a change, the views attach their
/// coordinator to the store.
private struct AssetLibraryStoreEnvironmentKey: EnvironmentKey {
    static let defaultValue: AssetLibraryStore? = nil
}

extension EnvironmentValues {
    var assetLibraryStore: AssetLibraryStore? {
        get { self[AssetLibraryStoreEnvironmentKey.self] }
        set { self[AssetLibraryStoreEnvironmentKey.self] = newValue }
    }
}
