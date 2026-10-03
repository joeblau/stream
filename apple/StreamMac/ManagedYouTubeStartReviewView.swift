import SwiftUI
import StreamCore

/// Embed as a native sheet/popover with the runtime-owned coordinator. Consent
/// resets on each attempt, so it cannot silently approve a different review.
struct ManagedYouTubeStartReviewView: View {
    @ObservedObject var coordinator: ManagedYouTubeStartCoordinator
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Review managed destinations").font(.title2.bold())
                ForEach(coordinator.entries) { entry in
                    ManagedYouTubeStartEntryView(coordinator: coordinator, entry: entry).id(entry.attempt)
                    Divider()
                }
                if coordinator.entries.isEmpty { Text("No managed destinations are waiting for review.") }
            }.padding(24)
        }.frame(minWidth: 480, idealWidth: 560, minHeight: 240)
    }
}

private struct ManagedYouTubeStartEntryView: View {
    @ObservedObject var coordinator: ManagedYouTubeStartCoordinator
    let entry: ManagedYouTubeStartEntry
    @State private var reviewedEffect = false
    @State private var earlyStart = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(entry.context.destination.name).font(.headline)
            switch entry.phase {
            case .checking: ProgressView("Checking current account, event and bound stream…")
            case .preparing: ProgressView("Rechecking this binding before sending video…")
            case .blocked:
                Text(entry.message ?? "This managed destination could not be verified.").foregroundStyle(.secondary)
                Button("Review again") { coordinator.reviewAgain(entry.id) }
            case .review:
                if let review = entry.review {
                    Text(review.eventTitle).font(.headline)
                    Text("Channel: \(review.binding.channelID)\nEvent: \(review.binding.eventID ?? "")\nBound stream: \(review.streamID)").font(.caption).textSelection(.enabled)
                    Text("\(review.privacy.capitalized) · Event \(review.lifecycle) · Stream \(review.streamState)")
                    Text("Scheduled: \(review.scheduledAt.formatted(date: .abbreviated, time: .complete))")
                    Text("\(review.profile.output.canvasWidth)×\(review.profile.output.canvasHeight) at \(review.profile.output.frameRate) fps · H.264 / AAC · \(review.profile.transport.displayName)")
                    Text(review.lifecycle == "live"
                         ? "YouTube reports this event is already Live. Sending video can resume content on this exact broadcast."
                         : (review.autoStart
                            ? "YouTube auto-start is enabled. Sending video can start this broadcast immediately with the reviewed privacy."
                            : "YouTube auto-start is disabled. Sending video connects the encoder; use YouTube Studio to explicitly transition the event to Live."))
                    Text(review.autoStart ? "YouTube auto-start is enabled." : "YouTube auto-start is disabled.").font(.caption)
                    Text(review.autoStop ? "YouTube auto-stop is enabled." : "YouTube auto-stop is disabled; end the event deliberately in its controls.").font(.caption)
                    Toggle("I reviewed this exact event and the effect of sending video", isOn: $reviewedEffect)
                    if review.requiresEarlyStart(at: Date()) {
                        Toggle("Send video before this event’s scheduled time", isOn: $earlyStart)
                    }
                    Link("Open YouTube Studio", destination: URL(string: "https://studio.youtube.com")!)
                    Button("Confirm and send video") {
                        coordinator.confirm(entry.id, consent: .init(reviewedPublicEffect: reviewedEffect, startBeforeScheduledTime: earlyStart))
                    }.disabled(!reviewedEffect || (review.requiresEarlyStart(at: Date()) && !earlyStart))
                    Text("This review expires after one minute. Changes require a new review.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Button("Cancel this destination", role: .cancel) { coordinator.cancel(entry.id) }
        }
    }
}
