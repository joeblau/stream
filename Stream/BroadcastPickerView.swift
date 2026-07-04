import SwiftUI
import ReplayKit
import StreamCore

/// SwiftUI wrapper around ReplayKit's visible system recording control.
///
/// `preferredExtension` is pinned to the extension bundle id so only our
/// `StreamBroadcast` extension is offered, and the microphone button is shown so
/// the user can route mic audio (a prerequisite for `.audioMic` buffers).
///
/// `onStartTap` fires when the user taps the system button (which opens the
/// "Start Broadcast" sheet). It lets the app assert its background-audio
/// keepalive proactively — before the broadcast is even confirmed — closing the
/// small window between the tap and the extension reporting live. It is
/// best-effort: if a future iOS changes the private view hierarchy and the
/// button can't be found, the keepalive still starts (a beat later) when the
/// broadcast actually goes live.
struct BroadcastPickerView: UIViewRepresentable {
    var onStartTap: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(onStartTap: onStartTap) }

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(
            frame: CGRect(x: 0, y: 0, width: 60, height: 60)
        )
        configure(picker)
        context.coordinator.hookButton(in: picker)
        return picker
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {
        // Re-assert configuration so it survives any view recycling.
        configure(uiView)
        context.coordinator.onStartTap = onStartTap
        context.coordinator.hookButton(in: uiView)
    }

    private func configure(_ picker: RPSystemBroadcastPickerView) {
        picker.preferredExtension = AppGroup.broadcastExtensionBundleID
        picker.showsMicrophoneButton = true

        picker.backgroundColor = .clear
    }

    /// Persists the target-action hook on the picker's system button. Adding a
    /// target does not replace ReplayKit's own action, so the sheet still opens.
    @MainActor
    final class Coordinator {
        var onStartTap: () -> Void
        private weak var hookedButton: UIButton?

        init(onStartTap: @escaping () -> Void) { self.onStartTap = onStartTap }

        func hookButton(in picker: RPSystemBroadcastPickerView) {
            guard let button = Self.firstButton(in: picker), button !== hookedButton else { return }
            hookedButton = button
            button.addTarget(self, action: #selector(buttonTapped), for: .touchUpInside)
        }

        @objc private func buttonTapped() { onStartTap() }

        /// Depth-first search for the picker's `UIButton` (ReplayKit nests it
        /// inside a container on some iOS versions).
        private static func firstButton(in view: UIView) -> UIButton? {
            for subview in view.subviews {
                if let button = subview as? UIButton { return button }
                if let nested = firstButton(in: subview) { return nested }
            }
            return nil
        }
    }
}
