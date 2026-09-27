import Foundation
import CoreGraphics

// MARK: - App Group constants (single source of truth)
public enum AppGroup {
    /// App Group identifier; identical to the UserDefaults suite name.
    public static let identifier = "group.com.joeblau.Stream"
    /// Base name for the JSON-encoded StreamSettings blob: the container file is
    /// `<settingsKey>.json`. Also the legacy UserDefaults key migrated from once.
    public static let settingsKey = "stream.settings.v1"
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

/// The video codec the encoder targets. HEVC (H.265) yields roughly a 40%
/// quality-per-bit gain over H.264 on text-heavy screen content in the 2–8 Mbps
/// band, at the cost of ingest compatibility: it rides SRT (MPEG-TS) and
/// *enhanced*-RTMP (E-RTMP `hvc1` negotiation) but NOT WHIP in the current RTC
/// transport or traditional RTMP ingests
/// such as Restream, which speak H.264 only. H.264 Main is therefore the safe,
/// universally-decodable default; HEVC is an opt-in the user validates against
/// their real endpoint (see the encoder wiring in RTMPPublisher/SessionPublisher).
public enum VideoCodec: String, Codable, CaseIterable, Sendable {
    case h264
    case hevc

    public var displayName: String {
        switch self {
        case .h264: return "H.264"
        case .hevc: return "HEVC"
        }
    }
}

/// The transport protocol the user is publishing with. Each protocol's URL and
/// key are stored SEPARATELY in the Keychain, so switching the segmented control
/// recalls that protocol's own credentials.
public enum StreamProtocol: String, Codable, CaseIterable, Sendable {
    case rtmp, rtmps, srt, whip

    public var displayName: String {
        switch self {
        case .rtmp: return "RTMP"
        case .rtmps: return "RTMPS"
        case .srt: return "SRT"
        case .whip: return "WHIP"
        }
    }

    /// URL scheme(s) accepted for this protocol.
    public var urlSchemes: [String] {
        switch self {
        case .rtmp: return ["rtmp"]
        case .rtmps: return ["rtmps"]
        case .srt: return ["srt"]
        case .whip: return ["http", "https"]
        }
    }

    public var urlPlaceholder: String {
        switch self {
        case .rtmp: return "rtmp://host:1935/app"
        case .rtmps: return "rtmps://live.restream.io/live"
        case .srt: return "srt://host:port?streamid=…&passphrase=…"
        case .whip: return "https://host/whip/endpoint"
        }
    }

    /// Label for the second (key) field — protocols carry the key differently.
    public var keyFieldLabel: String {
        switch self {
        case .rtmp, .rtmps: return "Stream key"
        case .srt: return "Stream ID / passphrase (optional)"
        case .whip: return "Bearer token (optional)"
        }
    }

    /// RTMP/RTMPS require a separate stream key; SRT/WHIP embed it in the URL.
    public var requiresKey: Bool {
        switch self {
        case .rtmp, .rtmps: return true
        case .srt, .whip: return false
        }
    }

    /// Whether the broadcast publisher can currently stream this protocol.
    /// All four are wired: RTMP/RTMPS via RTMPPublisher, SRT/WHIP via the unified
    /// StreamSession publisher. WHIP (WebRTC) is experimental — validate memory on
    /// device, as libdatachannel adds meaningful memory and CPU overhead.
    public var isPublishingSupported: Bool { true }

    /// Codecs the bundled transport can actually packetize. RTCHaishinKit's WHIP
    /// stream currently has an H.264 RTP packetizer only; advertising HEVC there
    /// silently left the encoder at a default/fallback configuration.
    public var supportedVideoCodecs: [VideoCodec] {
        switch self {
        case .whip: return [.h264]
        case .rtmp, .rtmps, .srt: return VideoCodec.allCases
        }
    }

