import AppKit
import CoreGraphics
import CoreVideo
import Foundation
import PDFKit
import StreamCore
import os.lock

/// G06 (issue #113): multi-page PDF / slide-deck sources — page-state
/// persistence, the pull-based page-rendering engine, and the pool/renderer
/// integration hooks.
///
/// **Design (the A02/G09 precedent).** Frames are PULLED by the composition
/// engines' render tick (`MediaFrameSource.pullFrame`) — the render tick is
/// the cadence, so pages composite with no timers of their own. Page state
/// (selected page + fit/fill framing) is PER SOURCE, persisted in the
/// presentations document (`stream.presentations.v1.json`, the PTZ/soundboard
/// document precedent) and mirrored process-wide through
/// `PDFDeckStateStore.shared` (the `SourcePayloadStore` pattern), so the
/// preview AND program engines read the same page on every tick and page
/// state can never fork between canvases — whatever the S08/S09 dual-canvas
/// wiring does, both pull identical pixels.
///
/// **Page changes are program-aware but NOT scene content** (the A02 media
/// transport precedent): a page command acts on the ONE shared deck state
/// for the source, so it is visible on program the moment the source is on
/// program, and it never stages, Takes, or joins the S12 undo snapshot
/// (playback position is not undoable scene content — same rule). Locks and
/// staging never gate navigation.
///
/// **Document identity.** `PDFSourcePayload.assetIdentifier` names a P03
/// asset-library entry; imports default to PROJECT COPIES, so packaging the
/// project retains the document bytes (and dedups by content hash). The
/// engine holds the `ResolvedAssetAccess` grant for its lifetime (the A02
/// session-held security-scope pattern).
///
/// ---
///
/// **INTEGRATION HOOKS (files owned by other agents — do not edit here):**
///
/// 1. `LayerGraph.swift` (G01) — mark the kind renderable:
///    `LayerPayload.isRenderable` → add `|| isPDF` (and an `isPDF` computed
///    property mirroring `isMedia`). Without this, `.addLayer(.pdf)` stays
///    rejected as model-only.
///
/// 2. `CaptureSourcePool.swift` (G08) — demand + one engine per source:
///    - `CaptureSourceKey`: add `case pdf(SourceDefinitionID)` (keyed by
///      registry source ID, exactly like `.media`; `.pdf` payloads carry no
///      physical-capture identity of their own).
///    - `CaptureSourceKey.demanded(layers:sources:)`: in the payload switch,
///      add `case .pdf:` with the same body as `.media` (insert
///      `.pdf(sourceID)` when `layer.sourceID` is set).
///    - Pool storage mirroring `mediaPlaybacks`:
///      `private var pdfPlaybacks: [CaptureSourceKey: PDFSourcePlayback] = [:]`
///      and a factory mirroring `mediaPlayback(for:id:)`:
///      ```swift
///      private func pdfPlayback(for key: CaptureSourceKey,
///                               id: SourceDefinitionID,
///                               assetLibrary: AssetLibraryStore) -> PDFSourcePlayback {
///          if let existing = pdfPlaybacks[key] { return existing }
///          let playback = PDFSourcePlayback(sourceID: id, assetLibrary: assetLibrary)
///          playback.onStatus = { [weak self] sourceID, status in
///              Task { @MainActor [weak self] in
///                  // Mirror into PDFDeckStore.pageCounts and sourceErrors,
///                  // exactly like the media status sink.
///              }
///          }
///          pdfPlaybacks[key] = playback
///          publishFrameHolders()
///          return playback
///      }
///      ```
///    - `start(_:settings:)`: `case .pdf(let id): startPDF(key, id: id)`
///      (load + optimistic `activeSources.insert`, like `startMedia`);
///      `stop(_:)` and `markMissing`: `pdfPlaybacks[key]?.pause()` (page and
///      document hold; the engine has nothing to park).
///    - `publishFrameHolders()`: merge the pdf engines into the keyed media
///      map: `frames.updateKeyedMedia(mediaPlaybacks.mapValues { $0 }.merging(
///      pdfPlaybacks.mapValues { $0 as any MediaFrameSource }) { _, pdf in pdf })`.
///    - Wire `playback.canvasSizeProvider` to the controller's active output
///      profile canvas so `.fill` framing crops to the output aspect. The
///      provider runs on the RENDER TICK (off-main, under the engine lock) —
///      capture a lock-protected value snapshot (the `SourcePayloadStore`
///      pattern), never a `@MainActor` property directly.
///    The pool needs an `AssetLibraryStore` reference (the dispatcher owns
///      one — `dispatcher.assetLibrary`); pass it at pool init or into the
///      factory.
///
/// 3. `SceneRenderer.swift` (G01) — pull + place, the `.media` case verbatim
///    with the pdf key:
///    - `captureKey(for:sourcePayloads:)`: `case .pdf: return layer.sourceID.map { .pdf($0) }`.
///    - The layer-image switch: `case .pdf:` — same body as `.media`
///      (`frames.media?(key)` → `CIImage(cvPixelBuffer:)` → `place(...)`).
///      The renderer's standard aspect-fit placement is what makes fit/fill
///      work: `.fit` pages letterbox, `.fill` pages arrive pre-cropped to the
///      canvas aspect so aspect-fit covers edge to edge.
///    - `isStaticContent`: add `.pdf` to the non-static list (page changes
///      must never bake into the nested-scene cache).
///
/// 4. `MainWindowView.swift` (G01) — embed `PDFSourceSectionView()` next to
///    `MediaSourcesSectionView()` in the sources/inspector column (same
///    hosting pattern; the view reads `SceneStore`, `CaptureSourcePool`, and
///    the dispatcher from the environment).

