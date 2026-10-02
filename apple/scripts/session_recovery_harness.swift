import Foundation
import StreamCore

private final class GrantCounter: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    func released() { lock.lock(); count += 1; lock.unlock() }
    var releases: Int { lock.lock(); defer { lock.unlock() }; return count }
}
private final class GrantOwner {
    let counter: GrantCounter
    init(_ counter: GrantCounter) { self.counter = counter }
    deinit { counter.released() }
}
@main struct SessionRecoveryHarness {
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("StreamRecoveryHarness-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = UUID(), profile = UUID(), outputID = UUID(), markerID = UUID(), recordingID = UUID()
        let original = SessionRecoveryCoordinator(directory: directory)
        var snapshot = SessionRecoverySnapshot(projectID: project, profileID: profile)
        snapshot.hasStagedEdits = true; snapshot.activeOutputIDs = [outputID]
        snapshot.remoteEvents = [.init(outputID: outputID)]
        snapshot.recordings = [.init(sessionID: recordingID, index: 2, file: "Segment2.mp4", status: .partial, duration: 12,
                                     markers: [.init(id: markerID, seconds: 3.5)])]
        let scenes = (0..<100).map { _ in UUID() }
        for scene in scenes { snapshot.programSceneID = scene; original.checkpoint(snapshot) }
        await original.flush()
        let current = try SessionRecoveryDiskStore.read(directory.appendingPathComponent("current.v1.json"))!
        precondition(current.programSceneID == scenes.last && current.id == original.sessionID)
        // Simulate a process ending without a clean shutdown callback.
        let restarted = SessionRecoveryCoordinator(directory: directory)
        precondition(restarted.pending?.id == original.sessionID && restarted.showReview)
        var restoreCalls = 0
        restarted.restoreLocalContext = { received in
            restoreCalls += 1
            precondition(received.projectID == project && received.recordings[0].markers[0].seconds == 3.5)
        }
        precondition(restoreCalls == 0, "Launch must only offer review, never restore or replay commands")
        let newProject = UUID(), newProfile = UUID()
        restarted.beginContext(projectID: newProject, profileID: newProfile)
        let newSnapshot = SessionRecoverySnapshot(projectID: newProject, profileID: newProfile)
        restarted.checkpoint(newSnapshot); await restarted.flush()
        // Late prior-runtime results cannot overwrite the selected project.
        restarted.checkpoint(snapshot); await restarted.flush()
        let selectedCurrent = try SessionRecoveryDiskStore.read(directory.appendingPathComponent("current.v1.json"))!
        precondition(selectedCurrent.projectID == newProject)
        let secondRestart = SessionRecoveryCoordinator(directory: directory)
        precondition(secondRestart.pending?.id == original.sessionID, "Pending recovery must survive a second interruption")
        precondition(restoreCalls == 0)
        await restarted.restore(); precondition(restoreCalls == 1)
        await restarted.dismiss()
        await restarted.finishCurrentSession()
        precondition(SessionRecoveryCoordinator(directory: directory).pending == nil)
        var stillRecording = newSnapshot; stillRecording.recordingWasActive = true
        restarted.checkpoint(stillRecording); await restarted.finishCurrentSession()
        precondition(SessionRecoveryCoordinator(directory: directory).pending != nil)

        let corruptDirectory = directory.appendingPathComponent("Corrupt")
        try FileManager.default.createDirectory(at: corruptDirectory, withIntermediateDirectories: true)
        let corruptURL = corruptDirectory.appendingPathComponent("current.v1.json"), corruptBytes = Data("broken journal".utf8)
        try corruptBytes.write(to: corruptURL)
        let corrupt = SessionRecoveryCoordinator(directory: corruptDirectory)
        precondition(corrupt.error != nil)
        corrupt.checkpoint(newSnapshot); await corrupt.flush()
        let preserved = try Data(contentsOf: corruptURL)
        precondition(preserved == corruptBytes && corrupt.error != nil)

        let recordings = directory.appendingPathComponent("Recordings")
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        let fixture: [String: Any] = [
            "sessionID": recordingID.uuidString, "segmentIndex": 2, "file": "Segment2.mp4",
            "context": ["projectID": project.uuidString, "profileID": profile.uuidString, "projectName": "secret-name-sentinel"],
            "status": "recoverable", "progress": ["durationSeconds": 12.0],
            "markers": [["id": markerID.uuidString, "seconds": 3.5, "title": "secret-marker-sentinel"]],
            "error": "https://private.invalid?token=secret-error-sentinel", "streamKey": "secret-key-sentinel"
        ]
        try JSONSerialization.data(withJSONObject: fixture).write(to: recordings.appendingPathComponent("Segment2.mp4.recording.json"))
        let counter = GrantCounter()
        var owner: GrantOwner? = GrantOwner(counter)
        var grant: SessionRecoveryDirectoryGrant? = SessionRecoveryDirectoryGrant(url: recordings, retaining: owner)
        owner = nil
        let inventory = try await SessionRecordingJournalReader.read(grant: grant!, projectID: project, profileID: profile, activeFiles: ["Segment2.mp4"])
        precondition(counter.releases == 0 && inventory.isVerified && inventory.segments.count == 1)
        precondition(inventory.segments[0].sessionID == recordingID && inventory.segments[0].index == 2 && inventory.segments[0].markers[0].id == markerID)
        let encoded = String(decoding: try JSONEncoder().encode(inventory.segments), as: UTF8.self)
        precondition(!encoded.contains("sentinel") && !encoded.contains("private.invalid"), "Actual recording journals must be allowlisted, never copied raw")
        grant = nil; precondition(counter.releases == 1)
        let missing = try await SessionRecordingJournalReader.read(grant: .init(url: recordings), projectID: project, profileID: profile, activeFiles: ["Missing.mp4"])
        precondition(!missing.isVerified)
        let wrongProfile = try await SessionRecordingJournalReader.read(grant: .init(url: recordings), projectID: project, profileID: UUID())
        precondition(wrongProfile.segments.isEmpty)
        print("PASS: shipping recovery coordinator/store and actual recording-journal reader; interrupted/second restart, explicit-only restoration, project-token isolation, bounded burst coalescing/atomic files, conservative recording shutdown, corrupt-byte preservation, actual segment/marker identity and timing, credential/title/path redaction, selected-profile inventory, directory grant lifetime; \(ProcessInfo.processInfo.operatingSystemVersionString)")
    }
}
