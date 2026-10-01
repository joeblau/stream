import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The S07 overlays & backgrounds panel (issue #74): the PROJECT-wide overlay
/// stack and the two background scopes, surfaced as a distinct section above
/// the scene's own layers in the layer panel.
///
/// Scopes and their edit paths (see StudioCommandDispatcher):
/// - PROJECT overlays: one shared list composited above EVERY scene. Edits
///   (add/remove/reorder/rename/visibility/lock) are project-level commands —
///   they apply immediately to both the staged and program compositions and
///   never read as pending staged edits.
/// - PER-SCENE overrides: hiding an overlay in the staged scene and the
///   scene's own background are scene content — they stage and Take/Revert
///   like any scene edit.
/// - PROJECT default background: the fallback behind every scene that has no
///   background of its own; unset = the documented black canvas.
///
/// G09 (issue #116) media overlays: the Add menu's Animated Image / Alpha
/// Video items validate the picked file's format at import (unsupported
/// files are rejected with an explicit error, never reaching program) and
/// register a media source + overlay in one dispatcher command. Media
/// overlay rows carry inline play/pause/replay transport, and the context
/// menu edits the payload's loop/autoplay/end-action policy live.
struct OverlayPanelView: View {
    @EnvironmentObject private var dispatcher: StudioCommandDispatcher
    @EnvironmentObject private var sceneStore: SceneStore
    @EnvironmentObject private var previewProgram: PreviewProgramModel
    @EnvironmentObject private var capturePool: CaptureSourcePool

    @State private var isExpanded = true
    /// Rename alert state: the overlay being renamed plus the field draft.
    @State private var renameTarget: LayerNode?
    @State private var draftName = ""
    /// G09 (issue #116): which media-overlay file picker is showing, if any.
    @State private var mediaPicker: MediaOverlayPickerKind?
    /// G09: import-time format rejection (unsupported animated image /
    /// non-alpha codec) — the error surfaces HERE, before the asset is
    /// registered, so it can never reach program.
    @State private var formatError: String?

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                backgroundRow(
                    title: "Scene Background",
                    background: previewProgram.stagedScene?.background,
                    inheritsProjectDefault: true,
                    apply: { dispatcher.execute(.setSceneBackground($0, in: nil)) })
                backgroundRow(
                    title: "Project Default Background",
                    background: sceneStore.defaultBackground,
                    inheritsProjectDefault: false,
                    apply: { dispatcher.execute(.setDefaultBackground($0)) })
                if !sceneStore.overlays.isEmpty {
                    Divider()
                    ForEach(sceneStore.overlays.reversed()) { overlay in
                        overlayRow(overlay)
                    }
                }
                addOverlayMenu
            }
            .padding(.vertical, 6)
        } label: {
            Label("Overlays & Background", systemImage: "square.3.layers.3d")
                .font(.callout.weight(.semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .alert("Rename Overlay", isPresented: renamePresented) {
            TextField("Name", text: $draftName)
            Button("Rename") { commitRename() }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Unsupported Overlay Format", isPresented: formatErrorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(formatError ?? "")
        }
        // G09: the two media-overlay pickers share one importer presentation.
        .fileImporter(isPresented: mediaPickerPresented,
                      allowedContentTypes: mediaPicker?.allowedContentTypes ?? [.data]) { result in
            guard let kind = mediaPicker, case .success(let url) = result else { return }
            mediaPicker = nil
            importMediaOverlay(kind: kind, url: url)
        }
    }

    /// G09 (issue #116): validates the picked file's format (the explicit
    /// pre-program error) and registers source + overlay in one command.
    private func importMediaOverlay(kind: MediaOverlayPickerKind, url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        switch kind {
        case .animatedImage:
            switch MediaOverlayClassifier.probeAnimatedImage(url: url) {
            case .failure(let error):
                formatError = error.message
            case .success:
                guard let payload = MediaSourceFactory.payload(forPickedFile: url) else { return }
                dispatcher.execute(.addMediaOverlay(
                    name: url.deletingPathExtension().lastPathComponent,
                    payload: payload))
            }
        case .alphaVideo:
            // The codec probe is async (AVAsset track load) — the bookmark
            // (the durable access grant) is created synchronously while the
            // picker's access is held; the probe re-acquires its own.
            guard let payload = MediaSourceFactory.payload(forPickedFile: url) else { return }
            let name = url.deletingPathExtension().lastPathComponent
            Task {
                let probeAccess = url.startAccessingSecurityScopedResource()
                defer { if probeAccess { url.stopAccessingSecurityScopedResource() } }
                switch await MediaOverlayClassifier.probeAlphaVideo(url: url) {
                case .failure(let error):
                    formatError = error.message
                case .success:
                    dispatcher.execute(.addMediaOverlay(name: name, payload: payload))
                }
            }
        }
    }

    // MARK: - Backgrounds

    /// One background scope row: a mode menu plus color picker(s) when the
    /// current value is a solid/gradient. `inheritsProjectDefault` adds the
    /// "Project Default" choice (nil) that only the per-scene scope has —
    /// the project default's own unset state IS the documented black
    /// fallback. Every change is one dispatcher command routed by `apply`.
    @ViewBuilder
    private func backgroundRow(title: String,
                               background: SceneBackground?,
                               inheritsProjectDefault: Bool,
                               apply: @escaping (SceneBackground?) -> Void) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            if case .solid(let colorHex) = background {
                colorPicker(colorHex, help: "Background color") { hex in
                    apply(.solid(colorHex: hex))
                }
                .frame(width: 44)
            }
            if case .gradient(let topColorHex, let bottomColorHex) = background {
                colorPicker(topColorHex, help: "Top color") { hex in
                    apply(.gradient(topColorHex: hex, bottomColorHex: bottomColorHex))
                }
                .frame(width: 28)
                colorPicker(bottomColorHex, help: "Bottom color") { hex in
                    apply(.gradient(topColorHex: topColorHex, bottomColorHex: hex))
                }
                .frame(width: 28)
            }
            Menu {
                if inheritsProjectDefault {
                    Button("Project Default") { apply(nil) }
                }
                Button("Black") { apply(.solid(colorHex: "#000000")) }
                Button("Solid Color") {
                    guard case .solid = background else {
                        apply(.solid(colorHex: "#1E1E1E"))
                        return
                    }
                }
                Button("Gradient") {
                    guard case .gradient = background else {
                        apply(.gradient(topColorHex: "#1E1E1E", bottomColorHex: "#000000"))
                        return
                    }
                }
            } label: {
                Text(menuLabel(background, inheritsProjectDefault: inheritsProjectDefault))
                    .font(.callout)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private func menuLabel(_ background: SceneBackground?,
                           inheritsProjectDefault: Bool) -> String {
        switch background {
        case .none:
            return inheritsProjectDefault ? "Project Default" : "Black"
        case .solid(let colorHex):
            return colorHex == "#000000" ? "Black" : "Solid Color"
        case .gradient:
            return "Gradient"
        case .image:
            return "Image"
        }
    }

    private func colorPicker(_ hex: String,
                             help: String,
                             onChange: @escaping (String) -> Void) -> some View {
        ColorPicker("", selection: Binding(
            get: { Self.color(from: hex) },
            set: { onChange(Self.hexString(from: $0)) }))
            .labelsHidden()
            .help(help)
    }

    // MARK: - Overlay rows

    private func overlayRow(_ overlay: LayerNode) -> some View {
        let hiddenHere = previewProgram.stagedScene?.hiddenOverlayIDs.contains(overlay.id) ?? false
        return HStack(spacing: 6) {
            Image(systemName: overlay.payload.systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(overlay.name)
                .lineLimit(1)
                .foregroundStyle(overlay.isVisible && !hiddenHere ? .primary : .secondary)
            if hiddenHere {
                Text("hidden here")
                    .font(.caption2)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                    .foregroundStyle(.secondary)
                    .help("This overlay is hidden in the staged scene (a per-scene override that stages and Takes like any scene edit).")
            }
            Spacer()
            // G09 (issue #116): media overlays (animated image / alpha
            // video) carry inline transport on the ONE shared playback
            // instance — replay/pause here can never fork preview vs
            // program playback.
            if let sourceID = overlay.sourceID, overlay.payload.isMedia {
                mediaTransportButtons(sourceID: sourceID)
            }
            Button {
                dispatcher.execute(.setOverlayLocked(overlay.id, locked: !overlay.isLocked))
            } label: {
                Image(systemName: overlay.isLocked ? "lock.fill" : "lock.open")
                    .foregroundStyle(overlay.isLocked ? Color.orange : Color.clear)
            }
            .buttonStyle(.borderless)
            .help(overlay.isLocked ? "Unlock \(overlay.name)" : "Lock \(overlay.name)")
            Button {
                dispatcher.execute(.setOverlayVisibility(overlay.id, visible: !overlay.isVisible))
            } label: {
                Image(systemName: overlay.isVisible ? "eye" : "eye.slash")
                    .foregroundStyle(overlay.isVisible ? .secondary : .tertiary)
            }
            .buttonStyle(.borderless)
            .help(overlay.isVisible ? "Hide in every scene" : "Show in every scene")
        }
        .contextMenu { overlayContextMenu(overlay, hiddenHere: hiddenHere) }
    }

    @ViewBuilder
    private func overlayContextMenu(_ overlay: LayerNode, hiddenHere: Bool) -> some View {
        Button("Rename…") {
            draftName = overlay.name
            renameTarget = overlay
        }
        // G09: media overlay playback policy (loop / autoplay / stop-on-
        // last-frame vs clear) lives on the registry source payload — edits
        // write through the registry, so the running playback engine picks
        // them up live at the next pass without restarting.
        if let sourceID = overlay.sourceID,
           let source = sceneStore.source(withID: sourceID),
           case .media(let payload) = source.payload {
            Divider()
            Button(payload.loops ? "Disable Loop" : "Enable Loop") {
                updateMediaPolicy(sourceID) { $0.loops.toggle() }
            }
            Button(payload.autoplay ? "Disable Autoplay" : "Enable Autoplay") {
                updateMediaPolicy(sourceID) { $0.autoplay.toggle() }
            }
            Menu("When Playback Ends") {
                ForEach(MediaEndAction.allCases, id: \.self) { action in
                    Button(action.displayName) {
                        updateMediaPolicy(sourceID) { $0.endAction = action }
                    }
                }
            }
            .help("Hold Last Frame keeps the final frame painting; Stop rewinds and clears (paint-nothing fallback).")
        }
        Divider()
        Button("Move Forward") {
            guard let index = sceneStore.overlays.firstIndex(where: { $0.id == overlay.id }) else { return }
            dispatcher.execute(.moveOverlay(overlay.id, toIndex: index + 1))
        }
        .disabled(sceneStore.overlays.last?.id == overlay.id)
        Button("Move Backward") {
            guard let index = sceneStore.overlays.firstIndex(where: { $0.id == overlay.id }) else { return }
            dispatcher.execute(.moveOverlay(overlay.id, toIndex: index - 1))
        }
        .disabled(sceneStore.overlays.first?.id == overlay.id)
        Divider()
        Button(hiddenHere ? "Show in This Scene" : "Hide in This Scene") {
            dispatcher.execute(.setOverlayHiddenInScene(overlay.id, hidden: !hiddenHere, in: nil))
        }
        .disabled(previewProgram.stagedScene == nil)
        Button(overlay.isLocked ? "Unlock" : "Lock") {
            dispatcher.execute(.setOverlayLocked(overlay.id, locked: !overlay.isLocked))
        }
        Divider()
        Button("Delete Overlay", role: .destructive) {
            dispatcher.execute(.removeOverlay(overlay.id))
        }
    }

    // MARK: - Add overlay

    private var addOverlayMenu: some View {
        Menu {
            Button("Text") {
                dispatcher.execute(.addOverlay(.text(TextSourcePayload(text: "LIVE"))))
            }
            Button("Shape") {
                dispatcher.execute(.addOverlay(.shape(ShapeSourcePayload())))
            }
            Divider()
            // G09 (issue #116): animated images and alpha video ride the A02
            // media playout engine, composited above every scene.
            Button("Animated Image…") {
                mediaPicker = .animatedImage
            }
            Button("Alpha Video…") {
                mediaPicker = .alphaVideo
            }
        } label: {
            Label("Add Overlay", systemImage: "plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Add a project overlay — composited above every scene")
    }

    // MARK: - Rename alert

    private var renamePresented: Binding<Bool> {
        Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } })
    }

    private func commitRename() {
        guard let renameTarget else { return }
        dispatcher.execute(.renameOverlay(renameTarget.id, to: draftName))
    }

    // MARK: - Media overlay pickers (G09)

    private var mediaPickerPresented: Binding<Bool> {
        Binding(
            get: { mediaPicker != nil },
            set: { if !$0 { mediaPicker = nil } })
    }

    private var formatErrorPresented: Binding<Bool> {
        Binding(
            get: { formatError != nil },
            set: { if !$0 { formatError = nil } })
    }

    // MARK: - Media overlay transport and policy (G09)

    /// Play/pause and replay for a media overlay's shared playback instance
    /// (session state — the same W05 media transport the Media Playout
    /// section uses).
    @ViewBuilder
    private func mediaTransportButtons(sourceID: SourceDefinitionID) -> some View {
        let status = capturePool.mediaStatus(for: sourceID)
        let isPlaying = status.phase == .playing
        Button {
            dispatcher.execute(isPlaying ? .mediaPause(sourceID) : .mediaPlay(sourceID))
        } label: {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .foregroundStyle(status.phase == .error ? .orange : .secondary)
        }
        .buttonStyle(.borderless)
        .help(status.phase == .error
              ? (status.errorMessage ?? "Playback error")
              : (isPlaying ? "Pause" : "Play"))
        Button {
            dispatcher.execute(.mediaRestart(sourceID))
        } label: {
            Image(systemName: "backward.end.fill")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help("Replay from the beginning")
    }

    /// Durable playback-policy edits write through the S05 registry update
    /// path (the MediaSourcesSectionView pattern): the media key is the
    /// source ID, so the playback engine keeps running and picks the new
    /// policy up live.
    private func updateMediaPolicy(_ sourceID: SourceDefinitionID,
                                   _ edit: (inout MediaSourcePayload) -> Void) {
        guard let source = sceneStore.source(withID: sourceID),
              case .media(var payload) = source.payload else { return }
        edit(&payload)
        var updated = source
        updated.payload = .media(payload)
        sceneStore.updateSource(updated)
    }

    // MARK: - Color conversion

    private static func color(from hex: String) -> Color {
        let components = HexColor.components(hex)
        return Color(red: components.red, green: components.green, blue: components.blue)
    }

    private static func hexString(from color: Color) -> String {
        let nsColor = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        return HexColor.string(red: Double(nsColor.redComponent),
                               green: Double(nsColor.greenComponent),
                               blue: Double(nsColor.blueComponent))
    }
}

/// G09 (issue #116): which media-overlay file picker is open — the two
/// kinds differ in accepted content types and in which import-time format
/// gate the picked file must pass (`MediaOverlayClassifier`).
private enum MediaOverlayPickerKind {
    case animatedImage
    case alphaVideo

    var allowedContentTypes: [UTType] {
        switch self {
        case .animatedImage:
            return [.gif, .png, .heic, .heif, .webP]
        case .alphaVideo:
            return [.movie, .quickTimeMovie, .mpeg4Movie]
        }
    }
}
