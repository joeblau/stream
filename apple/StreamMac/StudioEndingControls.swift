import StreamCore
import SwiftUI

struct StudioEndingControls: View {
    @ObservedObject var coordinator: StudioEndingCoordinator
    @State private var selection: [StudioEndingTarget] = []
    @State private var mode = StudioEndingCoordinator.Mode.local
    @State private var confirming = false
    @State private var outroID: UUID?
    @State private var outroSeconds = 10.0
    @State private var useOutro = false
    @State private var applyOutro = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Stop All Local…") { prepare(coordinator.activeTargets, mode: .local) }
                Button("End All…") { prepare(coordinator.activeTargets, mode: .both, allowOutro: true) }
                    .disabled(useOutro && outroID == nil)
            }.disabled(!coordinator.isBound || coordinator.activeTargets.isEmpty || coordinator.isWorking)
            if coordinator.isWorking { Button("Cancel Pending Ending") { coordinator.cancelPending() } }
            Toggle("Take an outro scene before End All", isOn: $useOutro).disabled(!coordinator.canUseOutro || coordinator.isWorking)
            if useOutro {
                Picker("Outro / black scene", selection: $outroID) {
                    Text("Choose a saved scene…").tag(Optional<UUID>.none)
                    ForEach(coordinator.outroChoices) { Text($0.name).tag(Optional($0.id)) }
                }
                Stepper("Minimum outro time: \(Int(outroSeconds)) seconds", value: $outroSeconds, in: 0...120, step: 1)
                Text("Take or revert pending edits first. This publishes the selected scene through the shared transition path and also appears in the continuing recording. Program or output-session changes cancel the delayed ending. Provider completion can extend the hold beyond this minimum.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let seconds = coordinator.countdown { Text("Outro on Program · \(seconds) seconds remaining").font(.caption.weight(.semibold)) }
            if let notice = coordinator.notice { Text(notice).font(.caption).foregroundStyle(.orange) }
            ForEach(coordinator.targets) { target in
                VStack(alignment: .leading, spacing: 4) {
                    Text(target.name).font(.caption.weight(.semibold))
                    if let binding = target.binding {
                        Text("\(binding.provider.name) · \(binding.eventID ?? binding.channelID)").font(.caption2).textSelection(.enabled)
                    }
                    HStack {
                        Button("Stop Local…") { prepare([target], mode: .local) }.disabled(target.session == nil)
                        Button("End Remote…") { prepare([target], mode: .remote) }.disabled(!coordinator.canEndRemote(target))
                        Button("End Both…") { prepare([target], mode: .both) }.disabled(target.session == nil)
                        if target.binding?.provider == .youtube {
                            Button("Review Remote") { coordinator.request([target], mode: .review) }
                        }
                    }.controlSize(.small).disabled(coordinator.isWorking || !coordinator.isBound)
                    if let binding = target.binding, binding.provider != .youtube {
                        Text("Remote completion is unavailable in this connector; local stop does not confirm remote end.").font(.caption2).foregroundStyle(.secondary)
                        Link("Open \(binding.provider.name) controls", destination: binding.provider.repairURL).font(.caption)
                    }
                    if let report = coordinator.reports[target.id] {
                        if !report.target.matches(target) {
                            Text("Previous session / routing receipt; the current output is a separate session.").font(.caption2).foregroundStyle(.secondary)
                        }
                        Text("Local: \(report.local.rawValue)").font(.caption2)
                        if report.local == .unconfirmed {
                            Button("Review Local Receipt") { coordinator.reviewLocal(target.id) }.font(.caption)
                        }
                        if report.remotePending { Text("Remote: awaiting provider response…").font(.caption2) }
                        else if let remote = report.remote {
                            Text("Remote: \(remoteLabel(remote))").font(.caption2).foregroundStyle(remote.confirmsEnd ? Color.secondary : Color.orange)
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                Text("Receipt \(remote.receivedAt.formatted(date: .omitted, time: .standard))\(context.date.timeIntervalSince(remote.receivedAt) > 60 ? " · stale; review remote state" : "")")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            if let failure = remote.failure { Text(failure.localizedDescription).font(.caption2).foregroundStyle(.orange) }
                        }
                        if let note = report.note { Text(note).font(.caption2).foregroundStyle(.orange) }
                    }
                }
            }
            Text("Local stop detaches publishing only. End Remote completes a supported verified provider event while local delivery continues. End All attempts each captured remote event and local stop independently; recording continues. Unconfirmed results require review before an explicit retry.")
                .font(.caption).foregroundStyle(.secondary)
            if !coordinator.isBound { Text("Ending hooks are not attached to this workspace yet.").font(.caption).foregroundStyle(.orange) }
        }
        .confirmationDialog(mode == .local ? "Stop local publishing?" : "End the selected broadcast targets?", isPresented: $confirming, titleVisibility: .visible) {
            Button(mode == .local ? "Stop Selected Local Outputs" : mode == .remote ? "Complete Selected Remote Event" : "End Selected Remote Events and Local Outputs", role: .destructive) {
                coordinator.request(selection, mode: mode, outroScene: applyOutro ? outroID : nil,
                    duration: outroSeconds)
            }
        } message: {
            Text(selection.map(\.name).joined(separator: ", ") + "\n\n" + (mode == .local ? "No remote completion request will be sent. Providers may apply their own disconnect/auto-stop policy." : "Only supported, permitted provider events are completed. Other remote states remain unconfirmed. A sent request cannot be undone.") + "\n\nLocal recording continues.")
        }
    }
    private func prepare(_ targets: [StudioEndingTarget], mode: StudioEndingCoordinator.Mode, allowOutro: Bool = false) {
        guard !targets.isEmpty else { return }
        if allowOutro && useOutro && outroID == nil { return }
        applyOutro = allowOutro && useOutro
        selection = targets; self.mode = mode; confirming = true
    }
    private func remoteLabel(_ receipt: ProviderCompletionReceipt) -> String {
        switch receipt.disposition {
        case .ended: "Completion acknowledged"
        case .alreadyEnded: "Already ended · fresh provider read"
        case .observed: receipt.event?.state.rawValue ?? "Unknown"
        case .blocked: "Unknown · no completion sent (check failed)"
        case .unconfirmed: "Unknown · completion not confirmed"
        case .unsupported: "Unavailable · manual provider action required"
        }
    }
}
