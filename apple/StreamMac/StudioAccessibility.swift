import AppKit
import SwiftUI

private struct StudioReduceMotionKey: EnvironmentKey {
    static let defaultValue = false
}
extension EnvironmentValues {
    var studioReduceMotion: Bool {
        get { self[StudioReduceMotionKey.self] }
        set { self[StudioReduceMotionKey.self] = newValue }
    }
}

/// Interface settings are machine-local; project exports carry no producer's
/// accessibility preferences or permission choices.
struct StudioInterfacePreferences: View {
    @AppStorage("studio.interface.textSize") private var textSize = 13.0
    @AppStorage("studio.interface.increaseContrast") private var increaseContrast = false
    @AppStorage("studio.interface.reduceMotion") private var reduceMotion = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Slider(value: $textSize, in: 11...20, step: 1) {
                Text("Interface text size")
            }
            .accessibilityValue("\(Int(textSize)) points")
            Text("Interface text size: \(Int(textSize)) points").font(.caption)
            Toggle("Increase interface contrast", isOn: $increaseContrast)
            Toggle("Reduce interface motion", isOn: $reduceMotion)
            Text("Interface preferences apply immediately. System accessibility preferences are also honored. Use Compact Layout from the toolbar on a smaller display.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct StudioInterfaceModifier: ViewModifier {
    @AppStorage("studio.interface.textSize") private var textSize = 13.0
    @AppStorage("studio.interface.increaseContrast") private var increaseContrast = false
    @AppStorage("studio.interface.reduceMotion") private var reduceMotion = false
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    func body(content: Content) -> some View {
        content
            .font(.system(size: min(20, max(11, textSize))))
            .environment(\.dynamicTypeSize, textSize >= 18 ? .accessibility1 : textSize >= 16 ? .xxxLarge : textSize >= 14 ? .xLarge : .large)
            .background(StudioContrastAttachment(increaseContrast: increaseContrast))
            .environment(\.studioReduceMotion, reduceMotion || systemReduceMotion)
            .transaction { if reduceMotion || systemReduceMotion { $0.animation = nil; $0.disablesAnimations = true } }
    }
}

/// AppKit owns the read-only colorSchemeContrast environment. Setting the
/// window's native accessible appearance updates SwiftUI and native controls
/// without applying a video color filter to the preview/program monitors.
private struct StudioContrastAttachment: NSViewRepresentable {
    let increaseContrast: Bool
    final class Attachment: NSView {
        var enabled = false
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); apply() }
        func apply() { window?.appearance = enabled ? NSAppearance(named: .accessibilityHighContrastDarkAqua) : nil }
    }
    func makeNSView(context: Context) -> Attachment {
        let view = Attachment(); view.enabled = increaseContrast; return view
    }
    func updateNSView(_ nsView: Attachment, context: Context) {
        nsView.enabled = increaseContrast; nsView.apply()
    }
}
