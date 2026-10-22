import SwiftUI

/// Thumbnail scenes use the same native button activation as other producer
/// controls. The caller keeps its thumbnail styling, drop/context menus and
/// scene-selection command, including the current Direct Live policy.
struct SceneSelectionButton<Content: View>: View {
    let name: String
    let isSelected: Bool
    let status: String
    let action: () -> Void
    let content: () -> Content

    init(name: String, isSelected: Bool, status: String = "", action: @escaping () -> Void,
         @ViewBuilder content: @escaping () -> Content) {
        self.name = name; self.isSelected = isSelected; self.status = status
        self.action = action; self.content = content
    }

    var body: some View {
        Button(action: action, label: content)
            .buttonStyle(.plain)
            .accessibilityLabel("Select scene \(name)")
            .accessibilityValue(([isSelected ? "Selected" : "Not selected", status]).filter { !$0.isEmpty }.joined(separator: ", "))
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
