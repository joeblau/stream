import Foundation
import Testing
import StreamCore

@Suite struct WebMContainerTests {
    private func element(_ id: [UInt8], _ bytes: [UInt8]) -> [UInt8] {
        precondition(bytes.count < 127)
        return id + [0x80 | UInt8(bytes.count)] + bytes
    }

    private func fixture(unknownSize: Bool = false, reference: Bool = false,
                         scale: [UInt8]? = nil) -> Data {
        let header = element([0x1a,0x45,0xdf,0xa3], element([0x42,0x82], Array("webm".utf8)))
        let track = element([0xae], element([0xd7], [1]) + element([0x83], [1])
            + element([0x86], Array("V_VP9".utf8)))
        let info = scale.map { element([0x15,0x49,0xa9,0x66], element([0x2a,0xd7,0xb1], $0)) } ?? []
        let block = element([0xa1], [0x81,0,1,0,42])
        let alpha = element([0x75,0xa1], element([0xa6], element([0xa5], [77])))
        let group = element([0xa0], block + alpha + (reference ? element([0xfb], [0]) : []))
        let cluster = element([0x1f,0x43,0xb6,0x75], element([0xe7], [0]) + group)
        let body = info + element([0x16,0x54,0xae,0x6b], track) + cluster
        let segment = unknownSize
            ? [0x18,0x53,0x80,0x67,0x01,0xff,0xff,0xff,0xff,0xff,0xff,0xff] + body
            : element([0x18,0x53,0x80,0x67], body)
        return Data(header + segment)
    }

    @Test func parsesTimestampAlphaAndKeyframe() throws {
        let parsed = try WebMContainerParser.parse(fixture())
        #expect(parsed.videoTrack?.codecID == "V_VP9")
        #expect(parsed.frames.count == 1)
        let frame = try #require(parsed.frames.first)
        #expect(frame.timestampNs == 1_000_000)
        #expect(frame.isKeyframe)
        #expect(Array(parsed.source[frame.payload]) == [42])
        let alpha = try #require(frame.alphaPayload)
        #expect(Array(parsed.source[alpha]) == [77])
        #expect(try WebMContainerParser.parse(fixture(reference: true)).frames.first?.isKeyframe == false)
    }

    @Test func handlesEightByteUnknownSegmentSize() throws {
        #expect(try WebMContainerParser.parse(fixture(unknownSize: true)).frames.count == 1)
    }

    @Test func enforcesGlobalWorkBudget() {
        #expect(throws: WebMContainerError.elementLimitExceeded) {
            try WebMContainerParser.parse(fixture(), maxElements: 3)
        }
    }

    @Test func rejectsChildEscapingItsParent() {
        let data = Data([0x1a,0x45,0xdf,0xa3,0x83,0x42,0x82,0x8a] + Array(repeating: UInt8(1),count:10))
        #expect(throws: WebMContainerError.self) { try WebMContainerParser.parse(data) }
    }

    @Test func rejectsTimestampAndIntegerOverflow() {
        #expect(throws: WebMContainerError.self) {
            try WebMContainerParser.parse(fixture(scale: Array(repeating: 255, count: 8)))
        }
        #expect(throws: WebMContainerError.self) {
            try WebMContainerParser.parse(fixture(scale: Array(repeating: 1, count: 9)))
        }
    }

    @Test func malformedHeadersFailWithoutReadingPastBounds() {
        for bytes: [UInt8] in [[], [0], [0x1a], [0x1a,0x45,0xdf,0xa3], [0x1a,0x45,0xdf,0xa3,0x81]] {
            #expect(throws: WebMContainerError.self) { try WebMContainerParser.parse(Data(bytes)) }
        }
    }
}