// MARK: - Status

/// One PDF source's load phase. Simpler than `MediaPlayoutPhase` — pages
/// don't play/pause/end; the deck is either unloaded, loading, ready to
/// render, or failed (missing/encrypted/unreadable document).
enum PDFSourcePhase: String, Sendable, Equatable {
    /// No engine has loaded the document yet (source just registered).
    case idle
    case loading
    /// Loaded and rendering the selected page.
    case ready
    case error
}

/// The inspector/transport UI's view of one PDF source. `pageCount` is known
/// once the document loads; `currentPage` mirrors the last rendered page.
struct PDFSourceStatus: Equatable, Sendable {
    var phase: PDFSourcePhase = .idle
    var pageCount: Int = 0
    var currentPage: Int = 0
    var errorMessage: String? = nil
}

// MARK: - Import-time probing

/// The decoded-at-import description of one PDF document: everything the
/// engine needs except the PDFDocument itself (not Sendable — built on the
/// engine side, the `AnimatedImageContents` pattern).
struct PDFDocumentContents: Sendable {
    let fileURL: URL
    let pageCount: Int
    /// The document's title metadata, when present (display only).
    let title: String?
}

/// Import/load-time probing for PDF documents: the "report unsupported
/// documents before they reach program" gate (the G09 classifier pattern).
/// Probes run on the caller's file while its access grant is held.
enum PDFSourceClassifier {
    /// The document must open, carry at least one page, and not be locked.
    static func probe(url: URL) -> Result<PDFDocumentContents, MediaOverlayFormatError> {
        guard let document = PDFDocument(url: url) else {
            return .failure(MediaOverlayFormatError(
                "The document could not be opened — pick a PDF file."))
        }
        guard document.pageCount > 0 else {
            return .failure(MediaOverlayFormatError(
                "\"\(url.lastPathComponent)\" has no pages."))
        }
        if document.isLocked {
            return .failure(MediaOverlayFormatError(
                "\"\(url.lastPathComponent)\" is password-protected — unlock it and re-export before importing."))
        }
        let title = document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
        return .success(PDFDocumentContents(fileURL: url,
                                            pageCount: document.pageCount,
                                            title: title))
    }
}

// MARK: - Process-wide deck state snapshot

/// Lock-protected, off-main-readable mirror of the persisted deck states —
/// the `SourcePayloadStore` pattern. `PDFDeckStore` (main actor) publishes on
/// every mutation; the playback engines read `snapshot()` from the render
/// tick, so page changes land on BOTH composition engines on their next pull
/// with no engine wiring at the call site.
final class PDFDeckStateStore: @unchecked Sendable {
    /// The process-wide live mirror (the pool/engines' other process-wide
    /// stores publish the same way).
    static let shared = PDFDeckStateStore()

    private var lock = os_unfair_lock_s()
    /// Registry source ID (UUID string) → page state.
    private var states: [String: DeckPageState] = [:]

    func publish(_ states: [String: DeckPageState]) {
        os_unfair_lock_lock(&lock)
        self.states = states
        os_unfair_lock_unlock(&lock)
    }

