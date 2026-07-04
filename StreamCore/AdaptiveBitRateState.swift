/// The apply signal returned by every mutating ABR handler. The pure policy
/// decides WHETHER to touch the encoder and how severe the frame-rate cut is; the
/// actor maps `severe` onto the real HaishinKit VideoCodecSettings constant.
/// `shouldApply == false` models the original `guard !capturePaused { return }`
/// early-returns (counter resets still happen; no setVideoSettings call).
public struct ABRDecision: Sendable, Equatable {
    public var shouldApply: Bool
    public var severe: Bool
    public init(shouldApply: Bool, severe: Bool) {
        self.shouldApply = shouldApply
        self.severe = severe
    }
}

/// The pure adaptive-bitrate decision math extracted from
/// `BroadcastAdaptiveBitRateController` so its reduction / probe / floor rules are
/// unit-tested on CI instead of resting on manual device testing (issue #21). The
/// actor owns HaishinKit application (reading `stream.audioSettings` + calling
/// `stream.setVideoSettings`) and delegates every numeric decision here. Every
/// formula is copied character-for-character from the original controller to
/// preserve the `Double→Int` truncation and `Int` floor-division exactly.
public struct AdaptiveBitRateState: Sendable, Equatable {
    /// Frame-interval constants, bit-identical to HaishinKit's
    /// `VideoCodecSettings.frameInterval30/10` (`(1/30)-0.001` / `(1/10)-0.001`,
    /// which Swift evaluates as Doubles — verified equal `bitPattern`). Kept local
    /// so the pure type needs no HaishinKit import; the ACTOR keeps calling
    /// `abr.frameInterval` so the encoder value stays byte-identical.
    static let frameInterval30 = (1.0 / 30.0) - 0.001   // 0.03233333333333333
    static let frameInterval10 = (1.0 / 10.0) - 0.001   // 0.099

    public let maximumBitRate: Int
    public let minimumBitRate: Int
    public let configuredFrameRate: Int
    public let preferredFrameInterval: Double

    public private(set) var targetBitRate: Int
    public private(set) var healthySeconds = 0
    public private(set) var zeroOutputSeconds = 0
    public private(set) var queueBytes = 0
    public private(set) var congestionActive = false
    public private(set) var capturePaused = false
    public private(set) var pathCeiling: Int
    public private(set) var currentInterface: NetworkPathSnapshot.Interface?
    public private(set) var lastGoodTarget: [NetworkPathSnapshot.Interface: Int] = [:]
    public private(set) var thermalBitRateScale: Double = 1.0
    public private(set) var thermalFrameRateCap: Int = .max

    public init(maximumBitRate: Int, frameRate: Int) {
        self.maximumBitRate = maximumBitRate
        minimumBitRate = max(300_000, maximumBitRate / 10)
        targetBitRate = maximumBitRate
        pathCeiling = maximumBitRate
        // Clamp only to a sane hardware maximum, NOT 30 — a 60 fps stream must keep
        // configuredFrameRate = 60 so the `> 30` congestion tier in frameInterval is
        // reachable.
        let clampedFrameRate = min(max(frameRate, 1), 120)
        configuredFrameRate = clampedFrameRate
        preferredFrameInterval = max(0, (1.0 / Double(clampedFrameRate)) - 0.001)
    }

    /// Folds the per-path ceiling + thermal scale live. NEVER cache this across a
    /// mutation of `pathCeiling`/`thermalBitRateScale`; callers read it fresh after
    /// mutating so an interface change can't silently defeat an active thermal cap.
    public var effectiveMaximum: Int {
        let thermalCeiling = Int(Double(maximumBitRate) * thermalBitRateScale)
        return max(minimumBitRate,
                   min(min(maximumBitRate, pathCeiling), thermalCeiling))
    }

    // MARK: - Event handlers (each mutates state, returns an apply signal)

    /// `.reset`: zero the counters, KEEP the learned target (returning to the
    /// configured maximum caused a congestion/reconnect feedback loop on
    /// constrained Wi-Fi). Always applies. No capturePaused guard (matches source).
    public mutating func onReset() -> ABRDecision {
        healthySeconds = 0
        zeroOutputSeconds = 0
        queueBytes = 0
        return ABRDecision(shouldApply: true, severe: false)
    }

    /// `.publishInsufficientBWOccured`. `audioBitRate` is the LIVE
    /// `stream.audioSettings.bitRate`, passed per-call (never snapshotted).
    public mutating func onInsufficientBandwidth(bytesOutPerSecond: Int,
                                                 queueBytesOut: Int,
                                                 audioBitRate: Int) -> ABRDecision {
        queueBytes = queueBytesOut
        guard !capturePaused else {
            zeroOutputSeconds = 0
            healthySeconds = 0
            return ABRDecision(shouldApply: false, severe: false)
        }
        healthySeconds = 0
        congestionActive = true
        if bytesOutPerSecond > 0 {
            zeroOutputSeconds = 0
            let available = max(0, bytesOutPerSecond * 8 - audioBitRate)
            // Leave substantial headroom for Wi-Fi variance, RTMP overhead, and
            // keyframes instead of targeting the measured ceiling.
            let reduced = Int(Double(available) * 0.65)
            targetBitRate = max(minimumBitRate, min(targetBitRate, reduced))
        } else {
            zeroOutputSeconds += 1
            targetBitRate = max(minimumBitRate, targetBitRate / 2)
        }
        return ABRDecision(shouldApply: true, severe: bytesOutPerSecond == 0)
    }

