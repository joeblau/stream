import StreamCore
import SwiftUI

@main
@MainActor
struct StreamMacApp: App {
    @StateObject private var sceneStore: SceneStore
    /// The W03 preview/program model (issue #66): owns the staged scene (what
    /// PREVIEW shows and edits mutate) vs the program snapshot (what the
    /// outputs emit), plus the direct-live editing mode. Both snapshots start
    /// from the persisted selection.
    @StateObject private var previewProgram: PreviewProgramModel
    @StateObject private var streamController: StreamController
    /// The shared settings session (W04, issue #67): one object binding the
    /// settings pane's draft, SettingsStore persistence, and the controller's
    /// active values. Owned here so the menu command (⌘,), the toolbar, and
    /// the W05 command layer / W06 first-run flow share it.
    @StateObject private var settingsSession: SettingsSession
    /// The shared permission center (W06, issue #69): onboarding, the
    /// just-in-time explainers, and the settings pane all read/request
    /// capture permissions through this one object. C10 (issue #79): the
    /// stream controller also observes it — permission transitions drive
    /// capture recovery, and screen-capture errors trigger its revocation
    /// probe.
    @StateObject private var permissions: PermissionsManager
    /// The recording output. Owned here (not by the window) so the W05
    /// command dispatcher drives the same instance the transport bar and the
    /// first-run flow show.
    @StateObject private var recorder: RecordingController
    /// The W05 command layer (issue #68): every studio action — UI, keyboard,
    /// and later automation/hardware — routes through this one ordered
    /// dispatcher, which validates against current session state, executes,
    /// and publishes the merged `StudioState`.
    @StateObject private var dispatcher: StudioCommandDispatcher

    /// W06 first-run gating: false until the setup guide is finished or
    /// skipped; the studio window presents the onboarding sheet while false.
    @AppStorage("onboarding.hasCompletedFirstRun") private var hasCompletedFirstRun = false

    init() {
        let sceneStore = SceneStore()
        let previewProgram = PreviewProgramModel(selected: sceneStore.selected)
        let permissions = PermissionsManager()
        let streamController = StreamController(sceneStore: sceneStore,
                                                previewProgram: previewProgram,
                                                permissions: permissions)
        let settingsSession = SettingsSession(controller: streamController)
        let recorder = RecordingController()
        _sceneStore = StateObject(wrappedValue: sceneStore)
        _previewProgram = StateObject(wrappedValue: previewProgram)
        _streamController = StateObject(wrappedValue: streamController)
        _permissions = StateObject(wrappedValue: permissions)
        _settingsSession = StateObject(wrappedValue: settingsSession)
        _recorder = StateObject(wrappedValue: recorder)
        _dispatcher = StateObject(wrappedValue: StudioCommandDispatcher(
            controller: streamController,
            sceneStore: sceneStore,
            session: settingsSession,
            recorder: recorder,
            previewProgram: previewProgram))
    }

