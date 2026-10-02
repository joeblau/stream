import Foundation
import Testing
@testable import StreamCore

@Suite struct DestinationProviderTemplateTests {
    @Test("Guides create isolated disabled drafts without weakening credential checks")
    func explicitCreation() {
        let capabilities = OutputCapabilities(hardwareTier: .uhd4K, hardwareMaxFrameRate: 60)
        for template in DestinationProviderTemplate.allCases {
            for transport in template.transports {
                let destination = template.makeDestination(transport: transport)
                #expect(!destination.isEnabled)
                #expect(destination.providerTemplate == template)
                #expect(!destination.followsProgramProfile)
                #expect(destination.ingestLimits?.source == .customOverride)
                #expect(destination.videoCodec == .h264)
                let errors = DestinationValidator.startErrors(destination, credentials: .init(), program: .default, capabilities: capabilities)
                #expect(errors.contains("Enter the destination endpoint URL."))
                if transport.requiresKey { #expect(errors.contains("Enter the stream key.")) }
            }
        }
        #expect(DestinationProviderTemplate.x.makeDestination().id != DestinationProviderTemplate.x.makeDestination().id)
    }
    @Test("Portable guidance round-trips, accepts older files and tolerates future guide IDs")
    func portableMetadata() throws {
        let source = DestinationProviderTemplate.instagram.makeDestination()
        let data = try JSONEncoder().encode(source)
        #expect(try JSONDecoder().decode(StreamDestination.self, from: data) == source)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["providerTemplateID"] as? String == "instagram")
        #expect(object["endpoint"] == nil && object["streamKey"] == nil)
        var legacy = object; legacy["providerTemplateID"] = nil
        let decoded = try JSONDecoder().decode(StreamDestination.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(decoded.providerTemplateID == nil)
        var future = object; future["providerTemplateID"] = "future-provider"
        #expect(try JSONDecoder().decode(StreamDestination.self, from: JSONSerialization.data(withJSONObject: future)).providerTemplate == nil)
        let duplicate = source.duplicated()
        #expect(duplicate.providerTemplateID == source.providerTemplateID && duplicate.id != source.id && !duplicate.isEnabled)
    }
    @Test("An attached service guide cannot imply unsupported protocol support")
    func protocolScope() {
        var destination = DestinationProviderTemplate.x.makeDestination()
        destination.transport = .srt
        let credentials = DestinationCredentials(endpoint: "srt://test.invalid:9000")
        let capabilities = OutputCapabilities(hardwareTier: .uhd4K, hardwareMaxFrameRate: 60)
        #expect(DestinationValidator.startErrors(destination, credentials: credentials, program: .default, capabilities: capabilities).contains { $0.contains("does not establish SRT") })
        destination.providerTemplateID = nil
        #expect(DestinationValidator.startErrors(destination, credentials: credentials, program: .default, capabilities: capabilities).isEmpty)
    }
    @Test("Portrait and three-second keyframes survive settings conversion without changing program")
    func settings() {
        let base = StreamSettings.default
        let portrait = DestinationProviderTemplate.instagram.makeDestination()
        let output = DestinationValidator.settings(portrait, credentials: .init(endpoint: "rtmps://test.invalid/live", streamKey: "fixture"), base: base)
        #expect(output.outputProfile.canvasWidth == 720 && output.outputProfile.canvasHeight == 1280 && output.frameRate == 30)
        #expect(base.outputProfile == .default)
        let x = DestinationProviderTemplate.x.makeDestination()
        #expect(DestinationValidator.settings(x, credentials: .init(), base: base).destinationKeyframeSeconds == 3)
    }
}
