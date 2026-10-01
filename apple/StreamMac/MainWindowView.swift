import AppKit
import SwiftUI
import StreamCore

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
        case media = "Media"
        case guests = "Guests"
        case destinations = "Destinations"
    }

    var body: some View {
        HSplitView {
            if showScenesPanel {
                SceneBrowserView()
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
    // list/grid modes. The ⌘1…⌘9 shortcuts above keep working because the
    // browser's manual order IS the store's scene order.

    // MARK: - Canvas panel

    private var canvasPanel: some View {
        VStack(spacing: 0) {
            monitorsRow
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
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
    private var monitorsRow: some View {
        HStack(spacing: 12) {
            PreviewView(
                image: controller.previewImage,
                label: "PREVIEW",
                accent: dispatcher.state.hasPendingStagedEdits ? .yellow : Color.secondary.opacity(0.3),
                isHighlighted: dispatcher.state.hasPendingStagedEdits,
                placeholder: controller.isPreviewing ? "Waiting for sources…" : "Preview off")
            PreviewView(
                image: controller.programImage,
                label: "PROGRAM",
                accent: dispatcher.state.stream.isLive ? .red : Color.secondary.opacity(0.3),
                isHighlighted: dispatcher.state.stream.isLive,
                placeholder: controller.isPreviewing ? "Waiting for sources…" : "Preview off")
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
            .keyboardShortcut(.defaultAction)
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
        .animation(.default, value: dispatcher.state.hasPendingStagedEdits)
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
            case .layers:
                // S03 (issue #71): the ordered layer panel — z-order, groups,
                // visibility, locks, add/remove/rename/duplicate.
                LayerPanelView()
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
