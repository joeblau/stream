import CryptoKit
import Foundation

// MARK: - P03 (issue #80): import planning, content hashing, dedup
//
// Importing a user pick is a two-step decision: hash the bytes, then decide
// whether the library already HAS this content. The issue's dedup rule covers
// PROJECT-OWNED assets: a second "import by copy" of byte-identical content
// reuses the existing copy instead of doubling the container's footprint.
// Linked imports dedup by RESOLVED PATH — linking the same file twice would
// create two rows pointing at one file, which reads as a bug, not a feature.
// A link import of content already present as a project copy is NOT a dedup
// hit (different ownership semantics — the user explicitly chose linking).

/// How the user wants the picked file/folder owned.
public enum AssetImportMode: String, Codable, CaseIterable, Sendable {
    /// Copy the bytes into the App Group container (project-owned).
    case copy
    /// Keep the original in place; persist a security-scoped bookmark.
    case link

    public var displayName: String {
        switch self {
        case .copy: return "Copy into Project"
        case .link: return "Link to Original"
        }
    }
}

/// The planner's verdict for one import candidate.
public enum AssetImportDecision: Equatable, Sendable {
    /// The library already has this asset; return the existing record's ID.
    /// The store performs no file work and adds no row.
    case reuseExisting(AssetID)
    /// No existing asset covers the candidate; proceed with the import.
    case importNew
}

/// Pure decision layer over the current inventory. Kept static and I/O-free
/// so the dedup rules are pinned by unit tests; the store feeds it values.
public enum AssetImportPlanner {

    /// The dedup decision for one import candidate.
    /// - Parameters:
    ///   - mode: copy or link.
    ///   - contentHash: SHA-256 of the candidate's bytes (nil for folders /
    ///     unreadable files — unhashable candidates never dedup by content).
    ///   - resolvedPath: the candidate's standardized absolute path.
    ///   - existing: the current inventory.
    public static func decide(mode: AssetImportMode,
                              contentHash: String?,
                              resolvedPath: String,
                              existing: [LibraryAsset]) -> AssetImportDecision {
        switch mode {
        case .copy:
            if let contentHash,
               let match = existing.first(where: {
                   $0.storage == .projectCopy && $0.contentHash == contentHash
               }) {
                return .reuseExisting(match.id)
            }
            return .importNew
        case .link:
            if let match = existing.first(where: {
                $0.storage == .linked && $0.lastKnownPath == resolvedPath
            }) {
                return .reuseExisting(match.id)
            }
            return .importNew
        }
    }
}

/// SHA-256 content identity. Hashing streams the file in chunks so a
/// multi-GB video never loads into memory at once. The hash covers BYTES
/// only — dedup is content-addressed, not name-addressed (a renamed copy of
/// the same clip still dedups).
public enum AssetContentHasher {

    private static let chunkSize = 1 << 20 // 1 MiB

    /// Hex-encoded SHA-256 of `data`.
    public static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Streams a file's bytes through SHA-256. Returns nil when the file
    /// can't be opened (the caller treats an unhashable candidate as
    /// dedup-ineligible, never as an import failure). Directories return nil
    /// — folder identity is the bookmark, not a hash.
    public static func sha256(contentsOf url: URL) -> String? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = (try? handle.read(upToCount: chunkSize)) ?? nil
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
