import AppKit
import Darwin
import Combine
import CryptoKit
import Foundation
import StreamCore
import SwiftUI

struct CompositionMetrics: Codable, Sendable {
    var startedAt = ProcessInfo.processInfo.systemUptime
    var sampledAt = ProcessInfo.processInfo.systemUptime
    var attempts = 0
    var rendered = 0
    var failed = 0
    var missedDeadlines = 0
    var totalRenderMilliseconds = 0.0
    var maxRenderMilliseconds = 0.0
    var subscriberQueueDepth = 0
    var subscriberDrops = 0
    var lastPresentationSeconds: Double?
    var achievedFPS: Double { Double(rendered) / max(0.001, sampledAt - startedAt) }
    var meanRenderMilliseconds: Double { totalRenderMilliseconds / Double(max(1, attempts)) }
}

struct StudioDiagnosticSnapshot: Codable, Sendable {
    var version = 1
    var time = Date()
    var os = ProcessInfo.processInfo.operatingSystemVersionString
    var hardwareModel = Self.machineModel()
    var processors = ProcessInfo.processInfo.processorCount
    var physicalMemoryBytes = ProcessInfo.processInfo.physicalMemory
    var peakMemoryBytes: Int64 = 0
    var processCPUSeconds = 0.0
    var thermalState = ProcessInfo.processInfo.thermalState.rawValue
    var profileWidth = 0
    var profileHeight = 0
    var targetFPS = 0
    var program = CompositionMetrics()
    var preview = CompositionMetrics()
    var programKernel = CompositionKernelMetrics()
    var previewKernel = CompositionKernelMetrics()
    var programClock: AVClockSnapshot = .unsupported
    var secondaryClock: AVClockSnapshot = .unsupported
    var sourceAudioClocks: [String: AVClockSnapshot] = [:]
    var streamState = "idle"
    var recordingState = "idle"
    var recordingVideoFrames = 0
    var recordingAudioChunks = 0
    var recordingDroppedVideo = 0
    var recordingDroppedAudio = 0
    var sources: [SourceDiagnosticSnapshot] = []
    var outputs: [DestinationDiagnosticSnapshot] = []
    var cpuPercent = 0.0
    var resourceSampleAgeMilliseconds: Double?
    var resourceCPUCapacityPercent: Double?
    var currentResidentBytes: UInt64?
    var physicalFootprintBytes: UInt64?
    var metalAllocatedBytes: Int?
    var mainActorDelayMilliseconds: Double?
    var metalUnifiedMemory: Bool?
    var metalRecommendedWorkingSetBytes: UInt64?
    var metalCounterSetCount: Int?
    var resourcePreviewLevel = "normal"
    var hardwareCanvasCeiling = OutputCapabilities.current.hardwareTier.displayName
    var hardwareFPSCeiling = OutputCapabilities.current.hardwareMaxFrameRate
    var estimatedEncoderSessions = 0
    var recordingElapsedSeconds = 0.0
    var recordingMediaSeconds = 0.0
    var recordingAVEndDifferenceSeconds: Double?
    var recordingAvailableBytes: Int64?
    var recordingBytes: Int64 = 0
    var audioUnderruns: [String: Int64] = [:]
    var audioTapDrops: [String: Int64] = [:]
    var events: [Event] = []
    struct Event: Codable, Sendable { let time: Date; let state: String }

    var liveSessionStartedAt: Date? {
        outputs.filter { ["connecting", "live", "reconnecting", "stopping"].contains($0.state) }
            .compactMap(\.startedAt).min()
    }

    static func machineModel() -> String {
        var bytes = [CChar](repeating: 0, count: 128)
        var size = bytes.count
        let result = bytes.withUnsafeMutableBufferPointer { sysctlbyname("hw.model", $0.baseAddress, &size, nil, 0) }
        guard result == 0 else { return "unknown" }
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    mutating func sampleProcess() {
        var usage = rusage()
        if getrusage(RUSAGE_SELF, &usage) == 0 {
            peakMemoryBytes = Int64(usage.ru_maxrss)
            processCPUSeconds = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        }
    }
}

struct SourceDiagnosticSnapshot: Codable, Sendable {
    var id: String
    var kind: String
    var state: String
    var deliveredFrames: Int?
    var deliveryFPS: Double?
    var captureClock: AVClockSnapshot = .unsupported
}

/// Export has its own boundary even when a future collector accidentally adds
/// endpoint text to a state or channel key. Runtime snapshots keep their IDs so
/// the inspector can resolve names; a bundle uses fresh, correlated pseudonyms.
extension StudioDiagnosticSnapshot {
    static let maximumExportBytes = 1_048_576
    enum ExportFailure: LocalizedError {
        case tooLarge
        var errorDescription: String? { "Diagnostics exceeded the 1 MiB export limit. Try again after the next health sample." }
    }

