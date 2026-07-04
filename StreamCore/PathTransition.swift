import Foundation

/// How a new `NetworkPathSnapshot` relates to the previous one, for reconnect
/// purposes. The classification is the heart of the publishers' path supervision;
/// the Task-based *debounce scheduling* stays per-publisher (cancellation
/// semantics differ), but the DECISION is shared and unit-tested here.
public enum PathTransition: Sendable, Equatable {
    /// Equal to the previous snapshot (NWPathMonitor re-emit on DNS/agent churn).
    case none
    /// First emission — adopt the interface + ceiling, take no reconnect action.
    case baseline
    /// Changed, but only benign metadata (isExpensive/isConstrained/linkQuality):
    /// update the bitrate ceiling, never reconnect.
    case ceilingOnly
    /// The path became unsatisfied — debounce, then pause outbound media.
    case pathLost
    /// The path came back after being unsatisfied — wake the reconnect loop.
    case pathRestored
    /// Both old and new are satisfied but the carrying link changed (Wi-Fi↔5G):
    /// debounce, then recycle onto the new interface.
    case liveHandoff(identity: String)
}

/// The classification plus the three orthogonal flags the publisher acts on.
public struct PathTransitionResult: Sendable, Equatable {
    public var transition: PathTransition
    /// Apply the per-path bitrate ceiling now (`previous == nil || snapshot != previous`).
    public var shouldUpdateCeiling: Bool
    /// This is the first (baseline) emission (`previous == nil`) — seed only.
    public var isBaseline: Bool
    /// Bump the "recent path change" clock that tightens the watchdog: true only
    /// when reachability or the link identity actually changed — NOT for benign
    /// isExpensive/isConstrained/linkQuality metadata flips (which would otherwise
    /// halve the watchdog budget on ordinary radio churn and trip false recycles).
    public var bumpsPathChangeClock: Bool

    public init(transition: PathTransition,
                shouldUpdateCeiling: Bool,
                isBaseline: Bool,
                bumpsPathChangeClock: Bool) {
        self.transition = transition
        self.shouldUpdateCeiling = shouldUpdateCeiling
        self.isBaseline = isBaseline
        self.bumpsPathChangeClock = bumpsPathChangeClock
    }
}

/// Classifies a path update. Mirrors `RTMPPublisher.handlePathUpdate` exactly so
/// both publishers make identical decisions.
public func classifyPathTransition(previous: NetworkPathSnapshot?,
                                   snapshot: NetworkPathSnapshot) -> PathTransitionResult {
    guard let previous else {
        return PathTransitionResult(transition: .baseline,
                                    shouldUpdateCeiling: true,
                                    isBaseline: true,
                                    bumpsPathChangeClock: false)
    }
    guard snapshot != previous else {
        return PathTransitionResult(transition: .none,
                                    shouldUpdateCeiling: false,
                                    isBaseline: false,
                                    bumpsPathChangeClock: false)
    }
    let bumps = snapshot.isSatisfied != previous.isSatisfied
        || snapshot.linkIdentity != previous.linkIdentity
    let transition: PathTransition
    if !snapshot.isSatisfied {
        transition = .pathLost
    } else if !previous.isSatisfied {
        transition = .pathRestored
    } else if snapshot.linkIdentity != previous.linkIdentity {
        transition = .liveHandoff(identity: snapshot.linkIdentity)
    } else {
        transition = .ceilingOnly
    }
    return PathTransitionResult(transition: transition,
                               shouldUpdateCeiling: true,
                               isBaseline: false,
                               bumpsPathChangeClock: bumps)
}

/// Debounce + window constants for path supervision, shared by both publishers.
public enum PathDebounce {
    /// Ordinary app-switch / AP-roam / VPN-agent flaps pass through unsatisfied for
    /// well under a second and must not detach a TCP flow that survives them.
    public static let pathLoss: UInt64 = 1_500_000_000     // 1.5s
    /// A Wi-Fi-edge flap must not tear down a healthy connection twice; genuine
    /// handoffs still beat reactive detection by an order of magnitude.
    public static let handoff: UInt64 = 500_000_000        // 0.5s
    /// For this long after a path change the watchdog's stall tolerance halves —
    /// the old flow is known-suspect, so a genuine stall should recycle fast.
    public static let recentPathChangeWindow: UInt64 = 10_000_000_000  // 10s
}
