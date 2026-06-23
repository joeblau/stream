import CoreVideo
import os.lock

/// Holds only the single most recent camera pixel buffer. Older frames are
/// dropped (never queued) to respect the broadcast extension's ~50MB memory
/// budget. Access is serialized with an `os_unfair_lock`, which is why the
/// class can safely be marked `@unchecked Sendable`.
final class LatestCameraFrame: @unchecked Sendable {
    private var lock = os_unfair_lock_s()
    private var buffer: CVPixelBuffer?

    init() {}

    /// Called from the `AVCaptureVideoDataOutput` delegate queue. Replaces any
    /// previously stored frame; the old frame is released immediately.
    func store(_ pixelBuffer: CVPixelBuffer) {
        os_unfair_lock_lock(&lock)
        buffer = pixelBuffer
        os_unfair_lock_unlock(&lock)
    }

    /// Called from the ReplayKit `processSampleBuffer` queue. Returns the most
    /// recent frame (retained reference) and clears the slot so a stale frame is
    /// not reused on the next screen frame if the camera has stalled.
    func take() -> CVPixelBuffer? {
        os_unfair_lock_lock(&lock)
        let b = buffer
        os_unfair_lock_unlock(&lock)
        return b
    }

    /// Drops any stored frame (used during teardown).
    func clear() {
        os_unfair_lock_lock(&lock)
        buffer = nil
        os_unfair_lock_unlock(&lock)
    }
}
