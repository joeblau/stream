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
            overloaded.appendVideo(try video(at: Double(index) / 60))
            overloaded.appendAudio(try audio(at: Double(index) / 100))
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

    static func feed(_ session: ProgramRecordingSession, seconds: Double) async throws {
        let clock = ContinuousClock(); let start = clock.now
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for index in 0..<Int(seconds * 60) {
                    let time = Double(index) / 60
                    try await clock.sleep(until: start.advanced(by: .seconds(time)))
                    session.appendVideo(try video(at: time))
                }
            }
            group.addTask {
                for index in 0..<Int(seconds * 100) {
                    let time = Double(index) / 100
                    try await clock.sleep(until: start.advanced(by: .seconds(time)))
                    session.appendAudio(try audio(at: time))
                }
            }
            try await group.waitForAll()
        }
    }

    static func video(at seconds: Double) throws -> CMSampleBuffer {
        var pixel: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, 320, 180, kCVPixelFormatType_32BGRA, nil, &pixel) == kCVReturnSuccess, let pixel else { throw CocoaError(.fileReadUnknown) }
        CVPixelBufferLockBaseAddress(pixel, [])
        let bright: UInt8 = (0.5..<0.6).contains(seconds) ? 255 : 0
        memset(CVPixelBufferGetBaseAddress(pixel), Int32(bright), CVPixelBufferGetDataSize(pixel))
        CVPixelBufferUnlockBaseAddress(pixel, [])
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixel, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 60), presentationTimeStamp: CMTime(seconds: 10_000 + seconds, preferredTimescale: 48_000), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixel, formatDescription: format!, sampleTiming: &timing, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw CocoaError(.fileReadUnknown) }
        return sample
    }

    static func audio(at seconds: Double) throws -> CMSampleBuffer {
        let floats: [Float] = (0..<960).map { index in
            let time = seconds + Double(index / 2) / 48_000
            return (0.5..<0.6).contains(time) ? Float(sin(time * 2 * .pi * 1000)) * 0.8 : 0
        }
        var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: floats.count * 4,
            blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: floats.count * 4,
            flags: 0, blockBufferOut: &block)
        let status = floats.withUnsafeBufferPointer { ptr in
            CMBlockBufferReplaceDataBytes(with: ptr.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: floats.count * 4)
        }
        precondition(status == noErr)
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block!,
            formatDescription: format!, sampleCount: 480,
            presentationTimeStamp: CMTime(seconds: 10_000 + seconds, preferredTimescale: 48_000),
            packetDescriptions: nil, sampleBufferOut: &sample)
        guard let sample else { throw CocoaError(.fileReadUnknown) }
        return sample
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
