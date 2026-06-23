import Foundation
import CoreGraphics

// MARK: - App Group constants (single source of truth)
public enum AppGroup {
    /// App Group identifier; identical to the UserDefaults suite name.
    public static let identifier = "group.com.joeblau.Stream"
    /// Key under which the JSON-encoded StreamSettings blob is stored.
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
        includeAppAudio: Bool = true
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

    private func even(_ value: Int) -> Int { value - (value % 2) }
}
