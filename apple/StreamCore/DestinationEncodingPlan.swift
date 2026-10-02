import Foundation

/// Limits are explicit ingest evidence or an explicit operator override, never
/// a universal claim about every service using a transport.
public struct DestinationIngestLimits: Codable, Equatable, Sendable {
    public enum Source: String, Codable, CaseIterable, Sendable {
        case conservativeDefault, validatedIngest, customOverride
        public var label: String {
            switch self {
            case .conservativeDefault: return "Conservative transport defaults"
            case .validatedIngest: return "Validated ingest limits"
            case .customOverride: return "Custom override"
            }
        }
    }
    public var source: Source
    public var maxWidth: Int
    public var maxHeight: Int
    public var maxFrameRate: Int
    public var codecs: [VideoCodec]
    public var maxKeyframeSeconds: Double
    public var maxAudioBitrate: Int

    public init(source: Source = .customOverride, maxWidth: Int = 1920, maxHeight: Int = 1080,
                maxFrameRate: Int = 60, codecs: [VideoCodec] = [.h264],
                maxKeyframeSeconds: Double = 2, maxAudioBitrate: Int = 320_000) {
        self.source = source
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.maxFrameRate = maxFrameRate
        self.codecs = codecs
        self.maxKeyframeSeconds = maxKeyframeSeconds
        self.maxAudioBitrate = maxAudioBitrate
    }

    public static func conservative(for transport: StreamProtocol) -> Self {
        let tier = OutputCapabilities.destinationTier(for: transport)
        return .init(source: .conservativeDefault, maxWidth: tier.longEdge, maxHeight: tier.shortEdge,
                     maxFrameRate: OutputCapabilities.destinationMaxFrameRate(for: transport),
                     codecs: transport == .srt ? VideoCodec.allCases : [.h264])
    }

    public func errors(profile: OutputProfile, codec: VideoCodec, keyframeSeconds: Double,
                       audioBitrate: Int) -> [String] {
        var errors: [String] = []
        if maxWidth < 2 || maxHeight < 2 || maxFrameRate < 1 || maxKeyframeSeconds <= 0 || codecs.isEmpty {
            errors.append("Ingest limits must contain positive geometry, frame rate, keyframe interval and a codec.")
        }
        if max(profile.canvasWidth, profile.canvasHeight) > max(maxWidth, maxHeight) ||
            min(profile.canvasWidth, profile.canvasHeight) > min(maxWidth, maxHeight) {
            errors.append("The selected canvas exceeds this destination's \(maxWidth)×\(maxHeight) limit.")
        }
        if profile.frameRate > maxFrameRate { errors.append("This destination is limited to \(maxFrameRate) fps.") }
        if !codecs.contains(codec) { errors.append("This destination's ingest limits do not accept \(codec.displayName).") }
        if keyframeSeconds > maxKeyframeSeconds { errors.append("This destination requires keyframes at most \(maxKeyframeSeconds) seconds apart.") }
        if audioBitrate > maxAudioBitrate { errors.append("Audio exceeds this destination's \(maxAudioBitrate / 1000) kbps limit.") }
        return errors
    }
}

/// A compatibility key includes every encoder-affecting setting. Sharing by
/// codec alone would silently lower another destination's quality or frame rate.
public struct DestinationEncoderKey: Hashable, Sendable {
    /// Equal encoder settings cannot share pixels from different compositions.
    public var canvas: OutputCanvas
    public var width: Int
    public var height: Int
    public var frameRate: Int
    public var codec: VideoCodec
    public var videoBitrate: Int
    public var audioBitrate: Int
    public var keyframeSeconds: Double
    public var audioFormat: String

    public init(destination: StreamDestination, program: OutputProfile) {
        let profile = destination.effectiveProfile(program: program)
        canvas = destination.canvas ?? .program
        width = profile.canvasWidth
        height = profile.canvasHeight
        frameRate = profile.frameRate
        codec = destination.videoCodec
        videoBitrate = destination.videoBitrate
        audioBitrate = destination.audioBitrate
        keyframeSeconds = destination.keyframeSeconds ?? 2
        audioFormat = destination.transport == .whip ? "opus-48000-stereo" : "aac-48000-stereo"
    }

    /// These are the actual fixed encoder's accepted settings. A custom ingest
    /// override outside this range keeps an independent publisher reservation.
    public func supportsFixedH264AAC(on transport: StreamProtocol, sourceFrameRate: Int? = nil) -> Bool {
        [.rtmp, .rtmps, .srt].contains(transport) && codec == .h264 &&
        (2...4096).contains(width) && (2...4096).contains(height) && width % 2 == 0 && height % 2 == 0 &&
        (1...60).contains(frameRate) && (sourceFrameRate.map { (1...60).contains($0) && frameRate <= $0 } ?? true) &&
        videoBitrate > 0 && (32_000...320_000).contains(audioBitrate) &&
        keyframeSeconds.isFinite && (1...10).contains(keyframeSeconds) && keyframeSeconds.rounded() == keyframeSeconds
    }
}

public struct DestinationEncodingPlan: Equatable, Sendable {
    public var compatibleGroups: [[UUID]]
    /// Reserved encoder groups in the selected actual backend mode. The default
    /// adaptive/raw backend still owns an encoder per publisher.
    public var encoderSessions: Int
    public var sharedH264AAC = false
    public var aggregateBitrate: Int
    public var requiredUplinkMbps: Double
    public var issues: [String]

    public init(destinations: [StreamDestination], program: OutputProfile,
                measuredUplinkMbps: Double? = nil, measuredSessionLimit: Int? = nil,
                shareH264AAC: Bool = false, sourceFrameRate: Int? = nil) {
        var groups: [DestinationEncoderKey: [UUID]] = [:]
        for destination in destinations {
            groups[DestinationEncoderKey(destination: destination, program: program), default: []].append(destination.id)
        }
        compatibleGroups = groups.values.map { $0.sorted { $0.uuidString < $1.uuidString } }
            .sorted { ($0.first?.uuidString ?? "") < ($1.first?.uuidString ?? "") }
        sharedH264AAC = shareH264AAC
        // Sharing is explicitly qualified only for fixed-profile H.264/AAC on
        // the desktop RTMP/RTMPS/SRT adapters. Other codec/transport combinations
        // still reserve a real encoder each, even if their settings match.
        var sharedKeys = Set<DestinationEncoderKey>()
        var separate = 0
        for destination in destinations {
            let key = DestinationEncoderKey(destination: destination, program: program)
            if shareH264AAC && key.supportsFixedH264AAC(on: destination.transport, sourceFrameRate: sourceFrameRate ?? program.frameRate) {
                sharedKeys.insert(key)
            } else { separate += 1 }
        }
        encoderSessions = shareH264AAC ? sharedKeys.count + separate : destinations.count
        aggregateBitrate = destinations.reduce(0) { $0 + $1.videoBitrate + $1.audioBitrate }
        // Protocol overhead + 25% spare capacity: an operator-visible estimate.
        requiredUplinkMbps = Double(aggregateBitrate) * 1.35 / 1_000_000
        issues = []
        if destinations.count > 10 { issues.append("Enable up to ten simultaneous destinations.") }
        if let limit = measuredSessionLimit, encoderSessions > limit {
            issues.append("\(encoderSessions) encoders exceed your tested session budget of \(limit).")
        }
        if let measuredUplinkMbps, measuredUplinkMbps < requiredUplinkMbps {
            issues.append("Measured uplink \(String(format: "%.1f", measuredUplinkMbps)) Mbps is below the \(String(format: "%.1f", requiredUplinkMbps)) Mbps estimate with headroom.")
        }
    }
}
