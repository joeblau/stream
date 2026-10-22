import AVFoundation
import Foundation
import StreamCore

/// Hardware-independent source stand-in. The test uses the app's actual
/// controller/writer and feeds both taps on their common source clock.
@MainActor final class StreamController {
    struct FrameSubscription: Hashable { let id = UUID() }
    struct AudioTapSubscription: Hashable { let id = UUID() }
    struct RecordingVideoSubscription: Hashable { let id = UUID() }
    struct Frame: @unchecked Sendable { let sampleBuffer: CMSampleBuffer }
    var activeProfile = OutputProfile(canvasWidth: 320, canvasHeight: 180, frameRate: 50)
    var activeSecondaryProfile: OutputProfile { activeProfile }
    let rawVideoResourceWorkspaceID = UUID()
    private let sourceResources = EngineSourceResources()
    private let broker = FrameDeliveryBroker()
    private var sourceBank: RawVideoResourceBank?
    private var sequence: Int64 = 0
    var holdNextInstallation = false
    private(set) var installationHeld = false
    private var installationContinuation: CheckedContinuation<Void, Never>?
    var demands = 0
    var networkPackets = 0
    var noisyVideo = false
    var activePublishingEncoderCount: Int { 1 }
    private var reservations = StudioEncoderReservations()
    func reserveRecordingEncoders(_ id: UUID, count: Int, canvas: OutputCanvas) -> String? {
        reservations.reserve(id, encoders: count, publishing: activePublishingEncoderCount)
    }
    func releaseRecordingEncoders(_ id: UUID) { reservations.release(id) }
    func recordingVideoSources() -> [RecordingVideoSource] { [] }
    func addRecordingVideoSource(targetID: String,
        deliveryProvider: @escaping @Sendable () -> RecordingVideoFrameDelivery? = { nil }) -> (RecordingVideoSubscription, IsolatedVideoSource)? { nil }
    func sourceFrameResourceRequest(canvasSize: CGSize, canvas: OutputCanvas = .program,
                                    clean: Bool = false) throws -> RawVideoResourceRequest {
        try sourceResources.request(size: canvasSize, canvas: canvas, clean: clean)
    }
    func awaitFrameDeliveryGeometry(canvas: OutputCanvas = .program, expectedSize: CGSize) async throws {
        try Task.checkCancellation()
        guard expectedSize == activeProfile.canvasSize else { throw RawVideoResourceFailure.sessionConflict }
    }
    func installFrameDelivery(token: UUID, domain: StableFrameDomainID, generation: UUID,
                              bank: RawVideoResourceBank, sourceBank: RawVideoResourceBank?, sourceReceipt: RawVideoResourceReceipt?,
                              transfer: FrameDeliveryTransfer = .copyBGRA, capacity: Int = 2,
                              canvas: OutputCanvas = .program, clean: Bool = false,
                              cancellation: FrameDeliveryCancellation,
                              authorized: @escaping @Sendable () -> Bool = { true },
                              sink: @escaping @Sendable (CompositedFrame) -> Void) async throws -> FrameDeliveryLease {
        if holdNextInstallation {
            holdNextInstallation = false; installationHeld = true
            await withCheckedContinuation { installationContinuation = $0 }
        }
        try Task.checkCancellation()
        guard !cancellation.isCancelled, let sourceBank, let sourceReceipt else { throw FrameDeliveryFailure.cancelled }
        try await awaitFrameDeliveryGeometry(canvas: canvas,
            expectedSize: CGSize(width: sourceBank.descriptor.width, height: sourceBank.descriptor.height))
        let lease = try broker.install(token: token, domain: domain, generation: generation, bank: bank,
            transfer: transfer, capacity: capacity, cancellation: cancellation, authorized: authorized, sink: sink)
        do { self.sourceBank = try sourceResources.commit(sourceBank, receipt: sourceReceipt,
                    size: activeProfile.canvasSize, canvas: canvas, clean: clean) }
        catch { broker.remove(lease); throw error }
        return lease
    }
    func releaseInstallation() {
        let continuation = installationContinuation; installationContinuation = nil; installationHeld = false
        continuation?.resume()
    }
    @discardableResult
    func removeFrameDelivery(_ lease: FrameDeliveryLease) async -> FrameDeliveryStatistics { broker.remove(lease) }
    func frameDeliveryStatistics(_ lease: FrameDeliveryLease) async -> FrameDeliveryStatistics { broker.statistics(for: lease) }
    func cancelFrameDelivery(token: UUID) async { broker.cancel(token: token) }
    func removeRecordingVideoSource(_ subscription: RecordingVideoSubscription) {}
    private var videos: [FrameSubscription: @Sendable (Frame) -> Void] = [:]
    private var audios: [AudioTapSubscription: @Sendable (CMSampleBuffer) -> Void] = [:]
    func addFrameSink(canvas: OutputCanvas = .program, sink: @escaping @Sendable (Frame) -> Void) -> FrameSubscription {
        let token = FrameSubscription(); videos[token] = sink; return token
    }
    func addProgramAudioTap(sink: @escaping @Sendable (CMSampleBuffer) -> Void) -> AudioTapSubscription {
        let token = AudioTapSubscription(); audios[token] = sink; return token
    }
    func addRecordingAudioTap(targetID: String, processing: IsolatedAudioProcessing,
                              sink: @escaping @Sendable (CMSampleBuffer) -> Void) -> AudioTapSubscription? {
        guard targetID != "missing" else { return nil }
        return addProgramAudioTap(sink: sink)
    }
    func removeFrameSink(_ token: FrameSubscription) { videos.removeValue(forKey: token) }
    func removeAudioTap(_ token: AudioTapSubscription) { audios.removeValue(forKey: token) }
    func noteRecordingStarted(canvas: OutputCanvas = .program) { demands += 1 }
    func noteRecordingStopped(canvas: OutputCanvas = .program) { demands -= 1 }
    func feed(seconds: Double, offset: Double = 0) async throws {
        let clock = ContinuousClock(); let start = clock.now
        for index in 0..<Int(seconds * 100) {
            let time = Double(index) / 100
            try await clock.sleep(until: start.advanced(by: .seconds(time)))
            let audio = try ProgramRecordingFixtures.audio(at: time + offset)
            for sink in audios.values { sink(audio) }
            if index % 2 == 0 {
                let video = try ProgramRecordingFixtures.video(at: time + offset, noisy: noisyVideo)
                if let sourceBank {
                    let owned = try FrameDeliveryConverter.copy(source: video, into: sourceBank)
                    sequence += 1
                    broker.offer(.init(sampleBuffer: owned, presentationTime: owned.presentationTimeStamp,
                        frameDuration: owned.duration, sequence: sequence))
                }
                for sink in videos.values { sink(Frame(sampleBuffer: video)) }
            }
            networkPackets += 1
        }
    }
}

