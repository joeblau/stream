import SwiftUI

/// SwiftUI App lifecycle entry point for the Stream app (iOS 26+).
///
/// The app itself never captures the screen. It edits and persists
/// `StreamCore.StreamSettings` (connection secrets in the Keychain, the rest in
/// the shared App Group), then lets the user start a system broadcast via
/// `RPSystemBroadcastPickerView`. The broadcast upload extension
/// (`com.joeblau.Stream.Broadcast`) reads those settings and performs the actual
/// encode + RTMP/RTMPS push.
@main
struct StreamApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