    func redactedExportData() throws -> Data {
        var exported = self
        let salt = UUID().uuidString
        func identifier(_ value: String, kind: String) -> String {
            let digest = SHA256.hash(data: Data((salt + kind + value).utf8))
            return kind + "-" + digest.prefix(12).map { String(format: "%02x", $0) }.joined()
        }
        func state(_ value: String) -> String {
            let allowed: Set<String> = ["idle", "connecting", "live", "reconnecting", "stopping", "failed",
                "preparing", "recording", "paused", "finishing", "unavailable", "capturing", "ready", "inactive"]
            return allowed.contains(value) ? value : "unknown"
        }
        func kernel(_ value: CompositionKernelMetrics) -> CompositionKernelMetrics {
            var result = value
            result.backend = value.backend.hasPrefix("Core Image on Metal:") ? "Core Image on Metal" : "unavailable"
            if value.unavailableReason != nil { result.unavailableReason = "Core Image kernel execution time unavailable." }
            return result
        }
        exported.resourcePreviewLevel = ["normal", "reduced", "minimum"].contains(resourcePreviewLevel) ? resourcePreviewLevel : "unknown"
        exported.programKernel = kernel(programKernel)
        exported.previewKernel = kernel(previewKernel)
        exported.streamState = state(streamState)
        exported.recordingState = state(recordingState)
        exported.os = String(os.prefix(256))
        exported.hardwareModel = String(hardwareModel.prefix(128))
        exported.hardwareCanvasCeiling = String(hardwareCanvasCeiling.prefix(128))
        exported.sources = sources.prefix(256).map { source in
            var source = source
            source.id = identifier(source.id, kind: "source")
            // Source kinds are internal identifiers, never titles or paths.
            let kinds: Set<String> = ["camera", "screen", "media", "syphon", "image", "text", "shape", "web",
                "appAudio", "scene", "pdf", "guest"]
            source.kind = kinds.contains(source.kind) ? source.kind : "other"
            source.state = state(source.state)
            return source
        }
        exported.outputs = outputs.prefix(64).map { output in
            var output = output
            output.id = identifier(output.id, kind: "output")
            output.state = state(output.state)
            return output
        }
        func channels(_ values: [String: Int64]) -> [String: Int64] {
            Dictionary(uniqueKeysWithValues: values.keys.sorted().prefix(256).map {
                (identifier($0, kind: "audio"), values[$0]!)
            })
        }
        exported.audioUnderruns = channels(audioUnderruns)
        exported.audioTapDrops = channels(audioTapDrops)
        exported.sourceAudioClocks = Dictionary(uniqueKeysWithValues: sourceAudioClocks.keys.sorted().prefix(256).map {
            (identifier($0, kind: "audio"), sourceAudioClocks[$0]!)
        })
        exported.events = events.suffix(256).map { event in
            let components = event.state.split(separator: ".", omittingEmptySubsequences: false)
            let label: String
            if components.count == 3, components[0] == "output", UUID(uuidString: String(components[1])) != nil {
                label = "output.\(identifier(String(components[1]), kind: "output")).\(state(String(components[2])))"
            } else if components.count == 2, components[0] == "recording" {
                label = "recording.\(state(String(components[1])))"
            } else { label = "unknown" }
            return Event(time: event.time, state: label)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        // An unavailable numeric probe must not prevent the rest of a bundle
        // being saved. This also keeps invalid telemetry distinguishable from 0.
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "unavailable", negativeInfinity: "unavailable", nan: "unavailable")
        let data = try encoder.encode(exported)
        guard data.count <= Self.maximumExportBytes else {
            throw ExportFailure.tooLarge
        }
        return data
    }
}

/// The runtime owns timers, events, and delta baselines. Hiding a panel cannot
/// restart a session clock or discard lifecycle evidence.
@MainActor final class StudioDiagnosticsMonitor: ObservableObject {
    @Published private(set) var snapshot = StudioDiagnosticSnapshot()
    private var events: [StudioDiagnosticSnapshot.Event] = []
    private var observations = Set<AnyCancellable>()
    private var outputLabels: [UUID: String] = [:]
    private var recordingLabel = ""
    private var previousCounts: [String: Int] = [:]
    private var previousUptime: Double?
    private var previousCPU: Double?
    private var samplingTask: Task<Void, Never>?
    private var isRunning = true

