import CoreVideo
import CoreMedia
import Dispatch
import Foundation
import StreamCore
import os.lock

/// Holds only the single most recent camera pixel buffer. Older frames are
/// dropped rather than queued to bound memory. Access is serialized with an
/// `os_unfair_lock`, which is why the
/// class can safely be marked `@unchecked Sendable`.
final class LatestCameraFrame: @unchecked Sendable {
    /// A camera frame together with the physical camera that produced it.
    ///
    /// The two consumers (the on-screen preview and the broadcast compositor)
    /// mirror the front camera and leave the back camera alone. Deriving that from
    /// `StreamSettings.cameraPosition` is wrong for the few hundred milliseconds a
    /// flip takes: the setting changes the instant the user taps, while the buffer
    /// on hand is still the *old* camera's. Carrying the position with the pixels
    /// keeps the mirroring correct throughout the swap.
    struct Frame {
        let buffer: CVPixelBuffer
        let position: CameraPosition
        let presentationTime: CMTime
        init(buffer: CVPixelBuffer, position: CameraPosition, presentationTime: CMTime = .invalid) {
            self.buffer = buffer; self.position = position; self.presentationTime = presentationTime
        }
    }

    /// Keep a camera frame across faster screen frames, but stop reusing it soon
    /// after camera capture stalls or is disabled.
    private static let maximumAgeNanoseconds: UInt64 = 500_000_000

    let deliveryTelemetry = FrameTelemetry()
    let captureClock = AVClockTelemetry()
    private var lock = os_unfair_lock_s()
    private var buffer: CVPixelBuffer?
    private var position: CameraPosition = .front
    private var presentationTime: CMTime = .invalid
    private var storedAt: UInt64 = 0
    #if os(macOS)
    private let recordingHistory = RecordingSourceHistory<Frame>()
    #endif

    init() {}

    /// Called from the `AVCaptureVideoDataOutput` delegate queue. Replaces any
    /// previously stored frame; the old frame is released immediately.
    func store(_ pixelBuffer: CVPixelBuffer, position: CameraPosition, presentationTime: CMTime = .invalid) {
        let now = DispatchTime.now().uptimeNanoseconds
        if presentationTime.isNumeric { captureClock.record(.video, presentationSeconds: presentationTime.seconds) }
        os_unfair_lock_lock(&lock)
        buffer = pixelBuffer
        self.position = position
        self.presentationTime = presentationTime
        storedAt = now
        #if os(macOS)
        recordingHistory.append(Frame(buffer: pixelBuffer, position: position, presentationTime: presentationTime),
                                time: presentationTime, byteCount: CVPixelBufferGetDataSize(pixelBuffer))
        #endif
        deliveryTelemetry.recordCaptured()
        os_unfair_lock_unlock(&lock)
    }

    /// Called from the ScreenCaptureKit sample consumer. Returns the most
    /// recent frame while it is fresh. Unlike a destructive take, this lets a
    /// 30 fps camera feed a 60 fps screen stream without alternating PiP on/off.
    func freshest() -> Frame? {
        let now = DispatchTime.now().uptimeNanoseconds
        os_unfair_lock_lock(&lock)
        let result: Frame?
        if let buffer, now &- storedAt <= Self.maximumAgeNanoseconds {
            result = Frame(buffer: buffer, position: position, presentationTime: presentationTime)
        } else {
            buffer = nil
            presentationTime = .invalid
            storedAt = 0
            #if os(macOS)
            recordingHistory.clear()
            #endif
            result = nil
        }
        os_unfair_lock_unlock(&lock)
        return result
    }

    #if os(macOS)
    func acquireRecordingHistory() -> RecordingSourceHistoryLease {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        let lease = recordingHistory.acquire()
        if let buffer {
            recordingHistory.append(Frame(buffer: buffer, position: position, presentationTime: presentationTime),
                                    time: presentationTime, byteCount: CVPixelBufferGetDataSize(buffer))
        }
        return lease
    }
    func recordingFrame(at time: CMTime) -> Frame? { recordingHistory.frame(at: time, maximumAge: 0.5) }
    #endif

    /// Drops any stored frame (used during teardown).
    func clear() {
        captureClock.reset()
        os_unfair_lock_lock(&lock)
        buffer = nil
        presentationTime = .invalid
        storedAt = 0
        #if os(macOS)
        recordingHistory.clear()
        #endif
        os_unfair_lock_unlock(&lock)
    }
}

#if os(macOS)
/// Enabled only by active Mac ISO consumers. Ordinary Program/iOS capture
/// keeps the original latest-only ownership. Leases share one bounded history.
final class RecordingSourceHistoryLease: @unchecked Sendable {
    private let release: @Sendable () -> Void
    init(release: @escaping @Sendable () -> Void) { self.release = release }
    deinit { release() }
}
final class RecordingSourceHistory<Frame>: @unchecked Sendable {
    private struct Entry { let frame: Frame; let time: CMTime; let bytes: Int }
    private let lock = NSLock()
    private var consumers: Set<UUID> = []
    private var frames: [Entry] = []
    private var bytes = 0
    private let maximumBytes = 96 * 1_024 * 1_024
    func acquire() -> RecordingSourceHistoryLease {
        let token = UUID(); lock.lock(); consumers.insert(token); lock.unlock()
        return RecordingSourceHistoryLease { [self] in
            lock.lock(); consumers.remove(token)
            if consumers.isEmpty { frames.removeAll(); bytes = 0 }
            lock.unlock()
        }
    }
    func append(_ frame: Frame, time: CMTime, byteCount: Int) {
        lock.lock(); defer { lock.unlock() }
        guard !consumers.isEmpty else { return }
        guard time.isNumeric, byteCount <= maximumBytes else { frames.removeAll(); bytes = 0; return }
        if let last = frames.last {
            if time == last.time { return }
            if time < last.time { frames.removeAll(); bytes = 0 }
        }
        frames.append(.init(frame: frame,time: time,bytes: byteCount)); bytes += byteCount
        while frames.count > 8 || bytes > maximumBytes { bytes -= frames.removeFirst().bytes }
    }
    func frame(at time: CMTime, maximumAge: Double? = nil) -> Frame? {
        lock.lock(); defer { lock.unlock() }
        guard time.isNumeric, let selected = frames.last(where: { $0.time <= time }),
              maximumAge.map({ (time-selected.time).seconds <= $0 }) ?? true else { return nil }
        return selected.frame
    }
    func clear() { lock.lock(); frames.removeAll(); bytes = 0; lock.unlock() }
}
#endif
