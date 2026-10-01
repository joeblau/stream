import Foundation

// MARK: - P03 (issue #80): availability (missing-file) logic + bookmark codec
//
// Availability is SESSION state, recomputed by probing — never persisted:
// a file moved while the app was quit must read as missing on next launch,
// not as whatever the last autosave recorded. Probing is asynchronous and
// per-asset, so a missing file (moved, access revoked, external disk
// disconnected) surfaces as a REPAIRABLE missing state on that row without
// stalling anything else — the evaluator below is the pure decision core,
// pinned by tests; the store gathers probe inputs off the main actor.

/// Why an asset is missing. Each reason maps to a repair path in the UI.
public enum AssetMissingReason: String, Codable, CaseIterable, Sendable {
    /// No file was ever linked (bookmark creation failed at import).
    case notLinked
    /// The bookmark no longer resolves at all (target deleted or the volume
    /// it lived on is gone and macOS can't rebuild the path).
    case bookmarkUnresolvable
    /// The bookmark resolved but the file isn't there (moved/deleted).
    case fileMovedOrDeleted
    /// The file sits on a volume that isn't mounted right now.
    case externalVolumeDisconnected
    /// The bookmark resolves but the sandbox refused access (revoked grant).
    case accessRevoked
    /// The project-owned copy is missing from the App Group container.
    case projectCopyMissing

    public var displayName: String {
        switch self {
        case .notLinked: return "No File Linked"
        case .bookmarkUnresolvable: return "Link Broken"
        case .fileMovedOrDeleted: return "Moved or Deleted"
        case .externalVolumeDisconnected: return "External Disk Disconnected"
        case .accessRevoked: return "Access Revoked"
        case .projectCopyMissing: return "Project Copy Missing"
        }
    }
}

/// An asset's availability. `unknown` is the pre-probe state: the library
/// never asserts availability until a probe ran (no false green rows).
public enum AssetAvailability: Equatable, Sendable {
    case unknown
    case available
    case missing(AssetMissingReason)

    public var isAvailable: Bool { self == .available }

    public var missingReason: AssetMissingReason? {
        if case .missing(let reason) = self { return reason }
        return nil
    }
}

/// The raw inputs one availability probe gathered. Kept as a plain value so
/// the evaluation rules are testable without touching the filesystem.
public struct AssetAvailabilityProbe: Equatable, Sendable {
    public var storage: AssetStorage
    /// Project copies: whether the container file exists. Unused for linked.
    public var projectCopyExists: Bool = false
    /// Linked assets: whether a bookmark exists at all.
    public var hasBookmark: Bool = false
    /// Linked assets: whether the bookmark resolved to a URL.
    public var bookmarkResolved: Bool = false
    /// Linked assets: macOS marked the bookmark stale (still resolved; the
    /// store refreshes the stored bookmark — not itself a missing state).
    public var bookmarkStale: Bool = false
    /// Linked assets: whether the resolved path exists on disk.
    public var resolvedFileExists: Bool = false
    /// Linked assets: whether the resolved file's volume is mounted (only
    /// consulted when the file is missing — distinguishes "moved" from
    /// "disk disconnected").
    public var volumeMounted: Bool = true
    /// Linked assets: whether the sandbox granted access to the resolved URL.
    public var accessGranted: Bool = false

    public init(storage: AssetStorage,
                projectCopyExists: Bool = false,
                hasBookmark: Bool = false,
                bookmarkResolved: Bool = false,
                bookmarkStale: Bool = false,
                resolvedFileExists: Bool = false,
                volumeMounted: Bool = true,
                accessGranted: Bool = false) {
        self.storage = storage
        self.projectCopyExists = projectCopyExists
        self.hasBookmark = hasBookmark
        self.bookmarkResolved = bookmarkResolved
        self.bookmarkStale = bookmarkStale
        self.resolvedFileExists = resolvedFileExists
        self.volumeMounted = volumeMounted
        self.accessGranted = accessGranted
    }
}

