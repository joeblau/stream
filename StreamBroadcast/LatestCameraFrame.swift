import CoreVideo
import Dispatch
import os.lock

/// Holds only the single most recent camera pixel buffer. Older frames are
/// dropped rather than queued to bound memory. Access is serialized with an
/// `os_unfair_lock`, which is why the
/// class can safely be marked `@unchecked Sendable`.
final class LatestCameraFrame: @unchecked Sendable {
    /// Keep a camera frame across faster screen frames, but stop reusing it soon
    /// after camera capture stalls or is disabled.
    private static let maximumAgeNanoseconds: UInt64 = 500_000_000

    private var lock = os_unfair_lock_s()
    private var buffer: CVPixelBuffer?
    private var storedAt: UInt64 = 0

    init() {}

    /// Called from the `AVCaptureVideoDataOutput` delegate queue. Replaces any
    /// previously stored frame; the old frame is released immediately.
    func store(_ pixelBuffer: CVPixelBuffer) {
        let now = DispatchTime.now().uptimeNanoseconds
        os_unfair_lock_lock(&lock)
        buffer = pixelBuffer
        storedAt = now
        os_unfair_lock_unlock(&lock)
    }

    /// Called from the ScreenCaptureKit sample consumer. Returns the most
    /// recent frame while it is fresh. Unlike a destructive take, this lets a
    /// 30 fps camera feed a 60 fps screen stream without alternating PiP on/off.
    func freshest() -> CVPixelBuffer? {
        let now = DispatchTime.now().uptimeNanoseconds
        os_unfair_lock_lock(&lock)
        let result: CVPixelBuffer?
        if let buffer, now &- storedAt <= Self.maximumAgeNanoseconds {
            result = buffer
        } else {
            buffer = nil
            storedAt = 0
            result = nil
        }
        os_unfair_lock_unlock(&lock)
        return result
    }

    /// Drops any stored frame (used during teardown).
    func clear() {
        os_unfair_lock_lock(&lock)
        buffer = nil
        storedAt = 0
        os_unfair_lock_unlock(&lock)
    }
}
