import AVFoundation
import CoreMedia
import Foundation
import StreamCore

private final class StaticFrame: @unchecked Sendable {
    let buffer: CVPixelBuffer
    init() throws { buffer = CMSampleBufferGetImageBuffer(try ProgramRecordingFixtures.video(at: 0, noisy: true))! }
}

private final class ArrivalProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var firstPTS: Double?
    private var firstArrival: Double?
    private var lastPTS: Double?
    private var lastArrival: Double?
    private var monotonic = true
    private var accepting = true
    private var sourceEnd: CMTime = .invalid
    func receive(_ frame: CompositedFrame, warmingFrames: Int, recording: ProgramRecordingSession) {
        let arrival = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        lock.lock(); defer { lock.unlock() }
        guard accepting else { return }
        recording.appendVideo(frame.sampleBuffer)
        sourceEnd = frame.presentationTime + frame.frameDuration
        guard frame.sequence > warmingFrames else { return }
        if let lastPTS, frame.presentationTime.seconds <= lastPTS { monotonic = false }
        if firstPTS == nil { firstPTS = frame.presentationTime.seconds; firstArrival = arrival }
        lastPTS = frame.presentationTime.seconds; lastArrival = arrival; count += 1
    }
    // Closing admission under the same lock fences an in-flight sink callback;
    // no frame can enter the recorder after this source frontier is returned.
    func closeVideo() -> CMTime {
        lock.lock(); defer { lock.unlock() }
        accepting = false
        return sourceEnd
    }
    func snapshot() -> (count: Int, error: Double, monotonic: Bool) {
        lock.lock(); defer { lock.unlock() }
        let error = abs(((lastPTS ?? 0) - (firstPTS ?? 0)) - ((lastArrival ?? 0) - (firstArrival ?? 0)))
        return (count, error, monotonic)
    }
}

private final class AudioFinishBoundary: @unchecked Sendable {
    private let lock = NSLock()
    private var value: CMTime?
    func set(_ time: CMTime) { lock.lock(); value = time; lock.unlock() }
    func snapshot() -> CMTime? { lock.lock(); defer { lock.unlock() }; return value }
}

private final class RecordingFailureFinalizer: @unchecked Sendable {
    private let lock = NSLock()
    private weak var session: ProgramRecordingSession?
    private var failedBeforeInstall = false
    func install(_ session: ProgramRecordingSession) {
        lock.lock(); self.session = session; let finish = failedBeforeInstall; lock.unlock()
        if finish { session.finish { _ in } }
    }
    func failed() {
        lock.lock(); let session = self.session; failedBeforeInstall = true; lock.unlock()
        session?.finish { _ in }
    }
}

private struct WorkloadResult: Codable {
    var width: Int
    var height: Int
    var fps: Int
    var layers: Int
    var seconds: Double
    var compositor: CompositionMetrics
    var healthySinkFrames: Int
    var hostClockDurationErrorSeconds: Double
    var maxMainActorSchedulingDelayMilliseconds: Double
    var processCPUSeconds: Double
    var peakMemoryBytes: Int64
    var recording: ProgramRecordingSession.Progress
    var recordingComplete: Bool
    var producedAudioFrames: Int64
    var sourceAudioTailCoverageSeconds: Double
}

