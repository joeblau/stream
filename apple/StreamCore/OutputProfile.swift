import Foundation
import CoreGraphics

// MARK: - OutputProfile (W07, issue #64)
//
// The canvas the program is composed and encoded at, owned by settings — NOT
// by the first arriving camera/screen frame. Source frames are aspect-fit into
// this fixed canvas, so a source whose native size changes mid-program never
// resizes the output. Resolution/fps edits are staged while an output (stream
// or recording) is active and applied on the next compatible session (see
// StreamController.applyOutputProfile on macOS).

/// A concrete output geometry: an even-pixel canvas plus a target frame rate.
/// Even dimensions are enforced at construction and decode (H.264/HEVC require
/// them), so a profile can never describe an unencodable size.
public struct OutputProfile: Codable, Equatable, Sendable {
    /// Canvas width in px, always even, ≥ 2.
    public private(set) var canvasWidth: Int
    /// Canvas height in px, always even, ≥ 2.
    public private(set) var canvasHeight: Int
    /// Target frames per second, ≥ 1.
    public private(set) var frameRate: Int

    public init(canvasWidth: Int, canvasHeight: Int, frameRate: Int) {
        self.canvasWidth = Self.evenDimension(canvasWidth)
        self.canvasHeight = Self.evenDimension(canvasHeight)
        self.frameRate = max(1, frameRate)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = OutputProfile.default
        self.init(
            canvasWidth: try c.decodeIfPresent(Int.self, forKey: .canvasWidth) ?? d.canvasWidth,
            canvasHeight: try c.decodeIfPresent(Int.self, forKey: .canvasHeight) ?? d.canvasHeight,
            frameRate: try c.decodeIfPresent(Int.self, forKey: .frameRate) ?? d.frameRate)
    }

    /// The shipped default, matching the historical 720p24 encode target.
    public static let `default` = OutputProfile(canvasWidth: 1280, canvasHeight: 720, frameRate: 24)

    /// Upgrade path for settings blobs that predate this model: a landscape
    /// 16:9 canvas whose short edge is the old `videoQuality` pick, at the old
    /// `frameRate`. The old fields stay in `StreamSettings` for the iOS app.
    public init(legacyVideoQuality: Int, frameRate: Int) {
        let shortEdge = max(2, legacyVideoQuality)
        self.init(canvasWidth: shortEdge * 16 / 9, canvasHeight: shortEdge, frameRate: frameRate)
    }

    public var canvasSize: CGSize {
        CGSize(width: canvasWidth, height: canvasHeight)
    }

    public var aspectDescription: String {
        if canvasWidth == canvasHeight { return "Square" }
        return canvasWidth > canvasHeight ? "Landscape" : "Portrait"
    }

    /// Mutations rebuild through the initializer so even-pixel/frame-rate
    /// invariants always hold.
    public func with(canvasWidth: Int? = nil, canvasHeight: Int? = nil, frameRate: Int? = nil) -> OutputProfile {
        OutputProfile(canvasWidth: canvasWidth ?? self.canvasWidth,
                      canvasHeight: canvasHeight ?? self.canvasHeight,
                      frameRate: frameRate ?? self.frameRate)
    }

    static func evenDimension(_ value: Int) -> Int {
        max(2, value - (value % 2))
    }
}

// MARK: - CanvasPreset

/// The sensible fixed canvas list the settings UI offers. Anything else is
/// `.custom` (free-form even-pixel width/height). Presets cover the three
/// orientations explicitly: landscape for desktop/TV, portrait for phone-first
/// platforms, square for feed posts.
public enum CanvasPreset: String, Codable, CaseIterable, Sendable {
    case landscape720, landscape1080, landscape4K
    case portrait720, portrait1080
    case square720, square1080
    case custom

    /// Fixed canvas size; nil for `.custom`.
    public var size: (width: Int, height: Int)? {
        switch self {
        case .landscape720: return (1280, 720)
        case .landscape1080: return (1920, 1080)
        case .landscape4K: return (3840, 2160)
        case .portrait720: return (720, 1280)
        case .portrait1080: return (1080, 1920)
        case .square720: return (720, 720)
        case .square1080: return (1080, 1080)
        case .custom: return nil
        }
    }

