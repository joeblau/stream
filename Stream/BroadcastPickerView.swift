import SwiftUI
import ReplayKit
import StreamCore

/// SwiftUI wrapper around `RPSystemBroadcastPickerView`. Tapping it presents the
/// system sheet that starts/stops a broadcast targeting our upload extension.
///
/// `preferredExtension` is pinned to the extension bundle id so only our
/// `StreamBroadcast` extension is offered, and the microphone button is shown so
/// the user can route mic audio (a prerequisite for `.audioMic` buffers).
struct BroadcastPickerView: UIViewRepresentable {

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(
            frame: CGRect(x: 0, y: 0, width: 60, height: 60)
        )
        picker.preferredExtension = AppGroup.broadcastExtensionBundleID
        picker.showsMicrophoneButton = true
        return picker
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {
        // Re-assert configuration so it survives any view recycling.
        uiView.preferredExtension = AppGroup.broadcastExtensionBundleID
        uiView.showsMicrophoneButton = true
    }
}
