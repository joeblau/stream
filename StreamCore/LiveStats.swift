import Foundation

/// A snapshot of the live broadcast's health, surfaced from the encoder/ABR to the
/// UI (the Settings live-stats card and the LIVE pill). Distinct from
/// `BroadcastState`, which is the coarse cross-process *liveness* heartbeat — this
/// is the fine-grained *metrics* the stats HUD renders while a stream is running.
///
/// The numbers are the encoder's current TARGETS after adaptive/thermal/path
/// clamping (the real, applied rate), not independently measured throughput —
/// measured fps/dropped-frame telemetry depends on M8, which is not yet built.
///
/// Pure value type with no iOS dependencies, so the health classification and the
/// display formatting are unit-tested in StreamCore on CI.
public struct LiveStats: Equatable, Sendable {
    /// Current encoder video bitrate (bits/sec), after ABR + thermal + path clamping.
    public var bitRate: Int
    /// Effective encode frame rate (fps) — the ABR/thermal target that is actually
    /// applied to the encoder, not a measured output rate.
    public var frameRate: Int
    /// Bytes waiting in the outbound socket queue (the uplink backlog).
    public var queueBytes: Int
    /// Consecutive ~1s ticks the socket sent zero bytes while data was queued — the
    /// stall signal the watchdog uses.
    public var zeroOutputSeconds: Int

    public init(bitRate: Int, frameRate: Int, queueBytes: Int, zeroOutputSeconds: Int) {
        self.bitRate = bitRate
        self.frameRate = frameRate
        self.queueBytes = queueBytes
        self.zeroOutputSeconds = zeroOutputSeconds
    }

    /// Uplink health, classified from the outbound backlog + stall signal. The
    /// thresholds mirror the publisher's own `VideoFrameAdmission` / watchdog tiers
    /// (RTMPPublisher): under 0.5 MB the queue is keeping up; a growing backlog or
    /// any zero-output stall means the uplink can't drain what the encoder produces.
    public enum LinkHealth: String, Sendable, Equatable, CaseIterable {
        case good, fair, congested

        public var label: String {
            switch self {
            case .good:      return "Good"
            case .fair:      return "Fair"
            case .congested: return "Congested"
            }
        }
    }

    /// 0.5 MB: the point at which `VideoFrameAdmission` starts shedding frames.
    static let fairQueueBytes = 524_288
    /// 2 MB: a deep backlog several stale seconds of video would sit behind.
    static let congestedQueueBytes = 2_097_152

    public var linkHealth: LinkHealth {
        if zeroOutputSeconds >= 2 || queueBytes >= Self.congestedQueueBytes { return .congested }
        if queueBytes >= Self.fairQueueBytes { return .fair }
        return .good
    }

    /// A compact bitrate label: "2.4 Mbps" at/above 1 Mbps, "850 kbps" below (the
    /// ABR can floor to ~300 kbps on a poor uplink). Matches the Settings video
    /// picker's Mbps formatting for the common case.
    public var bitRateLabel: String {
        let bps = max(0, bitRate)
        if bps >= 1_000_000 {
            return String(format: "%.1f Mbps", Double(bps) / 1_000_000)
        }
        return "\(bps / 1000) kbps"
    }

    /// A compact queue label in the card, e.g. "0 KB" / "512 KB" / "2.1 MB".
    public var queueLabel: String {
        let bytes = max(0, queueBytes)
        if bytes >= 1_048_576 {
            return String(format: "%.1f MB", Double(bytes) / 1_048_576)
        }
        return "\(bytes / 1024) KB"
    }

    /// Formats an elapsed broadcast duration: "MM:SS" under an hour, "H:MM:SS" past
    /// it (e.g. 65 → "01:05", 3665 → "1:01:05"). Negative inputs clamp to zero.
    public static func uptimeLabel(seconds: Int) -> String {
        let total = max(0, seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }
}
