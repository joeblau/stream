import Foundation

// E03 (issue #164): capability-gated background blur / replacement through
// Vision person segmentation.
//
// This file holds the PLATFORM-INDEPENDENT half of the feature so it is
// unit-testable in the StreamCore suite (which runs on an iOS simulator on
// CI): the persisted settings model, the capability matrix derivation, and
// the frame-cost governor that protects cadence at runtime. The Vision/CIFilter
// execution half lives in StreamMac (`PersonSegmentation.swift`,
// `SceneRenderer`).

/// What happens to the background behind the segmented person.
public enum BackgroundEffectMode: String, Codable, CaseIterable, Sendable {
    /// No segmentation work at all (the render no-op).
    case off
    /// The person composites over a Gaussian-blurred copy of the source.
    case blur
    /// The person composites over a solid-color backdrop
    /// (`BackgroundEffectSettings.replacementColorHex`).
    case replacement

    public var displayName: String {
        switch self {
        case .off: return "Off"
        case .blur: return "Blur"
        case .replacement: return "Replace"
        }
    }
}

/// The performance/quality control: maps to
/// `VNGeneratePersonSegmentationRequest.QualityLevel` on the render side.
/// Ordered cheapest → costliest.
public enum SegmentationQuality: String, Codable, CaseIterable, Sendable {
    /// Smallest mask, lowest cost — the tier every supported device can hold.
    case fast
    case balanced
    /// Full-resolution mask, highest cost — only worth it where the frame
    /// budget has room (see `SegmentationCapabilityMatrix`).
    case accurate

    public var displayName: String {
        switch self {
        case .fast: return "Fast"
        case .balanced: return "Balanced"
        case .accurate: return "Accurate"
        }
    }

    /// One step cheaper, or nil at the floor.
    public var cheaper: SegmentationQuality? {
        switch self {
        case .accurate: return .balanced
        case .balanced: return .fast
        case .fast: return nil
        }
    }
}

/// The persisted background-effect configuration of one source effect stack
/// (E03 rides E01's `SourceEffects` — layer overrides, source defaults, and
/// presets all carry this value). Additive wire format: every field decodes
/// with its default, so documents written before E03 keep loading.
public struct BackgroundEffectSettings: Hashable, Codable, Sendable {
    /// Off = no segmentation cost, source renders untouched.
    public var mode: BackgroundEffectMode = .off
    /// Requested segmentation quality; the runtime governor may hold the
    /// EFFECTIVE quality below this to protect frame cadence.
    public var quality: SegmentationQuality = .balanced
    /// 0...1. Blur mode: fraction of the maximum blur radius. Replacement
    /// mode: mask edge-feather fraction (softens the person cut-out).
    public var strength: Double = 0.5
    /// Backdrop color for replacement mode (parsed like scene background
    /// colors; unparsable values render as a neutral dark gray downstream).
    public var replacementColorHex: String = "#1A1A1A"

    public init() {}

    /// Additive decode: absent fields fall back to defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decodeIfPresent(BackgroundEffectMode.self, forKey: .mode) ?? .off
        quality = try container.decodeIfPresent(SegmentationQuality.self, forKey: .quality) ?? .balanced
        strength = try container.decodeIfPresent(Double.self, forKey: .strength) ?? 0.5
        replacementColorHex = try container.decodeIfPresent(String.self, forKey: .replacementColorHex)
            ?? "#1A1A1A"
    }

    /// True when enabling this value costs segmentation work.
    public var isEnabled: Bool { mode != .off }

    /// The value with every field in its documented range.
    public func clamped() -> BackgroundEffectSettings {
        var copy = self
        copy.strength = min(1, max(0, strength))
        return copy
    }

    /// The rejection reason for an invalid value, or nil (the dispatcher
    /// rejects invalid values through E01's existing `validationError` path).
    public var validationError: String? {
        if !strength.isFinite { return "Background effect strength must be a finite number." }
        if !(0...1).contains(strength) { return "Background effect strength must be between 0 and 1." }
        return nil
    }
}

// MARK: - Capability matrix

