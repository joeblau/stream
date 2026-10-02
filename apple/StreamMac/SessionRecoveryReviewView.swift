import SwiftUI
import StreamCore

private struct SessionRecoveryEnvironmentKey: EnvironmentKey {
    static let defaultValue: SessionRecoveryCoordinator? = nil
}
extension EnvironmentValues {
    var sessionRecovery: SessionRecoveryCoordinator? {
        get { self[SessionRecoveryEnvironmentKey.self] }
        set { self[SessionRecoveryEnvironmentKey.self] = newValue }
    }
}
struct SessionRecoveryReviewButton: View {
    @Environment(\.sessionRecovery) private var recovery
    var relink: () -> Void
    var body: some View {
        if let recovery { RecoveryButton(coordinator: recovery, relink: relink) }
    }
}
private struct RecoveryButton: View {
    @ObservedObject var coordinator: SessionRecoveryCoordinator
    var relink: () -> Void
    var body: some View {
        Button("Session Recovery", systemImage: "arrow.counterclockwise.circle") { coordinator.showReview.toggle() }
            .popover(isPresented: $coordinator.showReview, arrowEdge: .bottom) {
                SessionRecoveryReviewView(coordinator: coordinator, relink: relink).padding(16).frame(width: 500)
            }
    }
}
struct SessionRecoveryReviewView: View {
    @ObservedObject var coordinator: SessionRecoveryCoordinator
    var relink: () -> Void
    @State private var restoring = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review Previous Session").font(.headline)
            if let snapshot = coordinator.pending {
                Text("Last checkpoint: \(snapshot.updatedAt.formatted(date: .abbreviated, time: .standard))")
                    .font(.caption).foregroundStyle(.secondary)
                Text(coordinator.contextLabel?(snapshot.projectID, snapshot.profileID)
                     ?? "Project \(snapshot.projectID.uuidString.prefix(8)) · Profile \(snapshot.profileID.uuidString.prefix(8))").font(.caption)
                Text(snapshot.remoteEvents.contains { $0.state != .unknown }
                     ? "\(snapshot.activeOutputIDs.count) publishing connections were active. Cached provider event states appear below; verify their current state before manually starting."
                     : "\(snapshot.activeOutputIDs.count) publishing connections were active. Remote event state is unknown until verified with the provider; a local LIVE acknowledgement does not prove the event remains reconnectable.")
                    .font(.caption)
                ForEach(snapshot.remoteEvents, id: \.outputID) { event in
                    if event.state == .ended { Text("Event \(event.eventID ?? "unknown") ended; create a new event through the provider.").font(.caption) }
                    else if event.state == .reconnectable { Text("Event \(event.eventID ?? "unknown") was verified reconnectable at the last checkpoint; verify again before manually starting.").font(.caption) }
                }
                Text("\(snapshot.recordings.count) recording segments · \(snapshot.recordings.reduce(0) { $0 + $1.markers.count }) timed markers. \(snapshot.recordingInventoryVerified ? "Actual recorder journals were read." : "The recording inventory was incomplete or unavailable; relink its folder and review local files.")")
                    .font(.caption)
                if snapshot.hasStagedEdits {
                    Text("Restore can recover saved scene IDs, staged geometry/visibility and paused media positions. New/deleted layers, changed source payloads, text and effects require review in project backups.").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button(restoring ? "Restoring…" : "Restore Local Context…") {
                        restoring = true
                        Task { await coordinator.restore(); restoring = false }
                    }.disabled(restoring || coordinator.restoreLocalContext == nil)
                    Button("Relink Sources / Media") { coordinator.showReview = false; relink() }
                }
                Button("Review / Finalize Recording Copy…") { coordinator.reviewRecordings?() }
                    .disabled(coordinator.reviewRecordings == nil)
                Text("Inspect readable tracks in Recording Library and export a finalized copy. Public streams, recording, playback cues, macros and destructive commands never restart from this journal.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Dismiss Recovery") { Task { await coordinator.dismiss() } }
                    Spacer()
                    Button("Review Later") { coordinator.showReview = false }
                }
            } else { Text(coordinator.error == nil ? "No prior interrupted session requires review." : "No readable recovery session is available. Review project backups and recordings manually.").foregroundStyle(.secondary) }
            if let error = coordinator.error { Text(error).font(.caption).foregroundStyle(.orange) }
        }
    }
}