    public var displayName: String {
        switch self {
        case .landscape720: return "720p Landscape (1280×720)"
        case .landscape1080: return "1080p Landscape (1920×1080)"
        case .landscape4K: return "4K Landscape (3840×2160)"
        case .portrait720: return "720p Portrait (720×1280)"
        case .portrait1080: return "1080p Portrait (1080×1920)"
        case .square720: return "Square 720 (720×720)"
        case .square1080: return "Square 1080 (1080×1080)"
        case .custom: return "Custom…"
        }
    }

    /// The preset whose fixed size matches the profile's canvas, else `.custom`.
    public init(matching profile: OutputProfile) {
        self = CanvasPreset.allCases.first(where: {
            $0.size?.0 == profile.canvasWidth && $0.size?.1 == profile.canvasHeight
        }) ?? .custom
    }
}

// MARK: - OutputCapabilities (the single auditable gating place)

/// Every resolution/fps gating decision lives here: the hardware encoder
/// ceiling for this device, the per-destination (ingest) ceiling, and the
/// reason strings the UI shows for disabled options. Nothing else in the app
/// decides whether a canvas size or frame rate is offerable.
///
/// HaishinKit/VideoToolbox expose no honest "max resolution" probe (a session
/// either configures or fails at encode start), so the hardware tier uses
/// conservative documented limits: Apple Silicon Macs (≥8 cores, ≥8 GB) sustain
/// 4Kp60 in the VideoToolbox hardware H.264/HEVC encoders; the lower tiers
/// reuse `StreamCapability`'s existing memory thresholds. Destination ceilings
/// are the documented ingest limits — traditional RTMP ingests (Restream,
/// Twitch, YouTube) accept at most 1080p60, and the WHIP/RTC real-time path is
/// capped conservatively at 1080p30.
public struct OutputCapabilities: Equatable, Sendable {

    /// Resolution ceiling as a reference box: a canvas fits a tier when both
    /// its long and short edges fit the tier's long and short edges.
    public enum ResolutionTier: Int, Codable, CaseIterable, Sendable, Comparable {
        case hd720 = 0, fullHD1080 = 1, uhd4K = 2

        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

        public var longEdge: Int {
            switch self {
            case .hd720: return 1280
            case .fullHD1080: return 1920
            case .uhd4K: return 3840
            }
        }

        public var shortEdge: Int {
            switch self {
            case .hd720: return 720
            case .fullHD1080: return 1080
            case .uhd4K: return 2160
            }
        }

        public var displayName: String {
            switch self {
            case .hd720: return "720p"
            case .fullHD1080: return "1080p"
            case .uhd4K: return "4K"
            }
        }

        /// True when the canvas fits inside this tier's reference box.
        public func fits(width: Int, height: Int) -> Bool {
            max(width, height) <= longEdge && min(width, height) <= shortEdge
        }

        /// The smallest tier the canvas fits (nil when even 4K is too small).
        public static func smallestFitting(width: Int, height: Int) -> ResolutionTier? {
            ResolutionTier.allCases.first { $0.fits(width: width, height: height) }
        }
    }

    /// This device's hardware-encoder ceiling.
    public let hardwareTier: ResolutionTier
    /// This device's hardware frame-rate ceiling (thermal governor may pull the
    /// live rate lower at runtime).
    public let hardwareMaxFrameRate: Int

    public init(hardwareTier: ResolutionTier, hardwareMaxFrameRate: Int) {
        self.hardwareTier = hardwareTier
        self.hardwareMaxFrameRate = hardwareMaxFrameRate
    }

    /// Frame rates offered in the UI, gated per device/destination below.
    public static let supportedFrameRates: [Int] = [24, 25, 30, 50, 60]

