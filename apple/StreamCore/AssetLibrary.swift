import Foundation

// MARK: - P03 (issue #80): the asset library model
//
// The asset library is the project's single inventory of user-picked files and
// folders (video, audio, images, documents, folders). Two ownership modes:
//
//  - **Project copy** (`AssetStorage.projectCopy`): the file is COPIED into
//    the App Group container's `Assets/` folder at import time, so the project
//    owns the bytes. Copies deduplicate by content hash (importing the same
//    file twice references the existing copy).
//  - **Linked reference** (`AssetStorage.linked`): the file stays where the
//    user keeps it; the sandboxed access grant persists as an app-scope
//    SECURITY-SCOPED BOOKMARK (A02's pattern — the raw URL alone would not
//    reopen across launches).
//
// The model is pure value types in StreamCore so the import/dedup/availability
// logic is unit-testable without a host app. The persisted document follows
// the established additive-wire rule: every field decodes with a default so
// older/partial files keep loading (StreamSettings/SceneDocument precedent).

/// Phantom-free UUID wrapper (StreamCore has no `GraphID`; the library is
/// process-agnostic like the rest of StreamCore). Encodes as a bare UUID
/// string for a stable, diff-friendly wire format.
public struct AssetID: Hashable, Codable, Sendable, CustomStringConvertible {
    public var rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UUID.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue.uuidString }
}

/// What an asset IS, for display (kind icon/label) and consumer filtering
/// (media playout wants video, the soundboard wants audio, overlays want
/// images). Inferred from the file extension at import; folders are their
/// own kind.
public enum AssetKind: String, Codable, CaseIterable, Sendable {
    case video, audio, image, document, folder, other

    public var displayName: String {
        switch self {
        case .video: return "Video"
        case .audio: return "Audio"
        case .image: return "Image"
        case .document: return "Document"
        case .folder: return "Folder"
        case .other: return "File"
        }
    }

    /// SF Symbol name for the row badge.
    public var systemImage: String {
        switch self {
        case .video: return "film"
        case .audio: return "waveform"
        case .image: return "photo"
        case .document: return "doc"
        case .folder: return "folder"
        case .other: return "doc.questionmark"
        }
    }

    /// Extension-based inference (lowercased, no dot). No I/O and no
    /// UniformTypeIdentifiers dependency, so it runs in StreamCore tests.
    public static func inferring(fromExtension ext: String, isDirectory: Bool = false) -> AssetKind {
        if isDirectory { return .folder }
        switch ext.lowercased() {
        case "mp4", "mov", "m4v", "mkv", "webm", "avi", "prores": return .video
        case "mp3", "aac", "m4a", "wav", "aiff", "aif", "flac", "ogg", "caf": return .audio
        case "png", "jpg", "jpeg", "gif", "heic", "tiff", "tif", "bmp", "webp", "svg": return .image
        case "pdf", "txt", "rtf", "md", "doc", "docx", "pages": return .document
        default: return .other
        }
    }
}

/// Who owns the bytes: a copy inside the project's App Group container, or a
/// linked reference to a user-managed location via a security-scoped bookmark.
public enum AssetStorage: String, Codable, CaseIterable, Sendable {
    /// Copied into the container at import; survives moves of the original.
    case projectCopy
    /// The original file/folder stays put; a bookmark retains sandbox access.
    case linked

    public var displayName: String {
        switch self {
        case .projectCopy: return "Copied into Project"
        case .linked: return "Linked"
        }
    }
}

/// Descriptive metadata gathered at import time (size, type, and — when the
/// store can read it cheaply — media duration / image dimensions). Every
/// field is optional: metadata is best-effort and never gates availability.
public struct AssetMetadata: Hashable, Codable, Sendable {
    public var byteSize: Int64? = nil
    /// Uniform type identifier (e.g. "public.mpeg-4"), when known.
    public var contentType: String? = nil
    /// AV media duration in seconds (video/audio only).
    public var durationSeconds: Double? = nil
    /// Pixel dimensions (images/video frames), when readable.
    public var pixelWidth: Int? = nil
    public var pixelHeight: Int? = nil

    public init(byteSize: Int64? = nil,
                contentType: String? = nil,
                durationSeconds: Double? = nil,
                pixelWidth: Int? = nil,
                pixelHeight: Int? = nil) {
        self.byteSize = byteSize
        self.contentType = contentType
        self.durationSeconds = durationSeconds
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    /// Additive decode: files written before a field existed keep loading.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        byteSize = try container.decodeIfPresent(Int64.self, forKey: .byteSize)
        contentType = try container.decodeIfPresent(String.self, forKey: .contentType)
        durationSeconds = try container.decodeIfPresent(Double.self, forKey: .durationSeconds)
        pixelWidth = try container.decodeIfPresent(Int.self, forKey: .pixelWidth)
        pixelHeight = try container.decodeIfPresent(Int.self, forKey: .pixelHeight)
    }
}

