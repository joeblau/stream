import SwiftUI
import StreamCore

/// Ecamm Live-style main window: scene bar on top, program monitor center,
/// tabbed inspector on the right (Sources / Chat / Stats), transport controls
/// along the bottom.
struct MainWindowView: View {
    @EnvironmentObject private var sceneStore: SceneStore
    @EnvironmentObject private var controller: StreamController
    @StateObject private var recorder = RecordingController()
    @State private var inspectorTab: InspectorTab = .sources
    @State private var renamingScene: Scene?
    @State private var draftName = ""

    private enum InspectorTab: String, CaseIterable {
        case sources = "Sources"
        case chat = "Chat"
        case stats = "Stats"
    }

    var body: some View {
        VStack(spacing: 0) {
            sceneBar
            Divider()
            HStack(spacing: 0) {
                PreviewView(controller: controller)
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                inspector
                    .frame(width: 300)
            }
            .frame(maxHeight: .infinity)
            Divider()
            bottomBar
        }
        .frame(minWidth: 1280, minHeight: 800)
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

    private var renameBinding: Binding<Bool> {
        Binding(
            get: { renamingScene != nil },
            set: { if !$0 { renamingScene = nil } })
    }

    // MARK: - Scene bar

    private var sceneBar: some View {
        HStack(spacing: 8) {
            ForEach(Array(sceneStore.scenes.enumerated()), id: \.element.id) { index, scene in
                let pill = ScenePill(scene: scene, isSelected: scene.id == sceneStore.selectedID) {
                    sceneStore.selectedID = scene.id
                }
                Group {
                    if index < 9 {
                        pill.keyboardShortcut(KeyEquivalent(Character("\(index + 1)")),
                                              modifiers: .command)
                    } else {
                        pill
                    }
                }
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
                .onTapGesture(count: 2) {
                    draftName = scene.name
                    renamingScene = scene
                }
            }
            Spacer()
            Button {
                sceneStore.addScene()
            } label: {
                Image(systemName: "plus")
            }
            .help("Add scene")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Inspector

    private var inspector: some View {
        VStack(spacing: 0) {
            Picker("Inspector", selection: $inspectorTab) {
                ForEach(InspectorTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(8)

            switch inspectorTab {
            case .sources:
                sourcesTab
            case .chat:
                ChatSidebarView()
            case .stats:
                StatsHUDView(stream: controller)
            }
        }
    }

    private var sourcesTab: some View {
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

    // MARK: - Bottom bar

    private var bottomBar: some View {
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

/// A single selectable scene in the top bar.
private struct ScenePill: View {
    let scene: Scene
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(scene.name)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.15),
                            in: Capsule())
                .foregroundStyle(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }
}
