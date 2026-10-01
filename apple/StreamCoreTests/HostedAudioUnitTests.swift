import Foundation
import Testing
import StreamCore

/// Tests for the A11 hosted Audio Unit chain model (issue #123): the
/// persisted component identity, slot state blobs, additive chain decoding,
/// validation bounds, and the `isActive` semantics that let an AU-only chain
/// leave the zero-cost bypass path. Hosting itself (graph build, load
/// failures, plugin behavior) is runtime-validated with real third-party
/// AUs on macOS — the logic here is platform-pure.
@Suite struct HostedAudioUnitTests {

    private func makeComponent(subType: UInt32 = 0x64656C79) -> AudioUnitComponentID {
        // 'aufx' / 'dely' / 'appl' — identity only; availability is NOT
        // asserted (registry contents are machine-dependent).
        AudioUnitComponentID(componentType: 0x61756678, componentSubType: subType,
                             manufacturer: 0x6170706C, displayName: "Apple: AUDelay")
    }

    // MARK: - Component identity

    @Test func componentIDRoundTripsThroughCodable() throws {
        let component = makeComponent()
        let data = try JSONEncoder().encode(component)
        let decoded = try JSONDecoder().decode(AudioUnitComponentID.self, from: data)
        #expect(decoded == component)
        #expect(decoded.componentDescription.componentType == 0x61756678)
        #expect(decoded.componentDescription.componentSubType == 0x64656C79)
        #expect(decoded.componentDescription.componentManufacturer == 0x6170706C)
    }

    @Test func componentIDDescriptionCarriesNoFlags() {
        let description = makeComponent().componentDescription
        #expect(description.componentFlags == 0)
        #expect(description.componentFlagsMask == 0)
    }

    // MARK: - State blob codec

    @Test func stateRoundTripsThroughBinaryPlist() {
        let fullState: [String: Any] = [
            "kAUPresetNameKey": "Warm Room",
            "classData": Data([0x01, 0x02, 0x03]),
            "param-7": 0.42
        ]
        let blob = HostedAudioUnitSlot.encodeState(fullState)
        #expect(blob != nil)
        let decoded = HostedAudioUnitSlot.decodeState(blob)
        #expect(decoded?["kAUPresetNameKey"] as? String == "Warm Room")
        #expect(decoded?["classData"] as? Data == Data([0x01, 0x02, 0x03]))
        #expect(decoded?["param-7"] as? Double == 0.42)
    }

    @Test func nonPlistSafeStatePersistsNothing() {
        // A plugin publishing a non-property-list value must not take the
        // settings document down — the slot simply saves no blob.
        let fullState: [String: Any] = ["object": NSObject()]
        #expect(HostedAudioUnitSlot.encodeState(fullState) == nil)
        #expect(HostedAudioUnitSlot.encodeState(nil) == nil)
    }

    @Test func corruptStateBlobDecodesToNil() {
        #expect(HostedAudioUnitSlot.decodeState(Data([0xFF, 0xFE, 0x00])) == nil)
        #expect(HostedAudioUnitSlot.decodeState(nil) == nil)
    }

    // MARK: - Chain integration

    @Test func chainWithSlotsRoundTripsThroughCodable() throws {
        var chain = ChannelFXChain.preset(.voice)
        chain.audioUnits = [
            HostedAudioUnitSlot(component: makeComponent(), isEnabled: true,
                                state: HostedAudioUnitSlot.encodeState(["a": 1])),
            HostedAudioUnitSlot(component: makeComponent(subType: 0x6E646C79),
                                isEnabled: false)
        ]
        let data = try JSONEncoder().encode(chain)
        let decoded = try JSONDecoder().decode(ChannelFXChain.self, from: data)
        #expect(decoded == chain)
        #expect(decoded.audioUnits.count == 2)
        #expect(decoded.audioUnits[0].state != nil)
        #expect(decoded.audioUnits[1].isEnabled == false)
    }

    @Test func legacyChainBlobWithoutAudioUnitsStillDecodes() throws {
        // Additive decoding: a chain blob written before A11 carries no
        // `audioUnits` key and must decode to an empty slot list, not throw
        // (a throw would take the whole settings document down).
        var chain = ChannelFXChain.preset(.podcast)
        chain.audioUnits = [HostedAudioUnitSlot(component: makeComponent())]
        let data = try JSONEncoder().encode(chain)
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        object.removeValue(forKey: "audioUnits")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(ChannelFXChain.self, from: legacy)
        #expect(decoded.audioUnits.isEmpty)
        #expect(decoded.preset == .podcast)
        #expect(decoded.compressor == ChannelFXChain.preset(.podcast).compressor)
    }

    @Test func enabledSlotMakesChainActive() {
        var chain = ChannelFXChain() // Off: every native section bypassed
        #expect(chain.isActive == false)
        chain.audioUnits = [HostedAudioUnitSlot(component: makeComponent(), isEnabled: false)]
        #expect(chain.isActive == false)
        chain.audioUnits[0].isEnabled = true
        #expect(chain.isActive == true)
    }

    // MARK: - Validation

    @Test func slotCountIsBounded() {
        var chain = ChannelFXChain()
        chain.audioUnits = (0..<HostedAudioUnitSlot.maxSlotsPerChannel).map { _ in
            HostedAudioUnitSlot(component: makeComponent())
        }
        #expect(chain.validationError == nil)
        chain.audioUnits.append(HostedAudioUnitSlot(component: makeComponent()))
        #expect(chain.validationError != nil)
    }

    @Test func oversizedStateBlobIsRejected() {
        var chain = ChannelFXChain()
        chain.audioUnits = [HostedAudioUnitSlot(
            component: makeComponent(),
            state: Data(repeating: 0, count: HostedAudioUnitSlot.maxStateBytes + 1))]
        #expect(chain.validationError != nil)
    }
}
