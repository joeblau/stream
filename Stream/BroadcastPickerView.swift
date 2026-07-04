import SwiftUI
import ReplayKit
import StreamCore

/// SwiftUI wrapper around ReplayKit's visible system recording control.
///
/// `preferredExtension` is pinned to the extension bundle id so only our
/// `StreamBroadcast` extension is offered, and the microphone button is shown so
/// the user can route mic audio (a prerequisite for `.audioMic` buffers).
struct BroadcastPickerView: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(
            frame: CGRect(x: 0, y: 0, width: 60, height: 60)
        )
        configure(picker)
        return picker
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {
        // Re-assert configuration so it survives any view recycling.
        configure(uiView)
    }

    private func configure(_ picker: RPSystemBroadcastPickerView) {
        picker.preferredExtension = AppGroup.broadcastExtensionBundleID
        picker.showsMicrophoneButton = true

        picker.backgroundColor = .clear
    }
}
