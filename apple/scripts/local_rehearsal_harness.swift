import AVFoundation
import Combine
import Foundation
import StreamCore

private final class RehearsalPublisherBoundary: @unchecked Sendable {
    private let lock = NSLock()
    private var holdingStop = false
    private var stops: [CheckedContinuation<Void, Never>] = []
    private var events: AsyncStream<PublisherEvent>.Continuation?
    func install(_ continuation: AsyncStream<PublisherEvent>.Continuation) { lock.lock(); events = continuation; lock.unlock() }
    func holdStop() { lock.lock(); holdingStop = true; lock.unlock() }
    func fail() { lock.lock(); let events = events; lock.unlock(); events?.yield(.failed(message: "Injected transport loss")) }
    func stop() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if holdingStop { stops.append(continuation); lock.unlock() }
            else { lock.unlock(); continuation.resume() }
        }
    }
    func release() {
        lock.lock(); holdingStop = false; let pending = stops; stops.removeAll(); lock.unlock()
        for continuation in pending { continuation.resume() }
    }
}

/// The generated tool injects this at the publisher factory only. The actual
/// destination state machine and rehearsal entry points stay unchanged.
actor RehearsalPublisherProbe: Publisher {
    private nonisolated static let boundary = RehearsalPublisherBoundary()
    nonisolated let events: AsyncStream<PublisherEvent>
    private nonisolated let continuation: AsyncStream<PublisherEvent>.Continuation
    init() {
        (events, continuation) = AsyncStream.makeStream(of: PublisherEvent.self)
        Self.boundary.install(continuation)
    }
    nonisolated static func holdStop() { boundary.holdStop() }
    nonisolated static func fail() { boundary.fail() }
    nonisolated static func releaseStop() { boundary.release() }
    func start(_ settings: StreamSettings) async throws { continuation.yield(.published) }
    func stop() async { await Self.boundary.stop() }
    func pause() async {}
    func resume() async {}
    func setOutputSize(_ size: CGSize, nativeShortEdge: Int) async {}
    func appendVideo(_ sb: CMSampleBuffer) async {}
    nonisolated func enqueueMic(_ sb: CMSampleBuffer) {}
    nonisolated func enqueueApp(_ sb: CMSampleBuffer) {}
    nonisolated func enqueueProgram(_ sb: CMSampleBuffer) {}
    func setMicVolume(_ volume: Double) async {}
    func setThermalCeiling(bitRateScale: Double, frameRateCap: Int) async {}
    func statsSnapshot() async -> LiveStats? { nil }
}

