import CoreVideo
import os.lock

/// A10 (issue #122): the per-source video delay lines behind
/// `CompositionEngine.setVideoDelays`.
///
/// Camera and screen captures arrive with different hardware latency than the
/// mics, so a delayed source's frames are HELD here for a bounded number of
/// output ticks before the renderer sees them — the video reading of "delay
/// the earlier side" (the audio reading is the mix engine's ring read offset).
///
/// **Bounds.** A line holds at most `delayFrames + 1` buffers, and
/// `delayFrames` is clamped upstream to `AVSyncDelay.maxVideoDelayMs` at the
/// engine's fps (≤ 31 buffers at 60 fps), so the worst-case memory cost is a
/// fixed, documented number of pool buffers per delayed source. A source with
/// no configured delay takes the zero-overhead passthrough — no queue, no
/// retain.
///
/// **Warmup/stall.** Until the line fills, the freshest frame passes through
/// (the delay eases in instead of showing black); if the source stalls, the
/// held window freezes exactly like the undelayed latest-frame holders do.
///
/// Media sources are deliberately NOT delayable here: A02 playout is pulled
/// on the render tick and already rides the shared clock, so holding its
/// frames would only desync its own audio.
final class VideoFrameDelayLines: @unchecked Sendable {
    private struct CameraLine {
        var delayFrames = 0
        var queue: [LatestCameraFrame.Frame] = []
    }

    private struct ScreenLine {
        var delayFrames = 0
        var queue: [CVPixelBuffer] = []
    }

    private var lock = os_unfair_lock_s()
    private var cameraLines: [CaptureSourceKey: CameraLine] = [:]
    private var screenLines: [CaptureSourceKey: ScreenLine] = [:]

    /// Replaces the delay configuration (whole settings map, in OUTPUT
    /// frames). Lines whose delay went to 0 release their held frames; lines
    /// that survive keep their queue, so a delay edit mid-program never
    /// flashes stale content or black.
    func setDelays(_ framesByKey: [CaptureSourceKey: Int]) {
        os_unfair_lock_lock(&lock)
        cameraLines = cameraLines.filter { framesByKey[$0.key, default: 0] > 0 }
        screenLines = screenLines.filter { framesByKey[$0.key, default: 0] > 0 }
        for (key, frames) in framesByKey where frames > 0 {
            switch key {
            case .camera:
                cameraLines[key, default: CameraLine()].delayFrames = frames
            case .screen:
                screenLines[key, default: ScreenLine()].delayFrames = frames
            case .syphon, .media, .appAudio, .web:
                // G08 (issue #115): web widgets composite through the
                // BrowserOverlayFrameStore (not the keyed delay-line read
                // path), so a source-video-delay entry for a web key is a
                // no-op here, exactly like syphon/media/appAudio.
                break
            }
        }
        os_unfair_lock_unlock(&lock)
    }

    /// The camera-frame read the engine's delayed lookup wraps around the raw
    /// provider: push the fresh frame, return the one `delayFrames` ticks old.
    func cameraFrame(for key: CaptureSourceKey,
                     fresh: LatestCameraFrame.Frame?) -> LatestCameraFrame.Frame? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard var line = cameraLines[key], line.delayFrames > 0 else { return fresh }
        if let fresh {
            line.queue.append(fresh)
        }
        if line.queue.count > line.delayFrames + 1 {
            line.queue.removeFirst(line.queue.count - (line.delayFrames + 1))
        }
        cameraLines[key] = line
        if line.queue.count > line.delayFrames {
            return line.queue[0]
        }
        // Warmup (line still filling) or stall (no fresh frame): show the
        // freshest thing we have rather than black.
        return fresh ?? line.queue.last
    }

    /// The screen-frame twin of `cameraFrame(for:fresh:)`.
    func screenFrame(for key: CaptureSourceKey,
                     fresh: CVPixelBuffer?) -> CVPixelBuffer? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard var line = screenLines[key], line.delayFrames > 0 else { return fresh }
        if let fresh {
            line.queue.append(fresh)
        }
        if line.queue.count > line.delayFrames + 1 {
            line.queue.removeFirst(line.queue.count - (line.delayFrames + 1))
        }
        screenLines[key] = line
        if line.queue.count > line.delayFrames {
            return line.queue[0]
        }
        return fresh ?? line.queue.last
    }
}