    /// `.status`. The stall-apply (severe:true) and probe-apply (severe:false) sites
    /// are MUTUALLY EXCLUSIVE within one tick: the stall path requires
    /// bytesOut == 0, which forces `healthySeconds = 0` in the healthy-accounting
    /// `else`, so the `healthySeconds >= 30` probe guard cannot pass the same tick.
    /// A single `ABRDecision` is therefore byte-exact — do NOT collapse the branches.
    public mutating func onStatus(bytesOutPerSecond: Int,
                                  queueBytesOut: Int) -> ABRDecision {
        queueBytes = queueBytesOut
        guard !capturePaused else {
            zeroOutputSeconds = 0
            healthySeconds = 0
            return ABRDecision(shouldApply: false, severe: false)
        }
        var apply = false
        var severe = false
        // Zero output with an empty queue is normal for a paused/static capture; it
        // is a stall only when bytes are waiting to be sent.
        if bytesOutPerSecond == 0, queueBytes > 0 {
            zeroOutputSeconds += 1
            if zeroOutputSeconds >= 2 {
                congestionActive = true
                healthySeconds = 0
                targetBitRate = max(minimumBitRate, targetBitRate / 2)
                apply = true
                severe = true
            }
        } else {
            zeroOutputSeconds = 0
        }
        if queueBytes <= 32 * 1_024, bytesOutPerSecond > 0 {
            healthySeconds += 1
        } else {
            healthySeconds = 0
        }
        // Probe upward only after a sustained clean queue and in small steps.
        guard healthySeconds >= 30 else {
            return ABRDecision(shouldApply: apply, severe: severe)
        }
        healthySeconds = 0
        if targetBitRate < effectiveMaximum {
            targetBitRate = min(effectiveMaximum,
                                targetBitRate + max(75_000, effectiveMaximum / 20))
        } else {
            congestionActive = false
        }
        return ABRDecision(shouldApply: true, severe: false)
    }

    public mutating func onCapturePaused(_ paused: Bool) {
        capturePaused = paused
        healthySeconds = 0
        zeroOutputSeconds = 0
    }

    /// Per-path ceiling + interface seeding. ORDER IS LOAD-BEARING: `raised` is
    /// computed against the OLD `pathCeiling`; `pathCeiling` is assigned BEFORE the
    /// `effectiveMaximum` clamp so the clamp folds in the NEW ceiling + thermal cap.
    public mutating func onPathProfile(ceiling: Int,
                                       interface: NetworkPathSnapshot.Interface,
                                       isBaseline: Bool) -> ABRDecision {
        let clamped = max(minimumBitRate, min(ceiling, maximumBitRate))
        if isBaseline || currentInterface == nil {
            currentInterface = interface
        } else if let current = currentInterface, interface != current {
            lastGoodTarget[current] = targetBitRate
            currentInterface = interface
            let seed = lastGoodTarget[interface] ?? Int(Double(clamped) * 0.6)
            targetBitRate = max(minimumBitRate, min(seed, clamped))
            healthySeconds = 0
            zeroOutputSeconds = 0
        }
        let raised = clamped > pathCeiling
        pathCeiling = clamped
        targetBitRate = min(targetBitRate, effectiveMaximum)
        if raised { healthySeconds = 0 }   // restart the upward probe cleanly
        return ABRDecision(shouldApply: true, severe: false)
    }

    /// Store a thermal/Low-Power ceiling and clamp the current target to it. MUST
    /// NOT touch `healthySeconds` — resetting it on every thermal flap across a
    /// boundary would keep restarting the up-probe and starve recovery.
    public mutating func onThermalCeiling(bitRateScale: Double, frameRateCap: Int) {
        thermalBitRateScale = min(max(bitRateScale, 0.1), 1.0)
        thermalFrameRateCap = max(1, frameRateCap)
        targetBitRate = min(targetBitRate, effectiveMaximum)
    }

    // MARK: - Pure readouts

    /// The frame interval for the current congestion + thermal state; `max()` yields
    /// the more restrictive (lower fps) of the two.
    public func frameInterval(severe: Bool) -> Double {
        let congestionInterval: Double
        if severe {
            congestionInterval = Self.frameInterval10
        } else if congestionActive, configuredFrameRate > 30 {
            congestionInterval = Self.frameInterval30
        } else {
            congestionInterval = preferredFrameInterval
        }
        let cappedFrameRate = max(1, min(configuredFrameRate, thermalFrameRateCap))
        let thermalInterval = max(0, (1.0 / Double(cappedFrameRate)) - 0.001)
        return max(congestionInterval, thermalInterval)
    }

    /// The effective encode frame rate (fps), folding the same congestion + thermal
    /// caps as `frameInterval` (most-restrictive wins).
    public func currentFrameRate() -> Int {
        let congestionFps = (congestionActive && configuredFrameRate > 30) ? 30 : configuredFrameRate
        let thermalFps = max(1, min(configuredFrameRate, thermalFrameRateCap))
        return min(congestionFps, thermalFps)
    }
}
