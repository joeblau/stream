import Foundation
import CoreGraphics

// MARK: - App Group constants (single source of truth)
public enum AppGroup {
    /// App Group identifier; identical to the UserDefaults suite name.
    public static let identifier = "group.com.joeblau.Stream"
    /// Base name for the JSON-encoded StreamSettings blob: the container file is
    /// `<settingsKey>.json`. Also the legacy UserDefaults key migrated from once.
    public static let settingsKey = "stream.settings.v1"
    /// Bundle id of the broadcast upload extension (picker preferredExtension).
    public static let broadcastExtensionBundleID = "com.joeblau.Stream.Broadcast"
    /// Keychain `kSecAttrService` for the shared connection secrets.
    public static let keychainService = "com.joeblau.Stream.connection"
}

// MARK: - Enums (RawRepresentable for Codable stability)
public enum PIPCorner: String, Codable, CaseIterable, Sendable {
    case topLeft, topRight, bottomLeft, bottomRight
}

public enum CameraPosition: String, Codable, CaseIterable, Sendable {
    case front, back
}

/// Resolution target for the local HD backup recording, independent of the RTMP
/// stream resolution. The backup taps the broadcast mixer's output, so it can be
/// captured at a higher fidelity than the (often downscaled, bandwidth-limited)
/// network stream — the whole point of "back it up in HD so I can repost it".
public enum BackupQuality: String, Codable, CaseIterable, Sendable {
    /// Same resolution as the RTMP stream (lowest overhead).
    case matchStream
    /// Cap the short edge at 720px.
    case hd720
    /// Cap the short edge at 1080px (a safe, broadly-compatible HD default).
    case hd1080
    /// Full native source resolution — no downscale (max fidelity, heaviest).
    case native
}

// MARK: - StreamSettings (the ONLY shared persisted model)
public struct StreamSettings: Codable, Equatable, Sendable {
    public var rtmpURL: String          // e.g. "rtmps://live.restream.io/live"
    public var streamKey: String        // publish name / stream key
    /// Target SHORT edge of the encoded video, in px (e.g. 720). The long edge is
    /// derived from the live screen's real aspect ratio at broadcast start, so the
    /// stream matches the device orientation (portrait or landscape) with no squish.
    public var videoQuality: Int
    public var videoBitrate: Int        // bits per second
    public var audioBitrate: Int        // bits per second
    public var frameRate: Int           // fps hint
    public var pipEnabled: Bool
    public var pipCorner: PIPCorner
    public var pipScale: Double          // fraction of frame width, 0.10...0.40
    public var cameraPosition: CameraPosition
    public var preferredAudioInputUID: String?  // AVAudioSessionPortDescription.uid
    public var includeAppAudio: Bool
    /// Linear mic gain applied to the microphone track before mixing/encoding
    /// (1.0 = unity, 0 = silent, 2.0 = +6 dB). Software level control: iOS can't
    /// set most external mics' hardware input gain, so this scales the captured
    /// mic in the mix — the practical way to balance a DJI/Bluetooth mic.
    public var micVolume: Double
    /// When true, every broadcast is also recorded locally to an HD .mp4 in the
    /// shared App Group container (independent of the RTMP connection, so it
    /// survives a dropped/failed stream). The app auto-saves it to Photos.
    public var backupEnabled: Bool
    /// Target resolution for the local backup recording.
    public var backupQuality: BackupQuality

    public init(
        rtmpURL: String = "",
        streamKey: String = "",
        videoQuality: Int = 720,
        videoBitrate: Int = 3_000_000,
        audioBitrate: Int = 128_000,
        frameRate: Int = 30,
        pipEnabled: Bool = false,
        pipCorner: PIPCorner = .bottomRight,
        pipScale: Double = 0.28,
        cameraPosition: CameraPosition = .front,
        preferredAudioInputUID: String? = nil,
        includeAppAudio: Bool = true,
        micVolume: Double = 1.0,
        backupEnabled: Bool = false,
        backupQuality: BackupQuality = .hd1080
    ) {
        self.rtmpURL = rtmpURL
        self.streamKey = streamKey
        self.videoQuality = videoQuality
        self.videoBitrate = videoBitrate
        self.audioBitrate = audioBitrate
        self.frameRate = frameRate
        self.pipEnabled = pipEnabled
        self.pipCorner = pipCorner
        self.pipScale = pipScale
        self.cameraPosition = cameraPosition
        self.preferredAudioInputUID = preferredAudioInputUID
        self.includeAppAudio = includeAppAudio
        self.micVolume = micVolume
        self.backupEnabled = backupEnabled
        self.backupQuality = backupQuality
    }

