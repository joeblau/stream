import AppKit
import SwiftUI
import StreamCore

/// The persistent studio shell (W01): one window holding every production
/// control in dedicated, collapsible panels —
///
///     ┌──────────┬───────────────────────────┬──────────┬────────────┐
///     │  Scenes  │  Canvas (program preview) │   Chat   │ Inspector  │
///     │  column  │  ──────────────────────── │  column  │  column    │
///     │          │  Diagnostics strip        │          │            │
///     │          │  Transport bar            │          │            │
///     └──────────┴───────────────────────────┴──────────┴────────────┘
///
/// The columns are `HSplitView` panes, so they resize by dragging and
/// collapse/restore from the toolbar toggles; pane visibility persists in
/// `UserDefaults` (`@AppStorage`). Settings is a toolbar-presented sheet on
/// this window until W04 embeds it as a first-class panel — swap
/// `settingsSheet` for an inspector tab or dedicated pane then. W02 session
/// states surface in the diagnostics strip (StatsHUD + recording status) and
/// the transport bar (acknowledged-connection LIVE badge, per-state Go Live
/// button); window close while an output is active is confirmed in-window via
/// `WindowCloseGuard`.
struct MainWindowView: View {
    @EnvironmentObject private var sceneStore: SceneStore
    @EnvironmentObject private var controller: StreamController
    @StateObject private var recorder = RecordingController()

    // Panel visibility, persisted so the layout restores across launches.
    @AppStorage("studio.showScenesPanel") private var showScenesPanel = true
    @AppStorage("studio.showChatPanel") private var showChatPanel = true
    @AppStorage("studio.showInspectorPanel") private var showInspectorPanel = true
    @AppStorage("studio.showDiagnostics") private var showDiagnostics = true

    @State private var inspectorTab: InspectorTab = .sources
    @State private var showSettings = false
    @State private var settings = SettingsStore().load()
    @State private var renamingScene: Scene?
    @State private var draftName = ""

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
            }
            canvasPanel
                .frame(minWidth: 320)
                .layoutPriority(1)
            if showChatPanel {
                ChatSidebarView()
                    .frame(maxWidth: 420)
            }
            if showInspectorPanel {
                inspectorPanel
                    .frame(minWidth: 240, idealWidth: 300, maxWidth: 420)
            }
        }
        .background {
            // ⌘1…⌘9 jump straight to a scene from anywhere in the window; the
            // hidden buttons only carry the shortcuts.
            ForEach(1...9, id: \.self) { number in
                Button("") { sceneStore.select(number: number) }
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
                    controller.streamState.isActive || recorder.state.isActive
                },
                stopAllOutputs: {
                    controller.stopStream()
                    recorder.stop()
                },
                stopPreview: { controller.stopPreview() })
        }
        .toolbar { panelToggles }
        .sheet(isPresented: $showSettings) {
            SettingsView(settings: $settings,
                         outputActive: controller.streamState.isActive || recorder.state.isActive) {
                SettingsStore().save(settings)
                // Applies immediately when idle; staged ("next session") while
                // a stream or recording owns the encode geometry (W07).
                controller.applyOutputProfile(settings.outputProfile,
                                              destination: settings.selectedProtocol)
            }
        }
        .onAppear { controller.startPreview() }
        .alert("Rename Scene", isPresented: renameBinding) {
            TextField("Scene name", text: $draftName)
            Button("Rename") {
                if let scene = renamingScene {
                    sceneStore.rename(scene.id, to: draftName)
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

            Button {
                showSettings = true
            } label: {
                Label("Settings", systemImage: "gear")
            }
            .help("Open settings")
        }
    }

    private var renameBinding: Binding<Bool> {
        Binding(
            get: { renamingScene != nil },
            set: { if !$0 { renamingScene = nil } })
    }

    // MARK: - Scenes panel

    /// `List` wants an optional selection; the store never leaves zero scenes,
    /// so a deselect is ignored and a select writes straight through.
    private var sceneSelection: Binding<Scene.ID?> {
        Binding(
            get: { sceneStore.selectedID },
            set: { if let id = $0 { sceneStore.selectedID = id } })
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
                                sceneStore.delete(scene.id)
                            }
                            .disabled(sceneStore.scenes.count <= 1)
                        }
                }
            }

            Divider()
            Button {
                sceneStore.addScene()
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
    /// never opens a separate window.
    private var diagnosticsStrip: some View {
        HStack(spacing: 16) {
            StatsHUDView(stream: controller)

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
                sceneStore.update(updated)
            })
    }

    private func pipCornerBinding(for scene: Scene) -> Binding<PIPCorner> {
        Binding(
            get: { scene.pipCorner },
            set: { corner in
                var updated = scene
                updated.pipCorner = corner
                sceneStore.update(updated)
            })
    }

    private func pipScaleBinding(for scene: Scene) -> Binding<Double> {
        Binding(
            get: { scene.pipScale },
            set: { scale in
                var updated = scene
                updated.pipScale = scale
                sceneStore.update(updated)
            })
    }

    // MARK: - Transport bar

    private var transportBar: some View {
        HStack(spacing: 16) {
            Button {
                recorder.toggle(stream: controller)
            } label: {
                Label(recorder.state.isRecording ? "Stop Recording"
                      : recorder.state == .stopping ? "Stopping…" : "Record",
                      systemImage: recorder.state.isRecording ? "stop.circle.fill" : "record.circle")
            }
            .tint(recorder.state.isRecording ? .red : nil)
            .disabled(recorder.state == .stopping)

            Button {
                if controller.isPreviewing {
                    controller.stopPreview()
                } else {
                    controller.startPreview()
                }
            } label: {
                Label(controller.isPreviewing ? "Stop Preview" : "Preview",
                      systemImage: controller.isPreviewing ? "eye.slash" : "eye")
            }
            .help(controller.isPreviewing
                  ? "Stop the on-screen preview (an active stream or recording keeps running)"
                  : "Start the on-screen preview")

            Spacer()

            streamStatusBadge

            goLiveButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .animation(.default, value: controller.streamState)
    }

    /// The streaming session status: LIVE only on an acknowledged publish;
    /// connecting / reconnecting / stopping / failed are each distinct (W02).
    @ViewBuilder
    private var streamStatusBadge: some View {
        switch controller.streamState {
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
            switch controller.streamState {
            case .idle, .failed:
                Button {
                    controller.goLive()
                } label: {
                    Text(controller.streamState == .idle ? "Go Live" : "Retry Go Live")
                }
                .tint(.green)
            case .connecting:
                Button {
                    controller.stopStream()
                } label: {
                    Text("Cancel")
                }
                .tint(.orange)
            case .live, .reconnecting:
                Button {
                    controller.stopStream()
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
