import AppKit
import SwiftUI

private struct StudioTextScaleKey: EnvironmentKey { static let defaultValue = 1.0 }

private struct StudioIncreaseContrastKey: EnvironmentKey {
    static let defaultValue = false
}

private struct StudioReduceMotionKey: EnvironmentKey {
    static let defaultValue = false
}
extension EnvironmentValues {
    var studioTextScale: Double {
        get { self[StudioTextScaleKey.self] }
        set { self[StudioTextScaleKey.self] = newValue }
    }
    var studioIncreaseContrast: Bool {
        get { self[StudioIncreaseContrastKey.self] }
        set { self[StudioIncreaseContrastKey.self] = newValue }
    }
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
            Text("Interface text size: \(Int(textSize)) points").studioTextStyle(.caption)
            Toggle("Increase interface contrast", isOn: $increaseContrast)
            Toggle("Reduce interface motion", isOn: $reduceMotion)
            Text("Interface preferences apply immediately. System accessibility preferences are also honored. Use Compact Layout from the toolbar on a smaller display.")
                .studioTextStyle(.caption).foregroundStyle(.studioSecondary)
        }
    }
}

struct StudioInterfaceModifier: ViewModifier {
    @AppStorage("studio.interface.textSize") private var textSize = 13.0
    @AppStorage("studio.interface.increaseContrast") private var increaseContrast = false
    @AppStorage("studio.interface.reduceMotion") private var reduceMotion = false
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.colorSchemeContrast) private var systemContrast
    func body(content: Content) -> some View {
        content
            .font(.system(size: min(20, max(11, textSize))))
            .environment(\.studioTextScale, min(20, max(11, textSize)) / 13)
            .environment(\.dynamicTypeSize, textSize >= 18 ? .accessibility1 : textSize >= 16 ? .xxxLarge : textSize >= 14 ? .xLarge : .large)
            .background(StudioContrastAttachment(increaseContrast: increaseContrast))
            .environment(\.studioIncreaseContrast, increaseContrast || systemContrast == .increased)
            .environment(\.studioReduceMotion, reduceMotion || systemReduceMotion)
            .transaction { if reduceMotion || systemReduceMotion { $0.animation = nil; $0.disablesAnimations = true } }
    }
}

/// Native controls use the accessible appearance where macOS exposes it.
/// Some systems alias that appearance to Dark Aqua, so app-owned semantic
/// text/panel styles also implement the preference. Monitor pixels are never
/// filtered or recolored to increase interface contrast.
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

/// Secondary interface copy remains fully legible in the app contrast mode;
/// source imagery and explicitly colored media content keep their own colors.
struct StudioSecondaryStyle: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> some ShapeStyle {
        if environment.studioIncreaseContrast {
            return AnyShapeStyle(environment.colorScheme == .dark ? Color.white : Color.black)
        }
        return AnyShapeStyle(.secondary)
    }
}
extension ShapeStyle where Self == StudioSecondaryStyle {
    static var studioSecondary: StudioSecondaryStyle { .init() }
}

private struct StudioPanelSurface: ViewModifier {
    @Environment(\.studioIncreaseContrast) private var increaseContrast
    @Environment(\.colorScheme) private var colorScheme
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(increaseContrast ? .hidden : .automatic)
            .background { if increaseContrast { colorScheme == .dark ? Color.black : Color.white } }
            .overlay {
                if increaseContrast {
                    Rectangle().stroke(colorScheme == .dark ? Color.white : Color.black, lineWidth: 1)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
    }
}
extension View {
    func studioPanelSurface() -> some View { modifier(StudioPanelSurface()) }
}

/// macOS semantic Font styles do not scale when Dynamic Type changes. Scale
/// interface copy explicitly; media graphics and pixel dimensions are untouched.
private struct StudioTextStyle: ViewModifier {
    @Environment(\.studioTextScale) private var scale
    let style: Font.TextStyle
    let weight: Font.Weight?
    private var points: CGFloat {
        switch style {
        case .largeTitle: 26
        case .title: 22
        case .title2: 17
        case .title3: 15
        case .headline, .body: 13
        case .callout, .subheadline: 12
        case .caption: 11
        case .caption2, .footnote: 10
        @unknown default: 13
        }
    }
    func body(content: Content) -> some View {
        content.font(.system(size: points * scale, weight: weight ?? (style == .headline ? .semibold : .regular)))
    }
}
extension View {
    func studioTextStyle(_ style: Font.TextStyle, weight: Font.Weight? = nil) -> some View {
        modifier(StudioTextStyle(style: style, weight: weight))
    }
}