    func snapshot() -> [String: DeckPageState] {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return states
    }
}

// MARK: - Persisted deck store

/// G06 (issue #113): the persisted per-source presentation surface — selected
/// page + fit/fill framing for every registry PDF source — backed by
/// `PresentationDeckDocumentStore` (`stream.presentations.v1.json` in the
/// shared App Group container, the `PTZPresetStore` pattern: debounced atomic
/// autosave, corrupt-file quarantine, flush on termination).
///
/// Mutations are immediate, not staged: page state is live session/document
/// state (the media-transport precedent), NOT scene content — it never
/// stages, Takes, or joins the S12 undo stack. Every mutation republishes the
/// off-main snapshot, so both composition engines paint the new page on their
/// next tick.
@MainActor
final class PDFDeckStore: ObservableObject {
    /// Page state per registry PDF source. Absent = never navigated (the
    /// engine falls back to the payload's default page).
    @Published private(set) var decks: [SourceDefinitionID: DeckPageState] {
        didSet { scheduleAutosave(); publishSnapshot() }
    }
    /// Session mirror of each loaded document's page count (engines report it
    /// through their status callback). Drives the UI's "Page X of N" and the
    /// upper clamp for jump navigation before a document finishes loading.
    @Published private(set) var pageCounts: [SourceDefinitionID: Int] = [:]

    private static let autosaveDelay: TimeInterval = 0.75

    private let documentStore: PresentationDeckDocumentStore?
    private var autosaveTask: Task<Void, Never>?
    /// `nonisolated(unsafe)` so `deinit` can unregister it (the store lives
    /// for the app's lifetime; belt-and-braces like the other stores).
    nonisolated(unsafe) private var terminationObserver: NSObjectProtocol?

    init(documentStore: PresentationDeckDocumentStore? = PresentationDeckDocumentStore(fileURL: DesktopStorage.projectDirectory.appendingPathComponent(PresentationDeckDocumentStore.fileName))) {
        self.documentStore = documentStore
        let document = documentStore?.load() ?? PresentationDeckDocument()
        var restored: [SourceDefinitionID: DeckPageState] = [:]
        for (key, state) in document.decks {
            guard let uuid = UUID(uuidString: key) else { continue }
            restored[SourceDefinitionID(uuid)] = state
        }
        decks = restored
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushPendingWrites() }
        }
        publishSnapshot()
    }

    deinit {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
    }

    // MARK: - Reads

    /// The persisted state for a source, seeded from the payload's default
    /// page when the deck has never been navigated.
    func state(for id: SourceDefinitionID, fallbackPage: Int = 0) -> DeckPageState {
        decks[id] ?? DeckPageState(page: fallbackPage)
    }

    func pageCount(for id: SourceDefinitionID) -> Int? {
        pageCounts[id].flatMap { $0 > 0 ? $0 : nil }
    }

    // MARK: - Mutations (immediate, autosaved, republished)

    /// Absolute jump (0-based), clamped to the known page count.
    func setPage(_ page: Int, for id: SourceDefinitionID, fallbackFraming: DeckFraming = .fit) {
        var state = state(for: id)
        state = state.jumped(to: page, pageCount: pageCount(for: id))
        decks[id] = state
    }

    /// Relative next/previous navigation, clamped (decks never wrap).
    func advance(by delta: Int, for id: SourceDefinitionID, fallbackPage: Int = 0) {
        var state = state(for: id, fallbackPage: fallbackPage)
        state = state.advanced(by: delta, pageCount: pageCount(for: id))
        decks[id] = state
    }

    func setFraming(_ framing: DeckFraming, for id: SourceDefinitionID, fallbackPage: Int = 0) {
        var state = state(for: id, fallbackPage: fallbackPage)
        state.framing = framing
        decks[id] = state
    }

    /// An engine reported its document's page count: mirror it for the UI and
    /// re-clamp the persisted page (a relinked shorter document must not
    /// leave the deck pointing past its last page).
    func notePageCount(_ count: Int, for id: SourceDefinitionID) {
        pageCounts[id] = count
        if count > 0, let state = decks[id] {
            let clamped = state.clampedPage(pageCount: count)
            if clamped != state.page {
                decks[id] = DeckPageState(page: clamped, framing: state.framing)
            }
        }
    }

    /// Drops the source's deck state (source removed from the registry).
    func removeDeck(for id: SourceDefinitionID) {
        decks.removeValue(forKey: id)
        pageCounts.removeValue(forKey: id)
    }

    // MARK: - Persistence

    /// Writes any pending debounced autosave NOW (app termination).
    func flushPendingWrites() {
        autosaveTask?.cancel()
        writeDocument()
    }

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.autosaveDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.writeDocument()
        }
    }

    private func writeDocument() {
        var decks: [String: DeckPageState] = [:]
        for (id, state) in self.decks {
            decks[id.rawValue.uuidString] = state
        }
        documentStore?.save(PresentationDeckDocument(decks: decks))
    }

    private func publishSnapshot() {
        var states: [String: DeckPageState] = [:]
        for (id, state) in decks {
            states[id.rawValue.uuidString] = state
        }
        PDFDeckStateStore.shared.publish(states)
    }
}

