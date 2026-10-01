import AppKit
import SwiftUI

/// G03 (issue #106): the layer styling controls — shape mask, border,
/// shadow, opacity, perspective — hosted in the Sources inspector for the
/// single selected layer of the STAGED scene. Every edit is a complete
/// `LayerStyle` write through `.setLayerStyle`, so the style stages, Takes,
/// reverts, and undoes like any layer edit (slider scrubs coalesce into one
/// undo step), preview shows it immediately, and the original media is never
/// touched. Reset writes `.identity`; presets copy a complete value (project
/// level, the E01 preset pattern) — applying one is a write, never a live
/// link.
struct LayerStyleSectionView: View {
    @EnvironmentObject private var dispatcher: StudioCommandDispatcher
    @EnvironmentObject private var sceneStore: SceneStore
    @EnvironmentObject private var previewProgram: PreviewProgramModel

    @State private var presetName = ""

    /// The single selected layer of the staged scene, when it renders (the
    /// layers styling applies to). Nested scenes style through the same
    /// render tail, so `.scene` layers are included.
    private var selectedLayer: LayerNode? {
        guard let scene = previewProgram.stagedScene,
              sceneStore.selectedLayerIDs.count == 1,
              let id = sceneStore.selectedLayerIDs.first,
              let layer = scene.layers.first(where: { $0.id == id }),
              layer.payload.isRenderable
        else { return nil }
        return layer
    }

    var body: some View {
        if let layer = selectedLayer {
            styleSection(layer)
            Section("Scene Motion") {
                TextField("Motion ID", text: Binding(get: { layer.motionID.uuidString }, set: { value in
                    guard let id = UUID(uuidString: value) else { return }
                    dispatcher.execute(.setLayerMotionIdentity(layer.id, id, in: nil))
                }))
                Button("Make Motion Independent") {
                    dispatcher.execute(.setLayerMotionIdentity(layer.id, UUID(), in: nil))
                }
                Text("Copies share this ID. Matching requires one visible copy per scene and compatible source and mask settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            presetsSection(layer: layer)
        }
    }

    // MARK: - Style controls (staged scene content)

    private func styleSection(_ layer: LayerNode) -> some View {
        Section("Layer Style — \(layer.name)") {
            let style = styleBinding(for: layer)
            Picker("Mask", selection: style.mask.shape) {
                ForEach(LayerMask.Shape.allCases, id: \.self) { shape in
                    Text(shape.displayName).tag(shape)
                }
            }
            switch style.wrappedValue.mask.shape {
            case .none:
                EmptyView()
            case .rectangle:
                Slider(value: style.mask.cornerRadius, in: 0...200) { Text("Corner Radius") }
            case .circle:
                Text("An ellipse inscribed in the layer's frame.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .custom:
                Text("Custom masks use an asset-library image. The asset library (P03) is still landing — until it does, the layer renders unmasked.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if style.wrappedValue.mask.isActive {
                Slider(value: style.mask.feather, in: 0...100) { Text("Mask Feather") }
                Toggle("Invert Mask", isOn: style.mask.isInverted)
            }

            Slider(value: style.border.width, in: 0...100) { Text("Border Width") }
            if style.wrappedValue.border.isActive {
                ColorPicker("Border Color", selection: hexColorBinding(style.border.colorHex),
                            supportsOpacity: true)
            }

            Toggle("Shadow", isOn: style.shadow.isEnabled)
            if style.wrappedValue.shadow.isEnabled {
                Slider(value: style.shadow.offsetX, in: -200...200) { Text("Shadow X") }
                Slider(value: style.shadow.offsetY, in: -200...200) { Text("Shadow Y") }
                Slider(value: style.shadow.radius, in: 0...100) { Text("Shadow Blur") }
                ColorPicker("Shadow Color", selection: hexColorBinding(style.shadow.colorHex),
                            supportsOpacity: true)
            }

            Slider(value: style.opacity, in: 0...1) { Text("Opacity") }

            Slider(value: style.perspective.yawDegrees, in: -80...80) {
                Text("Perspective Yaw")
            }
            Slider(value: style.perspective.pitchDegrees, in: -80...80) {
                Text("Perspective Pitch")
            }

            if style.wrappedValue != .identity {
                Button("Reset Style") {
                    dispatcher.execute(.setLayerStyle(layer.id, .identity, in: nil))
                }
            }
            Text("Styling is non-destructive: it decorates the placed layer without altering the source. Pixel values are in 1080p reference units and scale with the output resolution.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// The style value the controls edit. Every set writes a complete style
    /// to the staged scene (undo-coalesced per layer by the dispatcher).
    private func styleBinding(for layer: LayerNode) -> Binding<LayerStyle> {
        Binding(
            get: { layer.style },
            set: { dispatcher.execute(.setLayerStyle(layer.id, $0.clamped(), in: nil)) })
    }

    // MARK: - Presets (project-level)

    private func presetsSection(layer: LayerNode) -> some View {
        Section("Style Presets") {
            HStack {
                TextField("Preset name", text: $presetName)
                Button("Save Current") {
                    let name = presetName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return }
                    dispatcher.execute(.addStylePreset(LayerStylePreset(
                        name: name, style: layer.style.clamped())))
                    presetName = ""
                }
                .disabled(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            ForEach(sceneStore.stylePresets) { preset in
                HStack {
                    Text(preset.name)
                        .lineLimit(1)
                    Spacer()
                    Button("Apply") {
                        dispatcher.execute(.setLayerStyle(layer.id, preset.style, in: nil))
                    }
                    Button(role: .destructive) {
                        dispatcher.execute(.removeStylePreset(preset.id))
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    // MARK: - Color bridging

    /// Bridges a `#RRGGBB`/`#RRGGBBAA` hex string to a SwiftUI `Color`
    /// (the E03 backdrop-color pattern), preserving alpha: writes 8-digit
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
}
