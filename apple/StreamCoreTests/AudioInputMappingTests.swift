import Testing
import Foundation
import StreamCore

/// Unit tests for the A05 hardware-channel mapping model (issue #84): the
/// resolution of a persisted `AudioInputMapping` against a device's actual
/// input channel count, including the clamping that keeps a mapping written
/// for a bigger interface honest on a smaller one.
@Suite struct AudioInputMappingTests {

    /// Tuples aren't `Equatable`, so pair assertions go through components.
    private func expectPair(_ pair: (left: Int, right: Int)?,
                            _ left: Int, _ right: Int,
                            sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(pair?.left == left, sourceLocation: sourceLocation)
        #expect(pair?.right == right, sourceLocation: sourceLocation)
    }

    @Test("`.all` is passthrough at any channel count")
    func allIsPassthrough() {
        #expect(AudioInputMapping.all.stereoPair(channelCount: 1) == nil)
        #expect(AudioInputMapping.all.stereoPair(channelCount: 8) == nil)
    }

    @Test("Mono selects one hardware channel onto both sides")
    func monoSelectsChannel() {
        expectPair(AudioInputMapping.mono(2).stereoPair(channelCount: 4), 2, 2)
        expectPair(AudioInputMapping.mono(0).stereoPair(channelCount: 1), 0, 0)
    }

    @Test("Stereo maps a hardware pair to L/R")
    func stereoMapsPair() {
        expectPair(AudioInputMapping.stereo(0, 1).stereoPair(channelCount: 8), 0, 1)
        expectPair(AudioInputMapping.stereo(4, 5).stereoPair(channelCount: 8), 4, 5)
    }

    @Test("Out-of-range indices clamp into the device instead of going silent")
    func outOfRangeClamps() {
        // A mapping persisted while an 8-channel interface was connected must
        // still produce signal if the device later reports fewer channels.
        expectPair(AudioInputMapping.mono(7).stereoPair(channelCount: 2), 1, 1)
        expectPair(AudioInputMapping.stereo(6, 7).stereoPair(channelCount: 2), 1, 1)
        expectPair(AudioInputMapping.mono(-1).stereoPair(channelCount: 4), 0, 0)
    }

    @Test("A device reporting no channels resolves to passthrough")
    func zeroChannelsPassthrough() {
        #expect(AudioInputMapping.mono(0).stereoPair(channelCount: 0) == nil)
        #expect(AudioInputMapping.stereo(0, 1).stereoPair(channelCount: 0) == nil)
    }

    @Test("Mappings round-trip through Codable")
    func mappingRoundTrips() throws {
        for mapping in [AudioInputMapping.all, .mono(3), .stereo(0, 5)] {
            let data = try JSONEncoder().encode(mapping)
            #expect(try JSONDecoder().decode(AudioInputMapping.self, from: data) == mapping)
        }
    }
}
