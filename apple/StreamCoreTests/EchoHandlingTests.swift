import Foundation
import Testing
import StreamCore

/// Tests for the A09 echo handling mode: persistence, backward-compatible
/// decode, and the documented path evaluation (issue #121: "evaluate … and
/// expose supported processing modes").
@Suite struct EchoHandlingTests {

    @Test("The echo handling mode round-trips through settings JSON")
    func modeRoundTrip() throws {
        var settings = StreamSettings.default
        settings.echoHandlingMode = .voiceIsolation
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(StreamSettings.self, from: data)
        #expect(decoded.echoHandlingMode == .voiceIsolation)
    }

    @Test("Settings blobs written before A09 decode to echo handling Off")
    func legacyBlobDecodesToOff() throws {
        let data = try JSONEncoder().encode(StreamSettings.default)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "echoHandlingMode")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(StreamSettings.self, from: legacy)
        #expect(decoded.echoHandlingMode == .off)
    }

    @Test("Every selectable mode declares its channel/stereo limitations")
    func modesDeclareLimitations() {
        for mode in EchoHandlingMode.allCases {
            #expect(!mode.displayName.isEmpty)
            #expect(!mode.limitationNote.isEmpty)
        }
    }

    @Test("The evaluation covers every candidate path the issue names")
    func evaluationCoversAllPaths() {
        let paths = EchoHandlingEvaluation.paths
        #expect(paths.count == EchoPathEvaluation.Path.allCases.count)
        for path in EchoPathEvaluation.Path.allCases {
            let evaluation = EchoHandlingEvaluation.evaluation(for: path)
            #expect(evaluation != nil)
            #expect(evaluation?.summary.isEmpty == false)
        }
    }

    @Test("Only the OS voice-isolation path is usable today")
    func onlyVoiceIsolationIsUsable() {
        let usable = EchoHandlingEvaluation.paths.filter(\.isUsable).map(\.path)
        #expect(usable == [.osVoiceIsolation])
    }
}
