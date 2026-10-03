import SwiftUI
import StreamCore

/// Embedded readiness checklist; the network test runs only after its explicit
/// action. Local rehearsal never creates any destination publisher.
struct StreamPreflightView: View {
    @EnvironmentObject private var controller: StreamController
    @EnvironmentObject private var recorder: RecordingController
    @EnvironmentObject private var dispatcher: StudioCommandDispatcher
    @EnvironmentObject private var permissions: PermissionsManager
    @StateObject private var uplink = UplinkProbeController()
    @State private var checks: [StreamPreflightCheck] = []
    @State private var audioHistory: [(time: Double, peak: Float)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(controller.isRehearsing ? "Local Rehearsal · Recording on this Mac" : "Preflight")
                .font(.headline)
                .foregroundStyle(controller.isRehearsing ? .orange : .primary)
            ForEach(checks) { check in
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: icon(check.status)).foregroundStyle(color(check.status))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(check.title).font(.caption.weight(.semibold))
                        Text(check.detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            Text("Uplink test: about 10 seconds, up to 32 MiB of synthetic upload payload plus network overhead to Cloudflare. No program media or credentials are sent. This estimates this network route; your provider may differ.")
                .font(.caption).foregroundStyle(.secondary)
            Link("Cloudflare test endpoint details", destination: URL(string: "https://github.com/cloudflare/speedtest#configuration")!)
                .font(.caption)
            if uplink.isRunning {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Uploaded \(Double(uplink.uploadedBytes) / 1_048_576, specifier: "%.0f") MiB")
                    Spacer()
                    Button("Cancel Test") { uplink.cancel() }
                }
            } else {
                Button("Run Uplink Test") {
                    uplink.start { controller.destinations.measuredUplinkMbps = $0 }
                }.disabled(controller.streamState.isActive)
            }
            if let result = uplink.result {
                Text("Measured \(result.megabitsPerSecond, specifier: "%.1f") Mbps over \(result.duration, specifier: "%.1f") seconds.")
                    .font(.caption)
            }
            if let error = uplink.error { Text(error).font(.caption).foregroundStyle(.orange) }
            Divider()
            Text("Local rehearsal uses preview and a recording on this Mac. Public publishing is disabled until rehearsal ends. Review the recording before public Go Live.")
                .font(.caption).foregroundStyle(.secondary)
            if controller.isRehearsing {
                Button("End Local Rehearsal") { dispatcher.execute(.stopRehearsal) }
                    .buttonStyle(.borderedProminent).tint(.orange)
            } else {
                Button("Begin Local Rehearsal") { dispatcher.execute(.startRehearsal) }
                    .disabled(controller.streamState.isActive || recorder.state.isActive)
            }
            Text("Managed YouTube destinations require a fresh native review of the exact event, stream, schedule, privacy and auto-start effect before sending video. Manual destinations send to their configured endpoint when started.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(10)
        .task {
            while !Task.isCancelled {
                permissions.refresh()
                let levels = await controller.mixerLevels()
                let now = ProcessInfo.processInfo.systemUptime
                if controller.outputSessionActive || controller.isPreviewing {
                    audioHistory.append((now, levels.buses[.program]?.peak ?? 0))
                    audioHistory.removeAll { now - $0.time > 3 }
                } else { audioHistory.removeAll() }
                var facts = controller.preflightFacts(programAudioPeak: audioHistory.map(\.peak).max(),
                    assetAvailability: dispatcher.assetLibrary.availability(of:))
                let storage = recorder.storagePreflight()
                facts.storageAvailableBytes = storage.availableBytes
                facts.storageWritable = storage.isWritable && storage.error == nil
                checks = facts.checks
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
        .onDisappear { uplink.cancel() }
    }
    private func icon(_ status: StreamPreflightCheck.Status) -> String {
        switch status {
        case .passed: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.circle.fill"
        case .unverified: return "questionmark.circle"
        }
    }
    private func color(_ status: StreamPreflightCheck.Status) -> Color {
        switch status {
        case .passed: return .green
        case .warning: return .orange
        case .failed: return .red
        case .unverified: return .secondary
        }
    }
}
