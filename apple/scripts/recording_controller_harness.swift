import AVFoundation
import Foundation
import StreamCore

/// Hardware-independent source stand-in. The test uses the app's actual
/// controller/writer and feeds both taps on their common source clock.
@MainActor final class StreamController {
    struct FrameSubscription: Hashable { let id = UUID() }
    struct AudioTapSubscription: Hashable { let id = UUID() }
    struct Frame: @unchecked Sendable { let sampleBuffer: CMSampleBuffer }
    var activeProfile = OutputProfile(canvasWidth: 320, canvasHeight: 180, frameRate: 50)
    var demands = 0
    var networkPackets = 0
    var noisyVideo = false
    private var videos: [FrameSubscription: @Sendable (Frame) -> Void] = [:]
    private var audios: [AudioTapSubscription: @Sendable (CMSampleBuffer) -> Void] = [:]
    func addFrameSink(sink: @escaping @Sendable (Frame) -> Void) -> FrameSubscription {
        let token = FrameSubscription(); videos[token] = sink; return token
    }
    func addProgramAudioTap(sink: @escaping @Sendable (CMSampleBuffer) -> Void) -> AudioTapSubscription {
        let token = AudioTapSubscription(); audios[token] = sink; return token
    }
    func removeFrameSink(_ token: FrameSubscription) { videos.removeValue(forKey: token) }
    func removeAudioTap(_ token: AudioTapSubscription) { audios.removeValue(forKey: token) }
    func noteRecordingStarted() { demands += 1 }
    func noteRecordingStopped() { demands -= 1 }
    func feed(seconds: Double, offset: Double = 0) async throws {
        let clock = ContinuousClock(); let start = clock.now
        for index in 0..<Int(seconds * 100) {
            let time = Double(index) / 100
            try await clock.sleep(until: start.advanced(by: .seconds(time)))
            let audio = try ProgramRecordingFixtures.audio(at: time + offset)
            for sink in audios.values { sink(audio) }
            if index % 2 == 0 {
                let video = try ProgramRecordingFixtures.video(at: time + offset, noisy: noisyVideo)
                for sink in videos.values { sink(Frame(sampleBuffer: video)) }
            }
            networkPackets += 1
        }
    }
}

@main struct RecordingControllerHarness {
    @MainActor static func main() async throws {
        let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = "com.joeblau.Stream.recording-validation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let recorder = RecordingController(defaults: defaults, defaultDirectory: folder)
        let source = StreamController()
        recorder.preferences.countdownSeconds = 1
        recorder.start(stream: source)
        precondition(recorder.state == .preparing && recorder.countdownRemaining == 1 && source.demands == 0)
        recorder.stop()
        try await Task.sleep(for: .milliseconds(1100))
        precondition(recorder.state == .idle && source.demands == 0, "Cancelled countdown cannot start later")
        print("PASS: controller countdown cancellation and independent demand")
        recorder.start(stream: source)
        try await Task.sleep(for: .milliseconds(1100))
        precondition(recorder.state == .preparing && source.demands == 1, "Countdown starts writer demand without claiming Recording")
        try await source.feed(seconds: 1)
        precondition(recorder.state == .recording)
        recorder.pause()
        try await Task.sleep(for: .milliseconds(30))
        precondition(recorder.state == .paused && source.demands == 1)
        let networkBefore = source.networkPackets
        try await source.feed(seconds: 0.3, offset: 1)
        precondition(source.networkPackets > networkBefore && recorder.state == .paused, "Other consumers continue while paused")
        recorder.resume()
        try await source.feed(seconds: 0.5, offset: 1.3)
        precondition(recorder.state == .recording)
        recorder.startNewFile()
        precondition(recorder.state == .preparing && source.demands == 1, "File rotation must retain source demand")
        try await source.feed(seconds: 0.5, offset: 1.8)
        await withCheckedContinuation { continuation in recorder.stop { continuation.resume() } }
        precondition(recorder.state == .idle && source.demands == 0)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "mp4" }
        precondition(files.count == 2, "Manual file rotation must finalize both files")
        for file in files {
            let asset = AVURLAsset(url: file)
            let video = try await asset.loadTracks(withMediaType: .video)
            let audio = try await asset.loadTracks(withMediaType: .audio)
            precondition(video.count == 1 && audio.count == 1)
        }
        print("PASS: actual controller prepare/write/pause/resume/rotate/stop, real finalized program tracks, and unrelated consumer progress")

        recorder.preferences.countdownSeconds = 0
        recorder.preferences.splitAfterMinutes = 1
        recorder.start(stream: source)
        try await source.feed(seconds: 0.2, offset: 100)
        try await source.feed(seconds: 0.2, offset: 161)
        try await Task.sleep(for: .milliseconds(1100))
        precondition(recorder.state == .preparing && source.demands == 1, "Source-clock duration must rotate independently")
        try await source.feed(seconds: 0.3, offset: 161.2)
        await withCheckedContinuation { continuation in recorder.stop { continuation.resume() } }
        let afterDuration = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "mp4" }
        precondition(afterDuration.count == 4 && recorder.state == .idle && source.demands == 0)
        print("PASS: automatic duration rotation uses the source clock and retains output demand")

        recorder.preferences.splitAfterMinutes = 0
        recorder.preferences.splitAfterMegabytes = 1
        source.noisyVideo = true
        recorder.start(stream: source)
        try await source.feed(seconds: 8, offset: 200)
        await withCheckedContinuation { continuation in recorder.stop { continuation.resume() } }
        let afterSize = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "mp4" }
        precondition(afterSize.count > afterDuration.count + 1 && recorder.state == .idle && source.demands == 0, "Actual on-disk bytes must trigger automatic size rotation")
        precondition(recorder.storagePreflight().isReady)
        print("PASS: real output size triggers automatic rotation; selected-folder storage preflight is writable and ready")
    }
}