// MARK: - Page-rendering engine

/// G06 (issue #113): the pull-based page renderer for ONE registry PDF
/// source. Implements the A02 `MediaFrameSource` contract so frames flow
/// through the existing media path once the pool hook (file header, hook 2)
/// registers it: the composition engines' render tick pulls the current
/// page's raster, preview and program read the SAME page state, and page
/// controls never enter the output — only the rasterized page does.
///
/// **Clock discipline.** There is no playhead: `pullFrame` renders the page
/// the deck snapshot names (falling back to the payload's default page),
/// cached per page/framing/canvas-aspect. A page command writes the deck
/// store; the next tick's pull rasterizes it once and re-caches.
///
/// **Threading.** `load`/status callbacks run on the main actor (pool /
/// observers); `pullFrame` runs on the composition engine actors. All mutable
/// state sits behind one unfair lock; observer closures never reenter it.
final class PDFSourcePlayback: MediaFrameSource, @unchecked Sendable {
    let sourceID: SourceDefinitionID
    /// Live payload reads (a relink — a different `assetIdentifier` — reloads
    /// the document in place). Reads the pool-published `SourcePayloadStore`,
    /// exactly like the A02 media path.
    private let payloadProvider: @Sendable () -> PDFSourcePayload?
    /// Resolves the payload's asset ID to a readable URL with its access
    /// grant held (P03 `AssetLibraryStore.access(for:)`); main-actor, called
    /// from `performLoad`. The returned token is retained for the engine's
    /// lifetime (the A02 session-held security-scope pattern).
    private let assetAccessProvider: @MainActor @Sendable (String) -> ResolvedAssetAccess?
    /// The current deck state for this source (page + framing) from the
    /// process-wide snapshot — nil before the deck is ever navigated.
    private let deckStateProvider: @Sendable () -> DeckPageState?
    /// Pool/controller-wired: the output canvas size, so `.fill` framing
    /// crops pages to the OUTPUT aspect. Nil = fill degrades to fit.
    var canvasSizeProvider: (@Sendable () -> CGSize?)?
    /// Pool-wired: status mirror for the inspector. Fired off the lock (the
    /// A02 observer rule — the pool hops actors).
    var onStatus: (@Sendable (SourceDefinitionID, PDFSourceStatus) -> Void)?

    /// Rasterization cap: the long side of a rendered page in pixels. 1920
    /// covers a 1080p canvas with headroom; the renderer scales from here.
    static let rasterLongSide = 1920

    private var lock = os_unfair_lock_s()
    private var document: PDFDocument?
    /// The held P03 access grant for the loaded document.
    private var accessToken: ResolvedAssetAccess?
    private var pageCount = 0
    /// Raster cache by page index for the CURRENT render configuration
    /// (framing + canvas aspect); a configuration change clears it.
    private var pageBuffers: [Int: CVPixelBuffer] = [:]
    private var cacheSignature = ""
    private var status = PDFSourceStatus()
    private var didLoad = false
    private var loadedAssetIdentifier: String?
    private var loadTask: Task<Void, Never>?

    init(sourceID: SourceDefinitionID,
         payloadProvider: @escaping @Sendable () -> PDFSourcePayload?,
         assetAccessProvider: @escaping @MainActor @Sendable (String) -> ResolvedAssetAccess?,
         deckStateProvider: @escaping @Sendable () -> DeckPageState?) {
        self.sourceID = sourceID
        self.payloadProvider = payloadProvider
        self.assetAccessProvider = assetAccessProvider
        self.deckStateProvider = deckStateProvider
    }

