import SwiftUI

/// E01 (issue #101): the per-source framing and picture adjustment controls,
/// hosted in the Sources inspector. Two deliberately separate scopes:
/// - LAYER OVERRIDES edit the selected layer of the STAGED scene — the value
///   stages, Takes, reverts, and undoes like any layer edit (preview shows it
///   immediately; program changes only on Take, unless direct-live is on).
/// - SOURCE DEFAULTS edit the bound registry source — project-level, applied
///   immediately to EVERY layer bound to that source in staged AND program.
/// A layer with no override inherits the source defaults (the caption reads
/// "inheriting"); any edit writes a complete override value. Reset clears the
/// scope back to inherit/identity; Bypass renders the source untouched without
/// losing the configuration. Presets copy a complete value — applying one is
/// a write to the chosen scope, never a live link.
struct SourceEffectsSectionView: View {
    @EnvironmentObject private var dispatcher: StudioCommandDispatcher
    @EnvironmentObject private var sceneStore: SceneStore
    @EnvironmentObject private var previewProgram: PreviewProgramModel

    @State private var presetName = ""

    /// The single selected layer of the staged scene, when it renders through
    /// the capture/media path (the layers source effects apply to).
    private var selectedLayer: LayerNode? {
        guard let scene = previewProgram.stagedScene,
              sceneStore.selectedLayerIDs.count == 1,
              let id = sceneStore.selectedLayerIDs.first,
              let layer = scene.layers.first(where: { $0.id == id })
        else { return nil }
        switch layer.payload {
        case .camera, .screen, .syphon, .media: return layer
        default: return nil
        }
    }

    private func boundSource(for layer: LayerNode) -> SourceDefinition? {
        layer.sourceID.flatMap { sceneStore.source(withID: $0) }
    }

    var body: some View {
        if let layer = selectedLayer {
            layerSection(layer)
            if let source = boundSource(for: layer) {
                sourceSection(source, for: layer)
            }
            presetsSection(layer: layer)
        }
    }

    // MARK: - Layer overrides (staged scene content)

    private func layerSection(_ layer: LayerNode) -> some View {
        Section("Layer Effects — \(layer.name)") {
            effectControls(layerOverrideBinding(for: layer))
            if layer.effectOverrides != nil {
                Button("Reset to Source Defaults") {
                    dispatcher.execute(.setLayerSourceEffects(layer.id, nil, in: nil))
                }
            } else {
                Text("Inheriting the source defaults (identity when unset). Any edit creates a layer override that replaces them wholesale.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The override value the controls edit: the existing override, else the
    /// inherited source defaults, else identity. Every set writes a complete
    /// override to the staged scene (undo-coalesced per layer by the
    /// dispatcher, so a slider scrub is one undo step).
    private func layerOverrideBinding(for layer: LayerNode) -> Binding<SourceEffects> {
        Binding(
            get: {
                layer.effectOverrides
                    ?? boundSource(for: layer)?.effectDefaults
                    ?? .identity
            },
            set: { dispatcher.execute(.setLayerSourceEffects(layer.id, $0.clamped(), in: nil)) })
    }

    // MARK: - Source defaults (project-level)

    private func sourceSection(_ source: SourceDefinition, for layer: LayerNode) -> some View {
        Section("Source Defaults — \(source.name)") {
            effectControls(sourceDefaultsBinding(for: source))
            if source.effectDefaults != nil {
                Button("Reset to Identity") {
                    dispatcher.execute(.setSourceEffectDefaults(source.id, nil))
                }
            }
            Text("Defaults apply to every layer bound to this source, in preview and program alike. A layer's own override replaces them.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func sourceDefaultsBinding(for source: SourceDefinition) -> Binding<SourceEffects> {
        Binding(
            get: { source.effectDefaults ?? .identity },
            set: { dispatcher.execute(.setSourceEffectDefaults(source.id, $0.clamped())) })
    }

    // MARK: - Presets (project-level)

    private func presetsSection(layer: LayerNode) -> some View {
        Section("Effect Presets") {
            HStack {
                TextField("Preset name", text: $presetName)
                Button("Save Current") {
                    let name = presetName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return }
                    dispatcher.execute(.addEffectPreset(SourceEffectPreset(
                        name: name,
                        effects: layerOverrideBinding(for: layer).wrappedValue.clamped())))
                    presetName = ""
                }
                .disabled(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            ForEach(sceneStore.effectPresets) { preset in
                HStack {
                    Text(preset.name)
                        .lineLimit(1)
                    Spacer()
                    Button("Apply to Layer") {
                        dispatcher.execute(.setLayerSourceEffects(layer.id, preset.effects, in: nil))
                    }
                    if let source = boundSource(for: layer) {
                        Button("Apply to Source") {
                            dispatcher.execute(.setSourceEffectDefaults(source.id, preset.effects))
                        }
                    }
                    Button(role: .destructive) {
                        dispatcher.execute(.removeEffectPreset(preset.id))
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    // MARK: - Shared controls

    /// The framing + picture adjustment controls bound to one scope's
    /// `SourceEffects` value. Ranges match `SourceEffects.validationError`.
    @ViewBuilder
    private func effectControls(_ effects: Binding<SourceEffects>) -> some View {
        Toggle("Bypass Effects", isOn: effects.isBypassed)
        Slider(value: effects.zoom, in: 1...4) {
            Text("Zoom")
        } minimumValueLabel: {
            Text("1×")
        } maximumValueLabel: {
            Text("4×")
        }
        if effects.wrappedValue.zoom > 1 {
            Slider(value: effects.panX, in: -1...1) { Text("Pan X") }
            Slider(value: effects.panY, in: -1...1) { Text("Pan Y") }
        }
        Toggle("Mirror", isOn: effects.isMirrored)
        Picker("Rotation", selection: effects.rotationDegrees) {
            Text("0°").tag(0.0)
            Text("90°").tag(90.0)
            Text("180°").tag(180.0)
            Text("270°").tag(270.0)
        }
        Slider(value: effects.brightness, in: -0.5...0.5) { Text("Brightness") }
        Slider(value: effects.contrast, in: 0.5...2) { Text("Contrast") }
        Slider(value: effects.saturation, in: 0...2) { Text("Saturation") }
        Slider(value: effects.temperature, in: 3000...9000, step: 100) {
            Text("Temperature")
        }
        Slider(value: effects.tint, in: -100...100) { Text("Tint") }
        Slider(value: effects.gamma, in: 0.5...2) { Text("Gamma") }
        ColorTransformControlsView(effects: effects)
    }
}