/// The tested capability matrix for E03: which person-segmentation quality
/// levels this device can hold at a target frame rate, derived as a pure
/// function of injected device signals (the `StreamCapability` precedent), so
/// CI pins it without depending on the runner's hardware. The Vision and
/// CIFilter work itself is public-API-only (`VNGeneratePersonSegmentationRequest`
/// + CIGaussianBlur/CIBlendWithMask); system camera effects (Control Center
/// Portrait/Studio Light, reactions) are evaluated separately in the issue
/// report — they are user-controlled system state, not compositor effects.
public struct SegmentationCapabilityMatrix: Equatable, Sendable {
    /// One quality level's standing on this device at the target frame rate.
    public struct Row: Equatable, Sendable {
        public let quality: SegmentationQuality
        /// Whether the public API will run this level here at all. On a
        /// supported OS every level RUNS — the differentiator is cost, so an
        /// over-budget level stays available-but-noted rather than hidden.
        public let isAvailable: Bool
        /// Planning estimate of the Vision request's cost on a 1080p frame,
        /// in milliseconds, for this device's performance tier. Estimates —
        /// the runtime governor measures the real cost and protects cadence.
        public let estimatedCostMs: Double
        /// Why this level is a poor fit at the target frame rate (nil when it
        /// fits the budget).
        public let note: String?

        public init(quality: SegmentationQuality, isAvailable: Bool,
                    estimatedCostMs: Double, note: String?) {
            self.quality = quality
            self.isAvailable = isAvailable
            self.estimatedCostMs = estimatedCostMs
            self.note = note
        }
    }

    /// The hard gate: person segmentation can be offered at all. False only
    /// when the OS predates the public API — the UI must show the unavailable
    /// reason instead of enabling controls (no pretending).
    public let isSupported: Bool
    /// Why segmentation is unavailable (nil when supported).
    public let unavailableReason: String?
    public let rows: [Row]
    /// The costliest quality that fits the frame budget at the target frame
    /// rate — the default the UI pre-selects. Nil when even `.fast` would
    /// blow the budget: the honest answer is then "don't offer the effect",
    /// and the UI disables controls with that explanation.
    public let recommendedQuality: SegmentationQuality?

    /// Fraction of one frame interval segmentation may consume before the
    /// static matrix (recommendation) and the runtime governor (downgrade /
    /// suspend) act. Half the frame leaves the compositor the other half.
    public static let frameBudgetFraction = 0.5

    /// Whether the effect should be OFFERED on this device (supported AND at
    /// least one quality fits the budget).
    public var isOfferable: Bool { isSupported && recommendedQuality != nil }

    public func row(for quality: SegmentationQuality) -> Row? {
        rows.first(where: { $0.quality == quality })
    }

    // MARK: - Derivation

    /// The performance tier cost estimates derive from. Deliberately the same
    /// style of device signals as `StreamCapability` (core count + physical
    /// memory — public `ProcessInfo` values):
    /// - HIGH (≥8 GB & ≥8 cores): Apple-Silicon-class; the Neural Engine
    ///   accelerates Vision requests.
    /// - MID (≥4 GB): runs every level, at a cost the frame rate must afford.
    /// - LOW: person segmentation runs but only `.fast` stands a chance of
    ///   fitting a real-time frame budget.
    public static let highMemoryFloor: UInt64 = 8_000_000_000
    public static let midMemoryFloor: UInt64 = 3_300_000_000
    public static let highCoreFloor = 8

    /// Estimated per-frame Vision cost (ms) at 1080p per tier and quality.
    /// Conservative planning figures used ONLY for the static recommendation;
    /// the runtime governor re-decides from measured costs.
    private static func estimatedCosts(processorCount: Int, physicalMemory: UInt64)
        -> [SegmentationQuality: Double] {
        if physicalMemory >= highMemoryFloor && processorCount >= highCoreFloor {
            return [.fast: 3, .balanced: 7, .accurate: 14]
        }
        if physicalMemory >= midMemoryFloor {
            return [.fast: 6, .balanced: 14, .accurate: 30]
        }
        return [.fast: 12, .balanced: 28, .accurate: 60]
    }