    /// Backward-compatible decode: every field falls back to its default when the
    /// key is absent, so adding new settings (e.g. the backup options) never wipes
    /// a user's previously-stored snapshot when it round-trips through the App
    /// Group on upgrade. `encode(to:)` stays synthesized.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = StreamSettings.default
        rtmpURL = try c.decodeIfPresent(String.self, forKey: .rtmpURL) ?? d.rtmpURL
        streamKey = try c.decodeIfPresent(String.self, forKey: .streamKey) ?? d.streamKey
        videoQuality = try c.decodeIfPresent(Int.self, forKey: .videoQuality) ?? d.videoQuality
        videoBitrate = try c.decodeIfPresent(Int.self, forKey: .videoBitrate) ?? d.videoBitrate
        audioBitrate = try c.decodeIfPresent(Int.self, forKey: .audioBitrate) ?? d.audioBitrate
        frameRate = try c.decodeIfPresent(Int.self, forKey: .frameRate) ?? d.frameRate
        pipEnabled = try c.decodeIfPresent(Bool.self, forKey: .pipEnabled) ?? d.pipEnabled
        pipCorner = try c.decodeIfPresent(PIPCorner.self, forKey: .pipCorner) ?? d.pipCorner
        pipScale = try c.decodeIfPresent(Double.self, forKey: .pipScale) ?? d.pipScale
        cameraPosition = try c.decodeIfPresent(CameraPosition.self, forKey: .cameraPosition) ?? d.cameraPosition
        preferredAudioInputUID = try c.decodeIfPresent(String.self, forKey: .preferredAudioInputUID) ?? d.preferredAudioInputUID
        includeAppAudio = try c.decodeIfPresent(Bool.self, forKey: .includeAppAudio) ?? d.includeAppAudio
        micVolume = try c.decodeIfPresent(Double.self, forKey: .micVolume) ?? d.micVolume
        backupEnabled = try c.decodeIfPresent(Bool.self, forKey: .backupEnabled) ?? d.backupEnabled
        backupQuality = try c.decodeIfPresent(BackupQuality.self, forKey: .backupQuality) ?? d.backupQuality
    }

    public static let `default` = StreamSettings()

    /// True only when a host and a stream key are present.
    public var isPublishable: Bool {
        guard let url = URL(string: rtmpURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "rtmp" || scheme == "rtmps",
              url.host != nil else { return false }
        return !streamKey.isEmpty
    }

    /// True when the URL scheme is rtmps (TLS auto-negotiated by HaishinKit).
    public var isSecure: Bool {
        URL(string: rtmpURL)?.scheme?.lowercased() == "rtmps"
    }

    /// Derives the encode dimensions from the live (already upright-oriented)
    /// screen size, preserving the real aspect ratio. The short edge is clamped to
    /// `videoQuality` (never upscaled above the source), and both edges are rounded
    /// to even numbers as required by H.264/HEVC. Locking this at broadcast start
    /// keeps the RTMP resolution stable for the whole session.
    public func encodeSize(forOrientedWidth width: Int, height: Int) -> CGSize {
        guard width > 0, height > 0 else {
            // Fallback to a portrait 9:16 canvas at the chosen quality.
            return CGSize(width: even(videoQuality), height: even(videoQuality * 16 / 9))
        }
        let shortEdge = min(width, height)
        let scale = min(1.0, Double(videoQuality) / Double(shortEdge))
        let w = even(Int((Double(width) * scale).rounded()))
        let h = even(Int((Double(height) * scale).rounded()))
        return CGSize(width: max(2, w), height: max(2, h))
    }

    /// Derives the local backup's encode dimensions. `streamSize` is the locked
    /// RTMP encode size (already aspect-correct for the screen); `sourceShortEdge`
    /// is the short edge of the actual frames the mixer emits (native screen size
    /// when no facecam compositing is happening, otherwise the stream size). The
    /// backup short edge is the chosen quality, clamped so it never exceeds the
    /// real source detail (no pointless upscaling) and never below the stream size
    /// would distort. Aspect ratio always matches the stream.
    public func backupEncodeSize(streamSize: CGSize, sourceShortEdge: Int) -> CGSize {
        let streamW = max(2, Int(streamSize.width.rounded()))
        let streamH = max(2, Int(streamSize.height.rounded()))
        let streamShort = min(streamW, streamH)
        let streamLong = max(streamW, streamH)

        let desired: Int
        switch backupQuality {
        case .matchStream: desired = streamShort
        case .hd720:       desired = 720
        case .hd1080:      desired = 1080
        case .native:      desired = max(sourceShortEdge, streamShort)
        }
        // Never ask for more detail than the source actually has.
        let shortEdge = max(2, min(desired, max(sourceShortEdge, streamShort)))

        // Preserve the stream aspect ratio exactly; scale the long edge to match.
        let aspect = Double(streamLong) / Double(streamShort)
        let short = even(shortEdge)
        let long = even(Int((Double(short) * aspect).rounded()))
        return streamH >= streamW
            ? CGSize(width: max(2, short), height: max(2, long))
            : CGSize(width: max(2, long), height: max(2, short))
    }

    /// A generous H.264 bitrate for the backup, scaled to its pixel area and frame
    /// rate (screen content compresses well, so ~0.12 bits/pixel looks clean),
    /// clamped to a sane HD range. Independent of the network `videoBitrate`.
    public func backupVideoBitrate(for size: CGSize) -> Int {
        let pixels = Double(size.width) * Double(size.height)
        let raw = Int(pixels * Double(max(1, frameRate)) * 0.12)
        return min(16_000_000, max(4_000_000, raw))
    }

    private func even(_ value: Int) -> Int { value - (value % 2) }
}
