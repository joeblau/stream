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
    func receive(_ frame: CompositedFrame, warmingFrames: Int) {
        guard frame.sequence > warmingFrames else { return }
        let arrival = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        lock.lock(); defer { lock.unlock() }
        if let lastPTS, frame.presentationTime.seconds <= lastPTS { monotonic = false }
        if firstPTS == nil { firstPTS = frame.presentationTime.seconds; firstArrival = arrival }
        lastPTS = frame.presentationTime.seconds; lastArrival = arrival; count += 1
    }
    func snapshot() -> (count: Int, error: Double, monotonic: Bool) {
        lock.lock(); defer { lock.unlock() }
        let error = abs(((lastPTS ?? 0) - (firstPTS ?? 0)) - ((lastArrival ?? 0) - (firstArrival ?? 0)))
        return (count, error, monotonic)
    }
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
                probe.receive(frame, warmingFrames: fps)
                recording.appendVideo(frame.sampleBuffer)
            }
            // A deliberately slow consumer exercises isolated drop-oldest fanout.
            await engine.addSink(token: UUID(), capacity: 1) { _ in Thread.sleep(forTimeInterval: 0.080) }
            var before = StudioDiagnosticSnapshot(); before.sampleProcess()
            let clock = ContinuousClock(); let started = clock.now
            let sourceStart = CMClockGetTime(CMClockGetHostTimeClock()).seconds
            let audio = Task {
                for index in 0..<1000 {
                    if Task.isCancelled { break }
                    recording.appendAudio(try ProgramRecordingFixtures.audio(at: sourceStart + Double(index) / 100 - 10_000))
                    try await clock.sleep(until: started.advanced(by: .milliseconds((index + 1) * 10)))
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
            try await audio.value
            await engine.stop()
            await engine.removeSink(token)
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
                peakMemoryBytes: after.peakMemoryBytes, recording: result.progress, recordingComplete: result.completed))
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
