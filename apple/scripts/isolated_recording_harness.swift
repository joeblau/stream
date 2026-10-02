import AVFoundation
import Foundation
import StreamCore

// AudioMixEngine uses capture keys only as opaque dictionary identities. No
// screen/microphone hardware is acquired by this native media harness.
struct CaptureSourceKey: Hashable, Sendable { let id: UUID }
struct SourceDefinitionID: Hashable, Sendable, CustomStringConvertible {
    let id: UUID
    var description: String { id.uuidString }
}

final class ISOProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: [String: IsolatedTrackProgress] = [:]
    private var packets = 0
    private var lowSpace = false
    func receive(_ progress: IsolatedTrackProgress) { lock.lock(); latest[progress.id] = progress; lock.unlock() }
    func snapshot(_ id: String) -> IsolatedTrackProgress? { lock.lock(); defer { lock.unlock() }; return latest[id] }
    func packet() { lock.lock(); packets += 1; lock.unlock() }
    func packetCount() -> Int { lock.lock(); defer { lock.unlock() }; return packets }
    func exhaust() { lock.lock(); lowSpace = true; lock.unlock() }
    func space() -> Int64 { lock.lock(); defer { lock.unlock() }; return lowSpace ? 1 : 2_000_000_000 }
}

@main struct IsolatedRecordingHarness {
    static func main() async throws {
        let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try await mixerRecording(folder)
        try await exhaustedTrack(folder)
        try await overloadedTrack(folder)
    }

