import AppKit
import SwiftUI
import StreamCore

/// The persistent studio shell (W01): one window holding every production
/// control in dedicated, collapsible panels —
///
///     ┌──────────┬───────────────────────────┬──────────┬────────────┬───────────┐
///     │  Scenes  │  Canvas (program preview) │   Chat   │ Inspector  │ Settings  │
///     │  column  │  ──────────────────────── │  column  │  column    │ (W04, ⌘,) │
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
/// reach the store/pipeline via its explicit Apply. W02 session
/// states surface in the diagnostics strip (StatsHUD + recording status) and
/// the transport bar (acknowledged-connection LIVE badge, per-state Go Live
/// button); window close while an output is active is confirmed in-window via
/// `WindowCloseGuard`.
struct MainWindowView: View {
    @EnvironmentObject private var sceneStore: SceneStore
    @EnvironmentObject private var controller: StreamController
    @EnvironmentObject private var session: SettingsSession
    @EnvironmentObject private var permissions: PermissionsManager
    /// The app's recording output (owned by the app shell since W05).
    @EnvironmentObject private var recorder: RecordingController
    /// The W05 command layer: every studio action below routes through this
    /// dispatcher instead of calling the controllers/stores directly.
    @EnvironmentObject private var dispatcher: StudioCommandDispatcher
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

    @State private var inspectorTab: InspectorTab = .sources
    @State private var renamingScene: Scene?
    @State private var draftName = ""

    /// Keyboard-focus tracking per panel, so dismissing settings returns
    /// focus to wherever it was (W04 acceptance).
    private enum StudioPanel: Hashable {
        case scenes, canvas, chat, inspector, settings
    }
    @FocusState private var focusedPanel: StudioPanel?
    @State private var panelBeforeSettings: StudioPanel?

    private enum InspectorTab: String, CaseIterable {
        case sources = "Sources"
        case mixer = "Mixer"
        case media = "Media"
        case guests = "Guests"
        case destinations = "Destinations"
    }

    var body: some View {
        HSplitView {
            if showScenesPanel {
                scenesPanel
                    .frame(minWidth: 180, idealWidth: 220, maxWidth: 320)
                    .focusable()
                    .focused($focusedPanel, equals: .scenes)
            }
            canvasPanel
                .frame(minWidth: 320)
                .layoutPriority(1)
                .focusable()
                .focused($focusedPanel, equals: .canvas)
            if showChatPanel {
                ChatSidebarView(chat: chat)
                    .frame(maxWidth: 420)
                    .focusable()
                    .focused($focusedPanel, equals: .chat)
            }
            if showInspectorPanel {
                inspectorPanel
                    .frame(minWidth: 240, idealWidth: 300, maxWidth: 420)
                    .focusable()
                    .focused($focusedPanel, equals: .inspector)
            }
            if session.isPresented {
                settingsPane
                    .frame(minWidth: 300, idealWidth: 360, maxWidth: 480)
                    .focusable()
                    .focused($focusedPanel, equals: .settings)
            }
        }
        .background {
            // ⌘1…⌘9 jump straight to a scene from anywhere in the window; the
            // hidden buttons only carry the shortcuts.
            ForEach(1...9, id: \.self) { number in
                Button("") { dispatcher.execute(.selectSceneAt(number)) }
                    .keyboardShortcut(KeyEquivalent(Character("\(number)")),
                                      modifiers: .command)
                    .hidden()
            }
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
            dispatcher.execute(.startPreview)
            // Restore a settings pane left open last launch.
            session.isPresented = showSettingsPanel
            permissions.refresh()
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
        .alert("Rename Scene", isPresented: renameBinding) {
            TextField("Scene name", text: $draftName)
            Button("Rename") {
                if let scene = renamingScene {
                    dispatcher.execute(.renameScene(scene.id, to: draftName))
                }
            }
            Button("Cancel", role: .cancel) {}
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

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var panelToggles: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
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

    private var renameBinding: Binding<Bool> {
        Binding(
            get: { renamingScene != nil },
            set: { if !$0 { renamingScene = nil } })
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

    /// `List` wants an optional selection; the store never leaves zero scenes,
    /// so a deselect is ignored and a select writes straight through.
    private var sceneSelection: Binding<Scene.ID?> {
        Binding(
            get: { sceneStore.selectedID },
            set: { if let id = $0 { dispatcher.execute(.selectScene(id)) } })
    }

    private var scenesPanel: some View {
        VStack(spacing: 0) {
            Text("Scenes")
                .font(.callout.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            List(selection: sceneSelection) {
                ForEach(sceneStore.scenes) { scene in
                    SceneRow(scene: scene)
                        .tag(scene.id)
                        .contextMenu {
                            Button("Rename…") {
                                draftName = scene.name
                                renamingScene = scene
                            }
                            Button("Delete", role: .destructive) {
                                dispatcher.execute(.deleteScene(scene.id))
                            }
                            .disabled(sceneStore.scenes.count <= 1)
                        }
                }
            }

            Divider()
            Button {
                dispatcher.execute(.addScene)
            } label: {
                Label("Add Scene", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Canvas panel

    private var canvasPanel: some View {
        VStack(spacing: 0) {
            PreviewView(controller: controller)
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
            if showDiagnostics {
                Divider()
                diagnosticsStrip
            }
            Divider()
            transportBar
        }
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

            if recorder.state.isRecording {
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

    // MARK: - Inspector panel

    private var inspectorPanel: some View {
        VStack(spacing: 0) {
            Picker("Inspector", selection: $inspectorTab) {
                ForEach(InspectorTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)

            switch inspectorTab {
            case .sources:
                sourcesInspector
            case .mixer:
                placeholder("Mixer", systemImage: "slider.vertical.3",
                            message: "Per-source audio levels land here in a later workstream.")
            case .media:
                placeholder("Media", systemImage: "photo.on.rectangle",
                            message: "Overlays, videos and images land here in a later workstream.")
            case .guests:
                placeholder("Guests", systemImage: "person.2",
                            message: "Remote guest management lands here in a later workstream.")
            case .destinations:
                placeholder("Destinations", systemImage: "paperplane",
                            message: "Multi-destination output lands here in a later workstream.")
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
            if let scene = sceneStore.selected {
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
                dispatcher.execute(dispatcher.state.recording.isRecording
                                   ? .stopRecording : .startRecording)
            } label: {
                Label(dispatcher.state.recording.isRecording ? "Stop Recording"
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
        .animation(.default, value: dispatcher.state.stream)
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
        .keyboardShortcut("l", modifiers: .command)
    }
}

/// A single scene row in the scenes panel.
private struct SceneRow: View {
    let scene: Scene

    var body: some View {
        Label(scene.name, systemImage: icon)
            .lineLimit(1)
    }

    private var icon: String {
        switch scene.layout {
        case .cameraSolo: return "person.fill"
        case .screenSolo: return "display"
        case .screenPlusCam: return "rectangle.inset.bottomright.filled"
        }
    }
}
