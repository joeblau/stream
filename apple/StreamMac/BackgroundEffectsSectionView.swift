import AppKit
import SwiftUI
import StreamCore

/// E03 (issue #164): the capability-gated background blur / replacement
/// controls for the selected CAMERA layer (person segmentation is meaningful
/// for camera feeds only), hosted in the Sources inspector directly after
/// E01's `SourceEffectsSectionView`.
///
/// HONEST GATING. Every enable path reads the tested capability matrix
/// (`SegmentationCapabilityMatrix.current`, derived from public device
/// signals): an unsupported OS, or a device where even Fast segmentation
/// can't fit half a 60 fps frame, shows the explicit reason and NO enabled
/// controls — the effect is never pretend-available. The quality picker lists
/// every public Vision level with its estimated frame cost, marks the
/// matrix's recommendation, and notes over-budget levels rather than hiding
/// them.
///
/// SCOPES. The settings ride E01's `SourceEffects` model, so this section
/// edits the same two scopes as the Source Effects section — the selected
/// layer's OVERRIDE (staged scene content: Takes/reverts/undoes) and the
/// bound source's DEFAULTS (project-level, apply immediately) — through the
/// existing `setLayerSourceEffects` / `setSourceEffectDefaults` commands. No
/// new commands exist for E03.
///
/// LIVE STATUS. The footer reports the coordinator's measured reality while
/// the effect is on: the governor's effective quality (which may sit below
/// the requested one), the last segmentation cost, and the passthrough
/// fallback state when segmentation becomes unavailable mid-stream.
public struct BackgroundEffectsSectionView: View {
    @EnvironmentObject private var dispatcher: StudioCommandDispatcher

    public init() {}

    public var body: some View {
        // The dispatcher's nested center doesn't invalidate views through the
        // dispatcher's own @Published (the CameraControlsSectionView
        // precedent), so the content observes the center directly.
        BackgroundEffectsSectionContent(center: dispatcher.backgroundEffects,
                                        dispatcher: dispatcher)
    }
}

private struct BackgroundEffectsSectionContent: View {
    @ObservedObject var center: BackgroundEffectsCenter
    let dispatcher: StudioCommandDispatcher
    @EnvironmentObject private var sceneStore: SceneStore
    @EnvironmentObject private var previewProgram: PreviewProgramModel

    /// Live status refresh while the section is on screen (the
    /// CameraControlsSectionView pattern — never per frame).
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// The single selected layer of the staged scene, when it renders a
    /// camera feed (the only payload kind person segmentation applies to).
    private var selectedCameraLayer: LayerNode? {
        guard let scene = previewProgram.stagedScene,
              sceneStore.selectedLayerIDs.count == 1,
              let id = sceneStore.selectedLayerIDs.first,
              let layer = scene.layers.first(where: { $0.id == id }),
              case .camera = layer.payload
        else { return nil }
        return layer
    }

    private func boundSource(for layer: LayerNode) -> SourceDefinition? {
        layer.sourceID.flatMap { sceneStore.source(withID: $0) }
    }

    /// The capture key the coordinator segments under — the registry
    /// payload's identity winning over the inline one (the same resolution
    /// `SceneRenderer.captureKey` performs).
    private func captureKey(for layer: LayerNode) -> CaptureSourceKey? {
        let payload = layer.sourceID.flatMap { sceneStore.source(withID: $0) }?.payload
            ?? layer.payload
        guard case .camera(let camera) = payload else { return nil }
        return .camera(camera)
    }

