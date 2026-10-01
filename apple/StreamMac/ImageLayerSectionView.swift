import AppKit
import SwiftUI
import StreamCore
import UniformTypeIdentifiers

/// G01 (issue #81): the image/logo layer controls — add an image layer from
/// a picked or Finder-dropped file (PNG/JPEG/HEIF/TIFF/PDF, validated at
/// import through `ImageAssetValidator`), and edit the selected image layer:
/// replace its file (same layer, same transform — the "swap this logo"
/// action), fit/fill content mode, and the library availability state.
///
/// Every edit routes through the W05 dispatcher: a replace is a complete
/// `ImageSourcePayload` write through `.setLayerImage` (staged scene content
/// — stages, Takes, reverts, and undoes like any layer edit, coalesced per
/// layer); an add appends a layer through `.updateScene` (the LayerPanelView
/// source-bound-layer precedent, which gives the view the layer ID for P03
/// usage tracking).
///
/// The P03 asset library is OPTIONAL here: when the orchestrator has wired
/// the shared `AssetLibraryStore` (`.environment(\.assetLibraryStore, …)`),
/// imports register as project copies with namespaced usage tracking and the
/// availability badge is live; until then the payload's own security-scoped
/// bookmark keeps the layer fully recoverable and rendering.
struct ImageLayerSectionView: View {
    @EnvironmentObject private var dispatcher: StudioCommandDispatcher
    @EnvironmentObject private var sceneStore: SceneStore
    @EnvironmentObject private var previewProgram: PreviewProgramModel
    /// The orchestrator-injected shared asset library (nil pre-wiring).
    @Environment(\.assetLibraryStore) private var assetLibrary
    @ObservedObject var coordinator: ImageLayerCoordinator

    /// What an in-flight file pick is for.
    private enum PickTarget {
        case add
        case replace(LayerID)
    }

    @State private var pickTarget: PickTarget?
    @State private var importError: String?
    @State private var isDropTargeted = false

    /// The single selected layer of the staged scene, when it is an image
    /// layer (the only layers these controls edit).
    private var selectedImageLayer: (layer: LayerNode, payload: ImageSourcePayload)? {
        guard let scene = previewProgram.stagedScene,
              sceneStore.selectedLayerIDs.count == 1,
              let id = sceneStore.selectedLayerIDs.first,
              let layer = scene.layers.first(where: { $0.id == id }),
              case .image(let payload) = layer.payload
        else { return nil }
        return (layer, payload)
    }

