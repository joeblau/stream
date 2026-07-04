import Testing
import StreamCore

/// Unit tests for `isPublishable` — the gate that decides whether the "Go Live"
/// control is enabled. It must validate that the URL parses, its scheme matches
/// the selected protocol, a host is present, and (for RTMP/RTMPS) a key is set.
@Suite struct StreamSettingsPublishableTests {

    private struct Case {
        let proto: StreamProtocol
        let url: String
        let key: String
        let expected: Bool
        let reason: String
    }

    private func settings(_ c: Case) -> StreamSettings {
        StreamSettings(selectedProtocol: c.proto, rtmpURL: c.url, streamKey: c.key)
    }

    @Test("isPublishable enforces scheme, host, and per-protocol key rules")
    func publishableMatrix() {
        let cases: [Case] = [
            .init(proto: .rtmps, url: "rtmps://live.restream.io/live", key: "abc",
                  expected: true,  reason: "valid RTMPS with key"),
            .init(proto: .rtmps, url: "rtmps://live.restream.io/live", key: "",
                  expected: false, reason: "RTMPS requires a key"),
            .init(proto: .rtmp,  url: "rtmp://host:1935/app", key: "k",
                  expected: true,  reason: "valid RTMP with key"),
            .init(proto: .rtmp,  url: "rtmps://host/app", key: "k",
                  expected: false, reason: "rtmp protocol rejects rtmps scheme"),
            .init(proto: .rtmps, url: "rtmp://host/app", key: "k",
                  expected: false, reason: "rtmps protocol rejects rtmp scheme"),
            .init(proto: .srt,   url: "srt://host:9000", key: "",
                  expected: true,  reason: "SRT needs no separate key"),
            .init(proto: .srt,   url: "srt://host:9000", key: "streamid",
                  expected: true,  reason: "SRT with an optional key is still fine"),
            .init(proto: .whip,  url: "https://host/whip", key: "",
                  expected: true,  reason: "WHIP over https"),
            .init(proto: .whip,  url: "http://host/whip", key: "",
                  expected: true,  reason: "WHIP over http (scheme allowed)"),
            .init(proto: .whip,  url: "srt://host/whip", key: "",
                  expected: false, reason: "WHIP rejects a non-http(s) scheme"),
            .init(proto: .rtmps, url: "not a valid url", key: "k",
                  expected: false, reason: "unparseable / scheme-less URL"),
            .init(proto: .rtmp,  url: "rtmp:app", key: "k",
                  expected: false, reason: "no host component"),
        ]

        for c in cases {
            #expect(settings(c).isPublishable == c.expected, "\(c.reason): \(c.url)")
        }
    }
}

/// Unit tests for `isSecure` — drives the lock icon. RTMPS and SRT are always
/// encrypted; RTMP never is; WHIP is secure only when the URL is HTTPS.
@Suite struct StreamSettingsSecureTests {

    private func settings(_ proto: StreamProtocol, _ url: String = "") -> StreamSettings {
        StreamSettings(selectedProtocol: proto, rtmpURL: url)
    }

    @Test("RTMPS and SRT are always reported secure")
    func alwaysSecure() {
        #expect(settings(.rtmps, "rtmps://host/live").isSecure)
        #expect(settings(.srt, "srt://host:9000").isSecure)
        // The URL value does not change the verdict for these two.
        #expect(settings(.rtmps, "").isSecure)
        #expect(settings(.srt, "").isSecure)
    }

    @Test("RTMP is never secure")
    func rtmpNeverSecure() {
        #expect(!settings(.rtmp, "rtmp://host/app").isSecure)
    }

    @Test("WHIP is secure only over HTTPS")
    func whipSecureOnlyOverHTTPS() {
        #expect(settings(.whip, "https://host/whip").isSecure)
        #expect(!settings(.whip, "http://host/whip").isSecure)
        #expect(!settings(.whip, "not a url").isSecure)
    }
}
