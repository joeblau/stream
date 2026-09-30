import StreamCore
import SwiftUI

@main
@MainActor
struct StreamMacApp: App {
    @StateObject private var sceneStore: SceneStore
    @StateObject private var streamController: StreamController

    init() {
        let sceneStore = SceneStore()
        _sceneStore = StateObject(wrappedValue: sceneStore)
        _streamController = StateObject(wrappedValue: StreamController(sceneStore: sceneStore))
    }

    // `SwiftUI.Scene` is qualified because the module also defines a `Scene`
    // model type (SceneModel.swift).
    var body: some SwiftUI.Scene {
        // One persistent studio window per running app: `Window` (unlike
        // `WindowGroup`) never opens a second copy — File > New Window and a
        // relaunch while running just focus the existing one. Settings live
        // inside this shell (toolbar sheet), so there is no separate
        // `SwiftUI.Settings` scene.
        Window("Stream Studio", id: "studio") {
            MainWindowView()
                .environmentObject(sceneStore)
                .environmentObject(streamController)
                .preferredColorScheme(.dark)
                // The smallest supported production layout (1024×640): all
                // panels stay usable, and any of them can collapse from there.
                .frame(minWidth: 1024, minHeight: 640)
        }
        .defaultSize(width: 1440, height: 900)
        .windowResizability(.contentMinSize)
    }
}
