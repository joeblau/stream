import StreamCore
import SwiftUI

@main
@MainActor
struct StreamMacApp: App {
    @StateObject private var sceneStore: SceneStore
    @StateObject private var streamController: StreamController
    /// The shared settings session (W04, issue #67): one object binding the
    /// settings pane's draft, SettingsStore persistence, and the controller's
    /// active values. Owned here so the menu command (⌘,), the toolbar, and
    /// later the W05 command layer / W06 first-run flow share it.
    @StateObject private var settingsSession: SettingsSession

    init() {
        let sceneStore = SceneStore()
        let streamController = StreamController(sceneStore: sceneStore)
        _sceneStore = StateObject(wrappedValue: sceneStore)
        _streamController = StateObject(wrappedValue: streamController)
        _settingsSession = StateObject(wrappedValue: SettingsSession(controller: streamController))
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
            MainWindowView()
                .environmentObject(sceneStore)
                .environmentObject(streamController)
                .environmentObject(settingsSession)
                .preferredColorScheme(.dark)
                // The smallest supported production layout (1024×640): all
                // panels stay usable, and any of them can collapse from there.
                .frame(minWidth: 1024, minHeight: 640)
        }
        .defaultSize(width: 1440, height: 900)
        .windowResizability(.contentMinSize)
        .commands {
            // Takes over the app menu's Settings slot: ⌘, opens the embedded
            // settings pane (and closes it when already open).
            CommandGroup(replacing: .appSettings) {
                Button(settingsSession.isPresented ? "Close Settings" : "Settings…") {
                    settingsSession.isPresented.toggle()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
