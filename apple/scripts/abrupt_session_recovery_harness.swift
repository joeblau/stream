import AppKit
import AVFoundation
import Combine
import CryptoKit
import Darwin
import Foundation
import StreamCore
import SwiftUI

private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw NSError(domain: "AbruptSessionRecovery", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

private final class WriterReceipt: @unchecked Sendable {
    private let lock = NSLock()
    private var progress = ProgramRecordingSession.Progress()
    private var failure: String?
    func receive(_ event: ProgramRecordingSession.Event) {
        lock.lock(); defer { lock.unlock() }
        if case .progress(let value) = event { progress = value }
        if case .failed(let message) = event { failure = message }
    }
    func read() -> (ProgramRecordingSession.Progress, String?) {
        lock.lock(); defer { lock.unlock() }; return (progress, failure)
    }
}

private struct Ready: Codable {
    let childPID: Int32
    let project: UUID
    let profile: UUID
    let session: UUID
    let scene: UUID
    let layer: UUID
    let media: UUID
    let recording: String
    let duration: Double
}

@MainActor private enum ViewReceipt { static var appeared = false }

@main @MainActor struct AbruptSessionRecoveryHarness {
    static func main() {
        setbuf(stdout, nil)
        let child = CommandLine.arguments.contains("--child")
        print("Stage: \(child ? "owned recorder child" : "recovery parent") started, PID \(getpid())")
        if !child && CGSessionCopyCurrentDictionary() == nil {
            print("UNQUALIFIED: actual recovery review presentation needs a logged-in WindowServer session")
            exit(77)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        if !child { app.finishLaunching() }
        Task { @MainActor in
            do {
                if child { try await recordUntilKilled() } else { try await recover() }
                exit(0)
            } catch {
                let native = error as NSError
                print("FAIL: \(native.localizedDescription); domain=\(native.domain), code=\(native.code); all owned artifacts preserved at \(GuestFixtureStorage.artifactRoot.path)")
                if let underlying = native.userInfo[NSUnderlyingErrorKey] as? NSError {
                    print("Underlying error: domain=\(underlying.domain), code=\(underlying.code)")
                }
                exit(1)
            }
        }
        app.run()
    }

    static func seedCatalog() throws {
        let root = GuestFixtureStorage.machineDirectory
        let catalog = StudioProjectCatalog()
        let directory = root.appendingPathComponent(StudioProjectCatalog.relativeDirectory(
            project: catalog.selectedProjectID, profile: catalog.selectedProfileID), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: GuestFixtureStorage.recordingsDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(catalog).write(to: root.appendingPathComponent("projects.v1.json"), options: .atomic)
    }

    static func recordUntilKilled() async throws {
        print("Stage: child constructing shipping Workspace in owned fixture storage")
        let workspace = StudioWorkspace(root: GuestFixtureStorage.machineDirectory)
        print("Stage: child shipping Workspace constructed")
        let runtime = workspace.runtime
        print("Stage: child creating owned 2-second WAV")
        let mediaURL = try createOwnedMedia()
        print("Stage: child owned WAV created; qualifying exact internal-media validation boundary (no security grant)")
        try qualifyOwnedMediaBoundary(mediaURL)
        let bookmark = try mediaURL.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let resolvedMedia = try AbruptFixtureOwnedMedia.resolve(bookmark)
        try require(resolvedMedia.resolvingSymlinksInPath().path == mediaURL.resolvingSymlinksInPath().path,
                    "Owned ordinary bookmark did not resolve the exact internal WAV")
        print("Stage: child owned internal-media bookmark created; restoring actual paused AVPlayer; external scope UNQUALIFIED")
        let media = runtime.sceneStore.addSource(SourceDefinition(name: "Owned paused media",
            payload: .media(MediaSourcePayload(bookmarkData: bookmark, fileName: mediaURL.lastPathComponent, autoplay: true))))
        runtime.controller.capturePool.restorePausedMediaPosition(media.id, seconds: 1.25)
        try await requirePausedMedia(runtime, id: media.id)
        let layer = LayerNode(name: "Owned recovery layer", payload: .text(TextSourcePayload(text: "Public synthetic fixture")), transform: .fullscreen)
        let scene = runtime.sceneStore.addScene(Scene(name: "Abrupt owned recording", layers: [layer]))
        runtime.previewProgram.setResilienceProgram(scene)
        var staged = scene
        staged.layers[0].transform.position.x = 0.23
        staged.layers[0].isVisible = false
        runtime.previewProgram.stage(staged)
        runtime.flush()

        let sessionID = UUID()
        let output = GuestFixtureStorage.recordingsDirectory.appendingPathComponent("interrupted-program.mp4")
        var configuration = ProgramRecordingSession.Configuration()
        configuration.frameRate = 60
        configuration.sessionID = sessionID.uuidString
        configuration.context = runtime.recorder.context
        let receipt = WriterReceipt()
        let session = ProgramRecordingSession(outputURL: output, configuration: configuration, event: receipt.receive)

        // The actual binding reads the actual writer journals. This owned writer
        // is outside RecordingController, so its real activity has a dedicated
        // publisher instead of falsely using the idle UI recorder's state.
        runtime.recoveryBinding?.shutdown()
        let active = CurrentValueSubject<Bool, Never>(true)
        runtime.recoveryBinding = SessionRecoveryRuntimeBinding(coordinator: workspace.recovery,
            projectID: workspace.selection.project, profileID: workspace.selection.profile,
            sceneStore: runtime.sceneStore, previewProgram: runtime.previewProgram,
            controller: runtime.controller, pdfDecks: runtime.dispatcher.pdfDecks,
            recordingActivity: active.eraseToAnyPublisher(), recordings: {
                try await SessionRecordingJournalReader.read(
                    grant: SessionRecoveryDirectoryGrant(url: GuestFixtureStorage.recordingsDirectory),
                    projectID: workspace.selection.project, profileID: workspace.selection.profile,
                    activeFiles: [output.lastPathComponent])
            })
        let clock = ContinuousClock()
        let start = clock.now
        let hostBase = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        let audio = Task.detached {
            for index in 0..<2_000 {
                try Task.checkCancellation()
                try await clock.sleep(until: start + .milliseconds(index * 10))
                session.appendAudio(try ProgramRecordingFixtures.audio(at: Double(index) / 100, timestampBase: hostBase))
            }
        }
        let video = Task.detached {
            for index in 0..<1_200 {
                try Task.checkCancellation()
                try await clock.sleep(until: start + .nanoseconds(Int64(index) * 1_000_000_000 / 60))
                let elapsed = CMClockGetTime(CMClockGetHostTimeClock()).seconds - hostBase
                session.appendVideo(try ProgramRecordingFixtures.video(at: elapsed, timestampBase: hostBase))
            }
        }
        defer { audio.cancel(); video.cancel() }
        var marked = false
        for _ in 0..<1_600 {
            let (progress, failure) = receipt.read()
            try require(failure == nil, "Owned recorder failed before abrupt exit: \(failure ?? "")")
            if !marked && progress.durationSeconds >= 1 {
                session.addMarker(title: "Before interruption")
                marked = true
            }
            if marked && progress.durationSeconds >= 6.2 && progress.videoSamples > 200 && progress.audioSamples > 500 {
                await runtime.recoveryBinding?.refreshRecordings()
                await workspace.recovery.flush()
                let ready = Ready(childPID: getpid(), project: workspace.selection.project, profile: workspace.selection.profile,
                    session: sessionID, scene: scene.id.rawValue, layer: layer.id.rawValue,
                    media: media.id.rawValue,
                    recording: output.lastPathComponent, duration: progress.durationSeconds)
                try JSONEncoder().encode(ready).write(to: GuestFixtureStorage.artifactRoot.appendingPathComponent("ready.json"), options: .atomic)
                print("READY: PID \(getpid()), real H264/AAC writer active for \(progress.durationSeconds)s, \(progress.videoSamples) video / \(progress.audioSamples) PCM buffers; actual journals and recovery checkpoint flushed")
                // No finish(), cancellation or clean-exit checkpoint. The parent
                // alone will terminate this explicitly spawned test process.
                try await Task.sleep(for: .seconds(10))
                throw NSError(domain: "AbruptSessionRecovery", code: 2, userInfo: [NSLocalizedDescriptionKey: "Parent did not kill its owned child"])
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(domain: "AbruptSessionRecovery", code: 3, userInfo: [NSLocalizedDescriptionKey: "Owned writer readiness exceeded 16 seconds"])
    }

    static func recover() async throws {
        try seedCatalog()
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--child"]
        let childLog = GuestFixtureStorage.artifactRoot.appendingPathComponent("child.log")
        FileManager.default.createFile(atPath: childLog.path, contents: nil)
        let log = try FileHandle(forWritingTo: childLog)
        defer { try? log.close(); GuestFixtureDefaults.value.removePersistentDomain(forName: GuestFixtureDefaults.name) }
        child.standardOutput = log; child.standardError = log
        try child.run()
        defer {
            // Never signal any process other than this invocation's live child.
            if child.isRunning { _ = Darwin.kill(child.processIdentifier, SIGKILL) }
        }
        let readyURL = GuestFixtureStorage.artifactRoot.appendingPathComponent("ready.json")
        var ready: Ready?
        for _ in 0..<1_800 {
            if let data = try? Data(contentsOf: readyURL) { ready = try JSONDecoder().decode(Ready.self, from: data); break }
            try require(child.isRunning, "Owned child exited before readiness; inspect \(childLog.path)")
            try await Task.sleep(for: .milliseconds(10))
        }
        guard let ready else { throw NSError(domain: "AbruptSessionRecovery", code: 4, userInfo: [NSLocalizedDescriptionKey: "Owned child readiness exceeded 18 seconds"]) }
        try require(ready.childPID == child.processIdentifier && child.isRunning, "Readiness PID does not match the live owned Process")
        try require(Darwin.kill(child.processIdentifier, SIGKILL) == 0, "Cannot SIGKILL the owned child")
        for _ in 0..<500 {
            if !child.isRunning { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try require(!child.isRunning, "Owned child did not exit within five seconds")
        child.waitUntilExit()
        try require(child.terminationReason == .uncaughtSignal && child.terminationStatus == SIGKILL, "Child did not exit from the explicit SIGKILL")

        let output = GuestFixtureStorage.recordingsDirectory.appendingPathComponent(ready.recording)
        let journalURL = output.appendingPathExtension("recording.json")
        let original = try Data(contentsOf: output)
        let originalJournal = try Data(contentsOf: journalURL)
        let digest = SHA256.hash(data: original).description
        let journal = try JSONSerialization.jsonObject(with: originalJournal) as! [String: Any]
        try require(journal["status"] as? String == "recording", "Killed child unexpectedly finalized its recorder journal")
        let checkpointURL = GuestFixtureStorage.machineDirectory.appendingPathComponent("SessionRecovery/current.v1.json")
        let checkpoint = try Data(contentsOf: checkpointURL)
        try checkpoint.write(to: GuestFixtureStorage.artifactRoot.appendingPathComponent("interrupted-checkpoint.json"), options: .atomic)
        print("Killed owned child PID \(ready.childPID): \(original.count) original bytes, SHA256 \(digest), recording journal retained; no writer finish callback ran")

        // Fresh shipping Workspace constructs the real startup reader and binds
        // its real restore/library hooks. No recovery checkpoint is fabricated.
        let workspace = StudioWorkspace(root: GuestFixtureStorage.machineDirectory)
        guard let pending = workspace.recovery.pending else { throw NSError(domain: "AbruptSessionRecovery", code: 5, userInfo: [NSLocalizedDescriptionKey: "Fresh shipping startup did not offer the interrupted session"]) }
        try require(workspace.recovery.showReview && pending.projectID == ready.project && pending.profileID == ready.profile
            && !pending.cleanExit && pending.recordingWasActive && pending.recordingInventoryVerified,
            "Startup lost actual selected context, abrupt recording activity or verified inventory")
        try require(pending.programSceneID == ready.scene && pending.stagedSceneID == ready.scene && pending.hasStagedEdits,
            "Startup lost actual program/staged scene identity")
        try require(pending.media.contains { $0.sourceID == ready.media && abs(($0.seconds ?? -1) - 1.25) < 0.01 },
            "Startup lost actual paused local media position")
        try require(pending.recordings.contains { $0.sessionID == ready.session && $0.file == ready.recording
            && $0.status == .recording && $0.duration > 6 && $0.markers.count == 1 },
            "Startup did not retain the actual writer segment/status/timed marker")
        try assertIdle(workspace)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 540, height: 640),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SessionRecoveryReviewView(coordinator: workspace.recovery, relink: {})
            .padding(16).onAppear { ViewReceipt.appeared = true })
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        for _ in 0..<300 {
            if ViewReceipt.appeared { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try require(ViewReceipt.appeared, "Actual shipping recovery review did not appear in the owned window")
        try require(workspace.runtime.previewProgram.stagedScene?.layers.first?.isVisible == true,
            "Saved staged edit was replayed before explicit Restore")
        try require(workspace.runtime.controller.capturePool.mediaStatus(for: SourceDefinitionID(ready.media)).phase == .idle,
            "Local media loaded/played before explicit Restore")
        await workspace.recovery.restore()
        try require(workspace.recovery.error == nil && workspace.runtime.previewProgram.programScene?.id.rawValue == ready.scene
            && workspace.runtime.previewProgram.stagedScene?.layers.first?.id.rawValue == ready.layer
            && workspace.runtime.previewProgram.stagedScene?.layers.first?.transform.position.x == 0.23
            && workspace.runtime.previewProgram.stagedScene?.layers.first?.isVisible == false,
            "Explicit shipping restore did not restore saved geometry/visibility/IDs")
        try await requirePausedMedia(workspace.runtime, id: SourceDefinitionID(ready.media))
        await workspace.recovery.flush()
        let secondReader = SessionRecoveryCoordinator(directory: GuestFixtureStorage.machineDirectory.appendingPathComponent("SessionRecovery"))
        try require(secondReader.pending?.id == pending.id && secondReader.pending?.recordings.first?.sessionID == ready.session,
            "Unresolved actual interrupted review was lost by subsequent local checkpoints")
        try assertIdle(workspace)
        workspace.recovery.reviewRecordings?()
        try require(workspace.showRecordingLibrary && !workspace.recovery.showReview, "Shipping review did not open the actual recording library hook")

        let library = RecordingLibraryModel()
        await library.refresh(access: try workspace.runtime.recorder.libraryAccess(), activeURLs: [])
        guard let entry = library.entries.first(where: { $0.url == output }) else { throw NSError(domain: "AbruptSessionRecovery", code: 6, userInfo: [NSLocalizedDescriptionKey: "Killed media missing from the actual library"]) }
        print("Actual interrupted library classification: \(entry.status), canExport=\(entry.canExport), duration=\(entry.duration), tracks=\(entry.tracks), error=\(entry.error ?? "none")")
        try require(entry.sessionID == ready.session.uuidString && entry.markers.count == 1
            && entry.context.projectID == ready.project.uuidString && entry.context.profileID == ready.profile.uuidString,
            "Library lost real recording context/marker association")
        try require(try Data(contentsOf: output) == original && Data(contentsOf: journalURL) == originalJournal,
            "Startup/inspection changed interrupted source bytes or journal")
        guard entry.status == "recoverable", entry.canExport else {
            throw NSError(domain: "AbruptSessionRecovery", code: 7, userInfo: [NSLocalizedDescriptionKey:
                "UNQUALIFIED PRODUCT CAPABILITY: the mature interrupted fragmented MP4 is unreadable/unexportable; original bytes preserved"])
        }
        try require(entry.duration >= 2 && entry.duration <= ready.duration + 0.2, "Recovered prefix duration is outside the actual written interval")
        try await ProgramRecordingFixtures.inspect(output, expectedDuration: nil, checkSync: true)
        let finalized = GuestFixtureStorage.artifactRoot.appendingPathComponent("finalized-copy.mp4")
        await library.exportClip(entry, from: 0, to: entry.duration, output: finalized)
        try require(library.error == nil && FileManager.default.fileExists(atPath: finalized.path),
            "Shipping finalized-copy export failed: \(library.error ?? "missing file")")
        try await ProgramRecordingFixtures.inspect(finalized, expectedDuration: entry.duration, checkSync: true)
        try require(try Data(contentsOf: output) == original && Data(contentsOf: journalURL) == originalJournal,
            "Finalize-copy changed interrupted original/journal")
        try assertIdle(workspace)
        print("PASS: actual owned SIGKILL → fragmented H264/AAC media → fresh shipping Workspace startup/review → explicit local stable-ID geometry + actual AVPlayer paused-position restore despite autoplay → actual library recoverable classification → decoded synchronized prefix → finalized playable copy; unresolved review survives subsequent checkpoints, interrupted original/journal SHA256 unchanged, no capture/provider/output restart")
        print("Artifacts retained: \(GuestFixtureStorage.artifactRoot.path)")
    }

    static func assertIdle(_ workspace: StudioWorkspace) throws {
        try require(!workspace.runtime.controller.isPreviewing && !workspace.runtime.controller.outputSessionActive
            && !workspace.runtime.recorder.state.isActive && !workspace.runtime.controller.secondaryRecorder.state.isActive
            && workspace.runtime.controller.destinationOutputs.states.isEmpty,
            "Recovery automatically started preview, recording or publishing")
    }

    static func createOwnedMedia() throws -> URL {
        let url = GuestFixtureStorage.artifactRoot.appendingPathComponent("owned-local-media.wav")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96_000)!
        buffer.frameLength = 96_000
        for channel in 0..<2 { memset(buffer.floatChannelData![channel], 0, 96_000 * MemoryLayout<Float>.size) }
        var settings = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        let file = try AVAudioFile(forWriting: url, settings: settings)
        try file.write(from: buffer)
        return url
    }

    static func qualifyOwnedMediaBoundary(_ media: URL) throws {
        let sibling = media.deletingLastPathComponent().appendingPathComponent("rejected-owned-sibling.wav")
        try Data("Owned boundary rejection fixture".utf8).write(to: sibling)
        defer { try? FileManager.default.removeItem(at: sibling) }
        let siblingBookmark = try sibling.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        var rejectedSibling = false
        do { _ = try AbruptFixtureOwnedMedia.resolve(siblingBookmark) } catch { rejectedSibling = true }
        try require(rejectedSibling, "Internal-media resolver admitted a different owned file")
        // Probe the actual URL validation against a same-name symlink without
        // changing the WAV bytes. Both paths belong exclusively to this child.
        let backup = media.deletingLastPathComponent().appendingPathComponent("owned-local-media-identity.wav")
        try FileManager.default.moveItem(at: media, to: backup)
        defer {
            try? FileManager.default.removeItem(at: media)
            try? FileManager.default.moveItem(at: backup, to: media)
        }
        try FileManager.default.createSymbolicLink(at: media, withDestinationURL: backup)
        var rejectedLink = false
        do { _ = try AbruptFixtureOwnedMedia.validate(media) } catch { rejectedLink = true }
        try require(rejectedLink, "Internal-media resolver admitted a symbolic link")
        print("PASS: owned internal-media boundary rejects sibling bookmark and same-name symlink; no external security grant claimed")
    }

    static func requirePausedMedia(_ runtime: StudioRuntime, id: SourceDefinitionID) async throws {
        for _ in 0..<500 {
            let state = runtime.controller.capturePool.mediaStatus(for: id)
            // Shipping recovery loads a previously idle AVPlayer into .ready
            // and seeks without calling Play; .paused describes a source that
            // had already been playing. Both must remain parked at the saved
            // position, despite the durable source's autoplay=true policy.
            let player = runtime.controller.capturePool.abruptFixturePlayerState(for: id)
            if [.ready, .paused].contains(state.phase) && abs(state.positionSeconds - 1.25) < 0.01,
                let player, abs(player.seconds - 1.25) < 0.01, player.rate == 0, player.muted {
                try await Task.sleep(for: .milliseconds(250))
                let held = runtime.controller.capturePool.mediaStatus(for: id)
                try require([.ready, .paused].contains(held.phase) && abs(held.positionSeconds - 1.25) < 0.01,
                    "Restored local media auto-played or advanced its saved position")
                guard let heldPlayer = runtime.controller.capturePool.abruptFixturePlayerState(for: id) else {
                    throw NSError(domain: "AbruptSessionRecovery", code: 9, userInfo: [NSLocalizedDescriptionKey: "Actual restored AVPlayer disappeared"])
                }
                try require(abs(heldPlayer.seconds - 1.25) < 0.01 && heldPlayer.rate == 0 && heldPlayer.muted,
                    "Actual AVPlayer seek failed, advanced or sounded despite the paused recovery policy")
                print("Actual owned AVPlayer: time=\(heldPlayer.seconds), rate=\(heldPlayer.rate), muted=\(heldPlayer.muted), phase=\(held.phase)")
                return
            }
            try require(state.phase != .error, "Owned local media failed to load: \(state.errorMessage ?? "unknown")")
            try await Task.sleep(for: .milliseconds(10))
        }
        let state = runtime.controller.capturePool.mediaStatus(for: id)
        throw NSError(domain: "AbruptSessionRecovery", code: 8, userInfo: [NSLocalizedDescriptionKey:
            "Actual local media did not remain parked at saved 1.25s within five seconds (phase=\(state.phase), position=\(state.positionSeconds))"])
    }
}