@main struct RecordingControllerHarness {
    @MainActor private static func waitUntil(_ label: String, _ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !predicate() {
            precondition(ContinuousClock.now < deadline, "Timed out: \(label)")
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    @MainActor static func main() async throws {
        let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = "com.joeblau.Stream.recording-validation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data(#"{"quality":"high","filenamePrefix":"Legacy"}"#.utf8), forKey: "recording.preferences.v1")
        let recorder = RecordingController(defaults: defaults, defaultDirectory: folder)
        let profileA = folder.appendingPathComponent("ProfileA"), profileB = folder.appendingPathComponent("ProfileB")
        recorder.loadPreferences(directory: profileA)
        precondition(recorder.preferences.quality == .high && recorder.preferences.filenamePrefix == "Legacy")
        recorder.preferences.filenamePrefix = "ShowA"
        recorder.loadPreferences(directory: profileB)
        precondition(recorder.preferences.quality == .standard && recorder.preferences.filenamePrefix == "Stream")
        recorder.preferences.filenamePrefix = "ShowB"
        recorder.loadPreferences(directory: profileA)
        precondition(recorder.preferences.filenamePrefix == "ShowA" && recorder.preferences.quality == .high)
        recorder.preferences.filenamePrefix = "Stream"
        recorder.preferences.quality = .standard
        print("PASS: legacy preset migration once, independent profile preferences, and reload persistence")
        let source = StreamController()
        recorder.preferences.isolatedTracks = [
            .init(targetID: "microphone", name: "Microphone", processing: .beforeEffects, format: .wav),
            .init(targetID: "bus.program", name: "Program Bus", processing: .afterEffects, format: .m4a),
            .init(targetID: "missing", name: "Disconnected Guest", processing: .afterEffects, format: .wav)
        ]
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
        let previousURL = recorder.currentOutputURL
        recorder.startNewFile()
        try await waitUntil("File rotation install acknowledgment") { recorder.currentOutputURL != previousURL && recorder.state == .preparing }
        precondition(source.demands == 1, "File rotation must retain source demand")
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
            let duration = try await asset.load(.duration).seconds
            let journal = try JSONSerialization.jsonObject(with: Data(contentsOf: file.appendingPathExtension("recording.json"))) as! [String: Any]
            for name in journal["isolatedFiles"] as! [String] {
                let isolated = folder.appendingPathComponent(name)
                let trackJournal = try JSONSerialization.jsonObject(with: Data(contentsOf: isolated.appendingPathExtension("isolated.json"))) as! [String: Any]
                let selection = trackJournal["selection"] as! [String: Any]
                let progress = trackJournal["progress"] as! [String: Any]
                if selection["targetID"] as? String == "missing" {
                    precondition(progress["status"] as? String == "failed")
                } else {
                    precondition(progress["status"] as? String == "complete", "Isolated finalization: \(progress)")
                    let audioFile = try AVAudioFile(forReading: isolated)
                    precondition(abs(Double(audioFile.length) / audioFile.fileFormat.sampleRate - duration) < 0.06)
                }
            }
        }
        print("PASS: actual controller pause/resume/rotation with synchronized WAV/M4A files; unresolved track fails independently; unrelated consumer advances")
        recorder.preferences.isolatedTracks = []

        recorder.preferences.countdownSeconds = 0
        recorder.preferences.splitAfterMinutes = 1
        recorder.start(stream: source)
        try await waitUntil("Duration recording install acknowledgment") { source.demands == 1 }
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
        try await waitUntil("Size recording install acknowledgment") { source.demands == 1 }
        try await source.feed(seconds: 8, offset: 200)
        await withCheckedContinuation { continuation in recorder.stop { continuation.resume() } }
        let afterSize = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "mp4" }
        precondition(afterSize.count > afterDuration.count + 1 && recorder.state == .idle && source.demands == 0, "Actual on-disk bytes must trigger automatic size rotation")
        precondition(recorder.storagePreflight().isReady)
        print("PASS: real output size triggers automatic rotation; selected-folder storage preflight is writable and ready")
        source.noisyVideo = false
        recorder.preferences.splitAfterMegabytes = 0
        recorder.start(stream: source)
        try await waitUntil("Handoff recording install") { source.demands == 1 }
        try await source.feed(seconds: 0.2, offset: 400)
        try await waitUntil("Handoff first actual writer append") { recorder.state == .recording }
        let heldPreviousURL = recorder.currentOutputURL
        source.holdNextInstallation = true
        recorder.startNewFile()
        try await waitUntil("Held rotation entered") { source.installationHeld }
        recorder.pause()
        precondition(recorder.state == .recording && !recorder.canSplit,
                     "Pause intent during handoff must neither pause the retiring segment nor disappear")
        source.releaseInstallation()
        try await waitUntil("Held rotation acknowledgment") { recorder.currentOutputURL != heldPreviousURL && recorder.state == .preparing }
        try await source.feed(seconds: 0.2, offset: 400.2)
        try await waitUntil("Deferred Pause actual writer acknowledgment") { recorder.state == .paused }
        recorder.resume()
        try await source.feed(seconds: 0.2, offset: 400.4)
        await withCheckedContinuation { continuation in recorder.stop { continuation.resume() } }
        precondition(recorder.state == .idle && source.demands == 0)
        print("PASS: held actual broker installation preserves Pause intent through new writer recording/paused acknowledgments")

        source.holdNextInstallation = true
        recorder.start(stream: source)
        try await waitUntil("Held initial installation entered") { source.installationHeld }
        var canceledStopCompleted = false
        recorder.stop { canceledStopCompleted = true }
        precondition(!canceledStopCompleted && source.demands == 0 && recorder.state == .stopping,
                     "Stop cannot acknowledge a still-pending installation")
        source.releaseInstallation()
        try await waitUntil("Canceled installation teardown") { canceledStopCompleted }
        precondition(recorder.state == .idle && recorder.currentOutputURL == nil && source.demands == 0)
        recorder.start(stream: source)
        try await waitUntil("Fresh retry installation") { source.demands == 1 }
        try await source.feed(seconds: 0.2, offset: 500)
        await withCheckedContinuation { continuation in recorder.stop { continuation.resume() } }
        precondition(recorder.state == .idle && source.demands == 0 && recorder.lastError == nil)
        print("PASS: Stop-before-install acknowledgment drains owned cancellation; fresh retry uses new private bank and completes actual writer")
    }
}
