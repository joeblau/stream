import AVFoundation
import CoreMedia
import Foundation

private func logFraction(_ message: String) { FileHandle.standardOutput.write(Data((message + "\n").utf8)) }
private final class FractionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: IsolatedVideoProgress?
    func receive(_ value: IsolatedVideoProgress) { lock.lock(); latest = value; lock.unlock() }
    func status() -> IsolatedVideoProgress? { lock.lock(); defer { lock.unlock() }; return latest }
}
@main struct FractionalISOAudioHarness {
    struct Decoded {
        let samples: [Float]
        let start: CMTime
        let end: CMTime
        let cue: Int
    }
    static func main() async throws {
        let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var failures: [String] = []
        for fraction in [10, 49, 51, 90] {
            if !(try await scenario(folder: folder, hundredths: fraction)) { failures.append("\(fraction)/100 sample") }
        }
        if !(try await scenario(folder: folder, hundredths: 51, nanosecondClock: true)) { failures.append("nanosecond512 grid") }
        guard failures.isEmpty else { throw NSError(domain: "FractionalISOAudioHarness", code: 1, userInfo: [NSLocalizedDescriptionKey: "Nonzero decoded PCM alignment at \(failures.joined(separator: ", "))"]) }
        logFraction("PASS: actual Program/associated ISO AAC .1/.49/.51/.9 sample origins; rational cues within one PCM sample; zero-lag waveform best; real whole-sample gaps preserved; original source timestamps")
    }
    static func finish(_ writer: ProgramRecordingSession) async -> ProgramRecordingSession.Result {
        await withCheckedContinuation { continuation in writer.finish { continuation.resume(returning: $0) } }
    }
    static func finish(_ writer: IsolatedVideoRecorder) async {
        await withCheckedContinuation { continuation in writer.finish { continuation.resume() } }
    }
    static func video(pts: CMTime, duration: CMTime, size: CGSize = CGSize(width: 320, height: 180)) throws -> CMSampleBuffer {
        var pixel: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA, nil, &pixel) == kCVReturnSuccess, let pixel else { throw CocoaError(.fileReadUnknown) }
        CVPixelBufferLockBaseAddress(pixel, [])
        memset(CVPixelBufferGetBaseAddress(pixel), 0, CVPixelBufferGetDataSize(pixel))
        CVPixelBufferUnlockBaseAddress(pixel, [])
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixel, formatDescriptionOut: &format) == noErr else { throw CocoaError(.fileReadUnknown) }
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixel, formatDescription: format!, sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else { throw CocoaError(.fileReadUnknown) }
        return sample
    }
    static func audio(index: Int, base: CMTime, frames: Int) throws -> CMSampleBuffer {
        let floats: [Float] = (0..<(frames * 2)).map { sample in
            let frame = index * frames + sample / 2
            let tone = frame >= 24_000 && !(65..<70).contains(index)
            return tone ? Float(sin(Double(frame) / 48_000 * 2 * .pi * 600)) * 0.4 : 0
        }
        var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8,
            mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr else { throw CocoaError(.fileReadUnknown) }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: floats.count * 4, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: floats.count * 4, flags: 0, blockBufferOut: &block) == noErr, let block else { throw CocoaError(.fileReadUnknown) }
        guard floats.withUnsafeBytes({ CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: $0.count) }) == noErr else { throw CocoaError(.fileReadUnknown) }
        var sample: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: format!, sampleCount: frames,
            presentationTimeStamp: base + CMTime(value: Int64(index * frames), timescale: 48_000), packetDescriptions: nil, sampleBufferOut: &sample) == noErr, let sample else { throw CocoaError(.fileReadUnknown) }
        return sample
    }
    static func decoded(_ url: URL) async throws -> Decoded {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        precondition(tracks.count == 1)
        let range = try await tracks[0].load(.timeRange)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false])
        reader.add(output); precondition(reader.startReading())
        var values: [Float] = [], start: CMTime = .invalid, end: CMTime = .invalid
        while let sample = output.copyNextSampleBuffer() {
            if !start.isNumeric { start = sample.presentationTimeStamp }
            guard let block = sample.dataBuffer else { throw CocoaError(.fileReadCorruptFile) }
            var packet = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / 4)
            precondition(packet.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) } == noErr)
            values += packet
            end = sample.presentationTimeStamp + CMTime(value: Int64(sample.numSamples), timescale: 48_000)
        }
        precondition(reader.status == .completed && start.isNumeric && end.isNumeric)
        precondition(abs((end - CMTimeRangeGetEnd(range)).seconds) <= 1 / 48_000)
        let cue = values.firstIndex { abs($0) > 0.025 }! / 2
        return .init(samples: values, start: start, end: end, cue: cue)
    }
    static func scenario(folder: URL, hundredths: Int, nanosecondClock: Bool = false) async throws -> Bool {
        let path = folder.appendingPathComponent("fraction-\(hundredths)\(nanosecondClock ? "-host-nanoseconds" : "")", isDirectory: true)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let base = nanosecondClock ? CMTime(value: 92_286_276_768_750, timescale: 1_000_000_000) : CMTime(value: 480_000_000, timescale: 48_000)
        let fractional = nanosecondClock ? CMTime(value: 10_459, timescale: 1_000_000_000) : CMTime(value: Int64(hundredths), timescale: 4_800_000)
        let packetFrames = nanosecondClock ? 512 : 480
        let origin = base - fractional, timeline = RecordingTimeline(), probe = FractionProbe()
        var config = ProgramRecordingSession.Configuration(); config.frameRate = 30
        let programURL = path.appendingPathComponent("program.mp4"), isoURL = path.appendingPathComponent("associated.mp4")
        let program = ProgramRecordingSession(outputURL: programURL, configuration: config, timeline: timeline)
        let source = IsolatedVideoSource(makeRenderer: {
            { size, pts, duration, _, _ in .init(sample: try? video(pts: pts, duration: duration, size: size), sourceAvailable: true) }
        })
        let isolated = IsolatedVideoRecorder(outputURL: isoURL,
            selection: .init(targetID: "fractional", name: "Owned Fractional PCM", frameRate: 15, audioTargetID: "bus.program"),
            source: source, sessionID: "fraction-\(hundredths)", segmentIndex: 1, programFile: programURL.lastPathComponent,
            context: .init(), budget: .current, timeline: timeline, event: probe.receive)
        let clock = ContinuousClock(), start = clock.now
        var videoIndex = 0
        for index in 0..<Int(ceil(1.4 * 48_000 / Double(packetFrames))) {
            let elapsed = Double(index * packetFrames) / 48_000
            try await clock.sleep(until: start.advanced(by: .seconds(elapsed)))
            let sample = try audio(index: index, base: base, frames: packetFrames)
            program.appendAudio(sample)
            // ISO joins after 30 real PCM packets and misses five real silent
            // packets. Its synthesized gap samples must match Program,
            // including fractional source-grid residue at a video origin.
            if index >= 30 && !(65..<70).contains(index) { isolated.appendAudio(sample) }
            while Double(videoIndex) / 30 <= elapsed {
                program.appendVideo(try video(pts: origin + CMTime(value: Int64(videoIndex), timescale: 30), duration: CMTime(value: 1, timescale: 30)))
                videoIndex += 1
            }
        }
        let result = await finish(program); await finish(isolated)
        precondition(result.completed, result.error ?? "Program failure")
        precondition(probe.status()?.status == "complete", probe.status()?.error ?? "ISO failure")
        let a = try await decoded(programURL), b = try await decoded(isoURL)
        let cueDifference = (b.start + CMTime(value: Int64(b.cue), timescale: 48_000)) - (a.start + CMTime(value: Int64(a.cue), timescale: 48_000))
        var errors: [Int: Double] = [:]
        for lag in -1...1 {
            var squared = 0.0, count = 0
            for frame in 24_100..<min(a.samples.count / 2, b.samples.count / 2) - 2 {
                guard !((65 * packetFrames - 1_024)..<(70 * packetFrames + 1_024)).contains(frame) else { continue } // native AAC gap transitions
                let delta = Double(a.samples[frame * 2]) - Double(b.samples[(frame + lag) * 2])
                squared += delta * delta; count += 1
            }
            errors[lag] = sqrt(squared / Double(count))
        }
        let aligned = errors[0]! < errors[-1]! && errors[0]! < errors[1]!
        let cueWithinSample = CMTimeAbsoluteValue(cueDifference) <= CMTime(value: 1, timescale: 48_000)
        let sameWindow = a.start == b.start && a.end == b.end && a.samples.count == b.samples.count
        let journal = try JSONSerialization.jsonObject(with: Data(contentsOf: isoURL.appendingPathExtension("video-isolated.json"))) as! [String: Any]
        let gaps = journal["gaps"] as! [[String: Any]]
        let timelineGaps = gaps.filter { $0["reason"] as? String == "associated-audio-timeline-gap" }
        let counts = timelineGaps.map { Int((($0["durationSeconds"] as! Double) * 48_000).rounded()) }
        let genuineGap = 5 * packetFrames
        let genuineGapPreserved = counts.contains(genuineGap)
        let programJournal = try JSONSerialization.jsonObject(with: Data(contentsOf: programURL.appendingPathExtension("recording.json"))) as! [String: Any]
        let isoJournal = try JSONSerialization.jsonObject(with: Data(contentsOf: isoURL.appendingPathExtension("recording.json"))) as! [String: Any]
        let programOffset = programJournal["audioStartOffsetSeconds"] as! Double
        let isoOffset = isoJournal["audioStartOffsetSeconds"] as! Double
        let sameSourceGrid = abs(programOffset - isoOffset) <= 1 / Double(base.timescale)
        logFraction("Genuine gap \(genuineGap) retained=\(genuineGapPreserved); clocktimescale=\(base.timescale); Program/ISO first source offsets=\(programOffset)/\(isoOffset), samegrid=\(sameSourceGrid)")
        logFraction("FRACTION \(hundredths)/100 sample \(nanosecondClock ? "host1e9/512" : "exact rational/480"): Program firstOffset=\(fractional.seconds) cueDifference=\(cueDifference.value)/\(cueDifference.timescale) RMSE −1/0/+1=\(errors[-1]!)/\(errors[0]!)/\(errors[1]!) gapCounts=\(counts) Program/ISO ends=\(a.end.value)/\(a.end.timescale),\(b.end.value)/\(b.end.timescale) aligned=\(aligned) cue<=1sample=\(cueWithinSample) commonWindow=\(sameWindow)")
        return aligned && cueWithinSample && sameWindow && genuineGapPreserved && sameSourceGrid
    }
}