    var body: some View {
        Group {
            Section("Image Layers") {
                Button("Add Image Layer…") { pickTarget = .add }
                Text("PNG, JPEG, HEIF, TIFF, or PDF — or drop an image file onto the preview canvas. Alpha is preserved, so transparent logos composite cleanly.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let (layer, payload) = selectedImageLayer {
                editorSection(layer: layer, payload: payload)
            }
        }
        // The attached file sheet (add or replace — same import pipeline).
        .fileImporter(isPresented: pickPresented,
                      allowedContentTypes: ImageAssetClassifier.allowedContentTypes) { result in
            guard let target = pickTarget else { return }
            pickTarget = nil
            guard case .success(let url) = result else { return }
            importFile(at: url, for: target)
        }
        .alert("Image Import", isPresented: errorPresented, presenting: importError) { _ in
            Button("OK") { importError = nil }
        } message: { message in
            Text(message)
        }
        .onAppear { attachLibrary() }
        .onChange(of: assetLibrary.map(ObjectIdentifier.init)) { _, _ in attachLibrary() }
    }

    // MARK: - Selected layer editor

    @ViewBuilder
    private func editorSection(layer: LayerNode, payload: ImageSourcePayload) -> some View {
        Section("Image — \(layer.name)") {
            HStack(spacing: 6) {
                Image(systemName: payload.contentMode == .fill ? "rectangle.fill" : "photo")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(payload.fileName ?? "No image linked")
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let width = payload.pixelWidth, let height = payload.pixelHeight {
                        Text("\(width)×\(height)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                availabilityBadge(for: payload)
            }
            Picker("Content Mode", selection: contentModeBinding(for: layer)) {
                ForEach(ImageContentMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            Button("Replace Image…") { pickTarget = .replace(layer.id) }
            if let availability = coordinator.availability(of: payload),
               case .missing(let reason) = availability {
                Label("Missing: \(reason.displayName) — repair it in the Asset Library panel.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        // Finder drag/drop replace: dropping an image file on this section
        // swaps the layer's asset (the same import pipeline as the sheet).
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers, for: .replace(layer.id))
        }
        // A reopened document may reference a library asset that hasn't been
        // decoded this session — publish it so the layer paints.
        .onAppear { coordinator.ensurePublished(payload) }
    }

    @ViewBuilder
    private func availabilityBadge(for payload: ImageSourcePayload) -> some View {
        if let availability = coordinator.availability(of: payload) {
            switch availability {
            case .unknown:
                ProgressView().controlSize(.small)
            case .available:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .help("Available in the asset library")
            case .missing(let reason):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("Missing: \(reason.displayName)")
            }
        }
    }

    // MARK: - Import pipeline

    /// Imports a picked/dropped file for an add or a replace: validation and
    /// library registration run in the coordinator; failures surface inline
    /// (the explicit format-validation gate — an unsupported file never
    /// reaches a scene).
    private func importFile(at url: URL, for target: PickTarget) {
        Task {
            switch await coordinator.importImage(at: url) {
            case .failure(let error):
                importError = error.message
            case .success(let payload):
                switch target {
                case .add:
                    addImageLayer(payload: payload, name: url.deletingPathExtension().lastPathComponent)
                case .replace(let layerID):
                    replaceImage(on: layerID, with: payload)
                }
            }
        }
    }

    /// The Finder-drop entry point (also used by the canvas drop in
    /// MainWindowView through the coordinator). Only supported image types
    /// accept the drop, so the cursor honestly refuses other files.
    @discardableResult
    private func handleDrop(_ providers: [NSItemProvider], for target: PickTarget) -> Bool {
        let supported = providers.filter { provider in
            provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard let provider = supported.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url, ImageAssetValidator.isSupportedExtension(url.pathExtension) else {
                return
            }
            Task { @MainActor in
                importFile(at: url, for: target)
            }
        }
        return true
    }

    /// Adds a logo-style layer (bottom-right bug; the renderer aspect-fits)
    /// at the front of the staged scene — the LayerPanelView source-bound
    /// precedent, which keeps the new layer's ID here for usage tracking.
    private func addImageLayer(payload: ImageSourcePayload, name: String) {
        guard var scene = previewProgram.stagedScene else { return }
        let layer = LayerNode(name: name, payload: .image(payload),
                              transform: LayerTransform(
                                position: GraphPoint(x: 0.98, y: 0.98),
                                size: GraphSize(width: 0.2, height: 0.2),
                                anchor: .bottomRight))
        scene.layers.append(layer)
        dispatcher.execute(.updateScene(scene))
        coordinator.noteUsage(of: payload, from: layer.id)
    }

    /// Replaces the selected layer's image (same layer/transform — undoable
    /// staged scene content through `.setLayerImage`), moving the P03 usage
    /// edge from the old asset to the new one.
    private func replaceImage(on layerID: LayerID, with payload: ImageSourcePayload) {
        guard let scene = previewProgram.stagedScene,
              let layer = scene.layers.first(where: { $0.id == layerID }),
              case .image(let oldPayload) = layer.payload else { return }
        dispatcher.execute(.setLayerImage(layerID, payload, in: nil))
        coordinator.removeUsage(of: oldPayload, from: layerID)
        coordinator.noteUsage(of: payload, from: layerID)
        coordinator.ensurePublished(payload)
    }

    private func contentModeBinding(for layer: LayerNode) -> Binding<ImageContentMode> {
        Binding(
            get: {
                if case .image(let payload) = layer.payload { return payload.contentMode }
                return .fit
            },
            set: { mode in
                guard case .image(var payload) = layer.payload else { return }
                payload.contentMode = mode
                dispatcher.execute(.setLayerImage(layer.id, payload, in: nil))
            })
    }

    private func attachLibrary() {
        guard let assetLibrary else { return }
        coordinator.attach(assetLibrary: assetLibrary)
    }

    // MARK: - Presentation bindings

    private var pickPresented: Binding<Bool> {
        Binding(get: { pickTarget != nil },
                set: { if !$0 { pickTarget = nil } })
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { importError != nil },
                set: { if !$0 { importError = nil } })
    }
}