/// The missing-state decision table. Order matters: more specific structural
/// failures (no bookmark, unresolvable) outrank content failures (missing
/// file), and a disconnected volume outranks "moved" (the file may be fine —
/// the disk just isn't here).
public enum AssetAvailabilityEvaluator {

    public static func evaluate(_ probe: AssetAvailabilityProbe) -> AssetAvailability {
        switch probe.storage {
        case .projectCopy:
            return probe.projectCopyExists ? .available : .missing(.projectCopyMissing)
        case .linked:
            guard probe.hasBookmark else { return .missing(.notLinked) }
            guard probe.bookmarkResolved else { return .missing(.bookmarkUnresolvable) }
            guard probe.resolvedFileExists else {
                return .missing(probe.volumeMounted
                                ? .fileMovedOrDeleted
                                : .externalVolumeDisconnected)
            }
            guard probe.accessGranted else { return .missing(.accessRevoked) }
            return .available
        }
    }
}

/// Security-scoped bookmark creation/resolution (the persisted sandbox
/// access grant, A02's pattern). Creation tries `.withSecurityScope` first
/// and falls back to a plain bookmark: local dev builds run with
/// CODE_SIGNING_ALLOWED=NO (no entitlements applied), so a hard failure there
/// would make every import unusable while developing — the degraded bookmark
/// still round-trips the path, and the availability probe honestly reports
/// `.accessRevoked` if the sandbox later refuses the plain grant.
public enum AssetBookmarkCodec {

    public struct ResolvedBookmark: Equatable, Sendable {
        public let url: URL
        /// macOS considers the bookmark stale — still usable, but the caller
        /// should refresh the stored bookmark from the resolved URL.
        public let isStale: Bool
    }

    /// The persisted access grant for a user-picked file/folder, or nil when
    /// no bookmark could be created at all. Security scope is macOS-only in
    /// Foundation; iOS builds (StreamCore's tests) fall back to plain
    /// bookmarks, as do macOS dev builds running without entitlements
    /// (CODE_SIGNING_ALLOWED=NO) — the degraded bookmark still round-trips
    /// the path, and the availability probe honestly reports `.accessRevoked`
    /// if the sandbox later refuses the plain grant.
    public static func makeBookmark(for url: URL) -> Data? {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        #if os(macOS)
        if let scoped = try? url.bookmarkData(options: [.withSecurityScope],
                                              includingResourceValuesForKeys: nil,
                                              relativeTo: nil) {
            return scoped
        }
        #endif
        return try? url.bookmarkData(options: [],
                                     includingResourceValuesForKeys: nil,
                                     relativeTo: nil)
    }

    /// Resolves a persisted bookmark. Does NOT start security-scope access —
    /// that's the caller's job (access is held by the consumer that reads
    /// the bytes; see `ResolvedAssetAccess` on the StreamMac side). Bookmarks
    /// created in the degraded (non-security-scoped) fallback are resolved
    /// without the scope option — a hard failure there would strand every
    /// asset imported by a local dev build.
    public static func resolve(_ bookmark: Data) -> ResolvedBookmark? {
        var isStale = false
        #if os(macOS)
        if let url = try? URL(resolvingBookmarkData: bookmark,
                              options: [.withSecurityScope],
                              relativeTo: nil,
                              bookmarkDataIsStale: &isStale) {
            return ResolvedBookmark(url: url, isStale: isStale)
        }
        #endif
        guard let url = try? URL(resolvingBookmarkData: bookmark,
                                 options: [],
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &isStale) else { return nil }
        return ResolvedBookmark(url: url, isStale: isStale)
    }

    /// Rebuilds the stored bookmark for a resolved URL (staleness refresh).
    /// Nil means "keep the old bookmark" — never blank a working grant.
    public static func refreshedBookmark(for url: URL) -> Data? {
        makeBookmark(for: url)
    }
}
