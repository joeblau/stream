import Testing
@testable import StreamCore

/// W04 (issue #67): validation runs BEFORE a settings draft is applied, so
/// malformed values must be caught here and never reach the store or the
/// controller. Empty-but-incomplete is deliberately not an error (Go Live
/// guards that via `isPublishable`); malformed is.
@Suite struct SettingsValidatorTests {

    @Test("Empty URL is incomplete, not invalid")
    func emptyURLPasses() {
        #expect(SettingsValidator.serverURLError("", for: .rtmp) == nil)
        #expect(SettingsValidator.serverURLError("   ", for: .rtmps) == nil)
    }

    @Test("Well-formed URLs for each protocol pass")
    func validURLs() {
        #expect(SettingsValidator.serverURLError("rtmp://live.restream.io/live", for: .rtmp) == nil)
        #expect(SettingsValidator.serverURLError("rtmps://host:443/app", for: .rtmps) == nil)
        #expect(SettingsValidator.serverURLError("srt://host:9000?streamid=x", for: .srt) == nil)
        #expect(SettingsValidator.serverURLError("https://host/whip/endpoint", for: .whip) == nil)
        #expect(SettingsValidator.serverURLError("http://host/whip", for: .whip) == nil)
    }

    @Test("A scheme the protocol cannot speak is invalid")
    func wrongScheme() {
        #expect(SettingsValidator.serverURLError("https://host/app", for: .rtmp) != nil)
        #expect(SettingsValidator.serverURLError("rtmp://host/app", for: .rtmps) != nil)
        #expect(SettingsValidator.serverURLError("rtmp://host/app", for: .whip) != nil)
    }

    @Test("Unparseable or host-less URLs are invalid")
    func malformedURLs() {
        #expect(SettingsValidator.serverURLError("not a url", for: .rtmp) != nil)
        #expect(SettingsValidator.serverURLError("rtmp://", for: .rtmp) != nil)
        #expect(SettingsValidator.serverURLError("rtmp://host:abc/app", for: .rtmp) != nil)
    }

    @Test("Out-of-range ports are invalid")
    func portRange() {
        #expect(SettingsValidator.serverURLError("rtmp://host:0/app", for: .rtmp) != nil)
        #expect(SettingsValidator.serverURLError("rtmp://host:99999/app", for: .rtmp) != nil)
        #expect(SettingsValidator.serverURLError("rtmp://host:65535/app", for: .rtmp) == nil)
        #expect(SettingsValidator.serverURLError("srt://host:9000", for: .srt) == nil)
    }

    @Test("Whitespace-only stream key is invalid; empty is incomplete")
    func streamKey() {
        #expect(SettingsValidator.streamKeyError("   ", for: .rtmp) != nil)
        #expect(SettingsValidator.streamKeyError("", for: .rtmp) == nil)
        #expect(SettingsValidator.streamKeyError("abc123", for: .rtmp) == nil)
        // SRT/WHIP embed credentials in the URL — no separate key to invalidate.
        #expect(SettingsValidator.streamKeyError("   ", for: .srt) == nil)
        #expect(SettingsValidator.streamKeyError("   ", for: .whip) == nil)
    }

    @Test("Blocking errors aggregate the malformed fields only")
    func blockingAggregation() {
        var settings = StreamSettings.default
        settings.rtmpURL = "https://wrong.scheme/app"
        settings.streamKey = "  "
        #expect(SettingsValidator.blockingErrors(for: settings).count == 2)

        settings.rtmpURL = "rtmps://live.restream.io/live"
        settings.streamKey = "key"
        #expect(SettingsValidator.blockingErrors(for: settings).isEmpty)

        // A fresh, empty snapshot blocks nothing — it is incomplete, not invalid.
        #expect(SettingsValidator.blockingErrors(for: .default).isEmpty)
    }
}