/// One library asset. The stable `id` survives relink/replace (a moved file
/// gets a new bookmark; swapped content gets a new hash/copy — neither
/// changes the identity usage sites reference).
public struct LibraryAsset: Identifiable, Hashable, Codable, Sendable {
    public var id: AssetID
    /// Display name (defaults to the file's base name at import; editable).
    public var name: String
    public var kind: AssetKind
    public var storage: AssetStorage
    /// The sandbox access grant for LINKED assets (nil until/unless the
    /// bookmark could be created — such an asset starts missing/repairable).
    public var bookmarkData: Data? = nil
    /// For PROJECT COPIES: the path inside the App Group container's
    /// `Assets/` folder (`<asset-uuid>/<original-name>`). Nil for linked.
    public var relativePath: String? = nil
    /// The original file's display name (bookmarks don't round-trip one).
    public var fileName: String
    /// SHA-256 of the file's bytes at import/replace (hex). Drives
    /// project-copy dedup; nil for folders and unreadable files.
    public var contentHash: String? = nil
    /// The last absolute path the asset resolved to — the repair dialog's
    /// "was at" hint. Display only; the bookmark/copy is the authority.
    public var lastKnownPath: String
    public var metadata: AssetMetadata
    public var addedAt: Date

    public init(id: AssetID = AssetID(),
                name: String,
                kind: AssetKind,
                storage: AssetStorage,
                bookmarkData: Data? = nil,
                relativePath: String? = nil,
                fileName: String,
                contentHash: String? = nil,
                lastKnownPath: String,
                metadata: AssetMetadata = AssetMetadata(),
                addedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.kind = kind
        self.storage = storage
        self.bookmarkData = bookmarkData
        self.relativePath = relativePath
        self.fileName = fileName
        self.contentHash = contentHash
        self.lastKnownPath = lastKnownPath
        self.metadata = metadata
        self.addedAt = addedAt
    }

    /// Additive decode (the SoundPad/MediaSourcePayload precedent): documents
    /// written before later P03 refinements keep loading.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(AssetID.self, forKey: .id) ?? AssetID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Asset"
        kind = try container.decodeIfPresent(AssetKind.self, forKey: .kind) ?? .other
        storage = try container.decodeIfPresent(AssetStorage.self, forKey: .storage) ?? .linked
        bookmarkData = try container.decodeIfPresent(Data.self, forKey: .bookmarkData)
        relativePath = try container.decodeIfPresent(String.self, forKey: .relativePath)
        fileName = try container.decodeIfPresent(String.self, forKey: .fileName) ?? "file"
        contentHash = try container.decodeIfPresent(String.self, forKey: .contentHash)
        lastKnownPath = try container.decodeIfPresent(String.self, forKey: .lastKnownPath) ?? ""
        metadata = try container.decodeIfPresent(AssetMetadata.self, forKey: .metadata) ?? AssetMetadata()
        addedAt = try container.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date.distantPast
    }
}

/// A usage site is a namespaced, consumer-owned string key —
/// "mediaSource/<uuid>", "soundPad/<uuid>", "overlay/<uuid>" — so every
/// downstream consumer (G01/G06/G08/E04) registers usage without the library
/// knowing their model types. One site key can reference many assets; an
/// asset's "Used by" list is the sites whose sets contain it.
public struct AssetLibraryDocument: Hashable, Codable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var assets: [LibraryAsset]
    /// Usage site key → referenced asset IDs (sorted for a stable wire).
    public var usage: [String: [AssetID]]

    public init(version: Int = AssetLibraryDocument.currentVersion,
                assets: [LibraryAsset] = [],
                usage: [String: [AssetID]] = [:]) {
        self.version = version
        self.assets = assets
        self.usage = usage
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version)
            ?? AssetLibraryDocument.currentVersion
        assets = try container.decodeIfPresent([LibraryAsset].self, forKey: .assets) ?? []
        usage = try container.decodeIfPresent([String: [AssetID]].self, forKey: .usage) ?? [:]
    }

    /// The sites referencing an asset, in stable sorted order.
    public func usageSites(of id: AssetID) -> [String] {
        usage.filter { $0.value.contains(id) }.map(\.key).sorted()
    }

    /// Records that `site` references `id` (idempotent per site/asset pair).
    public mutating func recordUsage(site: String, assetID: AssetID) {
        let trimmed = site.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, assets.contains(where: { $0.id == assetID }) else { return }
        var ids = usage[trimmed] ?? []
        guard !ids.contains(assetID) else { return }
        ids.append(assetID)
        ids.sort { $0.rawValue.uuidString < $1.rawValue.uuidString }
        usage[trimmed] = ids
    }

    /// Removes one site→asset edge (no-op when absent).
    public mutating func removeUsage(site: String, assetID: AssetID) {
        guard var ids = usage[site] else { return }
        ids.removeAll { $0 == assetID }
        usage[site] = ids.isEmpty ? nil : ids
    }

    /// Drops every edge from a site (consumer tearing down its references).
    public mutating func removeAllUsage(site: String) {
        usage[site] = nil
    }

    /// Drops edges to assets that no longer exist (load-time hygiene, the
    /// `pruneBrowserMetadata` precedent).
    public mutating func pruneUsage() {
        let existing = Set(assets.map(\.id))
        usage = usage.compactMapValues { ids in
            let pruned = ids.filter { existing.contains($0) }
            return pruned.isEmpty ? nil : pruned
        }
    }
}
