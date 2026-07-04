import Foundation

/// Access to legacy local HD backup recordings in the App Group container so the
/// app can still import files created by earlier versions.
///
/// The extension and the app are separate processes that never run at the same
/// time in normal use (you leave the app to broadcast, then return). They
/// coordinate purely through the filesystem:
///
///  - The extension writes `Stream-<timestamp>.mp4` while broadcasting, using
///    AVAssetWriter movie fragments so the file stays playable even if the
///    extension is force-killed mid-stream.
///  - On a clean finish it drops a `.complete` sidecar marker next to the file.
///  - The app imports any recording that is marked complete, OR any orphan whose
///    file has been untouched long enough that the extension is certainly gone
///    (crash / OOM recovery). After a successful Photos import it deletes both.
///
/// `Sendable`: holds no mutable state; every method is a pure filesystem op.
public struct RecordingStore: Sendable {

    /// Marker extension appended to a finished recording's URL.
    private static let completeMarker = "complete"
    /// Folder (inside the App Group container) that holds pending backups.
    private static let folderName = "Recordings"

    public init() {}

    // MARK: - Locations

    /// The `Recordings` directory inside the shared App Group container, or nil if
    /// the container is unavailable (misconfigured entitlement).
    public func recordingsDirectory() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier)?
            .appendingPathComponent(Self.folderName, isDirectory: true)
    }

    /// Ensures the recordings directory exists, returning it (or nil on failure).
    /// `AVAssetWriter` does not create intermediate directories, so the extension
    /// must call this before starting a recording.
    @discardableResult
    public func ensureRecordingsDirectory() -> URL? {
        guard let dir = recordingsDirectory() else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A unique, timestamped `.mp4` URL for a new recording (the file is not
    /// created here). Returns nil if the container is unavailable.
    public func makeRecordingURL(date: Date) -> URL? {
        guard let dir = ensureRecordingsDirectory() else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let name = "Stream-\(formatter.string(from: date)).mp4"
        return dir.appendingPathComponent(name)
    }

    // MARK: - Completion / listing

    private func markerURL(for recording: URL) -> URL {
        recording.appendingPathExtension(Self.completeMarker)
    }

    /// Writes the `.complete` sidecar for a cleanly-finished recording.
    public func markComplete(_ recording: URL) {
        FileManager.default.createFile(atPath: markerURL(for: recording).path, contents: nil)
    }

    /// Recordings ready to import: those with a completion marker, plus orphans
    /// (no marker) whose file has not been modified within `staleAfter` seconds —
    /// the extension that owned them has certainly exited. Sorted oldest-first.
    public func pendingRecordings(now: Date, staleAfter: TimeInterval = 30) -> [URL] {
        guard let dir = recordingsDirectory(),
              let entries = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]) else { return [] }

        let recordings = entries.filter { $0.pathExtension.lowercased() == "mp4" }
        let ready = recordings.filter { url in
            if FileManager.default.fileExists(atPath: markerURL(for: url).path) { return true }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantFuture
            return now.timeIntervalSince(modified) >= staleAfter
        }
        return ready.sorted { lhs, rhs in
            let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return l < r
        }
    }

    /// Removes a recording and its completion marker (called after a successful
    /// Photos import).
    public func remove(_ recording: URL) {
        try? FileManager.default.removeItem(at: recording)
        try? FileManager.default.removeItem(at: markerURL(for: recording))
    }

    // MARK: - Disk guard

    /// True when at least `minBytes` of capacity is available on the volume backing
    /// the container. Used to skip recording when storage is low rather than
    /// failing the writer mid-broadcast. Defaults to ~1 GB.
    ///
    /// Deliberately uses the FAST `.volumeAvailableCapacityKey` (a plain `statfs`),
    /// NOT `.volumeAvailableCapacityForImportantUsageKey` — the latter computes
    /// purgeable space and can block for seconds. Because this runs on the
    /// broadcast-start path (only when backup is enabled), a slow probe there
    /// stalls the whole broadcast, which presents to the user as a freeze.
    public func hasSufficientSpace(minBytes: Int = 1_000_000_000) -> Bool {
        guard let dir = recordingsDirectory(),
              let values = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
              let available = values.volumeAvailableCapacity else {
            // Unknown — don't block recording on a failed probe.
            return true
        }
        return available >= minBytes
    }
}