    static func finish(_ track: IsolatedAudioRecorder) async {
        await withCheckedContinuation { continuation in track.finish { continuation.resume() } }
    }
    static func finish(_ writer: ProgramRecordingSession) async -> ProgramRecordingSession.Result {
        await withCheckedContinuation { continuation in writer.finish { continuation.resume(returning: $0) } }
    }
    static func read(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: true)
        precondition(file.fileFormat.sampleRate == 48_000 && file.fileFormat.channelCount == 2)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        return CanonicalAudioConverter.interleavedFloats(buffer)!
    }
    static func rms(_ samples: [Float], from start: Double, to end: Double) -> Double {
        let begin = max(0, Int(start * 96_000)), finish = min(samples.count, Int(end * 96_000))
        precondition(finish > begin)
        return sqrt(samples[begin..<finish].reduce(0.0) { $0 + Double($1 * $1) } / Double(finish - begin))
    }
    static func journal(_ url: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url.appendingPathExtension("isolated.json"))) as! [String: Any]
    }

    static func mixerRecording(_ folder: URL) async throws {
        let probe = ISOProbe(), timeline = RecordingTimeline()
        let programURL = folder.appendingPathComponent("actual-mix.mp4")
        var config = ProgramRecordingSession.Configuration(); config.frameRate = 50
        config.sessionID = "actual-mixer-session"
        config.isolatedFiles = ["before.wav", "after.m4a"]
        config.context = .init(projectID: "project", profileID: "profile", projectName: "Show", profileName: "Studio")
        let writer = ProgramRecordingSession(outputURL: programURL, configuration: config, timeline: timeline)
        let rawURL = folder.appendingPathComponent("before.wav"), postURL = folder.appendingPathComponent("after.m4a")
        let raw = IsolatedAudioRecorder(outputURL: rawURL,
            selection: .init(targetID: "channel.mic.default", name: "Clean Microphone", processing: .beforeEffects),
            sessionID: config.sessionID, segmentIndex: 1, programFile: programURL.lastPathComponent,
            context: config.context, timeline: timeline, event: probe.receive)
        let post = IsolatedAudioRecorder(outputURL: postURL,
            selection: .init(targetID: "processed-mic", name: "Processed Microphone", processing: .afterEffects, format: .m4a),
            sessionID: config.sessionID, segmentIndex: 1, programFile: programURL.lastPathComponent,
            context: config.context, timeline: timeline, event: probe.receive)
        let engine = AudioMixEngine(), mic = AudioChannelID.microphone(deviceUID: nil)
        await engine.addTap(bus: .program, token: UUID(), capacity: 16) { writer.appendAudio($0); probe.packet() }
        await engine.addIsolatedTap(channel: mic, token: UUID(), capacity: 16, processing: .beforeEffects) { raw.append($0) }
        await engine.addIsolatedTap(channel: mic, token: UUID(), capacity: 16, processing: .afterEffects) { post.append($0) }
        await engine.run()
        let base = CMClockGetTime(CMClockGetHostTimeClock()).seconds + 0.02
        await engine.addChannel(mic) { sample in
            let offset = sample.presentationTimeStamp.seconds - base
            return (try? ProgramRecordingFixtures.audio(at: offset, timestampBase: base, amplitude: 0.2)) ?? sample
        }
        let clock = ContinuousClock(), start = clock.now
        for index in 0..<250 {
            let seconds = Double(index) / 100
            try await clock.sleep(until: start.advanced(by: .seconds(seconds)))
            // Stop this source for the final second while the bus, recording,
            // and unrelated consumer continue. Real underruns must be journaled.
            if index < 150 { engine.enqueue(mic, try ProgramRecordingFixtures.audio(at: seconds, timestampBase: base)) }
            if index % 2 == 0 { writer.appendVideo(try ProgramRecordingFixtures.video(at: seconds, timestampBase: base)) }
        }
        await engine.stop(); raw.deactivate(); post.deactivate()
        let result = await finish(writer)
        precondition(result.completed, result.error ?? "Program failed")
        await finish(raw); await finish(post)
        precondition(probe.snapshot("channel.mic.default")?.status == "complete")
        precondition(probe.snapshot("processed-mic")?.status == "complete")
        let before = try read(rawURL), after = try read(postURL)
        let beforeTone = Double(before.firstIndex(where: { abs($0) > 0.15 })! / 2) / 48_000
        let afterTone = Double(after.firstIndex(where: { abs($0) > 0.15 })! / 2) / 48_000
        let ratio = rms(before, from: beforeTone + 0.02, to: beforeTone + 0.08) / rms(after, from: afterTone + 0.02, to: afterTone + 0.08)
        precondition(abs(ratio - 4) < 0.12, "Real pre/post insert RMS ratio: \(ratio)")
        precondition(abs(beforeTone - afterTone) < 0.01, "WAV/AAC onset mismatch")
        for (id, url) in [("channel.mic.default", rawURL), ("processed-mic", postURL)] {
            let progress = probe.snapshot(id)!
            precondition(progress.missingSourceFrames >= 40_000, "Disconnected source must produce explicit counted gaps")
            precondition(abs(progress.durationSeconds - result.progress.durationSeconds) < 1.0 / 48_000)
            let metadata = try journal(url)
            precondition(metadata["sourceStartSeconds"] as? Double == result.progress.sessionStartSourceSeconds)
            precondition((metadata["gaps"] as? [[String: Any]])?.contains(where: { $0["reason"] as? String == "source-underrun-window" }) == true)
            precondition((metadata["context"] as? [String: Any])?["profileID"] as? String == "profile")
        }
        precondition(probe.packetCount() > 220, "Other bus consumers must advance after disconnect")
        try await ProgramRecordingFixtures.inspect(programURL, expectedDuration: nil, checkSync: true)
        print("PASS: actual AudioMixEngine pre/post inserts -> synchronized WAV/M4A, RMS ratio \(ratio), onset difference \(beforeTone-afterTone)s; disconnected-source silence and gaps; shared program session")
    }

    static func exhaustedTrack(_ folder: URL) async throws {
        let timeline = RecordingTimeline(), probe = ISOProbe()
        let programURL = folder.appendingPathComponent("independent-program.mp4")
        let writer = ProgramRecordingSession(outputURL: programURL, timeline: timeline)
        let healthyURL = folder.appendingPathComponent("healthy.wav"), partialURL = folder.appendingPathComponent("exhausted.wav")
        let healthy = IsolatedAudioRecorder(outputURL: healthyURL, selection: .init(targetID: "healthy", name: "Healthy"),
            sessionID: "independent", segmentIndex: 1, programFile: programURL.lastPathComponent, context: .init(), timeline: timeline, event: probe.receive)
        let exhausted = IsolatedAudioRecorder(outputURL: partialURL, selection: .init(targetID: "exhausted", name: "Exhausted"),
            sessionID: "independent", segmentIndex: 1, programFile: programURL.lastPathComponent, context: .init(), timeline: timeline,
            spaceProbe: { _ in probe.space() }, event: probe.receive)
        let original = folder.appendingPathComponent("existing.wav"), bytes = Data("existing-file".utf8)
        try bytes.write(to: original)
        let collision = IsolatedAudioRecorder(outputURL: original, selection: .init(targetID: "collision", name: "Collision"),
            sessionID: "independent", segmentIndex: 1, programFile: programURL.lastPathComponent, context: .init(), timeline: timeline, event: probe.receive)
        let clock = ContinuousClock(), start = clock.now
        for index in 0..<180 {
            let seconds = Double(index) / 100
            try await clock.sleep(until: start.advanced(by: .seconds(seconds)))
            if index == 90 { probe.exhaust() }
            let sample = try ProgramRecordingFixtures.audio(at: seconds)
            writer.appendAudio(sample); healthy.append(sample); exhausted.append(sample); collision.append(sample)
            if index % 2 == 0 { writer.appendVideo(try ProgramRecordingFixtures.video(at: seconds)) }
            probe.packet()
        }
        let result = await finish(writer); await finish(healthy); await finish(exhausted); await finish(collision)
        precondition(result.completed && probe.snapshot("healthy")?.status == "complete")
        precondition(probe.snapshot("exhausted")?.status == "failed" && probe.snapshot("collision")?.status == "failed")
        precondition(probe.snapshot("exhausted")!.durationSeconds > 0.5 && probe.snapshot("exhausted")!.durationSeconds < 1.4)
        let preserved = try Data(contentsOf: original), partial = try read(partialURL)
        precondition(preserved == bytes)
        precondition(partial.count > 48_000, "Playable partial WAV must be preserved")
        precondition(probe.packetCount() == 180)
        try await ProgramRecordingFixtures.inspect(programURL, expectedDuration: 1.8, checkSync: true)
        print("PASS: isolated low-storage and existing-file failures preserve partial/original files; healthy isolated track and H264/AAC program finish; other consumer continues")
    }

    static func overloadedTrack(_ folder: URL) async throws {
        let timeline = RecordingTimeline(), probe = ISOProbe()
        timeline.begin(at: CMTime(seconds: 10_000, preferredTimescale: 48_000))
        timeline.update(end: CMTime(seconds: 10_002, preferredTimescale: 48_000))
        let url = folder.appendingPathComponent("bounded.wav")
        let track = IsolatedAudioRecorder(outputURL: url, selection: .init(targetID: "bounded", name: "Bounded"),
            sessionID: "bounded", segmentIndex: 1, programFile: "program.mp4", context: .init(), timeline: timeline, event: probe.receive)
        for index in 0..<300 { track.append(try ProgramRecordingFixtures.audio(at: Double(index) / 100)) }
        await finish(track)
        let progress = probe.snapshot("bounded")!
        precondition(progress.status == "complete" && progress.droppedChunks > 0)
        precondition(abs(progress.durationSeconds - 2) < 1.0 / 48_000)
        let gaps = try journal(url)["gaps"] as! [[String: Any]]
        precondition(gaps.contains(where: { $0["reason"] as? String == "timeline-gap" }))
        print("PASS: isolated overload sheds \(progress.droppedChunks) chunks, writes aligned silence, and bounds three seconds of input to the two-second accepted program window")
    }
}
