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
        var config = ProgramRecordingSession.Configuration(); config.frameRate = 60
        let session = ProgramRecordingSession(outputURL: url, configuration: config, event: log.add)
        try await feed(session, seconds: 3)
        let result = await finish(session)
        precondition(result.completed, result.error ?? "Writer failed")
        precondition(log.recorded, "Recording must follow actual audio/video appends")
        precondition(result.progress.droppedAudio == 0 && result.progress.droppedVideo == 0, "Normal real-time workload must not shed samples")
        try await inspect(url, expectedDuration: 3, checkSync: true)
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
        try await inspect(pausedURL, expectedDuration: 2, checkSync: true)
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
        try await inspect(movURL, expectedDuration: 1, checkSync: true)
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
        try await inspect(firstURL, expectedDuration: 1, checkSync: true)
        try await inspect(secondURL, expectedDuration: 1, checkSync: false)
        precondition(firstResult.progress.videoSamples + secondResult.progress.videoSamples == 120, "Rotation must retain static video cadence")
        precondition(firstResult.progress.audioSamples + secondResult.progress.audioSamples == 200, "Rotation must retain program audio cadence")
        print("PASS: atomic tap-router rotation retains every sample while the previous file finishes independently")

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
        try await inspect(failureURL, expectedDuration: nil, checkSync: true)
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

    static func feed(_ session: ProgramRecordingSession, seconds: Double, offset: Double = 0) async throws {
        try await feed(videoSink: session.appendVideo, audioSink: session.appendAudio, seconds: seconds, offset: offset)
    }

    static func feed(videoSink: @escaping @Sendable (CMSampleBuffer) -> Void, audioSink: @escaping @Sendable (CMSampleBuffer) -> Void, seconds: Double, offset: Double = 0) async throws {
        let clock = ContinuousClock(); let start = clock.now
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for index in 0..<Int(seconds * 60) {
                    let time = Double(index) / 60
                    try await clock.sleep(until: start.advanced(by: .seconds(time)))
                    videoSink(try ProgramRecordingFixtures.video(at: time + offset))
                }
            }
            group.addTask {
                for index in 0..<Int(seconds * 100) {
                    let time = Double(index) / 100
                    try await clock.sleep(until: start.advanced(by: .seconds(time)))
                    audioSink(try ProgramRecordingFixtures.audio(at: time + offset))
                }
            }
            try await group.waitForAll()
        }
    }

    static func inspect(_ url: URL, expectedDuration: Double?, checkSync: Bool) async throws {
        let asset = AVURLAsset(url: url)
        let videos = try await asset.loadTracks(withMediaType: .video)
        let audios = try await asset.loadTracks(withMediaType: .audio)
        precondition(videos.count == 1 && audios.count == 1, "Both program tracks must exist")
        let duration = try await asset.load(.duration).seconds
        if let expectedDuration { precondition(abs(duration - expectedDuration) < 0.08, "Unexpected duration \(duration)") }
        let videoRange = try await videos[0].load(.timeRange)
        let audioRange = try await audios[0].load(.timeRange)
        precondition(abs(videoRange.start.seconds - audioRange.start.seconds) < 0.04, "Track start mismatch")
        precondition(abs(videoRange.duration.seconds - audioRange.duration.seconds) < 0.08, "Track end mismatch")
        let reader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderTrackOutput(track: videos[0], outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        let audioOutput = AVAssetReaderTrackOutput(track: audios[0], outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false])
        reader.add(videoOutput); reader.add(audioOutput)
        precondition(reader.startReading())
        var flash: Double?; var tone: Double?; var frameCount = 0
        while let sample = videoOutput.copyNextSampleBuffer() {
            frameCount += 1
            if let image = CMSampleBufferGetImageBuffer(sample) {
                CVPixelBufferLockBaseAddress(image, .readOnly)
                let value = CVPixelBufferGetBaseAddress(image)!.load(as: UInt8.self)
                CVPixelBufferUnlockBaseAddress(image, .readOnly)
                if value > 150 && flash == nil { flash = sample.presentationTimeStamp.seconds }
            }
        }
        while let sample = audioOutput.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var values = [Float](repeating: 0, count: length / 4)
            values.withUnsafeMutableBytes { ptr in _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: ptr.baseAddress!) }
            if tone == nil, let index = values.firstIndex(where: { abs($0) > 0.15 }) {
                tone = sample.presentationTimeStamp.seconds + Double(index / 2) / 48_000
            }
        }
        precondition(reader.status == .completed, reader.error?.localizedDescription ?? "Media decode failed")
        if checkSync {
            precondition(flash != nil && tone != nil, "Flash/tone must survive encoding")
            precondition(abs(flash! - tone!) < 0.06, "Decoded audio/video event drift \(flash! - tone!)")
        }
        print("Media: \(url.lastPathComponent), duration \(duration), frames \(frameCount), flash \(flash ?? -1), tone \(tone ?? -1)")
    }
}