    /// Derives the matrix from injected device signals. `macOSMajorVersion`
    /// is the API floor gate (`VNGeneratePersonSegmentationRequest` shipped
    /// in macOS 12; the app's deployment target is macOS 14, so the live gate
    /// always passes — the check exists for honesty and for injected tests).
    public static func evaluate(macOSMajorVersion: Int,
                                processorCount: Int,
                                physicalMemory: UInt64,
                                targetFrameRate: Int = 60) -> SegmentationCapabilityMatrix {
        guard macOSMajorVersion >= 12 else {
            return SegmentationCapabilityMatrix(
                isSupported: false,
                unavailableReason: "Person segmentation requires macOS 12 or later (this Mac is on macOS \(macOSMajorVersion)).",
                rows: [],
                recommendedQuality: nil)
        }
        let costs = estimatedCosts(processorCount: processorCount, physicalMemory: physicalMemory)
        let budgetMs = 1000.0 / Double(max(1, targetFrameRate)) * frameBudgetFraction
        var rows: [Row] = []
        var recommended: SegmentationQuality?
        // Cheapest → costliest; the recommendation is the LAST (costliest)
        // level that still fits the budget.
        for quality in SegmentationQuality.allCases {
            let cost = costs[quality] ?? .greatestFiniteMagnitude
            let fits = cost <= budgetMs
            if fits { recommended = quality }
            rows.append(Row(quality: quality,
                            isAvailable: true,
                            estimatedCostMs: cost,
                            note: fits ? nil
                                : "Estimated \(Int(cost.rounded())) ms per frame exceeds the \(String(format: "%.1f", budgetMs)) ms budget at \(targetFrameRate) fps — the governor would downgrade past it."))
        }
        return SegmentationCapabilityMatrix(
            isSupported: true,
            unavailableReason: recommended == nil
                ? "Even Fast segmentation (~\(Int((costs[.fast] ?? 0).rounded())) ms/frame) exceeds half of a \(targetFrameRate) fps frame on this Mac — background effects stay off to protect the output cadence."
                : nil,
            rows: rows,
            recommendedQuality: recommended)
    }
}

// MARK: - Frame-cost governor

/// The runtime cadence protector (E03): segmentation never blocks the render
/// tick, so a blown budget shows up as MEASURED per-request cost, not dropped
/// output frames. The governor reads those measurements and walks the
/// effective quality DOWN (accurate → balanced → fast → suspended) when the
/// request repeatedly exceeds its budget, and RESUMES at `.fast` after a
/// cooldown probe. While suspended the renderer composites the unmodified
/// source — the clean passthrough fallback. Pure value logic: deterministic
/// and unit-testable; the StreamMac coordinator records real costs into it.
public struct SegmentationFrameGovernor: Equatable, Sendable {
    /// What one recorded sample decided.
    public enum Decision: Equatable, Sendable {
        /// No change.
        case hold
        /// Effective quality stepped down.
        case downgrade(to: SegmentationQuality)
        /// Already at `.fast` and still over budget — suspend segmentation
        /// (renderer passes the source through) for the cooldown window.
        case suspend
        /// Cooldown elapsed — resume probing at `.fast`.
        case resume
    }

    /// The quality the coordinator should run right now. Starts at the
    /// requested quality; only the governor moves it.
    public private(set) var effectiveQuality: SegmentationQuality
    /// True while segmentation is suspended (passthrough fallback active).
    public private(set) var isSuspended = false

    /// Consecutive over-budget samples tolerated before acting (absorbs the
    /// odd slow frame: thermal spike, window-server hiccup).
    public let overBudgetTolerance: Int
    /// Frames to stay suspended before a `.fast` resume probe.
    public let suspendCooldownFrames: Int
    /// Budget fraction of one frame interval (defaults to the matrix's).
    public let budgetFraction: Double

    private var consecutiveOver = 0
    private var cooldownRemaining = 0

    public init(requestedQuality: SegmentationQuality,
                budgetFraction: Double = SegmentationCapabilityMatrix.frameBudgetFraction,
                overBudgetTolerance: Int = 3,
                suspendCooldownFrames: Int = 90) {
        self.effectiveQuality = requestedQuality
        self.budgetFraction = budgetFraction
        self.overBudgetTolerance = overBudgetTolerance
        self.suspendCooldownFrames = suspendCooldownFrames
    }

    /// Records one measured segmentation cost against the frame interval and
    /// returns the decision. While suspended, each call counts down the
    /// cooldown (the caller still ticks at the output cadence); the sample's
    /// cost is ignored because no work ran.
    public mutating func record(costMs: Double, frameIntervalMs: Double) -> Decision {
        if isSuspended {
            cooldownRemaining -= 1
            if cooldownRemaining <= 0 {
                isSuspended = false
                consecutiveOver = 0
                effectiveQuality = .fast
                return .resume
            }
            return .hold
        }
        let budgetMs = frameIntervalMs * budgetFraction
        guard frameIntervalMs > 0, costMs > budgetMs else {
            consecutiveOver = 0
            return .hold
        }
        consecutiveOver += 1
        guard consecutiveOver >= overBudgetTolerance else { return .hold }
        consecutiveOver = 0
        if let cheaper = effectiveQuality.cheaper {
            effectiveQuality = cheaper
            return .downgrade(to: cheaper)
        }
        isSuspended = true
        cooldownRemaining = suspendCooldownFrames
        return .suspend
    }
}