    // `SwiftUI.Scene` is qualified because the module also defines a `Scene`
    // model type (SceneModel.swift).
    var body: some SwiftUI.Scene {
        // One persistent studio window per running app: `Window` (unlike
        // `WindowGroup`) never opens a second copy — File > New Window and a
        // relaunch while running just focus the existing one. Settings live
        // inside this shell as an embedded pane (W04), so there is no
        // separate `SwiftUI.Settings` scene.
        Window("Stream Studio", id: "studio") {
            MainWindowView(firstRunCompleted: $hasCompletedFirstRun)
                .environmentObject(sceneStore)
                .environmentObject(previewProgram)
                .environmentObject(streamController)
                // C10 (issue #79): direct observation of the pool's per-source
                // health (missing badges) and the monitor's device lists
                // (relink pickers) — nested objects don't invalidate views
                // through the controller's own @Published.
                .environmentObject(streamController.capturePool)
                .environmentObject(streamController.deviceMonitor)
                .environmentObject(settingsSession)
                .environmentObject(permissions)
                .environmentObject(recorder)
                .environmentObject(dispatcher)
                // P03 (issue #80): the asset library — parked on the
                // dispatcher, injected for the library panel (environment
                // object) and the G01 image-layer views (environment key).
                .environmentObject(dispatcher.assetLibrary)
                .environment(\.assetLibraryStore, dispatcher.assetLibrary)
                .preferredColorScheme(.dark)
                // The smallest supported production layout (1024×640): all
                // panels stay usable, and any of them can collapse from there.
                .frame(minWidth: 1024, minHeight: 640)
        }
        .defaultSize(width: 1440, height: 900)
        .windowResizability(.contentMinSize)
        .commands {
            // S12 (issue #75): undo/redo for scene edits, routed through the
            // dispatcher like every studio action. The labels name the edit
            // ⌘Z / ⇧⌘Z would apply ("Undo Move Layer").
            CommandGroup(replacing: .undoRedo) {
                Button(dispatcher.state.undoLabel.map { "Undo \($0)" } ?? "Undo") {
                    dispatcher.execute(.undo)
                }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!dispatcher.state.canUndo)
                Button(dispatcher.state.redoLabel.map { "Redo \($0)" } ?? "Redo") {
                    dispatcher.execute(.redo)
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!dispatcher.state.canRedo)
            }
            // Takes over the app menu's Settings slot: ⌘, opens the embedded
            // settings pane (and closes it when already open) — routed through
            // the W05 command layer like every other studio action.
            CommandGroup(replacing: .appSettings) {
                Button(settingsSession.isPresented ? "Close Settings" : "Settings…") {
                    dispatcher.execute(settingsSession.isPresented
                                       ? .closeSettings
                                       : .openSettings(nil))
                }
                .keyboardShortcut(",", modifiers: .command)
                Divider()
                // W06: re-run the first-run setup guide on demand.
                Button("Setup Guide…") {
                    hasCompletedFirstRun = false
                }
            }
            // G11 (issue #117): the presentation annotation + live-demo
            // commands — every control the annotation toolbar has, with
            // hotkeys, routed through the dispatcher like every studio
            // action. State labels/checkmarks read the dispatcher's
            // published `StudioState.annotations` mirror.
            CommandMenu("Annotate") {
                let annotationState = dispatcher.state.annotations
                Button {
                    dispatcher.execute(.setAnnotationTool(nil))
                } label: {
                    if annotationState.activeTool == nil {
                        Label("Selection Tool", systemImage: "checkmark")
                    } else {
                        Text("Selection Tool")
                    }
                }
                .keyboardShortcut("0", modifiers: [.command, .option])
                ForEach(AnnotationTool.allCases, id: \.self) { tool in
                    Button {
                        dispatcher.execute(.setAnnotationTool(tool))
                    } label: {
                        if annotationState.activeTool == tool {
                            Label("\(tool.displayName) Tool", systemImage: "checkmark")
                        } else {
                            Text("\(tool.displayName) Tool")
                        }
                    }
                    .keyboardShortcut(toolShortcut(tool), modifiers: [.command, .option])
                }
                Divider()
                Button("Undo Annotation") {
                    dispatcher.execute(.undoAnnotationStroke(in: nil))
                }
                .keyboardShortcut("z", modifiers: [.command, .option])
                .disabled(!dispatcher.canExecute(.undoAnnotationStroke(in: nil)))
                Button("Redo Annotation") {
                    dispatcher.execute(.redoAnnotationStroke(in: nil))
                }
                .keyboardShortcut("z", modifiers: [.command, .option, .shift])
                .disabled(!dispatcher.canExecute(.redoAnnotationStroke(in: nil)))
                Button("Clear Annotations") {
                    dispatcher.execute(.clearAnnotations(in: nil))
                }
                .keyboardShortcut("k", modifiers: [.command, .option])
                .disabled(!dispatcher.canExecute(.clearAnnotations(in: nil)))
                Divider()
                Toggle("Annotations Visible in Scene", isOn: Binding(
                    get: { dispatcher.state.annotations.stagedVisible },
                    set: { dispatcher.execute(.setAnnotationVisibility(visible: $0, in: nil)) }))
                    .keyboardShortcut("v", modifiers: [.command, .option])
                    .disabled(!dispatcher.canExecute(.setAnnotationVisibility(visible: true, in: nil)))
                Toggle("Annotations in Program", isOn: Binding(
                    get: { dispatcher.state.annotations.stagedInProgram },
                    set: { dispatcher.execute(.setAnnotationsInProgram($0, in: nil)) }))
                    .keyboardShortcut("b", modifiers: [.command, .option])
                    .disabled(!dispatcher.canExecute(.setAnnotationsInProgram(true, in: nil)))
            }
            // G06 (issue #113): presentation page navigation — next/previous
            // plus first/last jumps, routed through the dispatcher like every
            // studio action. The target resolves live
            // (`presentationNavigationTarget`): the selected layer's PDF
            // source, else the first visible PDF source in the staged scene.
            // Page state is shared per source, so these hotkeys move preview
            // AND program together and can never fork the two canvases.
            CommandMenu("Present") {
                let target = dispatcher.presentationNavigationTarget()
                Button("Next Page") {
                    if let target { dispatcher.execute(.pdfNextPage(target)) }
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(target == nil)
                Button("Previous Page") {
                    if let target { dispatcher.execute(.pdfPreviousPage(target)) }
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(target == nil)
                Divider()
                Button("First Page") {
                    if let target { dispatcher.execute(.pdfGoToPage(target, page: 0)) }
                }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(target == nil)
                Button("Last Page") {
                    // Int.max clamps to the loaded page count in the store.
                    if let target { dispatcher.execute(.pdfGoToPage(target, page: .max)) }
                }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(target == nil)
            }
        }
    }
}

/// G11 (issue #117): the ⌥⌘ digit for each annotation tool (⌥⌘0 returns to
/// the selection tool).
private func toolShortcut(_ tool: AnnotationTool) -> KeyEquivalent {
    switch tool {
    case .pen: return "1"
    case .highlighter: return "2"
    case .pointer: return "3"
    }
}
