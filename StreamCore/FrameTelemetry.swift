import Foundation
import os

/// The four silent frame-shedding sites in the capture→encode pipeline, each of
/// which historically dropped a frame with no counter (issue #23 / M8). Kept
/// separate because they mean different things:
///
/// - `pacing`: the native-refresh screen feed downsampled to the target fps by the
///   PTS-deadline throttle. INTENTIONAL — it is how a 120 Hz ProMotion feed becomes
///   a 30/60 fps stream, so it dwarfs the others and is never a fault signal.
/// - `backpressure`: the `bufferingNewest(1)` capture→consumer hand-off evicting a
///   frame the consumer hadn't drained yet — the compositor/append stage can't keep
///   up with capture.
/// - `compositor`: the facecam compositor's pixel-buffer pool was exhausted (a slow
///   encoder holding surfaces), so the overlay was skipped and the raw screen frame
///   was sent instead. The frame still reaches the encoder; only the overlay dropped.
/// - `admission`: `VideoFrameAdmission` shed the frame under outbound congestion so
///   uplink latency stays bounded. The frame never reaches the encoder.
///
/// `backpressure` + `admission` are the "congestion" drops: a frame the pipeline
/// WANTED to encode but couldn't. Those are the fault signal surfaced in the HUD
/// and available to the adaptive logic; `pacing` and `compositor` are tracked for
/// completeness but excluded from the congestion total.
public enum FrameDropReason: Sendable, Equatable, CaseIterable {
    case pacing
    case backpressure
    case compositor
    case admission
}

/// A cumulative, immutable readout of the frame pipeline for one broadcast. All
/// counts are monotonic session totals; rates are derived from the delta between
/// two snapshots (see `FrameTelemetry.rate`).
public struct FrameTelemetrySnapshot: Equatable, Sendable {
    /// Screen frames delivered by ScreenCaptureKit, before any pacing/shedding.
    public var captured: Int
    /// Frames actually appended to the encoder (real frames + frame-repeats that
    /// hold a steady rate on a static screen), post-admission. The basis for
    /// achieved fps.
    public var encoded: Int
    public var pacingDrops: Int
    public var backpressureDrops: Int
    public var compositorDrops: Int
    public var admissionDrops: Int

    public init(captured: Int = 0,
                encoded: Int = 0,
                pacingDrops: Int = 0,
                backpressureDrops: Int = 0,
                compositorDrops: Int = 0,
                admissionDrops: Int = 0) {
        self.captured = captured
        self.encoded = encoded
        self.pacingDrops = pacingDrops
        self.backpressureDrops = backpressureDrops
        self.compositorDrops = compositorDrops
        self.admissionDrops = admissionDrops
    }

    /// Frames the pipeline wanted to encode but shed because it couldn't keep up
    /// (backpressure) or the uplink was congested (admission). The HUD + adaptive
    /// signal — pacing (intentional downsample) and compositor (overlay-only, frame
    /// still sent) are deliberately excluded.
    public var congestionDrops: Int { backpressureDrops + admissionDrops }

    /// Every shed frame across all four sites, for diagnostics.
    public var totalDrops: Int {
        pacingDrops + backpressureDrops + compositorDrops + admissionDrops
    }

    public func count(of reason: FrameDropReason) -> Int {
        switch reason {
        case .pacing:       return pacingDrops
        case .backpressure: return backpressureDrops
        case .compositor:   return compositorDrops
        case .admission:    return admissionDrops
        }
    }
}

/// Derived per-second rates between two `FrameTelemetrySnapshot`s.
public struct FrameTelemetryRates: Equatable, Sendable {
    /// Measured encode rate (frames/sec reaching the encoder) — the real fps the
    /// stream is achieving, distinct from the ABR's target fps.
    public var achievedFrameRate: Int
    /// Congestion frames (backpressure + admission) shed per second — a fast
    /// keep-up signal for the adaptive logic (M9).
    public var congestionDropsPerSecond: Int

    public init(achievedFrameRate: Int, congestionDropsPerSecond: Int) {
        self.achievedFrameRate = achievedFrameRate
        self.congestionDropsPerSecond = congestionDropsPerSecond
    }
}

/// Thread-safe cumulative counters for the capture→encode frame pipeline, shared
/// between the (serial sample-queue) capture output and the publisher actor so the
/// controller can read one snapshot per ~1 Hz telemetry poll. Mirrors
/// `VideoFrameAdmission`'s `OSAllocatedUnfairLock` pattern: a lock acquisition per
/// recorded frame is negligible next to per-frame CoreImage/VideoToolbox work.
///
/// Lives in StreamCore (transport-agnostic, no HaishinKit/ScreenCaptureKit
/// dependency) so the counting and the rate math are unit-tested on CI, where the
/// iOS 27 app itself can't build.
public final class FrameTelemetry: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: FrameTelemetrySnapshot())

    public init() {}

    /// A screen frame arrived from ScreenCaptureKit (counted before pacing/shedding).
    public func recordCaptured() {
        state.withLock { $0.captured &+= 1 }
    }

    /// A frame was appended to the encoder (real or frame-repeat), post-admission.
    public func recordEncoded() {
        state.withLock { $0.encoded &+= 1 }
    }

    public func recordDrop(_ reason: FrameDropReason) {
        state.withLock { snapshot in
            switch reason {
            case .pacing:       snapshot.pacingDrops &+= 1
            case .backpressure: snapshot.backpressureDrops &+= 1
            case .compositor:   snapshot.compositorDrops &+= 1
            case .admission:    snapshot.admissionDrops &+= 1
            }
        }
    }

    public func snapshot() -> FrameTelemetrySnapshot {
        state.withLock { $0 }
    }

    public func reset() {
        state.withLock { $0 = FrameTelemetrySnapshot() }
    }

    /// Pure rate math (static so it is trivially unit-tested): the per-second
    /// achieved fps and congestion-drop rate between an earlier and a later
    /// snapshot over `elapsed` seconds. A non-positive or too-small `elapsed`
    /// (clock hiccup, first poll) yields zero rather than a divide-by-zero spike;
    /// counter deltas are floored at zero so a `reset()` between samples can't go
    /// negative.
    public static func rate(from previous: FrameTelemetrySnapshot,
                            to current: FrameTelemetrySnapshot,
                            elapsed: TimeInterval) -> FrameTelemetryRates {
        guard elapsed >= 0.2 else {
            return FrameTelemetryRates(achievedFrameRate: 0, congestionDropsPerSecond: 0)
        }
        let encodedDelta = max(0, current.encoded - previous.encoded)
        let congestionDelta = max(0, current.congestionDrops - previous.congestionDrops)
        let fps = Int((Double(encodedDelta) / elapsed).rounded())
        let drops = Int((Double(congestionDelta) / elapsed).rounded())
        return FrameTelemetryRates(achievedFrameRate: max(0, fps),
                                   congestionDropsPerSecond: max(0, drops))
    }
}
