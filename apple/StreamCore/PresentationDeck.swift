import Foundation

/// G06 (issue #113): the pure page-state model behind multi-page PDF and
/// slide-image presentation. The StreamMac engine (`PDFSourcePlayback`)
/// rasterizes pages with PDFKit and feeds the deck's document/page counts
/// here; everything that decides WHICH page shows — clamping, next/previous/
/// jump navigation, fit/fill framing, per-source persistence — is plain
/// value math, so it lives in StreamCore and is unit-tested without PDFKit.
///
/// **Page state is per SOURCE, never per layer and never scene content.**
/// Preview and program read the same deck state (the A02 media-playback
/// precedent: one shared instance can never fork between canvases), so a
/// page change composites identically on both engines on their next tick.

/// How a page is framed when the page's aspect ratio differs from the
/// canvas the output renders at.
public enum DeckFraming: String, Codable, CaseIterable, Sendable {
    /// Preserve the whole page; mismatched aspect letterboxes (the
    /// renderer's standard aspect-fit placement).
    case fit
    /// Crop the page (centered) to the canvas aspect before rasterizing, so
    /// the aspect-fit placement covers edge to edge — the slide-deck
    /// "fill the screen" behavior.
    case fill

    public var displayName: String {
        switch self {
        case .fit: return "Fit (Letterbox)"
        case .fill: return "Fill (Crop)"
        }
    }
}

/// One presentation source's durable page state: the selected page (0-based)
/// and its framing. Navigation CLAMPS at both ends — decks don't wrap
/// (a presenter advancing past the last slide stays on it).
public struct DeckPageState: Hashable, Codable, Sendable {
    public var page: Int
    public var framing: DeckFraming

    public init(page: Int = 0, framing: DeckFraming = .fit) {
        self.page = page
        self.framing = framing
    }

    /// The page clamped into `0..<pageCount`. A deck whose page count isn't
    /// known yet (document not loaded) clamps to `page >= 0` only — the
    /// upper clamp lands when the engine reports the count.
    public func clampedPage(pageCount: Int?) -> Int {
        guard let pageCount, pageCount > 0 else { return max(0, page) }
        return min(max(0, page), pageCount - 1)
    }

    /// Next/previous-style relative navigation, clamped to the deck bounds
    /// (never wraps). Returns the new state.
    public func advanced(by delta: Int, pageCount: Int?) -> DeckPageState {
        var copy = self
        copy.page = DeckPageState(page: page + delta).clampedPage(pageCount: pageCount)
        return copy
    }

    /// Absolute jump (0-based), clamped like relative navigation.
    public func jumped(to target: Int, pageCount: Int?) -> DeckPageState {
        var copy = self
        copy.page = DeckPageState(page: target).clampedPage(pageCount: pageCount)
        return copy
    }

    /// Additive-wire decode: documents written before later fields keep
    /// loading (the established Stream document pattern).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        page = try container.decodeIfPresent(Int.self, forKey: .page) ?? 0
        framing = try container.decodeIfPresent(DeckFraming.self, forKey: .framing) ?? .fit
    }
}

/// The persisted presentations document: page state per REGISTRY SOURCE
/// (keyed by the source ID's UUID string — StreamCore has no `GraphID`).
/// Lives beside the PTZ/soundboard documents; it is NOT scene content, so
/// it never stages, Takes, or joins the S12 undo snapshot.
public struct PresentationDeckDocument: Codable, Sendable, Equatable {
    public var version: Int
    /// Source-ID UUID string → page state.
    public var decks: [String: DeckPageState]

    public init(version: Int = 1, decks: [String: DeckPageState] = [:]) {
        self.version = version
        self.decks = decks
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        decks = try container.decodeIfPresent([String: DeckPageState].self, forKey: .decks) ?? [:]
    }
}

/// File IO for the presentations document, mirroring the established
/// document pattern (atomic writes, corrupt-file quarantine, never overwrite
/// unreadable data). The URL is injectable so tests round-trip through a
/// temp file.
public struct PresentationDeckDocumentStore: Sendable {
    public static let fileName = "stream.presentations.v1.json"

    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// The production location: the shared App Group container, beside the
    /// scene, soundboard, and PTZ documents. Nil when the container is
    /// unavailable.
    public static func `default`() -> PresentationDeckDocumentStore? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier)
            .map { PresentationDeckDocumentStore(fileURL: $0.appendingPathComponent(fileName)) }
    }

    /// Loads the document; nil when the file is absent or unreadable. A
    /// present-but-undecodable file is quarantined aside (never overwritten).
    public func load() -> PresentationDeckDocument? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        guard let document = try? JSONDecoder().decode(PresentationDeckDocument.self, from: data)
        else {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            try? FileManager.default.moveItem(
                at: fileURL,
                to: fileURL.appendingPathExtension("corrupt.\(formatter.string(from: Date())).bak"))
            return nil
        }
        return document
    }

    public func save(_ document: PresentationDeckDocument) {
        guard let data = try? JSONEncoder().encode(document) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
