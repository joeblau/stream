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
                if [.facebookPages, .linkedinLive].contains(template) {
                    #expect(destination.followsProgramProfile && destination.ingestLimits == nil)
                    #expect(destination.keyframeSeconds == nil)
                } else {
                    #expect(!destination.followsProgramProfile)
                    #expect(destination.ingestLimits?.source == .customOverride)
                }
                #expect(destination.videoCodec == .h264)
                let errors = DestinationValidator.startErrors(destination, credentials: .init(), program: .default, capabilities: capabilities)
                #expect(errors.contains("Enter the destination endpoint URL."))
                if transport.requiresKey { #expect(errors.contains("Enter the stream key.")) }
            }
        }
        #expect(DestinationProviderTemplate.x.makeDestination().id != DestinationProviderTemplate.x.makeDestination().id)
    }
    @Test("Every guided starting profile validates once its issued credentials are supplied")
    func usableProfiles() {
        let capabilities = OutputCapabilities(hardwareTier: .uhd4K, hardwareMaxFrameRate: 60)
        for template in DestinationProviderTemplate.allCases {
            for transport in template.transports {
                let destination = template.makeDestination(transport: transport)
                let endpoint: String
                switch transport {
                case .rtmp: endpoint = "rtmp://test.invalid/live"
                case .rtmps: endpoint = "rtmps://test.invalid/live"
                case .srt: endpoint = "srt://test.invalid:9000?streamid=fixture"
                case .whip: endpoint = "https://test.invalid/whip/fixture"
                }
                let credentials = DestinationCredentials(endpoint: endpoint, streamKey: transport.requiresKey ? "fixture" : "")
                #expect(DestinationValidator.startErrors(destination, credentials: credentials, program: .default, capabilities: capabilities).isEmpty)
            }
        }
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
    @Test("Manual social guides retain provider identity without account or event authority")
    func manualSocialIdentity() throws {
        for template in [DestinationProviderTemplate.facebookPages, .linkedinLive] {
            var destination = template.makeDestination()
            let originalID = destination.id
            destination.name = "Renamed production destination"
            let data = try JSONEncoder().encode(destination)
            let reloaded = try JSONDecoder().decode(StreamDestination.self, from: data)
            #expect(reloaded.id == originalID && reloaded.providerTemplate == template)
            #expect(!reloaded.isEnabled && reloaded.transport == .rtmps)
            #expect(reloaded.providerBinding == nil)
            var oldManual = StreamDestination(id: reloaded.id, name: reloaded.name, isEnabled: false)
            oldManual.providerTemplateID = template.rawValue
            #expect(reloaded == oldManual)
            #expect(template.transports == [.rtmps] && !template.isRelay)
            #expect(template.capabilityDisclosure.contains("event scheduling"))
            #expect(template.capabilityDisclosure.contains("remote event state"))
            let duplicate = reloaded.duplicated()
            #expect(duplicate.id != originalID && duplicate.providerTemplate == template && !duplicate.isEnabled)
            var detached = reloaded
            detached.providerTemplateID = nil
            #expect(detached.providerTemplate == nil && detached.id == originalID)
            #expect(detached.outputProfile == reloaded.outputProfile && detached.transport == reloaded.transport)
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(object["providerBinding"] == nil && object["endpoint"] == nil && object["streamKey"] == nil)
        }
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
