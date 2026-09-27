import os

/// Bounded video-frame admission under outbound congestion. HaishinKit's RTMP/SRT
/// send queue is unbounded, so when the uplink can't drain it, SHEDDING input
/// video frames (proportional to how deep the queue is) keeps glass-to-glass
/// latency bounded instead of letting it grow to seconds and then hard-recycling.
/// Audio is never dropped. The depth is refreshed ~every 2s from the real socket
/// queue by each publisher's watchdog; this is the fast, coarse bound that
/// complements the encoder-level bitrate/frame-rate reductions the ABR already
/// applies.
///
/// Lives in StreamCore (transport-agnostic, no HaishinKit dependency) so both the
/// RTMP publisher and the unified SRT/WHIP session publisher share one admission
/// policy, and the queue→pacing tiers are unit-tested on CI.
public final class VideoFrameAdmission: @unchecked Sendable {
    private struct State { var keep = 1; var period = 1; var counter = 0 }
    private let lock = OSAllocatedUnfairLock<State>(initialState: State())

    public init() {}

    /// Maps outbound queue depth to a keep/period frame-pacing ratio.
    public func setQueueDepth(_ bytes: Int) {
        let keep: Int, period: Int
        switch bytes {
        case ..<524_288:   (keep, period) = (1, 1)  // < 0.5 MB: keep every frame
        case ..<1_048_576: (keep, period) = (2, 3)  // 0.5-1 MB: drop 1 in 3
        case ..<2_097_152: (keep, period) = (1, 2)  // 1-2 MB: drop 1 in 2
        default:           (keep, period) = (1, 3)  // > 2 MB: drop 2 in 3
        }
        lock.withLock { state in
            if state.period != period { state.counter = 0 }
            state.keep = keep
            state.period = period
        }
    }

    /// True when this video frame should be encoded and sent.
    public func admit() -> Bool {
        lock.withLock { state in
            guard state.period > 1 else { return true }
            let keep = state.counter % state.period < state.keep
            state.counter &+= 1
            return keep
        }
    }

    public func reset() {
        lock.withLock { $0 = State() }
    }
}
