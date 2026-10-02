import AppKit
import Darwin
import Foundation
import StreamCore
import SwiftUI

struct CompositionMetrics: Codable, Sendable {
    var startedAt = ProcessInfo.processInfo.systemUptime
    var sampledAt = ProcessInfo.processInfo.systemUptime
    var attempts = 0
    var rendered = 0
    var failed = 0
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
    var sourceHealth: [String: String] = [:]
    var audioUnderruns: [String: Int64] = [:]
    var audioTapDrops: [String: Int64] = [:]
    var events: [Event] = []
    struct Event: Codable, Sendable { let time: Date; let state: String }

    mutating func sampleProcess() {
        var usage = rusage()
        if getrusage(RUSAGE_SELF, &usage) == 0 {
            peakMemoryBytes = Int64(usage.ru_maxrss)
            processCPUSeconds = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        }
    }
}

struct StudioDiagnosticsView: View {
    @EnvironmentObject private var workspace: StudioWorkspace
    @State private var snapshot = StudioDiagnosticSnapshot()
    @State private var liveSince: Date?
    @State private var recordingSince: Date?
    @State private var events: [StudioDiagnosticSnapshot.Event] = []
    @State private var previousState = ""
    @State private var exportError: String?
    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading) {
                Text(String(format: "Program %.1f / %d fps · Render %.2f ms", snapshot.program.achievedFPS, snapshot.targetFPS, snapshot.program.meanRenderMilliseconds))
                Text("Queues \(snapshot.program.subscriberQueueDepth) · Shed \(snapshot.program.subscriberDrops) · Render failures \(snapshot.program.failed)")
            }
            if let liveSince { Text(liveSince, style: .timer).accessibilityLabel("Live elapsed time") }
            if let recordingSince { Text(recordingSince, style: .timer).accessibilityLabel("Recording elapsed time") }
            Spacer()
            Button("Export Diagnostics…") { export() }
            if let exportError { Text(exportError).foregroundStyle(.orange) }
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 12).padding(.vertical, 6)
        .task(id: workspace.currentProfile.id) {
            while !Task.isCancelled {
                var current = await workspace.runtime.controller.diagnosticSnapshot()
                let recorder = workspace.runtime.recorder
                current.recordingState = recordingLabel(recorder.state)
                current.recordingVideoFrames = recorder.progress.videoSamples
                current.recordingAudioChunks = recorder.progress.audioSamples
                current.recordingDroppedVideo = recorder.progress.droppedVideo
                current.recordingDroppedAudio = recorder.progress.droppedAudio
                let state = current.streamState + "/" + current.recordingState
                if state != previousState {
                    events.append(.init(time: Date(), state: state))
                    events = Array(events.suffix(256)); previousState = state
                }
                current.events = events
                if workspace.runtime.controller.streamState.isActive { if liveSince == nil { liveSince = Date() } } else { liveSince = nil }
                if recorder.state.isActive { if recordingSince == nil { recordingSince = Date() } } else { recordingSince = nil }
                snapshot = current
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    private func recordingLabel(_ state: RecordingSessionState) -> String {
        switch state { case .idle: "idle"; case .preparing: "preparing"; case .recording: "recording"; case .paused: "paused"; case .stopping: "finishing"; case .failed: "failed" }
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
