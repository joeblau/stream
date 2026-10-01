import Foundation

/// A05 (issue #84): how a multi-channel audio interface's HARDWARE input
/// channels feed one mix channel. Capture delivers every channel the device
/// exposes; the mapping picks what reaches the mix before format conversion:
///
/// - `all` — pass the device through unchanged (a built-in/USB mic's native
///   mono or stereo layout; the canonical converter normalizes it).
/// - `mono(channel)` — one hardware channel, duplicated to L/R (a single XLR
///   input on an interface).
/// - `stereo(left:right:)` — a hardware channel pair mapped to L/R (a stereo
///   line-in pair, or two adjacent mic pres as a stereo mic).
///
/// Channel indices are 0-based hardware input numbers; the UI presents them
/// 1-based. Codable is synthesized (stable associated-value layout) and the
/// enum is `Hashable` so it can ride SwiftUI picker tags and the W05 command
/// payloads.
public enum AudioInputMapping: Hashable, Codable, Sendable {
    case all
    case mono(Int)
    case stereo(Int, Int)

    /// Resolves the mapping against the device's actual input channel count:
    /// the (left, right) SOURCE channel indices to extract, or nil for
    /// passthrough (`.all`). Out-of-range indices clamp into the device —
    /// a persisted mapping written for a bigger interface degrades honestly
    /// instead of going silent.
    public func stereoPair(channelCount: Int) -> (left: Int, right: Int)? {
        guard channelCount > 0 else { return nil }
        switch self {
        case .all:
            return nil
        case .mono(let channel):
            let picked = min(max(channel, 0), channelCount - 1)
            return (picked, picked)
        case .stereo(let left, let right):
            return (min(max(left, 0), channelCount - 1),
                    min(max(right, 0), channelCount - 1))
        }
    }
}

/// A05 (issue #84): one audio input device's place in the multi-mic setup —
/// whether it captures into its own mix channel
/// (`AudioChannelID.microphone(deviceUID:)`), and which of its hardware
/// channels feed that channel. Persisted in `StreamSettings.audioInputs`
/// (additive `decodeIfPresent`, so older settings blobs load unchanged).
/// Identity is the capture device's stable `uniqueID`, so an unplugged
/// device keeps its entry (and mapping) and resumes when the same device
/// returns — the C10 relink rule applied to audio.
public struct AudioInputSelection: Hashable, Codable, Sendable {
    public var deviceUID: String
    public var isEnabled: Bool
    public var mapping: AudioInputMapping

    public init(deviceUID: String, isEnabled: Bool = true,
                mapping: AudioInputMapping = .all) {
        self.deviceUID = deviceUID
        self.isEnabled = isEnabled
        self.mapping = mapping
    }

    /// Backward-compatible decode: entries written before the mapping
    /// existed default to enabled/passthrough.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deviceUID = try c.decode(String.self, forKey: .deviceUID)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        mapping = try c.decodeIfPresent(AudioInputMapping.self, forKey: .mapping) ?? .all
    }
}
