import AVFoundation
import CoreMedia
import Foundation

@main private struct TerminalAudioEOSHarness {
    static func report(_ message: String) {
        FileHandle.standardOutput.write(Data((message + "\n").utf8))
    }
    static func until(_ label: String, _ predicate: @Sendable () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await predicate()) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let reached = await predicate()
        precondition(reached, "Terminal audio setup deadline: \(label)")
    }
    static func finish(_ session: ProgramRecordingSession) async -> ProgramRecordingSession.Result {
        await withCheckedContinuation { continuation in
            session.finish { continuation.resume(returning: $0) }
        }
    }
    static func main() async throws {
        let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        report("BOUNDARY actual ProgramRecordingSession/AVAssetWriter + owned generated pixels/PCM; injected final-video readiness gate; no capture/audio engine/helper/network/UI")
        try await terminalAudioAhead(folder)
        try await heldRealTail(folder)
    }
    static func terminalAudioAhead(_ folder: URL) async throws {
        report("BEGIN actual terminal-audio-ahead writer contract")
        var config = ProgramRecordingSession.Configuration()
        config.frameRate = 60; config.videoCapacity = 60
        let finalVideo = try ProgramRecordingFixtures.video(at: 59.0 / 60)
        config.validationHeldVideoPTS = finalVideo.presentationTimeStamp
        let session = ProgramRecordingSession(outputURL: folder.appendingPathComponent("audio-ahead.mp4"), configuration: config)
        for index in 0..<59 { session.appendVideo(try ProgramRecordingFixtures.video(at: Double(index) / 60)) }
        for index in 0..<100 { session.appendAudio(try ProgramRecordingFixtures.audio(at: Double(index) / 100)) }
        try await until("actual 59-video/100-audio accepted frontier") {
            let state = await session.validationSnapshot()
            return state.progress.videoSamples == 59 && state.progress.audioSamples == 100
                && state.videoEmpty && state.audioEmpty && state.audioEOSCalls == 0 && !state.finishRequested
        }
        let before = await session.validationSnapshot()
        precondition((before.progress.audioEndSeconds ?? 0) >= 1 - 1.0 / 48_000
            && (before.progress.videoEndSeconds ?? 1) < 1,
            "Terminal audio setup did not establish a genuine accepted audio-ahead frontier")
        report("FRONTIER video=59 audio=100 videoQueue=0 audioQueue=0 audioEOS=0")
        session.appendVideo(finalVideo)
        let result = await finish(session)
        let after = await session.validationSnapshot()
        report("RESULT terminal-eos completed=\(result.completed) video=\(result.progress.videoSamples) audio=\(result.progress.audioSamples) audioEOS=\(after.audioEOSCalls) error=\(result.error ?? "none")")
        precondition(result.completed && result.progress.videoSamples == 60 && result.progress.audioSamples == 100,
                     "Terminal audio EOS did not unblock final video")
        precondition(after.audioEOSCalls == 1 && result.progress.droppedAudio == 0 && result.progress.droppedVideo == 0
            && result.progress.videoTransfer == nil, "Terminal audio writer duplicated EOS or dropped an input")
        try await ProgramRecordingFixtures.inspect(result.url, expectedDuration: 1, checkSync: true)
        report("PASS terminal audio EOS: actual60video/100audio, one native audio EOS, original1s/80ms decode gates")
    }
    static func heldRealTail(_ folder: URL) async throws {
        report("BEGIN held real PCM tail")
        var config = ProgramRecordingSession.Configuration()
        config.frameRate = 60; config.videoCapacity = 60
        let session = ProgramRecordingSession(outputURL: folder.appendingPathComponent("held-tail.mp4"), configuration: config)
        for index in 0..<60 { session.appendVideo(try ProgramRecordingFixtures.video(at: Double(index) / 60)) }
        for index in 0..<99 { session.appendAudio(try ProgramRecordingFixtures.audio(at: Double(index) / 100)) }
        let finishing = Task { await finish(session) }
        try await until("actual finish awaiting one real PCM chunk") {
            let state = await session.validationSnapshot()
            return state.finishRequested && state.progress.audioSamples == 99 && state.audioEmpty
        }
        let held = await session.validationSnapshot()
        precondition(!held.awaitingFinishBoundary && !held.finishing && held.audioEOSCalls == 0 && held.acceptingAudio,
                     "Terminal audio EOS closed a genuinely missing PCM tail")
        session.appendAudio(try ProgramRecordingFixtures.audio(at: 0.99))
        let result = await finishing.value
        let after = await session.validationSnapshot()
        precondition(result.completed && result.progress.videoSamples == 60 && result.progress.audioSamples == 100
            && result.progress.droppedAudio == 0 && result.progress.droppedVideo == 0 && result.progress.videoTransfer == nil,
            "Held original PCM tail did not complete the unchanged recording boundary")
        precondition(after.audioEOSCalls == 1, "Held PCM tail duplicated native audio EOS")
        try await ProgramRecordingFixtures.inspect(result.url, expectedDuration: 1, checkSync: true)
        report("PASS held actual99+1PCM tail: no premature EOS;60video/100audio; original1s/80ms decode gates")
    }
}
