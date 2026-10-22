import SwiftUI

struct LayerGeometrySectionView: View {
    @EnvironmentObject private var workspace: StudioWorkspace
    let sceneID: SceneID
    let layer: LayerNode

    private struct Identity: Hashable {
        let runtime: ObjectIdentifier
        let scene: SceneID
        let layer: LayerID
    }

    var body: some View {
        let runtime = workspace.runtime
        LayerGeometryFields(workspace: workspace, runtime: runtime, sceneID: sceneID, layer: layer)
            .id(Identity(runtime: ObjectIdentifier(runtime), scene: sceneID, layer: layer.id))
    }
}

private struct LayerGeometryFields: View {
    @StateObject private var presentation: LayerGeometryPresentation
    init(workspace: StudioWorkspace, runtime: StudioRuntime, sceneID: SceneID, layer: LayerNode) {
        _presentation = StateObject(wrappedValue: LayerGeometryPresentation(workspace: workspace, runtime: runtime,
                                                                           sceneID: sceneID, layer: layer))
    }

    var body: some View {
        // Closures retain this exact draft. A callback from an old rendering of
        // the controls must not acquire the replacement editor's authority.
        let editor = presentation.editor
        Section("Layer Geometry — \(editor.layerName)") {
            ForEach(LayerGeometryDraft.Field.allCases, id: \.self) { field in
                VStack(alignment: .leading, spacing: 4) {
                    Text(field.label).studioTextStyle(.caption)
                    TextField(field.label, text: Binding(get: { editor.draft.values[field] ?? "" },
                        set: { editor.draft.values[field] = $0 }))
                        .labelsHidden()
                        .accessibilityLabel("\(editor.layerName), \(field.label)")
                        .textFieldStyle(.roundedBorder)
                        .disabled(editor.isRetired || (field == .height && editor.usesCameraPIP))
                }
            }
            Text("Position uses the \(anchorName(editor.anchor)) anchor. Percentages describe the stored box relative to the Program canvas; media retains its source framing and aspect fit. Rotation uses degrees. Type a decimal point for fractions. Only edited fields apply, and changes stay in this draft until Apply.")
                .studioTextStyle(.caption)
                .foregroundStyle(.studioSecondary)
            if editor.isCamera {
                Text("Camera PIP below 100% width uses the existing 10–40% width range, derives height from the source aspect ratio, and adds a 24-pixel inset at edge anchors. Set width to at least 100% for ordinary box geometry.")
                    .studioTextStyle(.caption).foregroundStyle(.studioSecondary)
            }
            Button("Apply Layer Geometry") { editor.apply() }
                .disabled(!editor.draft.isDirty || editor.unavailableReason != nil)
            Button("Reload Current Geometry") { editor.reload() }
                .disabled(editor.isRetired)
            if editor.isRetired {
                Text("This draft has retired. Start a new draft to replace its edits with the current layer values and canvas profile.")
                    .studioTextStyle(.caption).foregroundStyle(.studioSecondary)
                Button("Start New Geometry Draft") { presentation.startNewDraft(replacing: editor) }
                    .disabled(!presentation.canStartNewDraft(replacing: editor))
            }
            if let message = editor.error ?? editor.unavailableReason {
                Text(message).studioTextStyle(.caption).foregroundStyle(.primary)
            }
        }
        .studioTextStyle(.body)
    }

    private func anchorName(_ anchor: LayerAnchor) -> String {
        switch anchor {
        case .topLeft: "top-left"
        case .topRight: "top-right"
        case .bottomLeft: "bottom-left"
        case .bottomRight: "bottom-right"
        case .center: "center"
        }
    }
}