    /// The pool-hook convenience: payload from the registry's live
    /// `SourcePayloadStore`, asset access from the P03 library, deck state
    /// from the process-wide snapshot.
    @MainActor
    convenience init(sourceID: SourceDefinitionID, assetLibrary: AssetLibraryStore) {
        self.init(
            sourceID: sourceID,
            payloadProvider: {
                guard case .pdf(let payload) = SourcePayloadStore.shared.snapshot()[sourceID]
                else { return nil }
                return payload
            },
            assetAccessProvider: { identifier in
                guard let uuid = UUID(uuidString: identifier) else { return nil }
                return assetLibrary.access(for: AssetID(uuid))
            },
            deckStateProvider: {
                PDFDeckStateStore.shared.snapshot()[sourceID.rawValue.uuidString]
            })
    }

    // MARK: - Loading

    /// Resolves the asset and loads the document. No-op once loaded (or while
    /// a load is in flight) — the pool's demand-driven start calls this on
    /// first scene reference, exactly like the A02 media load.
    func load() {
        os_unfair_lock_lock(&lock)
        guard !didLoad, loadTask == nil else {
            os_unfair_lock_unlock(&lock)
            return
        }
        status.phase = .loading
        status.errorMessage = nil
        publishStatusLocked()
        os_unfair_lock_unlock(&lock)
        loadTask = Task { [weak self] in
            await self?.performLoad()
        }
    }

    @MainActor
    private func performLoad() {
        guard let payload = payloadProvider() else {
            fail("The presentation source has no registered payload — relink it to a document.")
            return
        }
        guard let identifier = payload.assetIdentifier, !identifier.isEmpty else {
            fail("No document is linked — import a PDF for this source.")
            return
        }
        guard let access = assetAccessProvider(identifier), access.isAccessible else {
            fail("The document is unavailable — relink it in the asset library to restore access.")
            return
        }
        switch PDFSourceClassifier.probe(url: access.url) {
        case .failure(let error):
            fail(error.message)
            return
        case .success(let contents):
            // PDFDocument is not Sendable; it is built and only ever read on
            // the loading actor and (under the engine lock) the render tick.
            guard let document = PDFDocument(url: contents.fileURL) else {
                fail("The document could not be reopened for rendering.")
                return
            }
            os_unfair_lock_lock(&lock)
            self.document = document
            accessToken = access
            pageCount = contents.pageCount
            pageBuffers = [:]
            loadedAssetIdentifier = identifier
            didLoad = true
            status.phase = .ready
            status.pageCount = contents.pageCount
            status.currentPage = currentPageLocked()
            status.errorMessage = nil
            publishStatusLocked()
            loadTask = nil
            os_unfair_lock_unlock(&lock)
        }
    }

    private func fail(_ message: String) {
        os_unfair_lock_lock(&lock)
        document = nil
        accessToken = nil
        pageBuffers = [:]
        status.phase = .error
        status.errorMessage = message
        publishStatusLocked()
        loadTask = nil
        os_unfair_lock_unlock(&lock)
    }

    // MARK: - Frame pulling (composition engine tick)

    /// The composition engines' per-tick read: the raster of the page the
    /// deck state names right now. A source with no pixels (loading, error,
    /// missing document) returns nil — the renderer's paint-nothing fallback,
    /// so page controls and chrome never enter the output.
    func pullFrame() -> CVPixelBuffer? {
        os_unfair_lock_lock(&lock)
        // A relink (the registry payload points at a different asset) reloads
        // the document in place; no other source is disturbed.
        if didLoad, let identifier = payloadProvider()?.assetIdentifier,
           identifier != loadedAssetIdentifier {
            teardownLocked()
        }
        if !didLoad, loadTask == nil, status.phase != .loading {
            // Reload after a teardown (relink) — load() manages its own lock,
            // so defer it past the unlock below.
            os_unfair_lock_unlock(&lock)
            load()
            return nil
        }
        guard didLoad, document != nil else {
            os_unfair_lock_unlock(&lock)
            return nil
        }
        let page = currentPageLocked()
        let framing = deckStateProvider()?.framing ?? .fit
        let canvas = canvasSizeProvider?()
        let signature = "\(framing.rawValue):\(Int(canvas?.width ?? 0))x\(Int(canvas?.height ?? 0))"
        if signature != cacheSignature {
            cacheSignature = signature
            pageBuffers = [:]
        }
        if let cached = pageBuffers[page] {
            os_unfair_lock_unlock(&lock)
            return cached
        }
        let rendered = renderPageLocked(page, framing: framing, canvas: canvas)
        if let rendered {
            pageBuffers[page] = rendered
        }
        if status.currentPage != page {
            status.currentPage = page
            publishStatusLocked()
        }
        os_unfair_lock_unlock(&lock)
        return rendered
    }

