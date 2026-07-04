import SwiftUI

/// SwiftUI App lifecycle entry point for the Stream app (iOS 27+).
///
/// `ScreenCaptureController` uses ScreenCaptureKit's system content picker and
/// owns capture, encoding, and network publishing in this process.
@main
struct StreamApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