@main struct StudioPerformanceHarness {
    @MainActor static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixed = try StaticFrame()
        let allCases = [(1280, 720, 30), (1920, 1080, 30), (1920, 1080, 60), (3840, 2160, 30)]
        let cases = CommandLine.arguments.contains("--4k-only") ? [allCases[3]] : allCases
        var results: [WorkloadResult] = []
        for (width, height, fps) in cases {
            var scene = Scene.screenPlusCam(name: "Synthetic static desktop and camera")
            for index in 0..<6 {
                scene.layers.append(LayerNode(name: "Editable shape \(index)", payload: .shape(ShapeSourcePayload(fillColorHex: "#245A86")),
                    transform: LayerTransform(position: GraphPoint(x: 0.1 + Double(index) * 0.12, y: 0.76), size: GraphSize(width: 0.08, height: 0.12), anchor: .topLeft)))
            }
            for index in 0..<4 {
                scene.layers.append(LayerNode(name: "Editable title \(index)", payload: .text(TextSourcePayload(text: "Workload title \(index)", fontSize: 30)),
                    transform: LayerTransform(position: GraphPoint(x: 0.02, y: Double(index) * 0.08), size: GraphSize(width: 0.65, height: 0.07), anchor: .topLeft)))
            }
            let engine = CompositionEngine(screenProvider: { fixed.buffer }, cameraProvider: { .init(buffer: fixed.buffer, position: .back) },
                sourcePayloadProvider: { [:] }, overlayContextProvider: { .empty }, sceneRegistryProvider: { [:] },
                transitionRequestProvider: { nil }, annotationProvider: { .empty }, canvasSize: CGSize(width: width, height: height), frameRate: fps)
            let probe = ArrivalProbe()
            var configuration = ProgramRecordingSession.Configuration()
            configuration.frameRate = fps; configuration.minimumSpaceBytes = 1; configuration.lowSpaceWarningBytes = 1
            let url = directory.appendingPathComponent("synthetic-\(width)x\(height)-\(fps).mp4")
            let finalizer = RecordingFailureFinalizer()
            let recording = ProgramRecordingSession(outputURL: url, configuration: configuration, event: { event in
                if case .failed = event { finalizer.failed() }
            })
            finalizer.install(recording)
            let token = UUID()
            await engine.addSink(token: token, capacity: 2) { frame in
                probe.receive(frame, warmingFrames: fps, recording: recording)
            }
            // A deliberately slow consumer exercises isolated drop-oldest fanout.
            await engine.addSink(token: UUID(), capacity: 1) { _ in Thread.sleep(forTimeInterval: 0.080) }
            var before = StudioDiagnosticSnapshot(); before.sampleProcess()
            let clock = ContinuousClock(); let started = clock.now
            let sourceStart = CMTimeConvertScale(CMClockGetTime(CMClockGetHostTimeClock()), timescale: 48_000, method: .roundTowardNegativeInfinity)
            let audioBoundary = AudioFinishBoundary()
            // Independent PCM follows its original 48 kHz source grid while
            // the engine runs. A fixed 1000 chunks ended at 10 s, before the
            // last actual frame's nominal endpoint (often 10.02–10.04 s).
            let audio = Task { () throws -> Int64 in
                var frames: Int64 = 0
                while true {
                    let pts = sourceStart + CMTime(value: frames, timescale: 48_000)
                    if let boundary = audioBoundary.snapshot(), pts >= boundary { return frames }
                    let sample = try ProgramRecordingFixtures.audio(at: Double(frames) / 48_000, timestampBase: 0, constantTone: true)
                    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000), presentationTimeStamp: pts, decodeTimeStamp: .invalid)
                    var timed: CMSampleBuffer?
                    let status = CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sample, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &timed)
                    guard status == noErr, let timed else { throw CocoaError(.fileReadUnknown) }
                    recording.appendAudio(timed)
                    frames += Int64(sample.numSamples)
                    try await clock.sleep(until: started.advanced(by: .milliseconds(frames * 1000 / 48_000)))
                }
            }
            await engine.run(scene: scene, canvasSize: CGSize(width: width, height: height), frameRate: fps)
            var deadline = started
            var maxDelay = 0.0
            while clock.now < started.advanced(by: .seconds(10)) {
                deadline = deadline.advanced(by: .milliseconds(20))
                try await clock.sleep(until: deadline)
                let delta = deadline.duration(to: clock.now).components
                maxDelay = max(maxDelay, Double(delta.seconds) * 1000 + Double(delta.attoseconds) / 1e15)
            }
            await engine.stop()
            await engine.removeSink(token)
            let finalVideoSourceEnd = probe.closeVideo()
            precondition(finalVideoSourceEnd.isNumeric, "No actual video frontier was delivered")
            recording.sealVideo()
            audioBoundary.set(finalVideoSourceEnd)
            let audioFrames = try await audio.value
            let sourceAudioTailCoverage = (sourceStart + CMTime(value: audioFrames, timescale: 48_000) - finalVideoSourceEnd).seconds
            precondition(sourceAudioTailCoverage >= 0, "Independent PCM must cover the final submitted video source endpoint")
            let metrics = await engine.metricsSnapshot()
            let result = await withCheckedContinuation { continuation in recording.finish { continuation.resume(returning: $0) } }
            var after = StudioDiagnosticSnapshot(); after.sampleProcess()
            let arrival = probe.snapshot()
            FileHandle.standardOutput.write(Data("ARRIVALS: \(width)x\(height) count \(arrival.count), monotonic \(arrival.monotonic), rendered \(metrics.rendered), failed \(metrics.failed)\n".utf8))
            precondition(arrival.count > fps && arrival.monotonic, "Static sources must keep producing monotonic output")
            precondition(arrival.error < 0.08, "Video duration diverged from host-clock audio: \(arrival.error)")
            if result.completed {
                try await ProgramRecordingFixtures.inspect(url, expectedDuration: nil, checkSync: false)
            } else {
                print("MEASURED LIMIT: \(width)x\(height) \(fps) recording failed: \(result.error ?? "Unknown writer failure")")
            }
            let measured = started.duration(to: clock.now).components
            results.append(.init(width: width, height: height, fps: fps, layers: scene.layers.count,
                seconds: Double(measured.seconds) + Double(measured.attoseconds) / 1e18, compositor: metrics,
                healthySinkFrames: arrival.count, hostClockDurationErrorSeconds: arrival.error,
                maxMainActorSchedulingDelayMilliseconds: maxDelay, processCPUSeconds: after.processCPUSeconds - before.processCPUSeconds,
                peakMemoryBytes: after.peakMemoryBytes, recording: result.progress, recordingComplete: result.completed,
                producedAudioFrames: audioFrames, sourceAudioTailCoverageSeconds: sourceAudioTailCoverage))
            print("SOURCE GRID: \(width)x\(height) \(fps) fps, \(audioFrames) independent PCM frames, final video source end \(finalVideoSourceEnd.seconds), PCM tail coverage \(sourceAudioTailCoverage) seconds, recording complete \(result.completed)")
            print("MEASURED: \(width)x\(height) \(fps) fps, \(scene.layers.count) layers, achieved \(metrics.achievedFPS), mean render \(metrics.meanRenderMilliseconds) ms, host-clock error \(arrival.error), main actor max lag \(maxDelay) ms")
        }
        struct Report: Codable {
            var date = Date()
            var os = ProcessInfo.processInfo.operatingSystemVersionString
            var hardwareModel = StudioDiagnosticSnapshot.machineModel()
            var processors = ProcessInfo.processInfo.processorCount
            var physicalMemory = ProcessInfo.processInfo.physicalMemory
            var limitations = "Ten-second synthetic capture/layer workloads with real H.264/AAC encoding, static-screen pacing and a slow fanout sink. This is a repeatable baseline, not physical-camera, media-decoder, network, GPU-utilization or sustained thermal qualification. Other workspace builds may compete for resources."
            var workloads: [WorkloadResult]
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(Report(workloads: results)).write(to: directory.appendingPathComponent("performance.json"), options: .atomic)
        print("PASS: paced static/layer workloads, monotonic host-clock timestamps, bounded slow sink isolation and machine-readable resource baseline. Recording qualification is reported separately for each workload.")
    }
}
