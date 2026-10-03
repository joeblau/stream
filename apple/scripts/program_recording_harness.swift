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
    var paused: Bool {
        lock.lock(); defer { lock.unlock() }
        return events.contains { if case .paused = $0 { return true }; return false }
    }
    var recorded: Bool {
        lock.lock(); defer { lock.unlock() }
        return events.contains { if case .recording = $0 { return true }; return false }
    }
}

private final class PausedWriterGate: @unchecked Sendable {
    private let lock = NSLock()
    private let releaseSignal = DispatchSemaphore(value: 0)
    private var entered = false
    var isEntered: Bool { lock.lock(); defer { lock.unlock() }; return entered }
    func holdFirst(_ frame: RecordingChatFrame) {
        lock.lock(); let first = !entered; entered = true; lock.unlock()
        if first { precondition(releaseSignal.wait(timeout: .now() + 3) == .success, "Pause accounting fixture did not release the writer") }
    }
    func release() { releaseSignal.signal() }
}

@main struct ProgramRecordingHarness {
    static func main() async throws {
        setbuf(stdout, nil)
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
        try await waitForMediaEnd(pausing, seconds: 1)
        pausing.pause()
        try await feed(pausing, seconds: 1, offset: 1)
        await resume(pausing)
        try await feed(pausing, seconds: 1, offset: 2)
        let resumedResult = await finish(pausing)
        precondition(resumedResult.completed, resumedResult.error ?? "Pause finalization failed")
        try await ProgramRecordingFixtures.inspect(pausedURL, expectedDuration: 2, checkSync: true)
        let pauseJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: pausedURL.appendingPathExtension("recording.json"))) as! [String: Any]
        precondition((pauseJSON["pauses"] as? [[String: Any]])?.count == 1, "Manifest must retain source-clock pause gap")
        print("PASS: pause omits one second from both tracks; resumed MP4 timestamps remain synchronized and decode")

        try await delayedBoundaries(folder, config: config)

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

        let videoOnlyURL = folder.appendingPathComponent("video-only-pause.mp4")
        try? FileManager.default.removeItem(at: videoOnlyURL)
        var videoOnlyConfig = config; videoOnlyConfig.requiresAudio = false
        let videoOnly = ProgramRecordingSession(outputURL: videoOnlyURL, configuration: videoOnlyConfig)
        try await feed(videoOnly, seconds: 1)
        try await waitForMediaEnd(videoOnly, seconds: 1)
        videoOnly.pause(); try await feed(videoOnly, seconds: 1, offset: 1)
        await resume(videoOnly)
        try await feed(videoOnly, seconds: 1, offset: 2)
        let videoOnlyResult = await finish(videoOnly)
        let videoOnlyAsset = AVURLAsset(url: videoOnlyURL)
        let onlyVideoTracks = try await videoOnlyAsset.loadTracks(withMediaType: .video)
        let onlyAudioTracks = try await videoOnlyAsset.loadTracks(withMediaType: .audio)
        let onlyDuration = try await videoOnlyAsset.load(.duration).seconds
        precondition(videoOnlyResult.completed && videoOnlyResult.progress.audioStatus == .notRequested)
        precondition(onlyVideoTracks.count == 1 && onlyAudioTracks.isEmpty && abs(onlyDuration - 2) < 0.04, "Video-only pause: tracks \(onlyVideoTracks.count)/\(onlyAudioTracks.count), duration \(onlyDuration), progress \(videoOnlyResult.progress)")
        print("PASS: video-only writer ignores unrequested audio and resumes its video clock after pause")

        let accountingURL = folder.appendingPathComponent("pause-discard-accounting.mp4")
        try? FileManager.default.removeItem(at: accountingURL)
        let pauseGate = PausedWriterGate()
        var accountingConfig = videoOnlyConfig; accountingConfig.onVideoAccepted = pauseGate.holdFirst
        let accounting = ProgramRecordingSession(outputURL: accountingURL, configuration: accountingConfig)
        accounting.appendVideo(try ProgramRecordingFixtures.video(at: 0))
        let pauseDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !pauseGate.isEntered && ContinuousClock.now < pauseDeadline { try await Task.sleep(for: .milliseconds(5)) }
        precondition(pauseGate.isEntered, "Pause accounting fixture did not reach actual writer acceptance")
        for frame in 1...10 { accounting.appendVideo(try ProgramRecordingFixtures.video(at: Double(frame) / 60)) }
        accounting.pause(); pauseGate.release()
        let accountingResult = await finish(accounting)
        precondition(accountingResult.completed && accountingResult.progress.videoSamples == 1 && accountingResult.progress.droppedVideo == 10,
            "Pause must account for every discarded pre-pause queued frame: \(accountingResult.progress)")
        print("PASS: pause discard accounting retains one actual accepted frame and counts ten queued-frame drops")

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

    static func delayedBoundaries(_ folder: URL, config: ProgramRecordingSession.Configuration) async throws {
        // Source clocks remain independent. Only audio arrival is delayed;
        // every sample keeps its original source PTS/data through all cuts.
        let clock = ContinuousClock()
        func audio(_ sink: @escaping @Sendable (CMSampleBuffer) -> Void,
                   start: ContinuousClock.Instant, count: Int) -> Task<Void, Error> {
            Task {
                for index in 0..<count {
                    let time = Double(index) / 100
                    try await clock.sleep(until: start.advanced(by: .seconds(time + 0.12)))
                    sink(try ProgramRecordingFixtures.audio(at: time,
                        eventSeconds: time < 1 ? 0.5 : 2.5))
                }
            }
        }
        func video(_ sink: @escaping @Sendable (CMSampleBuffer) -> Void,
                   start: ContinuousClock.Instant, offset: Double) async throws {
            for index in 0..<60 {
                let time = offset + Double(index) / 60
                try await clock.sleep(until: start.advanced(by: .seconds(time)))
                sink(try ProgramRecordingFixtures.video(at: time,
                    eventSeconds: time < 1 ? 0.5 : 2.5))
            }
        }
        let pauseURL = folder.appendingPathComponent("delayed-pause-stop.mp4")
        try? FileManager.default.removeItem(at: pauseURL)
        let log = EventLog(), paused = ProgramRecordingSession(outputURL: pauseURL, configuration: config, event: log.add)
        let start = clock.now
        let source = audio(paused.appendAudio, start: start, count: 300)
        try await video(paused.appendVideo, start: start, offset: 0)
        try await waitForMediaEnd(paused, seconds: 1)
        paused.pause()
        let deadline = clock.now.advanced(by: .seconds(3))
        while !log.paused && clock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        precondition(log.paused && log.failure() == nil, "Pause acknowledged before actual delayed PCM reached its sealed source boundary")
        try await clock.sleep(until: start.advanced(by: .seconds(2)))
        await resume(paused)
        try await video(paused.appendVideo, start: start, offset: 2)
        let result = await finish(paused) // audio is still arriving for its final 120 ms
        try await source.value
        print("TRACE delayed pause/stop final: \(result.progress), error \(result.error ?? "none")")
        precondition(result.completed && result.progress.droppedAudio == 0 && result.progress.droppedVideo == 0, result.error ?? "Delayed pause/stop lost media")
        precondition(abs((result.progress.audioEndSeconds ?? 0) - (result.progress.videoEndSeconds ?? 0)) < 1.0 / 48_000)
        try await ProgramRecordingFixtures.inspect(pauseURL, expectedDuration: 2, checkSync: true)
        print("PASS: independently delayed original-PTS PCM drains at pause and EOF; a shared resume boundary removes the source gap without dropped chunks or padded audio")

        let pendingURL = folder.appendingPathComponent("stop-during-pause-drain.mp4")
        try? FileManager.default.removeItem(at: pendingURL)
        let pending = ProgramRecordingSession(outputURL: pendingURL, configuration: config)
        let pendingStart = clock.now
        let pendingSource = audio(pending.appendAudio, start: pendingStart, count: 100)
        try await video(pending.appendVideo, start: pendingStart, offset: 0)
        try await waitForMediaEnd(pending, seconds: 1)
        pending.pause()
        let pendingResult = await finish(pending)
        try await pendingSource.value
        precondition(pendingResult.completed && pendingResult.progress.droppedAudio == 0 && pendingResult.progress.droppedVideo == 0,
                     pendingResult.error ?? "Stop during an outstanding pause drain lost its original PCM tail")
        try await ProgramRecordingFixtures.inspect(pendingURL, expectedDuration: 1, checkSync: true)
        print("PASS: stop during unresolved pause drainage seals one boundary, retains its delayed real PCM and finalizes once")

        let router = ProgramRecordingRouter()
        let firstURL = folder.appendingPathComponent("delayed-rotation-1.mp4"), nextURL = folder.appendingPathComponent("delayed-rotation-2.mp4")
        try? FileManager.default.removeItem(at: firstURL); try? FileManager.default.removeItem(at: nextURL)
        let first = ProgramRecordingSession(outputURL: firstURL, configuration: config)
        let next = ProgramRecordingSession(outputURL: nextURL, configuration: config)
        router.install(first)
        let splitStart = clock.now
        let splitSource = audio(router.appendAudio, start: splitStart, count: 201)
        try await video(router.appendVideo, start: splitStart, offset: 0)
        router.rotate(to: next, finishing: first)
        let previous = Task { await withCheckedContinuation { continuation in
            first.finish(waitingForSourceBoundary: true) { continuation.resume(returning: $0) }
        } }
        // 1.003 splits a real 480-frame PCM packet at sample 144. The old and
        // new writer receive the same immutable packet and retain disjoint data.
        try await video(router.appendVideo, start: splitStart, offset: 1.003)
        router.stop(next)
        let nextResult = await finish(next)
        let previousResult = await previous.value
        try await splitSource.value
        router.finished(first); router.finished(next)
        precondition(previousResult.completed && nextResult.completed, previousResult.error ?? nextResult.error ?? "Delayed rotation failed")
        precondition(abs((previousResult.progress.audioEndSeconds ?? 0) - 1.003) < 1.0 / 48_000,
                     "Retiring segment did not retain its exact PCM prefix")
        precondition((nextResult.progress.audioEndSeconds ?? 0) > 0.9999 && nextResult.progress.droppedAudio == 0,
                     "Next segment lost the original PCM suffix or EOF tail")
        try await ProgramRecordingFixtures.inspect(firstURL, expectedDuration: 1.003, checkSync: true)
        try await ProgramRecordingFixtures.inspect(nextURL, expectedDuration: 1, checkSync: false)
        print("PASS: native router rotation partitions a straddling PCM packet at one shared source cut; both independently finishing files retain delayed tails and decode")

        let leadingURL = folder.appendingPathComponent("accepted-audio-leading.mp4")
        try? FileManager.default.removeItem(at: leadingURL)
        let leading = ProgramRecordingSession(outputURL: leadingURL, configuration: config)
        try await feed(leading, seconds: 1)
        for index in 0..<5 { leading.appendAudio(try ProgramRecordingFixtures.audio(at: 1 + Double(index)/100)) }
        try await waitForMediaEnd(leading, seconds: 1.05)
        let lead = await finish(leading)
        precondition(lead.completed && abs((lead.progress.audioEndSeconds ?? 0)-1.05) < 1.0/48_000,
                     "Finalization truncated an already accepted audio-leading frontier")
        try await ProgramRecordingFixtures.inspect(leadingURL, expectedDuration: 1.05, checkSync: true)
        print("PASS: audio-leading accepted frontier is retained honestly at EOF; no implicit per-track shift or invented source samples")

        let missingURL = folder.appendingPathComponent("missing-audio-tail.mp4")
        try? FileManager.default.removeItem(at: missingURL)
        let missing = ProgramRecordingSession(outputURL: missingURL, configuration: config)
        try await feed(videoSink: missing.appendVideo, audioSink: { sample in
            if sample.presentationTimeStamp.seconds < 10_000.5 { missing.appendAudio(sample) }
        }, seconds: 1)
        let missingStart = clock.now
        let partial = await finish(missing)
        let elapsed = missingStart.duration(to: clock.now)
        precondition(!partial.completed && partial.recoverable && partial.error?.contains("drain") == true
            && elapsed >= .seconds(2.9) && elapsed < .seconds(4), "Missing PCM tail must time out honestly and finalize a playable partial")
        precondition((partial.progress.audioEndSeconds ?? 0) < 0.501 && (partial.progress.videoEndSeconds ?? 0) > 0.999,
                     "Missing tail was hidden by synthesized silence or altered source timestamps")
        let repeated = await finish(missing)
        precondition(repeated.progress.audioSamples == partial.progress.audioSamples && repeated.error == partial.error,
                     "Repeated stop did not return the same cleaned-up writer result")
        let asset = AVURLAsset(url: missingURL)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        precondition(audioTracks.count == 1 && videoTracks.count == 1)
        print("PASS: missing real PCM tail retains the strict three-second deadline, visible partial failure, original unequal frontiers and idempotent writer cleanup")

        let clippedURL = folder.appendingPathComponent("clipped-archive.mp4")
        for suffix in ["", ".chat.jsonl", ".chat.jsonl.summary.json", ".vtt"] {
            try? FileManager.default.removeItem(atPath: clippedURL.path + suffix)
        }
        let archiveTimeline = RecordingTimeline()
        let archive = RecordingChatArchive(programURL: clippedURL, sessionID: UUID().uuidString, segmentIndex: 1,
            context: .init(), timeline: archiveTimeline, preferences: .init(enabled: true))
        let message = RecordingChatMessage(id: "public-fixture", platform: "Fixture", author: nil, text: "Visible control",
            providerTimestamp: Date(), timestampIsReceiptTime: true, kind: "Text")
        let paint = RecordingChatPaint(slotID: "owned-slot", messageID: message.id, fingerprint: RecordingChatPaint.fingerprint(message.text))
        var archiveConfig = config
        archiveConfig.onVideoAccepted = { frame in archive.frame(frame, bindings: frame.painted.map { .init(paint: $0, message: message) }) }
        let clipped = ProgramRecordingSession(outputURL: clippedURL, configuration: archiveConfig, timeline: archiveTimeline)
        try await feed(videoSink: { sample in
            if sample.presentationTimeStamp.seconds >= 10_000.8 { RecordingChatPaint.attach([paint], to: sample) }
            clipped.appendVideo(sample)
        }, audioSink: clipped.appendAudio, seconds: 1)
        clipped.resolveFinishBoundary(CMTime(seconds: 10_000.997, preferredTimescale: 48_000))
        let clippedResult = await finish(clipped)
        await withCheckedContinuation { continuation in archive.finish(completed: clippedResult.completed) { continuation.resume() } }
        precondition(clippedResult.completed)
        try await ProgramRecordingFixtures.inspect(clippedURL, expectedDuration: 0.997, checkSync: true)
        var records: [RecordingChatRecord] = []
        _ = try RecordingChatReader.scan(archive.url, record: { records.append($0) })
        let summary = try JSONSerialization.jsonObject(with: Data(contentsOf: archive.url.appendingPathExtension("summary.json"))) as! [String: Any]
        precondition(abs((summary["durationSeconds"] as! Double)-0.997) < 1.0/48_000
            && records.last?.type == "hide" && abs(records.last!.seconds-0.997) < 1.0/48_000,
                     "Chat hide/summary retained a nominal image tail outside the sealed native movie")
        let subtitles = URL(fileURLWithPath: clippedURL.path + ".vtt")
        try RecordingChatReader.export(archive.url, format: .vtt, to: subtitles)
        let cues = try String(contentsOf: subtitles, encoding: .utf8)
        precondition(cues.contains("00:00:00.997"), "Exported cue did not honor the actual movie cut")
        print("PASS: native endSession clips a nominal accepted image tail; archive final hide, summary and exported cue follow the same sealed0.997s boundary")
    }

    static func waitForMediaEnd(_ session: ProgramRecordingSession, seconds: Double) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            let snapshot = session.timeline.snapshot()
            if snapshot.origin.isNumeric, snapshot.end.isNumeric,
               (snapshot.end - snapshot.origin).seconds >= seconds - 0.00001 { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        preconditionFailure("Writer did not accept the pre-pause media tail: \(session.timeline.snapshot())")
    }
    static func resume(_ session: ProgramRecordingSession) async {
        let accepted = await withCheckedContinuation { continuation in
            session.resume { continuation.resume(returning: $0) }
        }
        precondition(accepted, "Resume was not accepted by the actual writer queue")
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