    /// The page to paint: the deck snapshot's selection (clamped to the
    /// loaded page count), falling back to the payload's default page.
    private func currentPageLocked() -> Int {
        let requested = deckStateProvider()?.page ?? payloadProvider()?.page ?? 0
        return DeckPageState(page: requested).clampedPage(pageCount: pageCount > 0 ? pageCount : nil)
    }

    // MARK: - Demand-loss hold

    /// The pool's demand-loss behavior: nothing to park (pages don't play) —
    /// the document and page state hold for the next reference, exactly like
    /// the A02 pause-mid-file semantics. Explicit page state lives in the
    /// deck store, so a re-referenced source renders the SAME page.
    func pause() {}

    // MARK: - Rasterization

    /// Rasterizes one page into a 32BGRA pixel buffer. `.fit` preserves the
    /// whole page (the renderer's aspect-fit placement letterboxes it);
    /// `.fill` crops the page (centered) to the canvas aspect before
    /// rasterizing, so aspect-fit placement covers the canvas edge to edge.
    /// Pages paint on white first — PDF content assumes paper, and the
    /// renderer's premultiplied-alpha compositing must never see through it.
    private func renderPageLocked(_ index: Int, framing: DeckFraming,
                                  canvas: CGSize?) -> CVPixelBuffer? {
        guard let document,
              let page = document.page(at: index) else { return nil }
        var bounds = page.bounds(for: .mediaBox)
        // `bounds(for:)` is unrotated; 90°/270° pages present swapped.
        if page.rotation % 180 != 0 {
            bounds = CGRect(origin: bounds.origin,
                            size: CGSize(width: bounds.height, height: bounds.width))
        }
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        var drawRect = bounds
        if framing == .fill, let canvas, canvas.width > 0, canvas.height > 0 {
            let canvasAspect = canvas.width / canvas.height
            let pageAspect = bounds.width / bounds.height
            if abs(pageAspect - canvasAspect) > 0.001 {
                var crop = bounds
                if pageAspect > canvasAspect {
                    // Page wider than canvas: crop the sides.
                    crop.size.width = bounds.height * canvasAspect
                } else {
                    // Page taller than canvas: crop top/bottom.
                    crop.size.height = bounds.width / canvasAspect
                }
                crop.origin.x = bounds.midX - crop.width / 2
                crop.origin.y = bounds.midY - crop.height / 2
                drawRect = crop
            }
        }

        let scale = CGFloat(Self.rasterLongSide) / max(drawRect.width, drawRect.height)
        let pixelWidth = max(1, Int((drawRect.width * scale).rounded()))
        let pixelHeight = max(1, Int((drawRect.height * scale).rounded()))

        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, pixelWidth, pixelHeight,
                                  kCVPixelFormatType_32BGRA,
                                  attributes as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard let context = CGContext(
            data: baseAddress, width: pixelWidth, height: pixelHeight,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        // Paper first: the page content composites onto opaque white.
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        // Clip in device space (CTM still identity), then map the draw rect
        // (page space) onto the full buffer.
        context.clip(to: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        context.scaleBy(x: CGFloat(pixelWidth) / drawRect.width,
                        y: CGFloat(pixelHeight) / drawRect.height)
        context.translateBy(x: -drawRect.minX, y: -drawRect.minY)
        page.draw(with: .mediaBox, to: context)
        return buffer
    }

    // MARK: - Teardown

    /// Drops the current document (relink): the raster cache and the held
    /// access grant go, and the next pull re-loads from the new asset.
    private func teardownLocked() {
        document = nil
        accessToken = nil
        pageCount = 0
        pageBuffers = [:]
        didLoad = false
        loadedAssetIdentifier = nil
        status.phase = .idle
        status.pageCount = 0
        status.currentPage = 0
        publishStatusLocked()
    }

    /// Fires the status mirror off-lock on the main actor (the A02/G09
    /// observer rule: the pool hops actors and must never reenter the engine).
    private func publishStatusLocked() {
        let snapshot = status
        let handler = onStatus
        let id = sourceID
        DispatchQueue.main.async { handler?(id, snapshot) }
    }
}
