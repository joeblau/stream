import Foundation
import StreamCore

/// Holds the actual recorder's directory access token through background I/O.
final class SessionRecoveryDirectoryGrant: @unchecked Sendable {
    let url: URL
    private let owner: AnyObject?
    init(url: URL, retaining owner: AnyObject? = nil) { self.url = url; self.owner = owner }
}
struct SessionRecoveryRecordingInventory: Sendable {
    var segments: [SessionRecoverySegment] = []
    var isVerified = false
}
enum SessionRecordingJournalReader {
    private struct Journal: Decodable {
        struct Context: Decodable { var projectID: String?; var profileID: String? }
        struct Marker: Decodable { var id: UUID; var seconds: Double }
        struct Progress: Decodable { var durationSeconds: Double? }
        var sessionID: String
        var segmentIndex: Int
        var file: String
        var context: Context
        var status: String
        var markers: [Marker]?
        var progress: Progress?
    }
    static func read(grant: SessionRecoveryDirectoryGrant, projectID: UUID, profileID: UUID,
                     activeFiles: Set<String> = []) async throws -> SessionRecoveryRecordingInventory {
        try await Task.detached(priority: .utility) {
            try withExtendedLifetime(grant) {
                guard let enumerator = FileManager.default.enumerator(at: grant.url, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey], options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) else { throw CocoaError(.fileReadNoSuchFile) }
                var latest: [(URL, Date)] = []
                var seen = 0, skipped = false
                while let url = enumerator.nextObject() as? URL, seen < 5_000 {
                    seen += 1
                    guard url.lastPathComponent.hasSuffix(".recording.json") else { continue }
                    let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                    guard (values.fileSize ?? Int.max) <= 1_048_576 else { skipped = true; continue }
                    latest.append((url, values.contentModificationDate ?? .distantPast))
                    latest.sort { $0.1 > $1.1 }; if latest.count > 200 { latest.removeLast() }
                }
                var result = SessionRecoveryRecordingInventory(isVerified: seen < 5_000 && !skipped)
                var recognized: Set<String> = [], markerBudget = 4_000
                for (url, _) in latest {
                    guard let journal = try? JSONDecoder().decode(Journal.self, from: Data(contentsOf: url)) else { result.isVerified = false; continue }
                    guard UUID(uuidString: journal.context.projectID ?? "") == projectID,
                          UUID(uuidString: journal.context.profileID ?? "") == profileID,
                          let id = UUID(uuidString: journal.sessionID) else { continue }
                    let markers = (journal.markers ?? []).suffix(min(2_000, markerBudget)).map { SessionRecoveryMarker(id: $0.id, seconds: $0.seconds) }
                    let segment = SessionRecoverySegment(sessionID: id, index: journal.segmentIndex, file: journal.file,
                        status: SessionRecoverySegment.Status(rawValue: journal.status) ?? .unknown,
                        duration: journal.progress?.durationSeconds ?? 0, markers: markers)
                    guard segment.isValid else { result.isVerified = false; continue }
                    result.segments.append(segment); recognized.insert(segment.file); markerBudget -= markers.count
                }
                result.isVerified = result.isVerified && activeFiles.isSubset(of: recognized)
                return result
            }
        }.value
    }
}
