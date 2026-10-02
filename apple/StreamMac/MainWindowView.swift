import AppKit
import SwiftUI
import StreamCore
import UniformTypeIdentifiers

/// The persistent studio shell (W01): one window holding every production
/// control in dedicated, collapsible panels —
///
///     ┌──────────┬───────────────────────────┬──────────┬────────────┬───────────┐
///     │  Scenes  │  PREVIEW + PROGRAM (W03)  │   Chat   │ Inspector  │ Settings  │
///     │  browser │  Take / Revert / Direct   │  column  │  column    │ (W04, ⌘,) │
///     │  (S02)   │  Live controls            │          │            │           │
///     │          │  Live controls            │          │            │           │
///     │          │  ──────────────────────── │          │            │           │
///     │          │  Diagnostics strip        │          │            │           │
///     │          │  Transport bar            │          │            │           │
///     └──────────┴───────────────────────────┴──────────┴────────────┴───────────┘
///
/// The columns are `HSplitView` panes, so they resize by dragging and
/// collapse/restore from the toolbar toggles; pane visibility persists in
/// `UserDefaults` (`@AppStorage`). Settings (W04, issue #67) is an embedded
/// fifth pane — no longer a sheet — editing the shared `SettingsSession`
/// draft: ⌘, (menu) or the toolbar toggle opens it, Escape/close dismisses it
/// and returns keyboard focus to the previously focused panel, and edits only
/// reach the store/pipeline via its explicit Apply. W03 (issue #66) splits the
/// canvas into two always-labeled monitors — PREVIEW stages the selected scene
/// and every edit, PROGRAM shows the outgoing composition — with Take (⏎),
/// Revert, a pending-edits indication, and the explicit direct-live toggle.
/// W02 session states surface in the diagnostics strip (StatsHUD + recording
/// status) and the transport bar (acknowledged-connection LIVE badge,
/// per-state Go Live button); window close while an output is active is
/// confirmed in-window via `WindowCloseGuard`.
struct MainWindowView: View {
    @EnvironmentObject private var workspace: StudioWorkspace
    @EnvironmentObject private var sceneStore: SceneStore
    @EnvironmentObject private var controller: StreamController
    @EnvironmentObject private var session: SettingsSession
    @EnvironmentObject private var permissions: PermissionsManager
    /// The app's recording output (owned by the app shell since W05).
    @EnvironmentObject private var recorder: RecordingController
    /// The W05 command layer: every studio action below routes through this
    /// dispatcher instead of calling the controllers/stores directly.
    @EnvironmentObject private var dispatcher: StudioCommandDispatcher
    /// The W03 preview/program model: the inspector edits its staged scene.
    @EnvironmentObject private var previewProgram: PreviewProgramModel
    /// G01 (issue #81): the image-layer coordinator — imports, P03 library
    /// registration/usage, and decode publishing. Owned here so the inspector
    /// section and the canvas drop share one instance.
    @StateObject private var imageLayers = ImageLayerCoordinator()
    @StateObject private var shortcuts = StudioShortcutController()
    @Environment(\.studioReduceMotion) private var reduceMotion
    @State private var panelBeforeCommands: StudioPanel?
    @State private var panelBeforeSheet: StudioPanel?
    /// The orchestrator-injected shared P03 asset library (nil pre-wiring).
    @Environment(\.assetLibraryStore) private var assetLibrary
    /// Shared Restream chat connection: the sidebar shows it and the settings
    /// pane edits its credentials (W04 — one instance, one sign-in).
    @State private var chat = RestreamChat()

    /// W06 first-run gating (persisted by the app): while false, the studio
    /// window presents the setup-guide sheet.
    @Binding private var firstRunCompleted: Bool
    /// W06 just-in-time permission explainer: the kind whose source was just
    /// used without the permission granted, if any.
    @State private var permissionPrompt: PermissionsManager.Kind?

    init(firstRunCompleted: Binding<Bool>) {
        _firstRunCompleted = firstRunCompleted
    }

    // Panel visibility, persisted so the layout restores across launches.
    @AppStorage("studio.showScenesPanel") private var showScenesPanel = true
    @AppStorage("studio.showChatPanel") private var showChatPanel = true
    @AppStorage("studio.showInspectorPanel") private var showInspectorPanel = true
    @AppStorage("studio.showDiagnostics") private var showDiagnostics = true
    @AppStorage("studio.showSettingsPanel") private var showSettingsPanel = false

    @State private var inspectorTab: InspectorTab = .layers
    @State private var showStudioHelp = false

    /// Keyboard-focus tracking per panel, so dismissing settings returns
    /// focus to wherever it was (W04 acceptance).
    private enum StudioPanel: Hashable {
        case scenes, canvas, chat, inspector, settings
    }
    @FocusState private var focusedPanel: StudioPanel?
    @State private var panelBeforeSettings: StudioPanel?

    private enum InspectorTab: String, CaseIterable {
        case layers = "Layers"
        case sources = "Sources"
        case mixer = "Mixer"
        // A03 (issue #98): the sound panel (soundboard, music, scene sounds).
        case media = "Sound"
        // P03 (issue #80): the asset library — every referenced file, its
        // availability, and missing-asset repair.
        case assets = "Assets"
        case guests = "Guests"
        case destinations = "Destinations"
    }

