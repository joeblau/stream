import Testing
import Foundation
import StreamCore

/// Unit tests for the `StreamProtocol` enum — the per-transport metadata that
/// drives the UI (segmented control labels, field labels, placeholders) and the
/// publisher's key/scheme requirements.
@Suite struct StreamProtocolTests {

    @Test("All four cases are declared in a stable order")
    func caseIterableIsStable() {
        #expect(StreamProtocol.allCases == [.rtmp, .rtmps, .srt, .whip])
    }

    @Test("Display names match the wire/brand casing")
    func displayNames() {
        #expect(StreamProtocol.rtmp.displayName == "RTMP")
        #expect(StreamProtocol.rtmps.displayName == "RTMPS")
        #expect(StreamProtocol.srt.displayName == "SRT")
        #expect(StreamProtocol.whip.displayName == "WHIP")
    }

    @Test("URL schemes gate which URLs each protocol accepts")
    func urlSchemes() {
        #expect(StreamProtocol.rtmp.urlSchemes == ["rtmp"])
        #expect(StreamProtocol.rtmps.urlSchemes == ["rtmps"])
        #expect(StreamProtocol.srt.urlSchemes == ["srt"])
        // WHIP is HTTP-based signaling, so both schemes are valid.
        #expect(StreamProtocol.whip.urlSchemes == ["http", "https"])
    }

    @Test("Only RTMP/RTMPS require a separate stream key")
    func requiresKey() {
        #expect(StreamProtocol.rtmp.requiresKey)
        #expect(StreamProtocol.rtmps.requiresKey)
        #expect(!StreamProtocol.srt.requiresKey)   // key is embedded in the URL
        #expect(!StreamProtocol.whip.requiresKey)  // bearer token is optional
    }

    @Test("Every protocol is currently publishable")
    func allPublishingSupported() {
        for proto in StreamProtocol.allCases {
            #expect(proto.isPublishingSupported)
        }
    }

    @Test("Placeholders and key-field labels are always populated for the UI")
    func uiStringsNonEmpty() {
        for proto in StreamProtocol.allCases {
            #expect(!proto.urlPlaceholder.isEmpty, "urlPlaceholder for \(proto)")
            #expect(!proto.keyFieldLabel.isEmpty, "keyFieldLabel for \(proto)")
            #expect(!proto.displayName.isEmpty, "displayName for \(proto)")
        }
    }

    @Test("Raw values round-trip through Codable for persistence stability")
    func rawValueCodableRoundTrip() throws {
        for proto in StreamProtocol.allCases {
            let data = try JSONEncoder().encode(proto)
            let restored = try JSONDecoder().decode(StreamProtocol.self, from: data)
            #expect(restored == proto)
        }
    }
}
