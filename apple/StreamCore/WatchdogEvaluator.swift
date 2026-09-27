import Foundation

/// Rolling state for the outbound-queue stall watchdog, threaded across ~2s ticks.
public struct WatchdogState: Sendable, Equatable {
    /// Consecutive ticks the socket looked stalled. Recycle fires at the threshold.
    public var stalledTicks: Int
    /// Previous tick's queue depth, to detect a *growing* (not merely frozen) backlog.
    public var lastQueueBytes: Int

    public init(stalledTicks: Int = 0, lastQueueBytes: Int = 0) {
        self.stalledTicks = stalledTicks
        self.lastQueueBytes = lastQueueBytes
    }
}

/// The watchdog's decision for one tick.
public struct WatchdogDecision: Sendable, Equatable {
    /// Recycle the socket now (the queue is genuinely wedged).
    public var shouldRecycle: Bool
    /// The stalled-tick count that triggered the decision, for logging.
    public var stalledTicks: Int
    /// The queue depth to feed `VideoFrameAdmission.setQueueDepth`.
    public var queueDepthBytes: Int

    public init(shouldRecycle: Bool, stalledTicks: Int, queueDepthBytes: Int) {
        self.shouldRecycle = shouldRecycle
        self.stalledTicks = stalledTicks
        self.queueDepthBytes = queueDepthBytes
    }
}

/// The pure arithmetic of the outbound-queue stall watchdog, shared by both
/// publishers. The transport-touching guards (`connection.connected`,
/// `readyState`, `isPaused`, media freshness, mic-stall) stay in each publisher;
/// this is only the queue/stall math extracted from `RTMPPublisher.checkNetworkHealth`.
public enum WatchdogEvaluator {
    /// One tick. `recentPathChange` (computed by the caller from its own
    /// `lastPathChangeAt` + `PathDebounce.recentPathChangeWindow`) halves the
    /// tolerance. Mutates `state` in place and returns the recycle decision.
    ///
    /// Rules, byte-for-byte with the RTMP original:
    /// - `queueStuck` requires the backlog to be at/above the limit AND STRICTLY
    ///   GROWING (`>`), not merely frozen (`>=`) — a backgrounded app freezes the
    ///   ~1Hz telemetry, and a frozen-equal read must NOT be treated as a stall.
    /// - `zeroOutputSeconds` at/above its limit is an independent stall signal.
    /// - a stall must PERSIST `ticksToRecycle` ticks before recycling (a survivable
    ///   `.waiting` blip recovers on the same socket).
    /// - `eventAgeSeconds` is deliberately NOT an input: it freezes on backgrounding.
    public static func evaluate(queueBytes: Int,
                                zeroOutputSeconds: Int,
                                recentPathChange: Bool,
                                state: inout WatchdogState) -> WatchdogDecision {
        let queueLimit = recentPathChange ? 2_000_000 : 4_000_000
        let zeroLimit = recentPathChange ? 2 : 4
        let queueStuck = queueBytes >= queueLimit && queueBytes > state.lastQueueBytes
        state.lastQueueBytes = queueBytes
        if queueStuck || zeroOutputSeconds >= zeroLimit {
            state.stalledTicks += 1
        } else {
            state.stalledTicks = 0
        }
        let ticksToRecycle = recentPathChange ? 3 : 6
        let stalledTicks = state.stalledTicks
        let shouldRecycle = stalledTicks >= ticksToRecycle
        if shouldRecycle { state.stalledTicks = 0 }
        return WatchdogDecision(shouldRecycle: shouldRecycle,
                                stalledTicks: stalledTicks,
                                queueDepthBytes: queueBytes)
    }
}
