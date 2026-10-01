import AppKit
import SwiftUI
import StreamCore

/// G02 (issue #110): the text/title controls — the string, the full style
/// surface (font, size, color, alignment, background bar, padding, auto vs
/// fixed box, wrapping, overflow), timed/fly-in visibility, templates
/// (lower third, host/guest name captions with `{host}`/`{guest}` tokens),
/// and reusable named title-style presets — hosted in the Sources inspector
/// for the single selected TEXT layer of the STAGED scene. Every edit is a
/// complete `TextSourcePayload` write through `.setLayerText`, so the text
/// stages, Takes, reverts, and undoes like any layer edit (edits coalesce
/// into one undo step per layer), and preview shows it immediately. Applying
/// a template or preset copies a complete VALUE (never a live link).
struct TextLayerSectionView: View {
    @EnvironmentObject private var dispatcher: StudioCommandDispatcher
    @EnvironmentObject private var sceneStore: SceneStore
    @EnvironmentObject private var previewProgram: PreviewProgramModel

    @State private var presetName = ""
    /// The layer ID currently in custom-font mode (UI state only — the
    /// payload's `fontName` stays the single source of truth).
    @State private var customFontLayerID: LayerID?

    /// The single selected layer of the staged scene, when it is a text
    /// layer (the only layers these controls edit).
    private var selectedTextLayer: (layer: LayerNode, payload: TextSourcePayload)? {
        guard let scene = previewProgram.stagedScene,
              sceneStore.selectedLayerIDs.count == 1,
              let id = sceneStore.selectedLayerIDs.first,
              let layer = scene.layers.first(where: { $0.id == id }),
              case .text(let payload) = layer.payload
        else { return nil }
        return (layer, payload)
    }

    var body: some View {
        if let (layer, payload) = selectedTextLayer {
            textSection(layer: layer, payload: payload)
            styleSection(layer: layer, payload: payload)
            timingSection(layer: layer, payload: payload)
            templatesSection(layer: layer, payload: payload)
            presetsSection(layer: layer, payload: payload)
        }
    }

    // MARK: - Text content (staged scene content)