    var body: some View {
        VStack(spacing: 0) {
            if workspace.showProjects { ProjectBrowserView() }
            studioPanels
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { workspace.showProjects.toggle() } label: {
                    Label(workspace.currentProject.name + " · " + workspace.currentProfile.name, systemImage: "folder")
                }.help("Open shows and production profiles")
            }
            ToolbarItem(placement: .automatic) {
                Button { showStudioHelp.toggle() } label: { Label("Studio Help", systemImage: "questionmark.circle") }
                    .popover(isPresented: $showStudioHelp) { StudioHelpView() }
            }
        }
    }

    private var studioPanels: some View {
        HSplitView {
            if showScenesPanel {
                SceneBrowserView()
                    .frame(minWidth: 180, idealWidth: 220, maxWidth: 320)
                    .focusable()
                    .focused($focusedPanel, equals: .scenes)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Scenes panel")
                    .accessibilitySortPriority(5)
            }
            canvasPanel
                .frame(minWidth: 320)
                .layoutPriority(1)
                .focusable()
                .focused($focusedPanel, equals: .canvas)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Preview and program panel")
                .accessibilitySortPriority(4)
            if showChatPanel {
                ChatSidebarView(chat: chat)
                    .frame(maxWidth: 420)
                    .focusable()
                    .focused($focusedPanel, equals: .chat)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Chat panel")
                    .accessibilitySortPriority(3)
            }
            if showInspectorPanel {
                inspectorPanel
                    .frame(minWidth: 240, idealWidth: 300, maxWidth: 420)
                    .focusable()
                    .focused($focusedPanel, equals: .inspector)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Inspector panel")
                    .accessibilitySortPriority(2)
            }
            if session.isPresented {
                settingsPane
                    .frame(minWidth: 300, idealWidth: 360, maxWidth: 480)
                    .focusable()
                    .focused($focusedPanel, equals: .settings)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Settings panel")
                    .accessibilitySortPriority(1)
            }
        }
        .background(StudioShortcutWindowAttachment(shortcuts: shortcuts))
        .sheet(isPresented: $shortcuts.palettePresented, onDismiss: paletteDidDismiss) {
            StudioCommandPalette(shortcuts: shortcuts, actions: commandActions)
        }
        .sheet(isPresented: $shortcuts.editorPresented, onDismiss: restoreCommandFocus) {
            StudioShortcutEditor(shortcuts: shortcuts, actions: commandActions)
        }
        .onChange(of: shortcuts.palettePresented) { _, presented in
            if presented { panelBeforeCommands = focusedPanel; shortcuts.rememberCommandFocus() }
        }
        .onChange(of: shortcuts.editorPresented) { _, presented in
            if presented && panelBeforeCommands == nil { panelBeforeCommands = focusedPanel; shortcuts.rememberCommandFocus() }
        }
        .background {
            // W02 session policy: closing the window while streaming/recording
            // asks in-window instead of silently tearing the outputs down.
            WindowCloseGuard(
                hasActiveOutputs: {
                    dispatcher.state.stream.isActive || dispatcher.state.recording.isActive
                },
                stopAllOutputs: {
                    dispatcher.execute(.stopStream)
                    dispatcher.execute(.stopRecording)
                },
                stopPreview: { dispatcher.execute(.stopPreview) })
        }
        .toolbar { panelToggles }
        .onAppear {
            shortcuts.actions = { commandActions }
            shortcuts.onExecute = { action in
                if let command = action.command { dispatcher.execute(command) }
            }
            shortcuts.seedScenes(sceneStore.scenes.map { "scene.\($0.id.rawValue.uuidString).select" })
            dispatcher.execute(.startPreview)
            // Restore a settings pane left open last launch.
            session.isPresented = showSettingsPanel
            permissions.refresh()
            // G01: attach the shared P03 asset library when the orchestrator
            // has injected it (idempotent; nil pre-wiring).
            if let assetLibrary { imageLayers.attach(assetLibrary: assetLibrary) }
        }
        .onDisappear {
            shortcuts.uninstall()
            shortcuts.actions = { [] }; shortcuts.onExecute = { _ in }
        }
        .alert("Keyboard Command", isPresented: Binding(
            get: { shortcuts.message != nil && !shortcuts.editorPresented },
            set: { if !$0 { shortcuts.message = nil } })) {
            Button("OK") { shortcuts.message = nil }
        } message: { Text(shortcuts.message ?? "") }
        .onChange(of: assetLibrary.map(ObjectIdentifier.init)) { _, _ in
            if let assetLibrary { imageLayers.attach(assetLibrary: assetLibrary) }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            // Permissions may have changed in System Settings (W06).
            permissions.refresh()
        }
        // W06 first-run setup guide: shown only until completed/skipped.
        .sheet(isPresented: Binding(
            get: { !firstRunCompleted },
            set: { if !$0 { firstRunCompleted = true } })) {
            OnboardingView(recorder: recorder) {
                firstRunCompleted = true
            }
            .interactiveDismissDisabled()
        }
        // W06 just-in-time permission explainer: selecting a scene whose
        // source lacks its OS permission explains the purpose and offers the
        // request (or the denied-state repair) instead of a silent black
        // source.
        .sheet(item: $permissionPrompt) { kind in
            JustInTimePermissionSheet(kind: kind) {
                permissionPrompt = nil
            }
        }
        .onChange(of: permissionPrompt) { _, prompt in
            if prompt != nil { panelBeforeSheet = focusedPanel }
            else { focusedPanel = panelBeforeSheet; panelBeforeSheet = nil }
        }
        .onChange(of: firstRunCompleted) { _, complete in
            if complete { focusedPanel = .canvas }
        }
        .onChange(of: showScenesPanel) { _, visible in
            if !visible && focusedPanel == .scenes { focusedPanel = .canvas }
        }
        .onChange(of: showChatPanel) { _, visible in
            if !visible && focusedPanel == .chat { focusedPanel = .canvas }
        }
        .onChange(of: showInspectorPanel) { _, visible in
            if !visible && focusedPanel == .inspector { focusedPanel = .canvas }
        }
        .onChange(of: sceneStore.selected) { _, scene in
            promptForMissingSourcePermission(in: scene)
        }
        .onChange(of: session.isPresented) { _, presented in
            // Persist the layout, and move keyboard focus in/out of the pane.
            showSettingsPanel = presented
            if presented {
                panelBeforeSettings = focusedPanel
                focusedPanel = .settings
            } else {
                focusedPanel = panelBeforeSettings
                panelBeforeSettings = nil
            }
        }
        .alert("Stream",
               isPresented: Binding(
                   get: { controller.errorMessage != nil },
                   set: { if !$0 { controller.errorMessage = nil } }),
               presenting: controller.errorMessage) { _ in
            Button("OK") { controller.errorMessage = nil }
        } message: { message in
            Text(message)
        }
    }

    private var commandActions: [StudioPaletteAction] {
        dispatcher.paletteActions(scenes: sceneStore.scenes, sources: sceneStore.sources,
                                  stagedScene: previewProgram.stagedScene)
    }
    private func paletteDidDismiss() {
        if shortcuts.openEditorAfterPalette {
            shortcuts.openEditorAfterPalette = false
            shortcuts.editorPresented = true
        } else { restoreCommandFocus() }
    }
    private func restoreCommandFocus() {
        guard !shortcuts.palettePresented && !shortcuts.editorPresented else { return }
        focusedPanel = panelBeforeCommands ?? .canvas
        panelBeforeCommands = nil
        shortcuts.restoreCommandFocus()
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var panelToggles: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                shortcuts.palettePresented = true
            } label: { Label("Commands", systemImage: "command") }
            .help("Open the command palette (⇧⌘P)")
            Button("Shortcuts", systemImage: "keyboard") { shortcuts.editorPresented = true }
            Button("Compact Layout", systemImage: "rectangle.compress.vertical") {
                showChatPanel = false; showInspectorPanel = false
                session.isPresented = false; focusedPanel = .canvas
            }
            Menu("Focus", systemImage: "cursorarrow.rays") {
                Button("Scenes") { showScenesPanel = true; focusedPanel = .scenes }
                Button("Canvas") { focusedPanel = .canvas }
                Button("Chat") { showChatPanel = true; focusedPanel = .chat }
                Button("Inspector") { showInspectorPanel = true; focusedPanel = .inspector }
            }
            Toggle(isOn: $showScenesPanel) {
                Label("Scenes", systemImage: "rectangle.on.rectangle")
            }
            .toggleStyle(.button)
            .help("Show or hide the scenes panel")

            Toggle(isOn: $showDiagnostics) {
                Label("Diagnostics", systemImage: "waveform.path.ecg")
            }
            .toggleStyle(.button)
            .help("Show or hide the diagnostics strip")

            Toggle(isOn: $showChatPanel) {
                Label("Chat", systemImage: "bubble.left.and.bubble.right")
            }
            .toggleStyle(.button)
            .help("Show or hide the chat panel")

            Toggle(isOn: $showInspectorPanel) {
                Label("Inspector", systemImage: "sidebar.right")
            }
            .toggleStyle(.button)
            .help("Show or hide the inspector panel")

            Toggle(isOn: Binding(
                get: { session.isPresented },
                set: { dispatcher.execute($0 ? .openSettings(nil) : .closeSettings) }
            )) {
                Label("Settings", systemImage: "gear")
            }
            .toggleStyle(.button)
            .help("Show or hide the settings panel (⌘,)")
        }
    }

    // MARK: - Settings pane (W04)

    private var settingsPane: some View {
        SettingsView(session: session,
                     chat: chat,
                     onClose: { dispatcher.execute(.closeSettings) },
                     onResetLayout: resetPanelLayout)
    }

    /// Application section action: back to the all-panels-visible layout.
    private func resetPanelLayout() {
        showScenesPanel = true
        showChatPanel = true
        showInspectorPanel = true
        showDiagnostics = true
    }

    /// W06 just-in-time gating: when the selected scene starts using a source
    /// whose OS permission is missing, surface the explainer sheet (purpose
    /// copy + request/repair). Never during first run — the onboarding flow
    /// owns those prompts — and one prompt at a time.
    private func promptForMissingSourcePermission(in scene: Scene?) {
        guard firstRunCompleted, permissionPrompt == nil, let scene else { return }
        let layout = scene.layout
        if layout.usesCamera, permissions.status(for: .camera) != .granted {
            permissionPrompt = .camera
        } else if layout.usesScreen, permissions.status(for: .screenCapture) != .granted {
            permissionPrompt = .screenCapture
        }
    }

    // MARK: - Scenes panel
    //
    // The scenes column is the S02 scene browser (SceneBrowserView.swift,
    // issue #70): thumbnails, folders, drag-to-reorder, locks, search, and
    // list/grid modes. Keyboard mappings use scene UUIDs so browser reorder
    // and rename preserve every configured binding.

    // MARK: - Canvas panel

    private var canvasPanel: some View {
        VStack(spacing: 0) {
            // C01 (issue #76): the thumbnail camera switcher — live tiles for
            // every camera source; clicking assigns a camera to the selected
            // camera layer (or adds one).
            CameraSwitcherView()
            Divider()
            monitorsRow
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
            Divider()
            // G11 (issue #117): pen/highlighter/pointer annotation toolbar —
            // preview chrome only; program inclusion is an explicit toggle.
            AnnotationToolbarView()
            Divider()
            transitionControls
            if showDiagnostics {
                Divider()
                diagnosticsStrip
            }
            Divider()
            transportBar
        }
    }

    // MARK: - Preview / program monitors (W03)

    /// Two always-labeled monitors. PREVIEW renders the staged composition
    /// (selection + edits land here only); PROGRAM renders the outgoing
    /// composition the publisher/recording emit. Selecting a scene stages it
    /// without touching program; Take publishes staged → program.
    ///
    /// S04 (issue #72): the PREVIEW monitor carries the canvas-interaction
    /// overlay — click/marquee selection, drag/resize/rotate handles, snap
    /// guides, and keyboard nudging — drawn in SwiftUI over the image only,
    /// so the chrome never reaches the composed output. PROGRAM stays
    /// read-only (no overlay).
    private var monitorsRow: some View {
        HStack(spacing: 12) {
            PreviewView(
                image: controller.previewImage,
                label: "PREVIEW",
                accent: dispatcher.state.hasPendingStagedEdits ? .yellow : Color.secondary.opacity(0.3),
                isHighlighted: dispatcher.state.hasPendingStagedEdits,
                placeholder: controller.isPreviewing ? "Waiting for sources…" : "Preview off"
            ) { imageRect in
                CanvasInteractionView(
                    imageRect: imageRect,
                    canvasSize: dispatcher.state.activeProfile.canvasSize)
            }
            PreviewView(
                image: controller.programImage,
                label: "PROGRAM",
                accent: dispatcher.state.stream.isLive ? .red : Color.secondary.opacity(0.3),
                isHighlighted: dispatcher.state.stream.isLive,
                placeholder: controller.isPreviewing ? "Waiting for sources…" : "Preview off")
        }
        // G01 (issue #81): Finder drag/drop of an image file (PNG/JPEG/HEIF/
        // TIFF/PDF) onto the monitors adds an image layer to the staged
        // scene — the drop half of the add-asset acceptance (the file sheet
        // is in ImageLayerSectionView). Only image/PDF UTIs activate the
        // drop; the import pipeline validates the rest.
        .onDrop(of: [.image, .pdf], isTargeted: nil) { providers in
            handleImageFileDrop(providers)
        }
    }

    /// The W03 transition controls: Take publishes the staged composition
    /// atomically (⏎), Revert discards unpublished edits, the pending badge
    /// marks staged work program doesn't have yet, and the Direct Live toggle
    /// switches to the explicit edit-straight-to-program mode.
    private var transitionControls: some View {
        HStack(spacing: 12) {
            Button {
                dispatcher.execute(.take)
            } label: {
                Text("Take")
                    .frame(minWidth: 64)
            }
            .buttonStyle(.borderedProminent)
            .tint(dispatcher.state.hasPendingStagedEdits ? .accentColor : nil)
            .disabled(!dispatcher.canExecute(.take))
            .help("Publish the previewed scene to the program output (⏎)")

            Button("Revert") {
                dispatcher.execute(.revert)
            }
            .disabled(!dispatcher.canExecute(.revert))
            .help("Discard unpublished edits (preview goes back to the program scene)")

            if dispatcher.state.hasPendingStagedEdits {
                Label("Unpublished changes", systemImage: "circle.fill")
                    .foregroundStyle(.yellow)
                    .font(.caption.weight(.semibold))
                    .labelStyle(.titleAndIcon)
            }

            Spacer()

            Toggle(isOn: directLiveBinding) {
                Text("Direct Live")
                    .font(.callout)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .help("When on, scene edits and selections apply straight to the program output")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .animation(reduceMotion ? nil : .default, value: dispatcher.state.hasPendingStagedEdits)
    }

    private var directLiveBinding: Binding<Bool> {
        Binding(
            get: { dispatcher.state.directLiveEditing },
            set: { dispatcher.execute(.setDirectLiveEditing($0)) })
    }

    // MARK: - Diagnostics strip

    /// Live uplink health + recording status (W02 session states); this strip
    /// never opens a separate window. Rejected W05 commands surface here
    /// transiently (the dispatcher auto-clears the notice after a few
    /// seconds) — visible but never modal.
    private var diagnosticsStrip: some View {
        HStack(spacing: 16) {
            StatsHUDView(stream: controller)

            if let rejection = dispatcher.lastRejection {
                Label("\(rejection.command): \(rejection.message)",
                      systemImage: "exclamationmark.octagon.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
                    .lineLimit(1)
                    .id(rejection.sequence)
                    .transition(.opacity)
            }

            Spacer()

            if recorder.state == .preparing {
                Label("Preparing recording…", systemImage: "record.circle")
                    .foregroundStyle(.orange)
                    .font(.callout.weight(.semibold))
            } else if recorder.state.isRecording {
                Label("Recording", systemImage: "record.circle")
                    .foregroundStyle(.red)
                    .font(.callout.weight(.semibold))
            } else if recorder.state == .stopping {
                Label("Stopping…", systemImage: "record.circle")
                    .foregroundStyle(.orange)
                    .font(.callout.weight(.semibold))
            }
            if let url = recorder.lastRecordingURL {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Label(url.lastPathComponent, systemImage: "film")
                        .lineLimit(1)
                }
                .help("Reveal the finished recording in Finder")
            }
            if let warning = recorder.warning {
                Label(warning, systemImage: "externaldrive.badge.exclamationmark")
                    .foregroundStyle(.orange)
                    .font(.caption)
                    .lineLimit(1)
                    .help(warning)
            }
            if let url = recorder.lastPartialRecordingURL {
                Button("Reveal partial recording") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .help("Preserved fragments may be readable; arbitrary damaged files cannot be recovered.")
            }
            if let error = recorder.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - G01 image drops (issue #81)

    /// Adds an image layer to the staged scene from a dropped image file.
    /// The import pipeline validates the format (an unsupported/undecodable
    /// file surfaces its reason in the window's error alert, never reaches a
    /// scene); the new layer lands as a bottom-right logo-style bug the user
    /// repositions on canvas.
    private func handleImageFileDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }) else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in
                switch await imageLayers.importImage(at: url) {
                case .failure(let error):
                    controller.errorMessage = error.message
                case .success(let payload):
                    guard var scene = previewProgram.stagedScene else { return }
                    let layer = LayerNode(
                        name: url.deletingPathExtension().lastPathComponent,
                        payload: .image(payload),
                        transform: LayerTransform(
                            position: GraphPoint(x: 0.98, y: 0.98),
                            size: GraphSize(width: 0.2, height: 0.2),
                            anchor: .bottomRight))
                    scene.layers.append(layer)
                    dispatcher.execute(.updateScene(scene))
                    imageLayers.noteUsage(of: payload, from: layer.id)
                }
            }
        }
        return true
    }

    // MARK: - Inspector panel

    private var inspectorPanel: some View {
        VStack(spacing: 0) {
            Picker("Inspector", selection: $inspectorTab) {
                ForEach(InspectorTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.menu)
            .accessibilityLabel("Inspector section")
            .padding(8)

            switch inspectorTab {
            case .layers:
                // S03 (issue #71): the ordered layer panel — z-order, groups,
                // visibility, locks, add/remove/rename/duplicate.
                LayerPanelView()
            case .sources:
                sourcesInspector
            case .mixer:
                // A04 (issue #83): the embedded mixer — one strip per active
                // audio channel plus program/monitor masters.
                MixerPanelView()
            case .media:
                // A03 (issue #98): the embedded sound panel — soundboard
                // pads, music playlists, and the staged scene's sounds.
                SoundboardPanelView()
                    .environmentObject(dispatcher.soundboardStore)
                    .environmentObject(dispatcher.soundboard)
            case .assets:
                // P03 (issue #80): the asset library panel — inventory,
                // availability badges, and missing-asset repair.
                AssetLibraryPanelView()
            case .guests:
                placeholder("Guests", systemImage: "person.2",
                            message: "Remote guest management lands here in a later workstream.")
            case .destinations:
                ScrollView {
                    DestinationManagerView(session: controller.destinations,
                                           programProfile: controller.activeProfile)
                }
            }
        }
    }

    private func placeholder(_ title: String, systemImage: String, message: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sourcesInspector: some View {
        Form {
            // C01 (issue #76): the camera-source registry — add (system
            // default or any connected device), rename, retarget, remove,
            // and per-source capture status.
            CameraSourcesSectionView()
            // C02 (issue #77): the screen-source registry — add (pinned
            // display/window/application picker), rename, retarget, remove,
            // and per-source capture status.
            ScreenSourcesSectionView()
            // C09 (issue #163): Syphon server sources — discovered servers,
            // add/rename/relink/remove, and per-source receive status.
            SyphonSourcesSectionView()
            // A02 (issue #97): media file sources — add/rename/remove and
            // per-source playback status alongside transport in the layer panel.
            MediaSourcesSectionView()
            // G06 (issue #113): PDF/slide-deck sources — import, page
            // navigation (inspector + ⌥⌘ arrows), fit/fill, page state
            // shared per source across both canvases.
            PDFSourceSectionView()
            // A06 (issue #118): app/system audio-only sources — add (running
            // app or system mix), enable/disable, rename, retarget, remove,
            // and per-source capture status. Demand is registration-based,
            // independent of any screen scene.
            AppAudioSourcesSectionView()
            // W03: the inspector edits the STAGED scene (what PREVIEW shows);
            // changes reach program only via Take.
            if let scene = previewProgram.stagedScene {
                Picker("Layout", selection: layoutBinding(for: scene)) {
                    ForEach(SceneLayout.allCases, id: \.self) { layout in
                        Text(layout.displayName).tag(layout)
                    }
                }
                if scene.layout == .screenPlusCam {
                    Picker("Camera corner", selection: pipCornerBinding(for: scene)) {
                        Text("Top Left").tag(PIPCorner.topLeft)
                        Text("Top Right").tag(PIPCorner.topRight)
                        Text("Bottom Left").tag(PIPCorner.bottomLeft)
                        Text("Bottom Right").tag(PIPCorner.bottomRight)
                    }
                    Slider(value: pipScaleBinding(for: scene), in: 0.10...0.40) {
                        Text("Camera size")
                    }
                }
                LabeledContent("Screen", value: controller.screenCapture.isCapturing ? "Capturing" : "Off")
                LabeledContent("Mic level") {
                    ProgressView(value: Double(controller.audio.level))
                }
            }
            // S08 (issue #99): the staged scene's media entry/exit policy
            // and opt-in audio snapshot — applied when it becomes program.
            SceneBehaviorSectionView()
            // S09 (issue #100): the project default transition and the
            // staged scene's override — rendered only on Take (program);
            // direct-live uses the same transitions.
            TransitionSettingsSectionView()
            // G02 (issue #110): text/title editing for the selected text
            // layer — content, the full style surface, timed/fly-in
            // visibility, templates, and reusable title-style presets.
            TextLayerSectionView()
            // G08 (issue #115): browser/local-HTML widget configuration for
            // the selected web layer — URL or asset, viewport/fps, CSS
            // overrides, audio route, scene-entry refresh, runtime state.
            WebOverlaySectionView()
            // G01 (issue #81): image/logo layers — add from a file sheet or
            // a Finder drop, replace the selected image layer's asset, and
            // the fit/fill content mode. P03 asset registration/usage is
            // live once the shared AssetLibraryStore is injected.
            ImageLayerSectionView(coordinator: imageLayers)
            // G03 (issue #106): layer styling for the selected layer —
            // masks, borders, shadows, opacity, perspective (staged scene
            // content), plus reusable style presets.
            LayerStyleSectionView()
            // E01 (issue #101): per-source framing/picture adjustments for
            // the selected layer — layer overrides (staged scene content)
            // versus bound-source defaults (project-level), plus presets.
            SourceEffectsSectionView()
            // E03 (issue #164): capability-gated person-segmentation
            // background blur/replacement for the selected camera layer —
            // same override/defaults scopes, plus live segmentation status.
            BackgroundEffectsSectionView()
            // E05 (issue #109): capability-gated hardware camera controls
            // (focus/exposure/white-balance modes) and macOS reactions.
            CameraControlsSectionView()
            // E06 (issue #165): VISCA-over-IP PTZ targets, presets, and
            // opt-in recall-on-Take links.
            PTZControlSectionView()
        }
        .formStyle(.grouped)
    }

    private func layoutBinding(for scene: Scene) -> Binding<SceneLayout> {
        Binding(
            get: { scene.layout },
            set: { newLayout in
                var updated = scene
                updated.layout = newLayout
                dispatcher.execute(.updateScene(updated))
            })
    }

    private func pipCornerBinding(for scene: Scene) -> Binding<PIPCorner> {
        Binding(
            get: { scene.pipCorner },
            set: { corner in
                var updated = scene
                updated.pipCorner = corner
                dispatcher.execute(.updateScene(updated))
            })
    }

    private func pipScaleBinding(for scene: Scene) -> Binding<Double> {
        Binding(
            get: { scene.pipScale },
            set: { scale in
                var updated = scene
                updated.pipScale = scale
                dispatcher.execute(.updateScene(updated))
            })
    }

    // MARK: - Transport bar

    /// Every button routes through the W05 dispatcher and every label reads
    /// the published `StudioState` — this bar is the reference subscriber.
    private var transportBar: some View {
        HStack(spacing: 16) {
            Button {
                dispatcher.execute((dispatcher.state.recording == .preparing || dispatcher.state.recording.isRecording)
                                   ? .stopRecording : .startRecording)
            } label: {
                Label((dispatcher.state.recording == .preparing || dispatcher.state.recording.isRecording) ? "Stop Recording"
                      : dispatcher.state.recording == .stopping ? "Stopping…" : "Record",
                      systemImage: dispatcher.state.recording.isRecording ? "stop.circle.fill" : "record.circle")
            }
            .tint(dispatcher.state.recording.isRecording ? .red : nil)
            .disabled(dispatcher.state.recording == .stopping)

            Button {
                dispatcher.execute(dispatcher.state.preview == .active
                                   ? .stopPreview : .startPreview)
            } label: {
                Label(dispatcher.state.preview == .active ? "Stop Preview" : "Preview",
                      systemImage: dispatcher.state.preview == .active ? "eye.slash" : "eye")
            }
            .help(dispatcher.state.preview == .active
                  ? "Stop the on-screen preview (an active stream or recording keeps running)"
                  : "Start the on-screen preview")

            Spacer()

            streamStatusBadge

            goLiveButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .animation(reduceMotion ? nil : .default, value: dispatcher.state.stream)
    }

    /// The streaming session status: LIVE only on an acknowledged publish;
    /// connecting / reconnecting / stopping / failed are each distinct (W02).
    @ViewBuilder
    private var streamStatusBadge: some View {
        switch dispatcher.state.stream {
        case .idle:
            EmptyView()
        case .live:
            badge("LIVE", color: .red)
        case .connecting:
            badge("CONNECTING", color: .yellow)
        case .reconnecting(let reason):
            badge("RECONNECTING", color: .orange)
                .help("Connection lost — \(reason)")
        case .stopping:
            badge("STOPPING", color: .secondary)
        case .failed(let message):
            badge("FAILED", color: .red)
                .help(message)
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(text)
                .font(.headline)
                .foregroundStyle(color)
        }
        .transition(.opacity)
    }

    /// One button per streaming session state: Go Live from idle/failed,
    /// cancel while connecting, End Stream while live/reconnecting.
    @ViewBuilder
    private var goLiveButton: some View {
        Group {
            switch dispatcher.state.stream {
            case .idle, .failed:
                Button {
                    dispatcher.execute(.startStream)
                } label: {
                    Text(dispatcher.state.stream == .idle ? "Go Live" : "Retry Go Live")
                }
                .tint(.green)
            case .connecting:
                Button {
                    dispatcher.execute(.stopStream)
                } label: {
                    Text("Cancel")
                }
                .tint(.orange)
            case .live, .reconnecting:
                Button {
                    dispatcher.execute(.stopStream)
                } label: {
                    Text("End Stream")
                }
                .tint(.red)
            case .stopping:
                Button {} label: {
                    Text("Stopping…")
                }
                .disabled(true)
            }
        }
        .font(.headline)
        .frame(minWidth: 120)
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }
}

// MARK: - Transition settings (S09, issue #100)

/// The transition pickers in the Sources inspector: the PROJECT default
/// transition and the STAGED scene's override ("Inherit Default" = none).
/// Every edit routes through the dispatcher — the override is staged scene
/// content (Takes/reverts/undoes like any edit), the default is
/// project-level and applies immediately. Transitions render only on Take
/// (program); the preview monitor always cuts to the staged scene.
private struct TransitionSettingsSectionView: View {
    @EnvironmentObject private var dispatcher: StudioCommandDispatcher
    @EnvironmentObject private var sceneStore: SceneStore
    @EnvironmentObject private var previewProgram: PreviewProgramModel

    /// The scene-override picker's inherit sentinel (an optional
    /// `SceneTransitionStyle` tag: nil = inherit the project default).
    var body: some View {
        Section("Default Transition") {
            transitionEditor(defaultTransitionBinding, includeStyle: true)
        }
        if let scene = previewProgram.stagedScene {
            Section("Scene Transition") {
                Picker("Type", selection: overrideStyleBinding(for: scene)) {
                    Text("Default (\(sceneStore.defaultTransition.style.displayName))")
                        .tag(SceneTransitionStyle?.none)
                    ForEach(SceneTransitionStyle.allCases, id: \.self) { style in
                        Text(style.displayName).tag(SceneTransitionStyle?.some(style))
                    }
                }
                if scene.transition != nil {
                    transitionEditor(sceneTransitionBinding(for: scene),
                                     includeStyle: false)
                }
            }
        }
    }

    // MARK: Bindings

    private var defaultTransitionBinding: Binding<SceneTransition> {
        Binding(
            get: { sceneStore.defaultTransition },
            set: { dispatcher.execute(.setDefaultTransition($0)) })
    }

    /// The staged scene's override STYLE: nil tag = inherit (clears the
    /// override); a style keeps the existing override's settings when the
    /// style is unchanged, else seeds from the project default so the
    /// override starts from familiar values.
    private func overrideStyleBinding(for scene: Scene) -> Binding<SceneTransitionStyle?> {
        Binding(
            get: { scene.transition?.style },
            set: { style in
                guard let style else {
                    dispatcher.execute(.setSceneTransition(nil, in: nil))
                    return
                }
                if let existing = scene.transition, existing.style == style { return }
                let fallback = sceneStore.defaultTransition
                var transition = SceneTransition(style: style,
                                                 durationSeconds: fallback.durationSeconds,
                                                 direction: fallback.direction,
                                                 dipColorHex: fallback.dipColorHex)
                if style == .stinger {
                    transition.stingerCutPointSeconds = fallback.stingerCutPointSeconds
                    transition.stingerVolume = fallback.stingerVolume
                }
                dispatcher.execute(.setSceneTransition(transition, in: nil))
            })
    }

    private func sceneTransitionBinding(for scene: Scene) -> Binding<SceneTransition> {
        Binding(
            get: { scene.transition ?? sceneStore.defaultTransition },
            set: { dispatcher.execute(.setSceneTransition($0, in: nil)) })
    }

    // MARK: Editor

    /// The style-specific options for one transition configuration.
    @ViewBuilder
    private func transitionEditor(_ transition: Binding<SceneTransition>,
                                  includeStyle: Bool) -> some View {
        if includeStyle {
            Picker("Type", selection: transition.style) {
                ForEach(SceneTransitionStyle.allCases, id: \.self) { style in
                    Text(style.displayName).tag(style)
                }
            }
        }
        switch transition.wrappedValue.style {
        case .cut:
            EmptyView()
        case .layerMotion:
            durationSlider(transition)
            Picker("Easing", selection: transition.motionEasing) {
                ForEach(MotionEasing.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            Picker("Unmatched Layers", selection: transition.motionFallback) {
                Text("Cut").tag(MotionFallback.cut)
                Text("Dissolve").tag(MotionFallback.dissolve)
            }
            Text("Duplicate a layer or share its Motion ID across scenes. Ambiguous identities and incompatible source/mask changes use the selected fallback.")
                .font(.caption).foregroundStyle(.secondary)
        case .dissolve, .dipToColor, .wipe, .slide:
            durationSlider(transition)
            if transition.wrappedValue.style == .dipToColor {
                ColorPicker("Dip Color", selection: dipColorBinding(transition),
                            supportsOpacity: false)
            }
            if transition.wrappedValue.style == .wipe
                || transition.wrappedValue.style == .slide {
                Picker("Direction", selection: transition.direction) {
                    ForEach(TransitionDirection.allCases, id: \.self) { direction in
                        Text(direction.displayName).tag(direction)
                    }
                }
            }
        case .stinger:
            stingerEditor(transition)
        }
    }

    private func durationSlider(_ transition: Binding<SceneTransition>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Slider(value: transition.durationSeconds, in: 0.1...3.0, step: 0.05) {
                Text("Duration")
            }
            Text("Duration: \(transition.wrappedValue.durationSeconds, format: .number.precision(.fractionLength(2))) s")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func dipColorBinding(_ transition: Binding<SceneTransition>) -> Binding<Color> {
        Binding(
            get: {
                let components = HexColor.components(transition.wrappedValue.dipColorHex)
                return Color(NSColor(calibratedRed: components.red,
                                     green: components.green,
                                     blue: components.blue,
                                     alpha: 1))
            },
            set: { color in
                let nsColor = NSColor(color).usingColorSpace(.deviceRGB) ?? .black
                transition.wrappedValue.dipColorHex =
                    HexColor.string(red: Double(nsColor.redComponent),
                                    green: Double(nsColor.greenComponent),
                                    blue: Double(nsColor.blueComponent))
            })
    }

    /// The stinger options: the video file (security-scoped bookmark, the
    /// A02 media-source pattern), the cut point (seconds from playback
    /// start at which the scene swaps under the mask), and its audio
    /// volume in the mix.
    @ViewBuilder
    private func stingerEditor(_ transition: Binding<SceneTransition>) -> some View {
        HStack {
            Text(transition.wrappedValue.stingerFileName ?? "No stinger file")
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(transition.wrappedValue.stingerFileName == nil
                                 ? .secondary : .primary)
            Spacer()
            Button("Choose…") { pickStingerFile(transition) }
            if transition.wrappedValue.stingerBookmarkData != nil {
                Button("Clear") {
                    var updated = transition.wrappedValue
                    updated.stingerBookmarkData = nil
                    updated.stingerFileName = nil
                    transition.wrappedValue = updated
                }
            }
        }
        VStack(alignment: .leading, spacing: 2) {
            Slider(value: transition.stingerCutPointSeconds, in: 0...5.0, step: 0.1) {
                Text("Cut Point")
            }
            Text("Cut point: \(transition.wrappedValue.stingerCutPointSeconds, format: .number.precision(.fractionLength(1))) s into the stinger")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        VStack(alignment: .leading, spacing: 2) {
            Slider(value: transition.stingerVolume, in: 0...2.0, step: 0.05) {
                Text("Stinger Volume")
            }
            Text("Stinger volume: \(transition.wrappedValue.stingerVolume, format: .number.precision(.fractionLength(2)))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if transition.wrappedValue.stingerBookmarkData == nil {
            Text("Without a stinger file the Take falls back to a plain dissolve.")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    /// Picks the stinger video and stores its security-scoped bookmark (the
    /// sandboxed access grant), exactly like A02 media sources.
    private func pickStingerFile(_ transition: Binding<SceneTransition>) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .quickTimeMovie, .mpeg4Movie]
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Stinger"
        guard panel.runModal() == .OK, let url = panel.url,
              let payload = MediaSourceFactory.payload(forPickedFile: url) else { return }
        var updated = transition.wrappedValue
        updated.stingerBookmarkData = payload.bookmarkData
        updated.stingerFileName = payload.fileName
        transition.wrappedValue = updated
    }
}