@main @MainActor struct LocalRehearsalHarness {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        guard value() else { throw NSError(domain: "LocalRehearsalHarness", code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func wait(_ message: String, until ready: () -> Bool) async throws {
        for _ in 0..<1_200 {
            if ready() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try check(false, message)
    }
    static func blocked(_ controller: StreamController, recorder: RecordingController) throws {
        try check(controller.isRehearsing && !controller.destinationOutputs.isPublishingAllowed,
            "Rehearsal must reserve publishing before asynchronous recording acknowledgement")
        let destination = StreamDestination(name: "Blocked rehearsal publisher")
        controller.destinationOutputs.start(destination, settings: .default)
        try check(controller.destinationOutputs.states[destination.id] == nil,
            "The real output boundary allocated a publisher during rehearsal")
        controller.goLive()
        try check(controller.isRehearsing && !controller.streamState.isActive,
            "Public Go Live escaped the rehearsal guard")
    }
    static func main() async throws {
        let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let project = folder.appendingPathComponent("Project")
        try DesktopStorage.prepare(project)
        // No camera, screen, remote widget or media source is demanded.
        let scene = Scene(name: "Local rehearsal fixture", layers: [], background: .solid(colorHex: "#174A69"))
        let document = SceneDocument(sources: [], scenes: [scene], selectedID: scene.id)
        try JSONEncoder().encode(document).write(to: project.appendingPathComponent("stream.scenes.v2.json"))
        try JSONEncoder().encode([StreamDestination]()).write(to: project.appendingPathComponent("destinations.json"))
        var settings = StreamSettings.default
        settings.outputProfile = .init(canvasWidth: 320, canvasHeight: 180, frameRate: 30)
        settings.micVolume = 0; settings.audioInputs = []
        DesktopSettingsStore().saveNonSecret(settings)
        let scenes = SceneStore(), preview = PreviewProgramModel(selected: scenes.selected)
        let controller = StreamController(sceneStore: scenes, previewProgram: preview, permissions: PermissionsManager())
        let suite = "stream.rehearsal-validation.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); scenes.flushPendingWrites() }
        let recorder = RecordingController(defaults: defaults, defaultDirectory: folder.appendingPathComponent("Recordings"))
        recorder.preferences.countdownSeconds = 1
        controller.beginLocalRehearsal(recorder: recorder)
        try check(recorder.state == .preparing && recorder.countdownRemaining == 1 && controller.isPreviewing,
            "Shipping entry point did not start countdown/owned preview")
        try blocked(controller, recorder: recorder)
        controller.endLocalRehearsal(recorder: recorder)
        try check(!controller.isRehearsing && !controller.isPreviewing && recorder.state == .idle,
            "Countdown cancellation failed to release rehearsal-owned preview")
        // Queue old observer tasks, then begin a replacement before they run.
        controller.beginLocalRehearsal(recorder: recorder)
        await Task.yield()
        try blocked(controller, recorder: recorder)
        try check(recorder.state == .preparing, "An old callback released or started a new rehearsal")
        controller.endLocalRehearsal(recorder: recorder)
        try await Task.sleep(for: .milliseconds(1_200))
        try check(!recorder.state.isActive && controller.reservedRecordingEncoderCount == 0 && !controller.outputSessionActive,
            "Canceled countdown or late acknowledgement resurrected output ownership")
        print("PASS: shipping beginLocalRehearsal blocks public output during countdown; cancel and late old callbacks release only their rehearsal/preview")

        controller.startPreview()
        controller.beginLocalRehearsal(recorder: recorder)
        try blocked(controller, recorder: recorder)
        controller.endLocalRehearsal(recorder: recorder)
        try check(controller.isPreviewing && !controller.isRehearsing,
            "Ending rehearsal stopped a pre-existing preview")
        controller.stopPreview()
        recorder.preferences.countdownSeconds = 0
        controller.beginLocalRehearsal(recorder: recorder)
        try check(recorder.state == .preparing, "The writer must not claim Recording before accepting real media")
        try blocked(controller, recorder: recorder)
        controller.endLocalRehearsal(recorder: recorder)
        try check(controller.isRehearsing && recorder.state == .stopping,
            "Preparing stop released rehearsal before writer cleanup")
        try blocked(controller, recorder: recorder)
        try await wait("Preparing writer did not finalize/cancel", until: { !controller.isRehearsing })
        try check(!controller.isPreviewing && controller.reservedRecordingEncoderCount == 0,
            "Preparing writer leaked preview/encoder reservation")
        print("PASS: pre-existing preview is retained; preparation stop keeps public publishing blocked through actual writer cleanup")

        let unavailable = folder.appendingPathComponent("UnavailableFolder")
        try Data("A file cannot be a recording directory".utf8).write(to: unavailable)
        let failedRecorder = RecordingController(defaults: defaults, defaultDirectory: unavailable)
        controller.beginLocalRehearsal(recorder: failedRecorder)
        try check(!failedRecorder.state.isActive && failedRecorder.lastError != nil && !controller.isRehearsing && !controller.isPreviewing,
            "Synchronous storage failure leaked owned rehearsal or preview")
        controller.startPreview()
        controller.beginLocalRehearsal(recorder: failedRecorder)
        try check(controller.isPreviewing && !controller.isRehearsing && controller.destinationOutputs.isPublishingAllowed,
            "Storage failure removed an existing preview or retained its publishing guard")
        controller.stopPreview()

        let live = StreamDestination(name: "Already live fixture")
        controller.destinationOutputs.start(live, settings: settings)
        try await wait("Fixture publisher did not acknowledge", until: { controller.destinationOutputs.liveCount == 1 })
        let activeFacts = controller.preflightFacts(programAudioPeak: nil)
        try check(activeFacts.encoderCount == 1,
            "An active publisher omitted from the saved plan was undercounted")
        controller.beginLocalRehearsal(recorder: recorder)
        try check(!controller.isRehearsing && !recorder.state.isActive && controller.destinationOutputs.liveCount == 1,
            "Rehearsal changed an already active publisher")
        RehearsalPublisherProbe.holdStop()
        RehearsalPublisherProbe.fail()
        try await wait("Injected publisher failure did not reach its actual output state", until: {
            if case .failed = controller.destinationOutputs.states[live.id] { return true }; return false
        })
        try check(controller.destinationOutputs.activeCount == 0 && controller.activePublishingEncoderCount == 1
            && controller.preflightFacts(programAudioPeak: nil).encoderCount == 1,
            "Failed publisher still finalizing was omitted from actual encoder ownership")
        controller.beginLocalRehearsal(recorder: recorder)
        try check(!controller.isRehearsing && !recorder.state.isActive,
            "Rehearsal adopted a finalizing failed publisher")
        RehearsalPublisherProbe.releaseStop()
        try await wait("Fixture publisher stop did not finish", until: { controller.activePublishingEncoderCount == 0 })
        controller.destinationOutputs.stopAll()
        recorder.start(stream: controller)
        controller.beginLocalRehearsal(recorder: recorder)
        try check(!controller.isRehearsing && controller.destinationOutputs.isPublishingAllowed && recorder.state.isActive,
            "Rehearsal adopted a separately started recorder")
        await withCheckedContinuation { continuation in recorder.stop { continuation.resume() } }
        let other = UUID()
        try check(controller.reserveRecordingEncoders(other, count: 4, canvas: .program) == nil, "Fixture reservation failed")
        let reserved = controller.preflightFacts(programAudioPeak: nil)
        try check(!recorder.state.isActive && reserved.recordingEncoderReservations == 4 && reserved.encoderCount == 0,
            "Idle primary recorder hid studio-wide preparation/secondary/ISO/finalization reservations")
        for number in 1...2 {
            controller.destinations.create(.rtmp)
            let id = controller.destinations.selectedID!
            let index = controller.destinations.draft.firstIndex(where: { $0.id == id })!
            controller.destinations.draft[index].isEnabled = true
            controller.destinations.draft[index].name = "Planned fixture \(number)"
            controller.destinations.credentials[id] = .init(endpoint: "rtmp://fixture.invalid/live", streamKey: "fixture")
        }
        try check(controller.destinations.apply(), "Fixture destination plan did not save")
        let overload = controller.preflightFacts(programAudioPeak: nil)
        try check(overload.encoderCount == 2 && overload.recordingEncoderReservations == 4
            && overload.checks.first(where: { $0.id == "encoders" })?.status == .failed,
            "Planned publishing plus reservations escaped the studio session limit")
        controller.destinations.draft = []
        try check(controller.destinations.apply(), "Fixture plan did not clear")
        controller.beginLocalRehearsal(recorder: recorder)
        try check(!controller.isRehearsing && !recorder.state.isActive, "Rehearsal bypassed another preparing recording")
        controller.releaseRecordingEncoders(other)
        let one = UUID()
        try check(controller.reserveRecordingEncoders(one, count: 1, canvas: .program) == nil, "Remaining fixture reservation failed")
        try check(controller.preflightFacts(programAudioPeak: nil).recordingEncoderReservations == 1, "Checklist failed to release four reservations")
        controller.releaseRecordingEncoders(one)
        try check(controller.preflightFacts(programAudioPeak: nil).recordingEncoderReservations == 0, "Checklist retained final released reservation")
        print("PASS: failed starts restore owned state; existing live/recording/reserved preparation is rejected without mutation")
        print("PASS: checklist counts active/finalizing publishers outside the plan, two planned publishers plus four studio-wide reservations, rejects six against four, and releases 4→1→0 while primary recorder is idle")

        controller.beginLocalRehearsal(recorder: recorder)
        try blocked(controller, recorder: recorder)
        try await wait("Native compositor/mixer/writer did not record", until: { recorder.state == .recording })
        try await wait("Native media did not advance", until: { recorder.progress.durationSeconds >= 0.7 })
        let output = recorder.currentOutputURL!
        recorder.pause()
        try await wait("Writer did not pause", until: { recorder.state == .paused })
        try blocked(controller, recorder: recorder)
        recorder.resume()
        try await wait("Writer did not resume", until: { recorder.state == .recording })
        recorder.startNewFile()
        try await wait("Rotated writer did not record", until: { recorder.state == .recording && recorder.currentOutputURL != output })
        let next = recorder.currentOutputURL!
        try await wait("Rotated media did not advance", until: { recorder.progress.durationSeconds >= 0.5 })
        // Stop preview independently while the output retains recording demand.
        controller.stopPreview()
        try check(recorder.state.isActive && controller.isRehearsing, "Stopping preview ended rehearsal recording")
        controller.endLocalRehearsal(recorder: recorder)
        try check(controller.isRehearsing && recorder.state == .stopping,
            "Finalization prematurely unblocked public publishing")
        try blocked(controller, recorder: recorder)
        try await wait("Recording/previous segment cleanup did not release rehearsal", until: { !controller.isRehearsing })
        try check(recorder.state == .idle && !controller.isPreviewing && controller.destinationOutputs.isPublishingAllowed
            && controller.reservedRecordingEncoderCount == 0 && !controller.outputSessionActive && recorder.activeOutputURLs.isEmpty,
            "Completed rehearsal retained ownership or failed to enable fresh operator publishing")
        try await ProgramRecordingFixtures.inspect(output, expectedDuration: nil, checkSync: false)
        try await ProgramRecordingFixtures.inspect(next, expectedDuration: nil, checkSync: false)
        print("PASS: actual shipping compositor/mixer H264/AAC rehearsal survives pause/resume, rotation and preview stop; all files decode and guard releases after writer/segment finalization")

        controller.beginLocalRehearsal(recorder: recorder)
        try await wait("Storage-loss fixture did not start actual media", until: { recorder.state == .recording && recorder.progress.durationSeconds >= 0.5 })
        let interrupted = recorder.currentOutputURL!
        let relocated = folder.appendingPathComponent("RemovedRecordingPath")
        try FileManager.default.moveItem(at: interrupted.deletingLastPathComponent(), to: relocated)
        try await wait("Native unavailable recording path did not release rehearsal after writer failure", until: { !controller.isRehearsing })
        try check(!recorder.state.isActive && recorder.lastError != nil && recorder.activeOutputURLs.isEmpty
            && controller.reservedRecordingEncoderCount == 0 && controller.destinationOutputs.isPublishingAllowed && !controller.isPreviewing,
            "Asynchronous writer/storage failure left rehearsal/public publishing ownership behind")
        try await ProgramRecordingFixtures.inspect(relocated.appendingPathComponent(interrupted.lastPathComponent), expectedDuration: nil, checkSync: false)
        print("PASS: actual recording-directory relocation triggers asynchronous storage failure; readable partial tracks survive and rehearsal releases only after writer cleanup (physical unplug remains unqualified)")
        print("Configuration: \(ProcessInfo.processInfo.operatingSystemVersionString); \(ProcessInfo.processInfo.processorCount) CPUs; artifacts \(folder.path)")
        print("Qualification: hardware capture permission, credentials and external provider traffic are fixture boundaries; no TCC/default-device or live service changes")
    }
}
