import StreamCore
import SwiftUI

@main
@MainActor
struct StreamMacApp: App {
    @StateObject private var sceneStore: SceneStore
    @StateObject private var streamController: StreamController
    @State private var settings = SettingsStore().load()

    init() {
        let sceneStore = SceneStore()
        _sceneStore = StateObject(wrappedValue: sceneStore)
        _streamController = StateObject(wrappedValue: StreamController(sceneStore: sceneStore))
    }

    // `SwiftUI.Scene` is qualified because the module also defines a `Scene`
    // model type (SceneModel.swift).
    var body: some SwiftUI.Scene {
        WindowGroup {
            MainWindowView()
                .environmentObject(sceneStore)
                .environmentObject(streamController)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1440, height: 900)

        SwiftUI.Settings {
            SettingsView(settings: $settings) {
                SettingsStore().save(settings)
            }
        }
    }
}
