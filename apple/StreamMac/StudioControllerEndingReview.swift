import SwiftUI

/// Always mounted in the studio window: an external key can ask for the same
/// deliberate ending choice even when the Destinations inspector is closed.
struct StudioControllerEndingReview: View {
    @ObservedObject var coordinator: StudioEndingCoordinator
    var willPresent: () -> Void
    var didDismiss: () -> Void
    @State private var displayed: StudioEndingCoordinator.ControllerReview?
    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .onChange(of: coordinator.controllerReview, initial: true) { _, review in
                if review != nil && displayed == nil { willPresent() }
                if review == nil && displayed != nil { didDismiss() }
                displayed = review
            }
            .confirmationDialog("End the selected broadcast targets?", isPresented: Binding(
                get: { displayed != nil },
                set: { shown in if !shown, let id = displayed?.id { coordinator.cancelControllerReview(id) } }
            ), titleVisibility: .visible) {
                if let review = displayed {
                    Button(review.mode == .remote ? "Complete Selected Remote Event" : "End Selected Remote Events and Local Outputs", role: .destructive) {
                        coordinator.confirmControllerReview(review.id)
                    }
                    Button("Cancel", role: .cancel) { coordinator.cancelControllerReview(review.id) }
                }
            } message: {
                Text((displayed?.targets.map { target in
                    target.name + (target.binding.map { " · \($0.provider.name) · \($0.eventID ?? $0.channelID)" } ?? "")
                }.joined(separator: "\n") ?? "") + "\n\nOnly supported, permitted provider events are completed. Other remote states remain unconfirmed. A sent request cannot be undone.\n\nLocal recording continues.")
            }
    }
}
