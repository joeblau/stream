import AppKit
import SwiftUI

/// In-window session policy for closing the studio window (W02, issue #62).
///
/// Installs an `NSWindowDelegate` on the studio window so a close while an
/// output session is active asks for confirmation in-window instead of
/// silently tearing sessions down:
///
/// - **Streaming or recording active** → a sheet offers "Stop and Close"
///   (explicitly stops every output, then closes) or "Cancel" (window stays,
///   sessions keep running). Closing is never silent.
/// - **No active outputs** → the preview (presentation session) is stopped and
///   the close proceeds immediately.
struct WindowCloseGuard: NSViewRepresentable {
    /// True while the stream or recording session is active.
    let hasActiveOutputs: () -> Bool
    /// Stops every output session (stream + recording). Called on "Stop and Close".
    let stopAllOutputs: () -> Void
    /// Stops just the presentation session. Called on a plain close.
    let stopPreview: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(hasActiveOutputs: hasActiveOutputs,
                    stopAllOutputs: stopAllOutputs,
                    stopPreview: stopPreview)
    }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // The representable lives in the window's view hierarchy via
        // `.background`; claim the delegate once the window exists.
        if let window = nsView.window, window.delegate !== context.coordinator {
            window.delegate = context.coordinator
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        private let hasActiveOutputs: () -> Bool
        private let stopAllOutputs: () -> Void
        private let stopPreview: () -> Void

        init(hasActiveOutputs: @escaping () -> Bool,
             stopAllOutputs: @escaping () -> Void,
             stopPreview: @escaping () -> Void) {
            self.hasActiveOutputs = hasActiveOutputs
            self.stopAllOutputs = stopAllOutputs
            self.stopPreview = stopPreview
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard hasActiveOutputs() else {
                // No outputs at stake: end the presentation session and close.
                stopPreview()
                return true
            }
            let alert = NSAlert()
            alert.messageText = "A session is still active"
            alert.informativeText = "A production output is active. Closing the window will stop all outputs first."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Stop and Close")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: sender) { [weak self] response in
                guard response == .alertFirstButtonReturn else { return }
                self?.stopAllOutputs()
                self?.stopPreview()
                sender.close()
            }
            return false
        }
    }
}