    private func textSection(layer: LayerNode, payload: TextSourcePayload) -> some View {
        Section("Text — \(layer.name)") {
            TextEditor(text: payloadBinding(for: layer).text)
                .frame(minHeight: 56, maxHeight: 120)
                .font(.body)
            HStack {
                Button("Insert {host}") { insertToken("host", into: layer) }
                Button("Insert {guest}") { insertToken("guest", into: layer) }
            }
            .buttonStyle(.borderless)
            .font(.caption)
            if TitleTemplate.containsToken(payload.text) {
                Text("Tokens resolve to the published host/guest names on output; unset tokens render literally.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func insertToken(_ token: String, into layer: LayerNode) {
        guard case .text(var payload) = layer.payload else { return }
        if !payload.text.isEmpty, !payload.text.hasSuffix(" ") { payload.text += " " }
        payload.text += "{\(token)}"
        dispatcher.execute(.setLayerText(layer.id, payload, in: nil))
    }

    // MARK: - Style controls (staged scene content)

    private func styleSection(layer: LayerNode, payload: TextSourcePayload) -> some View {
        Section("Title Style") {
            let style = styleBinding(for: layer)
            Picker("Font", selection: fontPickerBinding(for: layer)) {
                Text("Default (Helvetica Neue Bold)").tag(Self.fontDefault)
                ForEach(Self.curatedFonts, id: \.self) { name in
                    Text(name).tag(name)
                }
                Text("Custom…").tag(Self.fontCustom)
            }
            if fontPickerBinding(for: layer).wrappedValue == Self.fontCustom {
                TextField("Font (PostScript or family name)",
                          text: fontNameBinding(for: layer))
                Text("A font that's missing on another Mac falls back through the pinned chain (Helvetica Neue → Helvetica → Apple Color Emoji → LastResort), so exported projects render predictably.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Slider(value: style.fontSize, in: 4...200) { Text("Font Size") }
            ColorPicker("Text Color", selection: hexColorBinding(style.colorHex),
                        supportsOpacity: true)
            Toggle("Background Bar", isOn: backgroundEnabledBinding(for: layer))
            if payload.backgroundColorHex != nil {
                ColorPicker("Background Color", selection: hexColorBinding(style.backgroundColorHex),
                            supportsOpacity: true)
            }
            Slider(value: style.padding, in: 0...100) { Text("Padding") }
            Picker("Alignment", selection: style.alignment) {
                ForEach(TextHorizontalAlignment.allCases, id: \.self) { alignment in
                    Text(alignment.displayName).tag(alignment)
                }
            }
            Picker("Vertical", selection: style.verticalAlignment) {
                ForEach(TextVerticalAlignment.allCases, id: \.self) { alignment in
                    Text(alignment.displayName).tag(alignment)
                }
            }
            Picker("Box", selection: style.boxSizing) {
                ForEach(TextBoxSizing.allCases, id: \.self) { sizing in
                    Text(sizing.displayName).tag(sizing)
                }
            }
            Toggle("Wrap Text", isOn: style.wraps)
            if payload.boxSizing == .fixed {
                Picker("Overflow", selection: style.overflow) {
                    ForEach(TextOverflow.allCases, id: \.self) { overflow in
                        Text(overflow.displayName).tag(overflow)
                    }
                }
            }
        }
    }

    // MARK: - Timed / fly-in visibility (staged scene content)

    private func timingSection(layer: LayerNode, payload: TextSourcePayload) -> some View {
        Section("Title Timing") {
            Toggle("Fly In / Timed Visibility", isOn: timingEnabledBinding(for: layer))
            if payload.timing != nil {
                let timing = timingBinding(for: layer)
                Slider(value: timing.flyInSeconds, in: 0...3, step: 0.05) {
                    Text("Fly-In Duration")
                }
                Picker("Fly-In Direction", selection: timing.flyInDirection) {
                    ForEach(TitleFlyInDirection.allCases, id: \.self) { direction in
                        Text(direction.displayName).tag(direction)
                    }
                }
                Slider(value: timing.holdSeconds, in: 0...30, step: 0.5) {
                    Text("Hold (0 = stays)")
                }
                if timing.wrappedValue.holdSeconds > 0 {
                    Slider(value: timing.fadeOutSeconds, in: 0...3, step: 0.05) {
                        Text("Fade-Out Duration")
                    }
                }
                Text("Timing starts when the title appears on output; hiding and showing it replays the animation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Templates (complete-value writes)

    private func templatesSection(layer: LayerNode, payload: TextSourcePayload) -> some View {
        Section("Title Templates") {
            templateButton("Lower Third", style: .lowerThird, text: nil, layer: layer)
            templateButton("Guest Name Caption", style: .guestName,
                           text: "{\(TitleTemplate.guestToken)}", layer: layer)
            templateButton("Host Name Caption", style: .hostName,
                           text: "{\(TitleTemplate.hostToken)}", layer: layer)
            templateButton("Headline", style: .headline, text: nil, layer: layer)
            Text("Templates write a complete style onto this layer — later template or preset edits never re-point it. Name captions use tokens that follow the published host/guest names.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func templateButton(_ title: String, style: TextTitleStyle,
                                text: String?, layer: LayerNode) -> some View {
        Button(title) {
            guard case .text(var payload) = layer.payload else { return }
            payload.style = style
            if let text { payload.text = text }
            dispatcher.execute(.setLayerText(layer.id, payload.clamped(), in: nil))
        }
    }

    // MARK: - Presets (project-level)

    private func presetsSection(layer: LayerNode, payload: TextSourcePayload) -> some View {
        Section("Title Style Presets") {
            HStack {
                TextField("Preset name", text: $presetName)
                Button("Save Current") {
                    let name = presetName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return }
                    dispatcher.execute(.addTextStylePreset(TextStylePreset(
                        name: name, style: payload.style.clamped())))
                    presetName = ""
                }
                .disabled(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            ForEach(sceneStore.textStylePresets) { preset in
                HStack {
                    Text(preset.name)
                        .lineLimit(1)
                    Spacer()
                    Button("Apply") {
                        guard case .text(var payload) = layer.payload else { return }
                        payload.style = preset.style
                        dispatcher.execute(.setLayerText(layer.id, payload.clamped(), in: nil))
                    }
                    Button(role: .destructive) {
                        dispatcher.execute(.removeTextStylePreset(preset.id))
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    // MARK: - Bindings

    /// The payload value the text controls edit. Every set writes a complete
    /// payload to the staged scene (undo-coalesced per layer).
    private func payloadBinding(for layer: LayerNode) -> Binding<TextSourcePayload> {
        Binding(
            get: {
                if case .text(let payload) = layer.payload { return payload }
                return TextSourcePayload()
            },
            set: { dispatcher.execute(.setLayerText(layer.id, $0.clamped(), in: nil)) })
    }

    /// The STYLE half of the payload (everything but the string) — what the
    /// style controls edit. Setting writes the whole payload back with the
    /// new style, leaving the text untouched.
    private func styleBinding(for layer: LayerNode) -> Binding<TextTitleStyle> {
        Binding(
            get: {
                if case .text(let payload) = layer.payload { return payload.style }
                return TextTitleStyle()
            },
            set: { style in
                guard case .text(var payload) = layer.payload else { return }
                payload.style = style
                dispatcher.execute(.setLayerText(layer.id, payload.clamped(), in: nil))
            })
    }

    /// The timing value (enabled state is a separate binding — nil = off).
    private func timingBinding(for layer: LayerNode) -> Binding<TitleTiming> {
        Binding(
            get: {
                if case .text(let payload) = layer.payload { return payload.timing ?? TitleTiming() }
                return TitleTiming()
            },
            set: { timing in
                guard case .text(var payload) = layer.payload else { return }
                payload.timing = timing
                dispatcher.execute(.setLayerText(layer.id, payload.clamped(), in: nil))
            })
    }

    private func timingEnabledBinding(for layer: LayerNode) -> Binding<Bool> {
        Binding(
            get: {
                if case .text(let payload) = layer.payload { return payload.timing != nil }
                return false
            },
            set: { enabled in
                guard case .text(var payload) = layer.payload else { return }
                payload.timing = enabled ? (payload.timing ?? TitleTiming()) : nil
                dispatcher.execute(.setLayerText(layer.id, payload.clamped(), in: nil))
            })
    }

    private func backgroundEnabledBinding(for layer: LayerNode) -> Binding<Bool> {
        Binding(
            get: {
                if case .text(let payload) = layer.payload {
                    return payload.backgroundColorHex != nil
                }
                return false
            },
            set: { enabled in
                guard case .text(var payload) = layer.payload else { return }
                payload.backgroundColorHex = enabled ? (payload.backgroundColorHex ?? "#00000080") : nil
                dispatcher.execute(.setLayerText(layer.id, payload.clamped(), in: nil))
            })
    }

    // MARK: - Font picking

    /// Picker sentinel tags: the default (nil font name) and the custom
    /// free-text entry.
    private static let fontDefault = ""
    private static let fontCustom = "\u{1}custom"
    private static let curatedFonts = [
        "HelveticaNeue", "HelveticaNeue-Bold", "AvenirNext-Bold",
        "Futura-Medium", "Georgia-Bold", "Menlo-Bold", "AmericanTypewriter"
    ]

    /// The picker's selection: the default tag for nil, the custom sentinel
    /// while the layer is in custom mode or carries a non-curated name, else
    /// the curated font name itself.
    private func fontPickerBinding(for layer: LayerNode) -> Binding<String> {
        Binding(
            get: {
                guard case .text(let payload) = layer.payload,
                      let name = payload.fontName, !name.isEmpty
                else { return Self.fontDefault }
                if customFontLayerID == layer.id { return Self.fontCustom }
                return Self.curatedFonts.contains(name) ? name : Self.fontCustom
            },
            set: { selection in
                guard case .text(var payload) = layer.payload else { return }
                switch selection {
                case Self.fontDefault:
                    payload.fontName = nil
                    customFontLayerID = nil
                case Self.fontCustom:
                    customFontLayerID = layer.id
                    if payload.fontName == nil {
                        // Seed a real, non-curated font to start editing from.
                        payload.fontName = "HelveticaNeue-Medium"
                    }
                default:
                    payload.fontName = selection
                    customFontLayerID = nil
                }
                dispatcher.execute(.setLayerText(layer.id, payload.clamped(), in: nil))
            })
    }

    /// The free-text font name for the custom entry.
    private func fontNameBinding(for layer: LayerNode) -> Binding<String> {
        Binding(
            get: {
                if case .text(let payload) = layer.payload { return payload.fontName ?? "" }
                return ""
            },
            set: { name in
                guard case .text(var payload) = layer.payload else { return }
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                payload.fontName = trimmed.isEmpty ? nil : trimmed
                dispatcher.execute(.setLayerText(layer.id, payload.clamped(), in: nil))
            })
    }

    // MARK: - Color bridging

    /// Bridges a `#RRGGBB`/`#RRGGBBAA` hex string to a SwiftUI `Color`
    /// (the G03 style-section pattern), preserving alpha: writes 8-digit
    /// hex when the color is translucent, 6-digit when opaque.
    private func hexColorBinding(_ hex: Binding<String>) -> Binding<Color> {
        Binding(
            get: {
                let components = HexColor.components(hex.wrappedValue)
                return Color(NSColor(calibratedRed: components.red,
                                     green: components.green,
                                     blue: components.blue,
                                     alpha: components.alpha))
            },
            set: { color in
                let nsColor = NSColor(color).usingColorSpace(.deviceRGB) ?? .white
                func byte(_ value: CGFloat) -> Int {
                    min(255, max(0, Int((value * 255).rounded())))
                }
                if nsColor.alphaComponent >= 0.999 {
                    hex.wrappedValue = HexColor.string(red: Double(nsColor.redComponent),
                                                       green: Double(nsColor.greenComponent),
                                                       blue: Double(nsColor.blueComponent))
                } else {
                    hex.wrappedValue = String(
                        format: "#%02X%02X%02X%02X",
                        byte(nsColor.redComponent), byte(nsColor.greenComponent),
                        byte(nsColor.blueComponent), byte(nsColor.alphaComponent))
                }
            })
    }

    /// The background bar's optional color: reads as opaque black when unset
    /// (the toggle controls presence); writes nil only through the toggle.
    private func hexColorBinding(_ hex: Binding<String?>) -> Binding<Color> {
        hexColorBinding(Binding(
            get: { hex.wrappedValue ?? "#00000080" },
            set: { hex.wrappedValue = $0 }))
    }
}
