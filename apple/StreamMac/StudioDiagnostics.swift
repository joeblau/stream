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
    var streamState = "idle"
    var recordingState = "idle"
    var recordingVideoFrames = 0
    var recordingAudioChunks = 0
    var recordingDroppedVideo = 0
    var recordingDroppedAudio = 0
    var sources: [SourceDiagnosticSnapshot] = []
    var outputs: [DestinationDiagnosticSnapshot] = []
    var cpuPercent = 0.0
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
    }
    private func note(_ label: String) {
        events.append(.init(time: Date(), state: label)); events = Array(events.suffix(256))
    }
    func sample(controller: StreamController, recorder: RecordingController) async {
        var current = await controller.diagnosticSnapshot()
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
            if let start = snapshot.outputs.compactMap(\.startedAt).min() {
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
            if let exportError { Text(exportError).foregroundStyle(.orange) }
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 12).padding(.vertical, 6)
        .task(id: workspace.currentProfile.id) {
            while !Task.isCancelled {
                await monitor.sample(controller: workspace.runtime.controller, recorder: workspace.runtime.recorder)
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }
    private var details: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Studio Health").font(.headline)
                Text(String(format: "CPU %.1f%% · Peak memory %.0f MB · Encoder sessions %d (reserved / active)", snapshot.cpuPercent, Double(snapshot.peakMemoryBytes) / 1_000_000, snapshot.estimatedEncoderSessions))
                Text("Encoder count includes recording reservations (Program, secondary, ISO, preflight and overlapping finalization) plus active publishers; it is not measured hardware utilization.")
                    .foregroundStyle(.secondary)
                Text("Hardware canvas ceiling \(snapshot.hardwareCanvasCeiling), \(snapshot.hardwareFPSCeiling) fps · Thermal state \(snapshot.thermalState)")
                ForEach(snapshot.outputs, id: \.id) { output in
                    let name = UUID(uuidString: output.id).flatMap { workspace.runtime.controller.destinationOutputs.names[$0] } ?? "Output"
                    Text("\(name): \(output.state) · \(output.achievedFPS.map(String.init) ?? "—") fps · \(output.bitrate.map { "\($0 / 1000) kbps" } ?? "—")")
                    Text("Video queue \(output.videoQueueDepth), shed \(output.videoMailboxDrops) · Socket \(output.socketQueueBytes ?? 0) bytes · Congestion drops \(output.encoderCongestionDrops ?? 0)")
                }
                ForEach(snapshot.sources, id: \.id) { source in
                    let name = workspace.runtime.sceneStore.sources.first { $0.id.description == source.id }?.name ?? source.kind
                    Text("\(name): \(source.state) · Capture delivery \(source.deliveryFPS.map { String(format: "%.1f fps", $0) } ?? "—")")
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
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "stream-diagnostics.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(snapshot).write(to: url, options: .atomic)
        } catch { exportError = error.localizedDescription }
    }
}
