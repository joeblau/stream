import UIKit

/// Centralized haptic feedback so every control interaction feels consistent.
/// Respects the system's haptic settings (no-ops when the user disables them).
enum Haptics {
    /// A light tap for button presses. Call from SwiftUI action closures, which
    /// already run on the main actor.
    @MainActor static func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}
