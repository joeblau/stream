import SwiftUI

/// Preserve one set of controls and their native focus/popover ownership as
/// the canvas narrows or interface text grows. Overflow scrolls instead of
/// imposing a larger pane minimum or wrapping transport buttons out of view.
struct StudioControlRow<Content: View>: View {
    let accessibilityLabel: String
    @ViewBuilder var content: () -> Content
    @State private var viewportWidth: CGFloat = 0

    var body: some View {
        ScrollView(.horizontal) {
            content().frame(minWidth: viewportWidth)
        }
        .scrollIndicators(.visible)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { proxy in
            max(0, proxy.size.width)
        } action: { width in
            viewportWidth = width
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }
}