    init(controller: StreamController, recorder: RecordingController) {
        controller.destinationOutputs.$states.sink { [weak self] states in
            guard let self else { return }
            for (id, state) in states {
                let label: String = switch state {
                case .idle: "idle"; case .connecting: "connecting"; case .live: "live"
                case .reconnecting: "reconnecting"; case .stopping: "stopping"; case .failed: "failed"
                }
                if self.outputLabels[id] != label {
                    self.outputLabels[id] = label
                    self.note("output.\(id.uuidString).\(label)")
                }
            }
        }.store(in: &observations)
        recorder.$state.sink { [weak self] state in
            guard let self else { return }
            let label: String = switch state {
            case .idle: "idle"; case .preparing: "preparing"; case .recording: "recording"
            case .paused: "paused"; case .stopping: "finishing"; case .failed: "failed"
            }
            if label != self.recordingLabel { self.recordingLabel = label; self.note("recording.\(label)") }
        }.store(in: &observations)
        samplingTask = Task { @MainActor [weak self, weak controller, weak recorder] in
            while !Task.isCancelled {
                // Do not retain the runtime or monitor across the sleep. The
                // sampler belongs to the runtime, including while its UI is hidden.
                if let self, let controller, let recorder {
                    await self.sample(controller: controller, recorder: recorder)
                } else { return }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }
    deinit { samplingTask?.cancel() }

    func shutdown() {
        isRunning = false
        samplingTask?.cancel()
        samplingTask = nil
        observations.removeAll()
    }
    private func note(_ label: String) {
        events.append(.init(time: Date(), state: label)); events = Array(events.suffix(256))
    }
    func sample(controller: StreamController, recorder: RecordingController) async {
        var current = await controller.diagnosticSnapshot()
        // A project switch can retire this runtime while actor snapshots are
        // in flight. Keep its last snapshot rather than publishing late results.
        guard isRunning, !Task.isCancelled else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let previousUptime {
            let elapsed = max(0.001, now - previousUptime)
            if let previousCPU { current.cpuPercent = max(0, (current.processCPUSeconds - previousCPU) / elapsed * 100) }
            for index in current.sources.indices {
                let source = current.sources[index]
                if let count = source.deliveredFrames, let previous = previousCounts[source.id] {
                    current.sources[index].deliveryFPS = Double(max(0, count - previous)) / elapsed
                }
            }
        }
        previousCounts = Dictionary(uniqueKeysWithValues: current.sources.compactMap { source in
            source.deliveredFrames.map { (source.id, $0) }
        })
        previousUptime = now; previousCPU = current.processCPUSeconds
        current.recordingState = recordingLabel
        let progress = recorder.progress
        current.recordingVideoFrames = progress.videoSamples; current.recordingAudioChunks = progress.audioSamples
        current.recordingDroppedVideo = progress.droppedVideo; current.recordingDroppedAudio = progress.droppedAudio
        current.recordingElapsedSeconds = progress.elapsedWallSeconds; current.recordingMediaSeconds = progress.durationSeconds
        current.recordingAVEndDifferenceSeconds = progress.avEndDifferenceSeconds
        current.recordingAvailableBytes = progress.availableBytes; current.recordingBytes = progress.bytesWritten
        // The runtime ledger retains ISO/secondary/rotation reservations through
        // countdown, preflight and writer finalization. It counts reserved
        // recording capacity; publisher state counts active publishing sessions.
        current.estimatedEncoderSessions = controller.activePublishingEncoderCount + controller.reservedRecordingEncoderCount
        current.events = events
        snapshot = current
    }
}

struct StudioDiagnosticsView: View {
    @EnvironmentObject private var workspace: StudioWorkspace
    @State private var exportError: String?
    @State private var showDetail = false
    private var snapshot: StudioDiagnosticSnapshot { workspace.runtime.diagnostics.snapshot }
    var body: some View {
        StudioDiagnosticsContent(monitor: workspace.runtime.diagnostics, workspace: workspace,
            exportError: $exportError, showDetail: $showDetail)
    }
}

private struct StudioDiagnosticsContent: View {
    @ObservedObject var monitor: StudioDiagnosticsMonitor
    let workspace: StudioWorkspace
    @Binding var exportError: String?
    @Binding var showDetail: Bool
    private var snapshot: StudioDiagnosticSnapshot { monitor.snapshot }
    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading) {
                Text(String(format: "Program %.1f / %d fps · Render %.2f ms", snapshot.program.achievedFPS, snapshot.targetFPS, snapshot.program.meanRenderMilliseconds))
                Text("Queues \(snapshot.program.subscriberQueueDepth) · Shed \(snapshot.program.subscriberDrops) · Late ticks \(snapshot.program.missedDeadlines) · Render failures \(snapshot.program.failed)")
            }
            if let start = snapshot.liveSessionStartedAt {
                Text(start, style: .timer).accessibilityLabel("Live session elapsed time")
            }
            if workspace.runtime.recorder.state.isActive {
                Text("Rec \(LiveStats.uptimeLabel(seconds: Int(snapshot.recordingElapsedSeconds)))")
                    .accessibilityLabel("Recording elapsed \(Int(snapshot.recordingElapsedSeconds)) seconds")
            }
            Spacer()
            Button("Health Details") { showDetail.toggle() }
                .popover(isPresented: $showDetail) { details }
            Button("Export Diagnostics…") { export() }
                .help("Save bounded performance and session metadata with anonymous source/output IDs; credentials, media and source titles are excluded.")
            if let exportError { Text(exportError).foregroundStyle(.orange) }
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 12).padding(.vertical, 6)
    }
    private var details: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Studio Health").font(.headline)
                Text(String(format: "CPU %.1f%% · Peak memory %.0f MB · Encoder sessions %d (reserved / active)", snapshot.cpuPercent, Double(snapshot.peakMemoryBytes) / 1_000_000, snapshot.estimatedEncoderSessions))
                if let age = snapshot.resourceSampleAgeMilliseconds {
                    Text("Resource sample age \(String(format: "%.0f ms", age)) · CPU \(snapshot.resourceCPUCapacityPercent.map { String(format: "%.1f%% of logical machine capacity", $0) } ?? "measuring") · Main actor delay \(snapshot.mainActorDelayMilliseconds.map { String(format: "%.1f ms", $0) } ?? "unavailable")")
                    Text("Current resident \(snapshot.currentResidentBytes.map { String(format: "%.1f MB", Double($0) / 1_000_000) } ?? "unavailable") · Physical footprint \(snapshot.physicalFootprintBytes.map { String(format: "%.1f MB", Double($0) / 1_000_000) } ?? "unavailable") · Metal allocated \(snapshot.metalAllocatedBytes.map { String(format: "%.1f MB", Double($0) / 1_000_000) } ?? "unavailable")")
                    Text("Optional preview budget: \(snapshot.resourcePreviewLevel) · Unified memory \(snapshot.metalUnifiedMemory.map { $0 ? "yes" : "no" } ?? "unavailable") · Metal working set \(snapshot.metalRecommendedWorkingSetBytes.map { String(format: "%.0f MB", Double($0) / 1_000_000) } ?? "unavailable") · Counter sets \(snapshot.metalCounterSetCount.map(String.init) ?? "unavailable")")
                } else { Text("Runtime resource sample unavailable") }
                Text("Encoder count includes recording reservations (Program, secondary, ISO, preflight and overlapping finalization) plus active publishers; it is not measured hardware utilization.")
                    .foregroundStyle(.secondary)
                Text("Hardware canvas ceiling \(snapshot.hardwareCanvasCeiling), \(snapshot.hardwareFPSCeiling) fps · Thermal state \(snapshot.thermalState)")
                if let milliseconds = snapshot.programKernel.meanMilliseconds {
                    Text(String(format: "Core Image Metal kernel mean %.3f ms · Max %.3f ms · Samples %d", milliseconds, snapshot.programKernel.maximumMilliseconds, snapshot.programKernel.samples))
                } else { Text("Core Image Metal kernel time unavailable") }
                Text("Sampled completed Core Image tasks; kernel time is not process-wide GPU utilization.").foregroundStyle(.secondary)
                AVClockDiagnosticRow(title: "Program compositor / mixed audio fanout", clock: snapshot.programClock)
                if snapshot.secondaryClock.videoSamples > 0 {
                    AVClockDiagnosticRow(title: "Secondary compositor / mixed audio fanout", clock: snapshot.secondaryClock)
                }
                Text("A−V projects timestamp clocks to the same host observation time. Rate skew measures their relative advancement; positive means audio advances faster. Callback delivery changes can affect these observations. This is not measured lip sync, device oscillator drift or receiver playout.")
                    .foregroundStyle(.secondary)
                ForEach(snapshot.outputs, id: \.id) { output in
                    let name = UUID(uuidString: output.id).flatMap { workspace.runtime.controller.destinationOutputs.names[$0] } ?? "Output"
                    Text("\(name): \(output.state) · \(output.achievedFPS.map(String.init) ?? "—") fps · \(output.bitrate.map { "\($0 / 1000) kbps" } ?? "—")")
                    Text("Video queue \(output.videoQueueDepth), shed \(output.videoMailboxDrops) · Socket \(output.socketQueueBytes.map(String.init) ?? "unavailable") bytes · Congestion drops \(output.encoderCongestionDrops.map(String.init) ?? "unavailable")")
                    AVClockDiagnosticRow(title: "\(name) \(output.sharedEncodedClock == nil ? "normalized raw encoder ingress" : "encoded publisher ingress")", clock: output.encoderInputClock ?? .unsupported)
                    AVClockDiagnosticRow(title: "\(name) shared H.264/AAC encoded callbacks", clock: output.sharedEncodedClock ?? .unsupported)
                }
                ForEach(snapshot.sources, id: \.id) { source in
                    let name = workspace.runtime.sceneStore.sources.first { $0.id.description == source.id }?.name ?? source.kind
                    Text("\(name): \(source.state) · Capture delivery \(source.deliveryFPS.map { String(format: "%.1f fps", $0) } ?? "—")")
                    AVClockDiagnosticRow(title: "\(name) capture callbacks", clock: source.captureClock)
                }
                ForEach(snapshot.sourceAudioClocks.keys.sorted(), id: \.self) { label in
                    AVClockDiagnosticRow(title: "\(label) original PCM / Program video", clock: snapshot.sourceAudioClocks[label] ?? .unsupported)
                }
                Text("Capture delivery counts new camera/screen frames. A static screen may deliver zero while Program keeps its output cadence.")
                    .foregroundStyle(.secondary)
                Text("Audio underrun frames \(snapshot.audioUnderruns.values.reduce(0, +)) · Audio tap drops \(snapshot.audioTapDrops.values.reduce(0, +))")
                if let difference = snapshot.recordingAVEndDifferenceSeconds {
                    Text(String(format: "Recording track endpoint difference %.3f ms", difference * 1000))
                }
                Text("Track endpoint difference measures last written timestamps; it is not a clock drift or perceptual sync measurement.")
                    .foregroundStyle(.secondary)
                Text("Recorder shed video \(snapshot.recordingDroppedVideo), audio \(snapshot.recordingDroppedAudio) · File \(snapshot.recordingBytes) bytes · Available \(snapshot.recordingAvailableBytes.map(String.init) ?? "unknown") bytes")
            }.padding(16)
        }.frame(width: 540, height: 440)
    }
    private func export() {
        exportError = nil
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "stream-diagnostics.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try snapshot.redactedExportData().write(to: url, options: .atomic)
        } catch { exportError = error.localizedDescription }
    }
}

