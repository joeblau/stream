import UIKit

/// Centralized haptic feedback so every control interaction feels consistent.
/// Respects the system's haptic settings (no-ops when the user disables them).
@MainActor
enum Haptics {
    /// One long-lived generator, kept warm. Allocating a generator per tap makes
    /// the Taptic Engine cold-start inside the button's action — a stall the user
    /// feels as the whole control responding late, not just the haptic. Reusing a
    /// prepared instance keeps the engine spun up so the tap fires immediately.
    private static let impact = UIImpactFeedbackGenerator(style: .light)

    /// A light tap for button presses. Call from SwiftUI action closures, which
    /// already run on the main actor.
    static func tap() {
        impact.impactOccurred()
        // Re-arm for the next press. The engine idles down after a couple of
        // seconds, so this is what keeps repeat taps snappy.
        impact.prepare()
    }

    /// Warms the Taptic Engine ahead of the first interaction (scene activation),
    /// so even the very first button press doesn't pay the spin-up cost.
    static func warmUp() {
        impact.prepare()
    }
}