    var body: some View {
        if let layer = selectedCameraLayer {
            Group {
                if !center.capability.isSupported, let reason = center.capability.unavailableReason {
                    Section("Background Effects — \(layer.name)") {
                        Label(reason, systemImage: "person.crop.rectangle.badge.xmark")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if center.capability.recommendedQuality == nil,
                          let reason = center.capability.unavailableReason {
                    Section("Background Effects — \(layer.name)") {
                        Label(reason, systemImage: "gauge.with.dots.needle.bottom.50percent")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    layerSection(layer)
                    if let source = boundSource(for: layer) {
                        sourceSection(source, for: layer)
                    }
                    statusSection(layer)
                }
            }
            .onAppear { refresh(layer) }
            .onReceive(timer) { _ in refresh(layer) }
        }
    }

    private func refresh(_ layer: LayerNode) {
        center.refresh(keys: captureKey(for: layer).map { [$0] } ?? [])
    }

    // MARK: - Layer overrides (staged scene content)

    private func layerSection(_ layer: LayerNode) -> some View {
        Section("Layer Background — \(layer.name)") {
            backgroundControls(layerBackgroundBinding(for: layer))
            if layer.effectOverrides == nil {
                Text("Inheriting the source defaults (identity when unset). Any edit creates a layer override that replaces them wholesale.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func layerBackgroundBinding(for layer: LayerNode) -> Binding<BackgroundEffectSettings> {
        Binding(
            get: {
                (layer.effectOverrides
                    ?? boundSource(for: layer)?.effectDefaults
                    ?? .identity).background
            },
            set: { background in
                var effects = layer.effectOverrides
                    ?? boundSource(for: layer)?.effectDefaults
                    ?? .identity
                effects.background = background.clamped()
                dispatcher.execute(.setLayerSourceEffects(layer.id, effects, in: nil))
            })
    }

    // MARK: - Source defaults (project-level)

    private func sourceSection(_ source: SourceDefinition, for layer: LayerNode) -> some View {
        Section("Source Background Defaults — \(source.name)") {
            backgroundControls(sourceBackgroundBinding(for: source))
            Text("Defaults apply to every layer bound to this source, in preview and program alike. A layer's own override replaces them.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func sourceBackgroundBinding(for source: SourceDefinition) -> Binding<BackgroundEffectSettings> {
        Binding(
            get: { (source.effectDefaults ?? .identity).background },
            set: { background in
                var effects = source.effectDefaults ?? .identity
                effects.background = background.clamped()
                dispatcher.execute(.setSourceEffectDefaults(source.id, effects))
            })
    }

    // MARK: - Live status

    @ViewBuilder
    private func statusSection(_ layer: LayerNode) -> some View {
        let isEnabled = (layer.effectOverrides
            ?? boundSource(for: layer)?.effectDefaults
            ?? .identity).background.isEnabled
        if isEnabled, let key = captureKey(for: layer),
           let status = center.statuses[key] {
            Section("Segmentation Status") {
                if let reason = status.unavailableReason {
                    Label("Segmentation unavailable — \(reason) Showing the unmodified camera.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if status.isFallbackPassthrough {
                    Text("Segmentation paused to protect the frame rate — showing the unmodified camera. It resumes automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    LabeledContent("Effective quality",
                                   value: status.effectiveQuality.displayName)
                    LabeledContent("Segmentation cost",
                                   value: String(format: "%.1f ms", status.lastCostMs))
                    if !status.isSegmenting {
                        Text("Waiting for the first person mask — showing the unmodified camera.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Shared controls

    /// The mode/strength/quality controls bound to one scope's
    /// `BackgroundEffectSettings`. Quality rows come from the capability
    /// matrix: the recommendation is marked, over-budget levels carry their
    /// cost note in the label instead of being hidden.
    @ViewBuilder
    private func backgroundControls(_ settings: Binding<BackgroundEffectSettings>) -> some View {
        Picker("Background Effect", selection: settings.mode) {
            ForEach(BackgroundEffectMode.allCases, id: \.self) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        if settings.wrappedValue.isEnabled {
            switch settings.wrappedValue.mode {
            case .blur:
                Slider(value: settings.strength, in: 0...1) { Text("Blur Strength") }
            case .replacement:
                ColorPicker("Backdrop", selection: colorBinding(settings), supportsOpacity: false)
                Slider(value: settings.strength, in: 0...1) { Text("Edge Feather") }
            case .off:
                EmptyView()
            }
            Picker("Segmentation Quality", selection: settings.quality) {
                ForEach(center.capability.rows, id: \.quality) { row in
                    Text(qualityLabel(row)).tag(row.quality)
                }
            }
            Text("Person segmentation runs off the render tick; if it can't keep up, the quality steps down automatically and the camera passes through unmodified rather than dropping output frames.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func qualityLabel(_ row: SegmentationCapabilityMatrix.Row) -> String {
        var label = "\(row.quality.displayName) (~\(Int(row.estimatedCostMs.rounded())) ms)"
        if row.quality == center.capability.recommendedQuality {
            label += " — Recommended"
        }
        return label
    }

    /// The backdrop color, bridged between SwiftUI `Color` and the settings'
    /// hex string (the transition dip-color pattern).
    private func colorBinding(_ settings: Binding<BackgroundEffectSettings>) -> Binding<Color> {
        Binding(
            get: {
                let components = HexColor.components(settings.wrappedValue.replacementColorHex)
                return Color(NSColor(calibratedRed: components.red,
                                     green: components.green,
                                     blue: components.blue,
                                     alpha: 1))
            },
            set: { color in
                let nsColor = NSColor(color).usingColorSpace(.deviceRGB) ?? .black
                settings.wrappedValue.replacementColorHex =
                    HexColor.string(red: Double(nsColor.redComponent),
                                    green: Double(nsColor.greenComponent),
                                    blue: Double(nsColor.blueComponent))
            })
    }
}
