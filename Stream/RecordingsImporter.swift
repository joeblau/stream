import Foundation
import Photos
import StreamCore

/// Saves finished local HD backup recordings from the shared App Group container
/// into the user's Photos library so they can repost a broadcast even if the live
/// stream died.
///
/// Saving is USER-INITIATED: the app surfaces a "Save to Photos" button that is
/// enabled only when there are finished recordings waiting, and Photos permission
/// is requested at the moment the user taps it — never silently on launch.
///
/// `@MainActor @Observable`: drives the status row/button in the UI (mirrors the
/// existing `AudioInputProvider` / `CameraSupport` pattern).
@MainActor
@Observable
final class RecordingsImporter {

    enum Status: Equatable {
        case idle
        case importing
        case saved(Int)          // number saved on the most recent pass
        case needsPhotosAccess   // add-only permission denied/restricted
        case failed
    }

    private(set) var status: Status = .idle
    /// Finished recordings still waiting in the container (not yet in Photos).
    private(set) var pendingCount: Int = 0

    private let store = RecordingStore()
    private var isRunning = false

    /// Recomputes how many finished recordings are waiting. Cheap (a directory
    /// scan) and touches no Photos APIs, so it is safe to call on every foreground
    /// to keep the Save button's enabled/disabled state current.
    func refreshPendingCount() {
        pendingCount = store.pendingRecordings(now: Date()).count
    }

    /// Requests add-only Photos access (this is when we ask) and saves every
    /// finished backup, deleting each local copy on success. Safe to call
    /// repeatedly; only one pass runs at a time and anything left behind is
    /// retried on the next tap.
    func importPending() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        let pending = store.pendingRecordings(now: Date())
        pendingCount = pending.count
        guard !pending.isEmpty else { status = .idle; return }

        // Add-only access is sufficient to write videos and is the least-
        // privileged prompt we can show.
        let auth = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard auth == .authorized || auth == .limited else {
            status = .needsPhotosAccess
            return
        }

        status = .importing
        var saved = 0
        for url in pending {
            do {
                try await Self.saveVideoToPhotos(url)
                store.remove(url)
                saved += 1
            } catch {
                // Leave this file in place; it'll be retried on the next tap.
            }
        }
        refreshPendingCount()
        status = saved > 0 ? .saved(saved) : .failed
    }

    /// Performs the Photos write from a NON-isolated context.
    ///
    /// PhotoKit invokes the change block on its own private background queue. If
    /// the block inherited this type's `@MainActor` isolation, Swift's executor
    /// check (`swift_task_isCurrentExecutor`) traps with `dispatch_assert_queue_fail`
    /// (SIGTRAP) the instant PhotoKit runs it off the main thread — which is the
    /// crash that happened whenever there was a video to save. Marking this
    /// `nonisolated` keeps the change block actor-agnostic so it runs safely on
    /// PhotoKit's queue. `url` is `Sendable`.
    nonisolated private static func saveVideoToPhotos(_ url: URL) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
    }
}
