import Foundation

/// The resolution and frame-rate ceiling a *device* can sustain for the whole
/// in-app pipeline (ScreenCaptureKit capture → optional facecam compositing →
/// H.264 encode → RTMP/SRT/WHIP publish, all in one process).
///
/// This replaces the old hard `maxStreamShortEdge = 720` / `min(fps, 30)`
/// constants that made the headline 1080p60 target unreachable. The ceiling is
/// derived from real device signals (core count + physical memory) so a capable
/// phone unlocks 1080p60 while an older one stays at a safe 720p30. The
/// *thermal* half of "capability" is layered on top at runtime by
/// `ThermalPowerGovernor` + the adaptive controller, which pull the live rate
/// back below this static ceiling whenever the device runs warm or low on power.
///
/// The derivation is a pure function of injected values (`device(processorCount:
/// physicalMemory:)`) so it is deterministic and unit-testable on CI, which runs
/// the StreamCore suite on whatever simulator the runner ships. Only `current`
/// reads the live `ProcessInfo`, and that is used exclusively by the app.
public struct StreamCapability: Equatable, Sendable {
    /// Largest encoded SHORT edge (px) this device may stream. The long edge
    /// follows the screen's real aspect ratio. 1080 on capable devices, else 720.
    public let maxShortEdge: Int
    /// Highest encoded frame rate (fps) this device may stream. 60 on capable
    /// devices, else 30. The thermal governor caps this further at runtime.
    public let maxFrameRate: Int

    public init(maxShortEdge: Int, maxFrameRate: Int) {
        self.maxShortEdge = maxShortEdge
        self.maxFrameRate = maxFrameRate
    }

    // MARK: - Device signal thresholds

    /// ≈6 GB+ of RAM (reported physical memory sits a little under the nominal
    /// spec, so 5.0 GB is a safe divider between 4 GB and 6 GB devices). Devices
    /// at or above this — iPhone 14 Pro / 15 / 16 / 17-class and recent iPad
    /// Pro/Air — have the memory headroom to run capture + compositing + a real
    /// 1080p60 encoder without tripping jetsam.
    static let highMemoryFloor: UInt64 = 5_000_000_000
    /// ≈4 GB of RAM (3.3 GB divider sits between the ~2.9 GB a 3 GB device
    /// reports and the ~3.7 GB a 4 GB device reports). Enough for 1080p30, but
    /// not the doubled encoder + capture load of 60 fps.
    static let midMemoryFloor: UInt64 = 3_300_000_000
    /// 1080p60's encoder throughput needs the full performance-core complement;
    /// every 6 GB+ iPhone and iPad reports at least this many logical cores.
    static let highCoreFloor = 6

    // MARK: - Derivation

    /// Derives the ceiling from device signals. Resolution and frame rate are
    /// gated independently so a mid-tier device still gets 1080p (at 30 fps)
    /// rather than being dropped all the way to 720p:
    ///
    /// - 6 GB+ & ≥6 cores → **1080p60** (the headline target)
    /// - 4 GB            → **1080p30**
    /// - ≤3 GB           → **720p30**
    ///
    /// Deliberately conservative: the thermal governor can only pull the rate
    /// *down* from here, so the ceiling must be a rate the device can actually
    /// hold when cool, not an aspirational peak.
    public static func device(
        processorCount: Int = ProcessInfo.processInfo.processorCount,
        physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> StreamCapability {
        let maxShortEdge = physicalMemory >= midMemoryFloor ? 1080 : 720
        let maxFrameRate = (physicalMemory >= highMemoryFloor && processorCount >= highCoreFloor)
            ? 60 : 30
        return StreamCapability(maxShortEdge: maxShortEdge, maxFrameRate: maxFrameRate)
    }

    /// This device's ceiling, computed once from the live `ProcessInfo`. Used by
    /// the app (encoder, capture pacing, and the Settings pickers). Tests use
    /// `device(processorCount:physicalMemory:)` with injected values instead so
    /// they never depend on the CI runner's hardware.
    public static let current = device()
}
