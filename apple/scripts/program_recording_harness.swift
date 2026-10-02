import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ProgramRecordingSession.Event] = []
    func add(_ event: ProgramRecordingSession.Event) { lock.lock(); events.append(event); lock.unlock() }
    func failure() -> String? {
        lock.lock(); defer { lock.unlock() }
        for event in events { if case .failed(let error) = event { return error } }
        return nil
    }
    var recorded: Bool {
        lock.lock(); defer { lock.unlock() }
        return events.contains { if case .recording = $0 { return true }; return false }
    }
}

@main struct ProgramRecordingHarness {
    static func main() async throws {
        let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("synchronized-60fps.mp4")
        try? FileManager.default.removeItem(at: url)
        let log = EventLog()
        let requireRealtime = ProcessInfo.processInfo.environment["STREAM_RECORDING_REQUIRE_REALTIME"] == "1"
        var config = ProgramRecordingSession.Configuration(); config.frameRate = 60
        let session = ProgramRecordingSession(outputURL: url, configuration: config, event: log.add)
        // The measured event follows encoder warmup; VM startup loss remains
        // counted without erasing the event used for decoded sync validation.
        try await feed(session, seconds: 3, eventSeconds: 2)
        let result = await finish(session)
        precondition(result.completed, result.error ?? "Writer failed")
        precondition(log.recorded, "Recording must follow actual audio/video appends")
        precondition(result.progress.videoSamples + result.progress.droppedVideo == 180 && result.progress.audioSamples + result.progress.droppedAudio == 300,
            "Every supplied sample must be written or counted as dropped")
        if requireRealtime {
            precondition(result.progress.droppedAudio == 0 && result.progress.droppedVideo == 0,
                "Physical-Mac real-time qualification must not shed samples")
        }
        print("Qualification: \(requireRealtime ? "physical-Mac zero-drop cadence" : "portable writer contracts; real-time cadence awaits physical-Mac qualification"), drops video/audio \(result.progress.droppedVideo)/\(result.progress.droppedAudio)")
        try await ProgramRecordingFixtures.inspect(url, expectedDuration: 3, checkSync: true)
        print("PASS: actual AAC/H.264 tracks, 60fps static frames, preroll audio, three-second duration and flash/tone A/V synchronization")

        let pausedURL = folder.appendingPathComponent("pause-resume.mp4")
        try? FileManager.default.removeItem(at: pausedURL)
        let pausing = ProgramRecordingSession(outputURL: pausedURL, configuration: config)
        try await feed(pausing, seconds: 1)
        try await Task.sleep(for: .milliseconds(50))
        pausing.pause()
        try await feed(pausing, seconds: 1, offset: 1)
        pausing.resume()
        try await Task.sleep(for: .milliseconds(20))
        try await feed(pausing, seconds: 1, offset: 2)
        let resumedResult = await finish(pausing)
        precondition(resumedResult.completed, resumedResult.error ?? "Pause finalization failed")
        try await ProgramRecordingFixtures.inspect(pausedURL, expectedDuration: 2, checkSync: true)
        let pauseJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: pausedURL.appendingPathExtension("recording.json"))) as! [String: Any]
        precondition((pauseJSON["pauses"] as? [[String: Any]])?.count == 1, "Manifest must retain source-clock pause gap")
        print("PASS: pause omits one second from both tracks; resumed MP4 timestamps remain synchronized and decode")

        let movURL = folder.appendingPathComponent("hevc-high.mov")
        try? FileManager.default.removeItem(at: movURL)
        var mov = config; mov.container = .mov; mov.codec = .hevc; mov.quality = .high
        let alternative = ProgramRecordingSession(outputURL: movURL, configuration: mov)
        try await feed(alternative, seconds: 1)
        let alternativeResult = await finish(alternative)
        precondition(alternativeResult.completed, alternativeResult.error ?? "HEVC/MOV preset failed")
        try await ProgramRecordingFixtures.inspect(movURL, expectedDuration: 1, checkSync: true)
        let movie = AVURLAsset(url: movURL)
        let movieTracks = try await movie.loadTracks(withMediaType: .video)
        let formats = try await movieTracks[0].load(.formatDescriptions)
        precondition(CMFormatDescriptionGetMediaSubType(formats[0]) == kCMVideoCodecType_HEVC, "Selected codec must actually be HEVC")
        print("PASS: MOV/HEVC high-quality preset produces actual HEVC video and AAC audio")

        let firstURL = folder.appendingPathComponent("rotation-1.mp4")
        let secondURL = folder.appendingPathComponent("rotation-2.mp4")
        try? FileManager.default.removeItem(at: firstURL); try? FileManager.default.removeItem(at: secondURL)
        let router = ProgramRecordingRouter()
        var firstConfig = config; firstConfig.sessionID = "rotation-test"
        let first = ProgramRecordingSession(outputURL: firstURL, configuration: firstConfig)
        router.install(first)
        try await feed(videoSink: router.appendVideo, audioSink: router.appendAudio, seconds: 1)
        var secondConfig = firstConfig; secondConfig.segmentIndex = 2
        let second = ProgramRecordingSession(outputURL: secondURL, configuration: secondConfig)
        router.install(second)
        let firstFinish = Task { await finish(first) }
        try await feed(videoSink: router.appendVideo, audioSink: router.appendAudio, seconds: 1, offset: 1)
        router.install(nil)
        let firstResult = await firstFinish.value
        let secondResult = await finish(second)
        precondition(firstResult.completed && secondResult.completed, "Both rotated segments must finalize")
        try await ProgramRecordingFixtures.inspect(firstURL, expectedDuration: 1, checkSync: true)
        try await ProgramRecordingFixtures.inspect(secondURL, expectedDuration: 1, checkSync: false)
        let rotationVideoDrops = firstResult.progress.droppedVideo + secondResult.progress.droppedVideo
        let rotationAudioDrops = firstResult.progress.droppedAudio + secondResult.progress.droppedAudio
        precondition(firstResult.progress.videoSamples + secondResult.progress.videoSamples + rotationVideoDrops == 120, "Rotation must account for every supplied video frame")
        precondition(firstResult.progress.audioSamples + secondResult.progress.audioSamples + rotationAudioDrops == 200, "Rotation must account for every supplied audio chunk")
        if requireRealtime { precondition(rotationVideoDrops == 0 && rotationAudioDrops == 0, "Physical-Mac rotation cadence must not shed samples") }
        print("PASS: atomic tap-router rotation accounts for each sample while the previous file finishes independently; drops video/audio \(rotationVideoDrops)/\(rotationAudioDrops)")

        let failureURL = folder.appendingPathComponent("preserved-low-space.mp4")
        try? FileManager.default.removeItem(at: failureURL)
        let failureLog = EventLog(); let began = Date()
        let failing = ProgramRecordingSession(outputURL: failureURL, configuration: config, spaceProbe: { _ in
            Date().timeIntervalSince(began) > 1 ? 10_000_000 : 10_000_000_000
        }, event: failureLog.add)
        try await feed(failing, seconds: 2.2)
        let partial = await finish(failing)
        precondition(!partial.completed && partial.recoverable && failureLog.failure() != nil, "Low storage must fail visibly and classify finalized fragments as recoverable")
        precondition(FileManager.default.fileExists(atPath: failureURL.path), "Failure must preserve media")
        precondition(FileManager.default.fileExists(atPath: failureURL.appendingPathExtension("recording.json").path), "Failure journal must survive")
        try await ProgramRecordingFixtures.inspect(failureURL, expectedDuration: nil, checkSync: true)
        print("PASS: low-disk failure preserves playable partial audio/video and failure journal while independent source tasks continue")

        let overloadURL = folder.appendingPathComponent("bounded-overload.mp4")
        try? FileManager.default.removeItem(at: overloadURL)
        var small = config; small.videoCapacity = 2; small.audioCapacity = 4
        let overloaded = ProgramRecordingSession(outputURL: overloadURL, configuration: small)
        for index in 0..<1000 {
            overloaded.appendVideo(try ProgramRecordingFixtures.video(at: Double(index) / 60))
            overloaded.appendAudio(try ProgramRecordingFixtures.audio(at: Double(index) / 100))
        }
        let overloadedResult = await finish(overloaded)
        precondition(overloadedResult.progress.droppedAudio > 0 && overloadedResult.progress.droppedVideo > 0, "Overload must be bounded and counted")
        print("PASS: bounded ingestion counts video/audio loss; no per-sample asynchronous writer backlog")

        let absentURL = folder.appendingPathComponent("absent-volume.mp4")
        let absentLog = EventLog()
        let absent = ProgramRecordingSession(outputURL: absentURL, spaceProbe: { _ in
            throw CocoaError(.fileNoSuchFile)
        }, event: absentLog.add)
        try await Task.sleep(for: .milliseconds(100))
        let absentResult = await finish(absent)
        precondition(!absentResult.completed && absentLog.failure() != nil, "Removed volume must fail visibly")
        print("PASS: removed-volume and no-media finalization paths")
        let existingURL = folder.appendingPathComponent("existing-output.mp4")
        let original = Data("Existing file must survive a writer-open failure".utf8)
        try original.write(to: existingURL)
        let existingLog = EventLog()
        let existing = ProgramRecordingSession(outputURL: existingURL, event: existingLog.add)
        try await feed(existing, seconds: 0.2)
        let existingResult = await finish(existing)
        precondition(!existingResult.completed && existingLog.failure() != nil, "Actual writer-open error must reach the studio")
        let preserved = try Data(contentsOf: existingURL)
        precondition(preserved == original, "Open failure must preserve the existing file")
        print("PASS: real AVAssetWriter open failure surfaces errors and does not delete existing media")
        print("Configuration: \(ProcessInfo.processInfo.operatingSystemVersionString); \(ProcessInfo.processInfo.processorCount) CPUs; files: \(folder.path)")
    }

    static func finish(_ session: ProgramRecordingSession) async -> ProgramRecordingSession.Result {
        await withCheckedContinuation { continuation in session.finish { continuation.resume(returning: $0) } }
    }

    static func feed(_ session: ProgramRecordingSession, seconds: Double, offset: Double = 0, eventSeconds: Double = 0.5) async throws {
        try await feed(videoSink: session.appendVideo, audioSink: session.appendAudio, seconds: seconds, offset: offset, eventSeconds: eventSeconds)
    }

    static func feed(videoSink: @escaping @Sendable (CMSampleBuffer) -> Void, audioSink: @escaping @Sendable (CMSampleBuffer) -> Void, seconds: Double, offset: Double = 0, eventSeconds: Double = 0.5) async throws {
        let clock = ContinuousClock(); let start = clock.now
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for index in 0..<Int(seconds * 60) {
                    let time = Double(index) / 60
                    try await clock.sleep(until: start.advanced(by: .seconds(time)))
                    videoSink(try ProgramRecordingFixtures.video(at: time + offset, eventSeconds: eventSeconds))
                }
            }
            group.addTask {
                for index in 0..<Int(seconds * 100) {
                    let time = Double(index) / 100
                    try await clock.sleep(until: start.advanced(by: .seconds(time)))
                    audioSink(try ProgramRecordingFixtures.audio(at: time + offset, eventSeconds: eventSeconds))
                }
            }
            try await group.waitForAll()
        }
    }


}