    /// Derives the hardware ceiling from device signals (pure and injectable
    /// for tests, like `StreamCapability.device`). 4K needs Apple Silicon
    /// class: ≥8 logical cores and ≥8 GB RAM (reported memory sits under the
    /// nominal spec, so 7 GB divides 8 GB devices from 16 GB ones). Lower
    /// tiers reuse StreamCapability's memory floors.
    public static func hardware(
        processorCount: Int = ProcessInfo.processInfo.processorCount,
        physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> OutputCapabilities {
        let tier: ResolutionTier
        if processorCount >= 8 && physicalMemory >= 7_000_000_000 {
            tier = .uhd4K
        } else if physicalMemory >= StreamCapability.midMemoryFloor {
            tier = .fullHD1080
        } else {
            tier = .hd720
        }
        let maxFPS = (physicalMemory >= StreamCapability.highMemoryFloor
                      && processorCount >= StreamCapability.highCoreFloor) ? 60 : 30
        return OutputCapabilities(hardwareTier: tier, hardwareMaxFrameRate: maxFPS)
    }

    /// This device's ceiling, computed once. The app uses this; tests inject.
    public static let current = hardware()

    /// The highest resolution tier the configured destination accepts.
    public static func destinationTier(for proto: StreamProtocol) -> ResolutionTier {
        switch proto {
        // Traditional and enhanced RTMP ingests (Restream, Twitch, YouTube)
        // document 1080p as their maximum accepted resolution.
        case .rtmp, .rtmps, .whip: return .fullHD1080
        case .srt: return .uhd4K
        }
    }

    /// The highest frame rate the configured destination accepts.
    public static func destinationMaxFrameRate(for proto: StreamProtocol) -> Int {
        switch proto {
        // The RTC real-time path is capped conservatively until WHIP's
        // high-fps behavior is validated on device.
        case .whip: return 30
        case .rtmp, .rtmps, .srt: return 60
        }
    }

    /// Effective ceiling for a destination: the lower of hardware and ingest.
    public func maxTier(for proto: StreamProtocol) -> ResolutionTier {
        min(hardwareTier, Self.destinationTier(for: proto))
    }

    public func maxFrameRate(for proto: StreamProtocol) -> Int {
        min(hardwareMaxFrameRate, Self.destinationMaxFrameRate(for: proto))
    }

    /// Program/local outputs are constrained by this Mac, independently of
    /// any destination ingest. Each destination validates its own profile.
    public func hardwareGateReason(for profile: OutputProfile) -> String? {
        if !hardwareTier.fits(width: profile.canvasWidth, height: profile.canvasHeight) {
            return "This Mac encodes up to \(hardwareTier.displayName)"
        }
        if profile.frameRate > hardwareMaxFrameRate {
            return "This Mac supports up to \(hardwareMaxFrameRate) fps"
        }
        return nil
    }

    public func clampedToHardware(_ profile: OutputProfile) -> OutputProfile {
        fitted(profile, tier: hardwareTier, maxFPS: hardwareMaxFrameRate)
    }

    /// Nil when the profile is offerable for the destination; otherwise a
    /// short human reason the UI shows next to the disabled option.
    public func gateReason(for profile: OutputProfile,
                           destination proto: StreamProtocol) -> String? {
        if !hardwareTier.fits(width: profile.canvasWidth, height: profile.canvasHeight) {
            return "This Mac encodes up to \(hardwareTier.displayName)"
        }
        if !Self.destinationTier(for: proto).fits(width: profile.canvasWidth, height: profile.canvasHeight) {
            return "\(proto.displayName) ingests accept up to \(Self.destinationTier(for: proto).displayName)"
        }
        if profile.frameRate > hardwareMaxFrameRate {
            return "This Mac supports up to \(hardwareMaxFrameRate) fps"
        }
        if profile.frameRate > Self.destinationMaxFrameRate(for: proto) {
            return "\(proto.displayName) supports up to \(Self.destinationMaxFrameRate(for: proto)) fps"
        }
        return nil
    }

    /// The closest offerable profile for the destination: resolution reduced
    /// to the effective tier (aspect preserved), fps clamped. Used when the
    /// protocol switches under a profile the new destination cannot carry.
    public func clamped(_ profile: OutputProfile,
                        destination proto: StreamProtocol) -> OutputProfile {
        fitted(profile, tier: maxTier(for: proto), maxFPS: maxFrameRate(for: proto))
    }

    private func fitted(_ profile: OutputProfile, tier: ResolutionTier, maxFPS: Int) -> OutputProfile {
        var width = profile.canvasWidth
        var height = profile.canvasHeight
        if !tier.fits(width: width, height: height) {
            let scale = min(Double(tier.longEdge) / Double(max(width, height)),
                            Double(tier.shortEdge) / Double(min(width, height)))
            width = OutputProfile.evenDimension(Int((Double(width) * scale).rounded()))
            height = OutputProfile.evenDimension(Int((Double(height) * scale).rounded()))
        }
        let fps = min(profile.frameRate, maxFPS)
        return OutputProfile(canvasWidth: width, canvasHeight: height, frameRate: fps)
    }
}