    public func supports(_ codec: VideoCodec) -> Bool {
        supportedVideoCodecs.contains(codec)
    }
}

// MARK: - StreamSettings (the ONLY shared persisted model)
public struct StreamSettings: Codable, Equatable, Sendable {
    /// The selected transport. Its URL + key live in the Keychain per-protocol.
    public var selectedProtocol: StreamProtocol
    public var rtmpURL: String          // active protocol's connection URL
    public var streamKey: String        // active protocol's key / stream id
    /// Target SHORT edge of the encoded video, in px (e.g. 720). The long edge is
    /// derived from the live screen's real aspect ratio at broadcast start, so the
    /// stream matches the device orientation (portrait or landscape) with no squish.
    public var videoQuality: Int
    public var videoBitrate: Int        // bits per second
    public var audioBitrate: Int        // bits per second
    public var frameRate: Int           // fps hint
    /// The encoder's target video codec. HEVC is honored on SRT and
    /// enhanced-RTMP; traditional RTMP ingests fall back to H.264 (see `VideoCodec`).
    public var videoCodec: VideoCodec
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
    /// When true, mic audio runs through the VoicePolishProcessor chain (broadcast
    /// EQ, two-stage compression, −1.5 dBFS limiting) before mixing/encoding.
    /// Applied at broadcast start; toggling mid-stream takes effect next broadcast.
    public var voicePolishEnabled: Bool
    /// When true, every broadcast is also recorded locally to an HD .mp4 in the
    /// shared App Group container (independent of the RTMP connection, so it
    /// survives a dropped/failed stream). The app auto-saves it to Photos.
    public var backupEnabled: Bool
    /// Target resolution for the local backup recording.
    public var backupQuality: BackupQuality

    public init(
        selectedProtocol: StreamProtocol = .rtmps,
        rtmpURL: String = "",
        streamKey: String = "",
        videoQuality: Int = 720,
        videoBitrate: Int = 3_000_000,
        audioBitrate: Int = 128_000,
        // 24 fps: lighter encode and thermal load than 30 while remaining smooth
        // for screencast content.
        frameRate: Int = 24,
        // H.264 Main by default: universally decodable, and the only codec
        // traditional RTMP ingests (Restream) accept. HEVC is an explicit opt-in.
        videoCodec: VideoCodec = .h264,
        pipEnabled: Bool = false,
        pipCorner: PIPCorner = .bottomRight,
        pipScale: Double = 0.28,
        cameraPosition: CameraPosition = .front,
        preferredAudioInputUID: String? = nil,
        includeAppAudio: Bool = true,
        micVolume: Double = 1.0,
        voicePolishEnabled: Bool = true,
        backupEnabled: Bool = false,
        backupQuality: BackupQuality = .hd1080
    ) {
        self.selectedProtocol = selectedProtocol
        self.rtmpURL = rtmpURL
        self.streamKey = streamKey
        self.videoQuality = videoQuality
        self.videoBitrate = videoBitrate
        self.audioBitrate = audioBitrate
        self.frameRate = frameRate
        self.videoCodec = videoCodec
        self.pipEnabled = pipEnabled
        self.pipCorner = pipCorner
        self.pipScale = pipScale
        self.cameraPosition = cameraPosition
        self.preferredAudioInputUID = preferredAudioInputUID
        self.includeAppAudio = includeAppAudio
        self.micVolume = micVolume
        self.voicePolishEnabled = voicePolishEnabled
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
        selectedProtocol = try c.decodeIfPresent(StreamProtocol.self, forKey: .selectedProtocol) ?? d.selectedProtocol
        rtmpURL = try c.decodeIfPresent(String.self, forKey: .rtmpURL) ?? d.rtmpURL
        streamKey = try c.decodeIfPresent(String.self, forKey: .streamKey) ?? d.streamKey
        videoQuality = try c.decodeIfPresent(Int.self, forKey: .videoQuality) ?? d.videoQuality
        videoBitrate = try c.decodeIfPresent(Int.self, forKey: .videoBitrate) ?? d.videoBitrate
        audioBitrate = try c.decodeIfPresent(Int.self, forKey: .audioBitrate) ?? d.audioBitrate
        frameRate = try c.decodeIfPresent(Int.self, forKey: .frameRate) ?? d.frameRate
        videoCodec = try c.decodeIfPresent(VideoCodec.self, forKey: .videoCodec) ?? d.videoCodec
        pipEnabled = try c.decodeIfPresent(Bool.self, forKey: .pipEnabled) ?? d.pipEnabled
        pipCorner = try c.decodeIfPresent(PIPCorner.self, forKey: .pipCorner) ?? d.pipCorner
        pipScale = try c.decodeIfPresent(Double.self, forKey: .pipScale) ?? d.pipScale
        cameraPosition = try c.decodeIfPresent(CameraPosition.self, forKey: .cameraPosition) ?? d.cameraPosition
        preferredAudioInputUID = try c.decodeIfPresent(String.self, forKey: .preferredAudioInputUID) ?? d.preferredAudioInputUID
        includeAppAudio = try c.decodeIfPresent(Bool.self, forKey: .includeAppAudio) ?? d.includeAppAudio
        micVolume = try c.decodeIfPresent(Double.self, forKey: .micVolume) ?? d.micVolume
        voicePolishEnabled = try c.decodeIfPresent(Bool.self, forKey: .voicePolishEnabled) ?? d.voicePolishEnabled
        backupEnabled = try c.decodeIfPresent(Bool.self, forKey: .backupEnabled) ?? d.backupEnabled
        backupQuality = try c.decodeIfPresent(BackupQuality.self, forKey: .backupQuality) ?? d.backupQuality
    }

