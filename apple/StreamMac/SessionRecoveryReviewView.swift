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
                Text("\(snapshot.activeOutputIDs.count) publishing connections were active. Remote state remains unknown until explicitly verified with the current account. A local stop does not end a remote event.")
                    .font(.caption)
                RecoveryEventReviewList(coordinator: coordinator.remoteReview)
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

private struct RecoveryEventReviewList: View {
    @ObservedObject var coordinator: RecoveryEventReviewCoordinator
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(coordinator.events, id: \.outputID) { event in
                        let review = coordinator.review(event.outputID)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text("\(event.provider?.name ?? "Unmanaged output") · \(event.eventID ?? event.outputID.uuidString)")
                                    .font(.caption).lineLimit(1)
                                Spacer()
                                Button(coordinator.verifying.contains(event.outputID) ? "Verifying…" : "Verify Remote State") {
                                    coordinator.verify(event.outputID)
                                }.disabled(!coordinator.canVerify(event.outputID))
                            }
                            Text(review.state == .reconnectable ? "Live · reconnect review candidate" : review.state.rawValue.capitalized)
                                .font(.caption).bold()
                            Text(review.reason.message).font(.caption).foregroundStyle(.secondary)
                            if let checkedAt = review.checkedAt {
                                Text("Checked \(checkedAt.formatted(date: .abbreviated, time: .standard)); receipt expires after 60 seconds.")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }.frame(maxHeight: 220)
        }
    }
}
