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

    @Test("A blob written before the capture-privacy settings existed gets their defaults")
    func missingCapturePrivacyDefaults() throws {
        // C03 (issue #78): snapshots from builds predating the privacy keys
        // must decode to cursor shown / audio included / no default
        // exclusions — never throw and wipe the user's other settings.
        let s = try decode(#"{"videoBitrate": 6000000}"#)
        #expect(s.captureShowsCursor)
        #expect(s.captureIncludesAudio)
        #expect(s.captureExcludedBundleIDs.isEmpty)
    }

    @Test("Capture-privacy settings round-trip through encode/decode")
    func capturePrivacyRoundTrips() throws {
        let original = StreamSettings(
            captureShowsCursor: false,
            captureIncludesAudio: false,
            captureExcludedBundleIDs: ["com.1password.1password", "com.apple.keychainaccess"])
        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(StreamSettings.self, from: data)
        #expect(restored == original)
        #expect(restored.captureExcludedBundleIDs == ["com.1password.1password", "com.apple.keychainaccess"])
    }

    @Test("A blob written before the A04 mixer document existed gets the default mixer")
    func missingMixerDefaults() throws {
        // A04 (issue #83): snapshots from builds predating the mixer must
        // decode to the all-unity, nothing-soloed/muted document — never
        // throw and wipe the user's other settings.
        let s = try decode(#"{"videoBitrate": 6000000}"#)
        #expect(s.mixer == MixerSettings())
    }

    @Test("The A04 mixer document round-trips through encode/decode")
    func mixerRoundTrips() throws {
        var mixer = MixerSettings()
        mixer.channelVolumes["app.com.example.player"] = 0.8
        mixer.channelMutes["mic.default"] = true
        mixer.soloedChannels = ["capture.screen-1"]
        mixer.channelAuxSends["guest.abc"] = 1
        mixer.busGains = ["program": 0.9, "monitor": 1.4]
        mixer.mutedBuses = ["program"]
        let original = StreamSettings(mixer: mixer)
        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(StreamSettings.self, from: data)
        #expect(restored == original)
        #expect(restored.mixer.soloedChannels == ["capture.screen-1"])
        #expect(restored.mixer.mutedBuses == ["program"])
    }

    @Test("A blob written before the A05 audio-input list existed gets an empty list")
    func missingAudioInputsDefaults() throws {
        // A05 (issue #84): snapshots from builds predating multi-mic must
        // decode to no ADDITIONAL inputs — the legacy preferredAudioInputUID
        // default-mic path is untouched, so that mic stays enabled.
        let s = try decode(#"{"preferredAudioInputUID": "usb-mic-1"}"#)
        #expect(s.audioInputs.isEmpty)
        #expect(s.preferredAudioInputUID == "usb-mic-1")
    }

    @Test("The A05 audio-input list round-trips through encode/decode")
    func audioInputsRoundTrip() throws {
        let original = StreamSettings(audioInputs: [
            AudioInputSelection(deviceUID: "interface-8ch", isEnabled: true,
                                mapping: .stereo(2, 3)),
            AudioInputSelection(deviceUID: "usb-mic-2", isEnabled: false,
                                mapping: .mono(1)),
        ])
        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(StreamSettings.self, from: data)
        #expect(restored == original)
        #expect(restored.audioInputs.count == 2)
        #expect(restored.audioInputs[0].mapping == .stereo(2, 3))
        #expect(restored.audioInputs[1].isEnabled == false)
    }

    @Test("An A05 input entry written before enable/mapping keys existed gets defaults")
    func audioInputSelectionDefaults() throws {
        let s = try decode(#"{"audioInputs": [{"deviceUID": "usb-mic-3"}]}"#)
        #expect(s.audioInputs == [AudioInputSelection(deviceUID: "usb-mic-3",
                                                      isEnabled: true, mapping: .all)])
    }

    @Test("A blob written before A07 monitoring existed decodes to monitoring off on the system default")
    func missingMonitoringDefaults() throws {
        // A07 (issue #119): snapshots from builds predating monitoring must
        // never surprise the user with audio output on upgrade.
        let s = try decode(#"{"micVolume": 1.2}"#)
        #expect(s.monitoringEnabled == false)
        #expect(s.monitorOutputDeviceUID == nil)
    }

    @Test("The A07 monitoring settings round-trip through encode/decode")
    func monitoringRoundTrip() throws {
        let original = StreamSettings(monitoringEnabled: true,
                                      monitorOutputDeviceUID: "AppleUSBAudioEngine:Focusrite:Scarlett")
        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(StreamSettings.self, from: data)
        #expect(restored == original)
        #expect(restored.monitoringEnabled == true)
        #expect(restored.monitorOutputDeviceUID == "AppleUSBAudioEngine:Focusrite:Scarlett")
    }
}
