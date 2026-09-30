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
/// states plug in at the diagnostics strip and the placeholder inspector
/// tabs (mixer / media / guests / destinations).
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
        .toolbar { panelToggles }
        .sheet(isPresented: $showSettings) {
            SettingsView(settings: $settings) {
                SettingsStore().save(settings)
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

    /// Live uplink health + recording status. W02 (session states) extends
    /// this strip; it never opens a separate window.
    private var diagnosticsStrip: some View {
        HStack(spacing: 16) {
            StatsHUDView(stream: controller)

            Spacer()

            if recorder.isRecording {
                Label("Recording", systemImage: "record.circle")
                    .foregroundStyle(.red)
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
                Label(recorder.isRecording ? "Stop Recording" : "Record",
                      systemImage: recorder.isRecording ? "stop.circle.fill" : "record.circle")
            }
            .tint(recorder.isRecording ? .red : nil)

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

            Spacer()

            if controller.isLive {
                HStack(spacing: 6) {
                    Circle()
                        .fill(.red)
                        .frame(width: 8, height: 8)
                    Text("LIVE")
                        .font(.headline)
                        .foregroundStyle(.red)
                }
                .transition(.opacity)
            }

            Button {
                if controller.isLive {
                    controller.stopStream()
                } else {
                    controller.goLive()
                }
            } label: {
                Text(controller.isLive ? "End Stream" : "Go Live")
                    .font(.headline)
                    .frame(minWidth: 120)
            }
            .buttonStyle(.borderedProminent)
            .tint(controller.isLive ? .red : .green)
            .controlSize(.large)
            .keyboardShortcut("l", modifiers: .command)
            .disabled(!controller.isPreviewing && !controller.isLive)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .animation(.default, value: controller.isLive)
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