    public static let `default` = StreamSettings()

    /// Defense-in-depth for restored/legacy settings: never hand a codec to a
    /// transport that cannot packetize it, even if the UI has not normalized yet.
    public var effectiveVideoCodec: VideoCodec {
        selectedProtocol.supports(videoCodec) ? videoCodec : .h264
    }

    /// True only when the selected protocol can currently publish AND its URL
    /// (plus its key, where the protocol requires one) are present and valid.
    public var isPublishable: Bool {
        guard selectedProtocol.isPublishingSupported,
              let url = URL(string: rtmpURL),
              let scheme = url.scheme?.lowercased(),
              selectedProtocol.urlSchemes.contains(scheme),
              url.host != nil else { return false }
        return selectedProtocol.requiresKey ? !streamKey.isEmpty : true
    }

    /// True when the connection is encrypted (RTMPS TLS, SRT AES, or WHIP HTTPS).
    public var isSecure: Bool {
        switch selectedProtocol {
        case .rtmps, .srt: return true
        case .whip: return URL(string: rtmpURL)?.scheme?.lowercased() == "https"
        case .rtmp: return false
        }
    }

    /// Derives the encode dimensions from the live (already upright-oriented)
    /// screen size, preserving the real aspect ratio. The short edge is clamped to
    /// `videoQuality` (never upscaled above the source) AND to `maxShortEdge` — the
    /// device-capability ceiling from `StreamCapability` (1080 on capable hardware,
    /// 720 otherwise) that replaced the old hard-coded 720 cap. Both edges are
    /// rounded to even numbers as required by H.264/HEVC. Locking this at broadcast
    /// start keeps the stream resolution stable for the whole session.
    public func encodeSize(forOrientedWidth width: Int, height: Int, maxShortEdge: Int) -> CGSize {
        let targetShortEdge = max(2, min(videoQuality, maxShortEdge))
        guard width > 0, height > 0 else {
            // Fallback to a portrait 9:16 canvas at the (capped) chosen quality.
            return CGSize(width: even(targetShortEdge), height: even(targetShortEdge * 16 / 9))
        }
        let shortEdge = min(width, height)
        let scale = min(1.0, Double(targetShortEdge) / Double(shortEdge))
        let w = even(Int((Double(width) * scale).rounded()))
        let h = even(Int((Double(height) * scale).rounded()))
        return CGSize(width: max(2, w), height: max(2, h))
    }

    /// The encode frame rate for a device capability: the user's chosen rate
    /// clamped to `[1, maxFrameRate]`. `maxFrameRate` is `StreamCapability`'s
    /// device ceiling (60 on capable hardware, else 30); this replaced the hard
    /// `min(frameRate, 30)` scattered across the encode/repeat paths. The thermal
    /// governor and adaptive controller cap the live rate further at runtime.
    public func encodeFrameRate(maxFrameRate: Int) -> Int {
        min(max(frameRate, 1), max(1, maxFrameRate))
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
