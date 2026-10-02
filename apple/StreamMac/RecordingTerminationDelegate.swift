import AppKit

/// A normal Quit waits for the writer instead of letting SwiftUI destroy it
/// while finishWriting is in flight. Forced termination retains completed movie
/// fragments and the journal; recovery still depends on the bytes on disk.
@MainActor
final class RecordingTerminationDelegate: NSObject, NSApplicationDelegate {
    static weak var recorder: RecordingController?
    static var finishSession: (@MainActor () async -> Void)?
    private var finalizing = false
    private var terminationPending = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard Self.recorder?.state.isActive == true || Self.finishSession != nil else { return .terminateNow }
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        if let recorder = Self.recorder, recorder.state.isActive {
            recorder.stop { [weak self] in Task { @MainActor in await self?.finalizeTermination() } }
        } else { Task { @MainActor [weak self] in await self?.finalizeTermination() } }
        // A removed drive/blocked encoder must not make the app impossible to
        // quit. The fragmented file and last saved journal remain on disk.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(15))
            await self?.finalizeTermination()
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(22))
            self?.allowTermination()
        }
        return .terminateLater
    }

    private func finalizeTermination() async {
        guard terminationPending, !finalizing else { return }
        finalizing = true
        await Self.finishSession?()
        allowTermination()
    }

    private func allowTermination() {
        guard terminationPending else { return }
        terminationPending = false
        NSApplication.shared.reply(toApplicationShouldTerminate: true)
    }
}
