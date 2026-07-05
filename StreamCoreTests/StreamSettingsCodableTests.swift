import Testing
import Foundation
import StreamCore

/// Unit tests for `StreamSettings` Codable behavior. The custom `init(from:)`
/// exists so that a settings blob written by an OLDER build (missing the newer
/// keys) still decodes — every absent key falls back to its default instead of
/// throwing and wiping the user's saved snapshot on upgrade.
@Suite struct StreamSettingsCodableTests {

    private func decode(_ json: String) throws -> StreamSettings {
        try JSONDecoder().decode(StreamSettings.self, from: Data(json.utf8))
    }

    @Test("An empty object decodes to the full defaults")
    func emptyObjectIsDefaults() throws {
        #expect(try decode("{}") == .default)
    }

    @Test("A partial blob keeps present keys and defaults the rest")
    func partialKeepsPresentDefaultsRest() throws {
        let s = try decode(#"{"videoQuality": 1080, "frameRate": 30}"#)
        #expect(s.videoQuality == 1080)
        #expect(s.frameRate == 30)
        // Untouched keys fall back to defaults.
        #expect(s.selectedProtocol == .rtmps)
        #expect(s.micVolume == 1.0)
        #expect(s.audioBitrate == 128_000)
    }

    @Test("A blob written before the codec setting existed defaults to H.264")
    func missingVideoCodecDefaultsToH264() throws {
        // The upgrade path that matters: a snapshot from a build that predates
        // `videoCodec` must decode to the safe, universally-decodable H.264 rather
        // than throw and wipe the user's other saved settings.
        let s = try decode(#"{"videoBitrate": 6000000}"#)
        #expect(s.videoCodec == .h264)
        #expect(s.videoBitrate == 6_000_000)
    }

    @Test("An explicit HEVC codec decodes back to HEVC")
    func explicitHEVCDecodes() throws {
        #expect(try decode(#"{"videoCodec": "hevc"}"#).videoCodec == .hevc)
        #expect(try decode(#"{"videoCodec": "h264"}"#).videoCodec == .h264)
    }

    @Test("Explicit JSON null falls back to the default (not a decode failure)")
    func nullFallsBackToDefault() throws {
        let s = try decode(#"{"selectedProtocol": null, "videoQuality": null}"#)
        #expect(s.selectedProtocol == .rtmps)
        #expect(s.videoQuality == 720)
    }

    @Test("Unknown future keys are ignored, not rejected (forward compatibility)")
    func unknownKeysIgnored() throws {
        let s = try decode(#"{"videoQuality": 720, "someFutureKey": 42, "nested": {"x": 1}}"#)
        #expect(s.videoQuality == 720)
    }

    @Test("A fully-populated settings value round-trips through encode/decode")
    func fullRoundTrip() throws {
        let original = StreamSettings(
            selectedProtocol: .srt,
            rtmpURL: "srt://host:9000",
            streamKey: "sid",
            videoQuality: 1080,
            videoBitrate: 6_000_000,
            audioBitrate: 192_000,
            frameRate: 30,
            videoCodec: .hevc,
            pipEnabled: true,
            pipCorner: .topLeft,
            pipScale: 0.33,
            cameraPosition: .back,
            preferredAudioInputUID: "dji-usb-c-48k",
            includeAppAudio: false,
            micVolume: 1.5,
            backupEnabled: true,
            backupQuality: .native)
        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(StreamSettings.self, from: data)
        #expect(restored == original)
    }

    @Test("A nil optional audio input UID round-trips as nil")
    func nilOptionalRoundTrips() throws {
        let original = StreamSettings(preferredAudioInputUID: nil)
        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(StreamSettings.self, from: data)
        #expect(restored.preferredAudioInputUID == nil)
        #expect(restored == original)
    }

    @Test("An unknown protocol raw value is a hard decode error (documented boundary)")
    func unknownEnumRawValueThrows() {
        // decodeIfPresent tolerates a MISSING key, but a present-yet-invalid enum
        // value still throws — adding a new StreamProtocol case is not silently
        // forward-compatible for blobs written by that newer build.
        #expect(throws: (any Error).self) {
            _ = try decode(#"{"selectedProtocol": "quic"}"#)
        }
    }
}
