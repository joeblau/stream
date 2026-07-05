import Testing
import Foundation
import StreamCore

/// Unit tests for the `VideoCodec` encoder setting. The raw values are the
/// persisted, cross-process contract (they land in the JSON settings blob and are
/// read by both publishers), so a rename here is a breaking change these pins
/// catch. See `StreamSettingsCodableTests` for the settings-level round-trip.
@Suite struct VideoCodecTests {

    @Test("Exactly the two shipping codecs are offered")
    func casesAreH264AndHEVC() {
        #expect(VideoCodec.allCases == [.h264, .hevc])
    }

    @Test("Raw values are the stable persisted keys")
    func rawValuesAreStable() {
        // A rename would silently reset every user's saved codec to the default on
        // upgrade, so pin the wire strings explicitly.
        #expect(VideoCodec.h264.rawValue == "h264")
        #expect(VideoCodec.hevc.rawValue == "hevc")
    }

    @Test("Display names are the user-facing codec labels")
    func displayNames() {
        #expect(VideoCodec.h264.displayName == "H.264")
        #expect(VideoCodec.hevc.displayName == "HEVC")
    }

    @Test("The default settings target H.264 (universally decodable)")
    func defaultSettingsUseH264() {
        // H.264 is the only codec traditional RTMP ingests accept, and the app's
        // default protocol is RTMPS → Restream, so the out-of-box codec must be H.264.
        #expect(StreamSettings.default.videoCodec == .h264)
    }

    @Test("Each codec round-trips through Codable")
    func codableRoundTrip() throws {
        for codec in VideoCodec.allCases {
            let data = try JSONEncoder().encode(codec)
            #expect(try JSONDecoder().decode(VideoCodec.self, from: data) == codec)
        }
    }
}