private struct AVClockDiagnosticRow: View {
    let title: String
    let clock: AVClockSnapshot
    private var state: String {
        switch clock.state {
        case .unsupported: "Unavailable: boundary not instrumented"
        case .noAudio: "Unavailable: no associated audio observations"
        case .noVideo: "Unavailable: no video observations"
        case .warming: "Measuring: needs two seconds of fresh observations"
        case .staleAudio: "Unavailable: audio observations older than two seconds"
        case .staleVideo: "Unavailable: video observations older than two seconds"
        case .unstable: "Uncertain: callback delivery jitter"
        case .stable: "Stable timestamp progression"
        case .offset: "Timestamp offset"
        case .drifting: "Observed timestamp-rate skew"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(title): \(state)")
            if let offset = clock.audioMinusVideoMilliseconds,
               let rate = clock.relativeRateMillisecondsPerSecond,
               let uncertainty = clock.rateUncertaintyMillisecondsPerSecond {
                Text(String(format: "A−V %+.1f ms · Rate %+.2f ms/s (SE %.2f) · Window %.1f s", offset, rate, uncertainty, clock.windowSeconds))
            }
            Text("Residual RMS audio \(clock.audioResidualMilliseconds.map { String(format: "%.2f ms", $0) } ?? "unavailable"), video \(clock.videoResidualMilliseconds.map { String(format: "%.2f ms", $0) } ?? "unavailable")")
                .foregroundStyle(.secondary)
            Text("Age audio \(clock.audioAgeMilliseconds.map { String(format: "%.0f ms", $0) } ?? "unavailable"), video \(clock.videoAgeMilliseconds.map { String(format: "%.0f ms", $0) } ?? "unavailable") · Samples \(clock.audioSamples)/\(clock.videoSamples) · Rejected \(clock.rejectedSamples) · Epoch changes \(clock.discontinuities)")
                .foregroundStyle(.secondary)
        }.accessibilityElement(children: .combine)
    }
}
