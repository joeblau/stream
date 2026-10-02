import AppKit

/// A normal Quit waits for the writer instead of letting SwiftUI destroy it
/// while finishWriting is in flight. Forced termination retains completed movie
/// fragments and the journal; recovery still depends on the bytes on disk.
@MainActor
final class RecordingTerminationDelegate: NSObject, NSApplicationDelegate {
    static weak var recorder: RecordingController?
    private var terminationPending = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let recorder = Self.recorder, recorder.state.isActive else { return .terminateNow }
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        recorder.stop { [weak self] in self?.allowTermination() }
        // A removed drive/blocked encoder must not make the app impossible to
        // quit. The fragmented file and last saved journal remain on disk.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(15))
            self?.allowTermination()
        }
        return .terminateLater
    }

    private func allowTermination() {
        guard terminationPending else { return }
        terminationPending = false
        NSApplication.shared.reply(toApplicationShouldTerminate: true)
    }
}
