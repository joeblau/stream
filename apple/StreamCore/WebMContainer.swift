import Foundation

/// G10 (issue #166): read-only EBML/WebM container parser — the pure-logic
/// core of the optional WebM/VP9 adapter. AVFoundation does not demux WebM,
/// so an adapter that feeds decoded frames into the `MediaFrameSource` pull
/// contract must walk the container itself: this parser turns a WebM file
/// into a track list plus a file-ordered frame index (payload ranges,
/// nanosecond timestamps, keyframe flags, and the VP8/VP9 alpha companion
/// stream carried in `BlockAdditions`).
///
/// **Scope.** WebM only (Matroska doctype accepted but not a target): the
/// elements an overlay player needs — Segment Info (timecode scale,
/// duration), Tracks (codec, codec-private, dimensions, alpha mode), and
/// Cluster blocks (SimpleBlock and BlockGroup, since alpha can only ride
/// BlockGroup/BlockAdditions). Cues are ignored on purpose: the adapter
/// builds its own keyframe index from the blocks it parses, so seeking never
/// trusts a file's (possibly missing) cue table. Laced blocks are rejected
/// with `unsupportedLacing` rather than decoded — ffmpeg's WebM muxer never
/// laces video, and silently misreading lace headers would corrupt frames.
///
/// **Bounded work.** Parsing is bounds-checked at every step: element counts
/// are capped, master-element nesting is depth-limited, and frame payloads
/// are stored as ranges into the source data (no copies), so peak memory is
/// the file itself plus the index.
public struct WebMContainer: Sendable {
    /// The bytes the index ranges refer into (shared, not copied).
    public let source: Data
    /// EBML doctype string ("webm" / "matroska") — diagnostics.
    public let docType: String
    /// Segment Info TimecodeScale in nanoseconds (WebM default 1_000_000).
    public let timecodeScaleNs: UInt64
    /// Segment duration in nanoseconds when the file declares one.
    public let durationNs: Double?
    public let tracks: [WebMTrack]
    /// Every SimpleBlock/BlockGroup block in file order (all tracks).
    public let frames: [WebMFrame]

    /// The first video track, if any (the overlay adapter decodes exactly one).
    public var videoTrack: WebMTrack? {
        tracks.first(where: { $0.type == .video })
    }

    /// Blocks of one track in file (decode) order.
    public func frames(forTrack trackNumber: UInt64) -> [WebMFrame] {
        frames.filter { $0.trackNumber == trackNumber }
    }
}

public struct WebMTrack: Sendable, Equatable {
    public enum TrackType: UInt64, Sendable {
        case video = 1
        case audio = 2
        case other = 0
    }

    public let number: UInt64
    public let type: TrackType
    /// Raw CodecID string ("V_VP9", "V_VP8", "V_AV1", "A_OPUS", …).
    public let codecID: String
    /// CodecPrivate payload range (VP9: the vpcC configuration record).
    public let codecPrivate: Range<Int>?
    public let pixelWidth: UInt64
    public let pixelHeight: UInt64
    /// Track Video AlphaMode element present and nonzero (VP8/VP9 alpha).
    public let hasAlphaMode: Bool
    /// DefaultDuration (per-frame) in nanoseconds when declared.
    public let defaultDurationNs: UInt64?
}

public struct WebMFrame: Sendable, Equatable {
    public let trackNumber: UInt64
    /// Absolute presentation timestamp in nanoseconds (cluster timecode plus
    /// the block's signed relative timecode, scaled by TimecodeScale).
    public let timestampNs: Int64
    /// SimpleBlock keyframe flag, or a BlockGroup with no ReferenceBlock.
    public let isKeyframe: Bool
    /// BlockDuration in nanoseconds when the BlockGroup declares one.
    public let durationNs: UInt64?
    /// Compressed frame bytes, as a range into `WebMContainer.source`.
    public let payload: Range<Int>
    /// The BlockAdditional with AddID 1 (the alpha companion frame), when
    /// the block carries one, as a range into `WebMContainer.source`.
    public let alphaPayload: Range<Int>?
}

public enum WebMContainerError: Error, Equatable {
    /// File does not start with an EBML header element.
    case notEBML
    /// EBML doctype is neither "webm" nor "matroska".
    case notWebM(String)
    /// A variable-length integer ran past its enclosing bounds.
    case malformedVINT(offset: Int)
    /// An element declares a size exceeding its parent / the file.
    case truncatedElement(offset: Int)
    /// Master-element nesting exceeded the depth cap.
    case nestingTooDeep
    /// Total parsed element count exceeded the work cap.
    case elementLimitExceeded
    /// A SimpleBlock/Block uses EBML or Xiph lacing, which is unsupported.
    case unsupportedLacing(offset: Int)
    /// The Segment carries no Tracks element.
    case missingTracks
    case invalidValue(String)
}

public enum WebMContainerParser {

    /// Parse a whole WebM file. `maxElements` bounds the total work for
    /// hostile or corrupt input; one million elements covers hours of
    /// overlay-length clips while a fuzzed file trips it immediately.
    public static func parse(_ input: Data,
                             maxElements: Int = 1_000_000) throws -> WebMContainer {
        guard input.count <= 512 * 1_024 * 1_024 else { throw WebMContainerError.invalidValue("File exceeds 512 MB prototype limit.") }
        // Data slices can retain a nonzero index origin.
        let data = input.startIndex == 0 ? input : Data(input)
        var reader = Reader(data: data, end: data.count, budget: Budget(limit: maxElements))
        var state = ParseState(maxElements: maxElements)
        try parseTopLevel(reader: &reader, state: &state, end: data.count)
        guard let docType = state.docType else { throw WebMContainerError.notEBML }
        guard docType == "webm" || docType == "matroska" else {
            throw WebMContainerError.notWebM(docType)
        }
        guard !state.tracks.isEmpty else { throw WebMContainerError.missingTracks }
        return WebMContainer(
            source: data,
            docType: docType,
            timecodeScaleNs: state.timecodeScaleNs,
            durationNs: state.durationNs,
            tracks: state.tracks,
            frames: state.frames)
    }

    // MARK: - Element IDs (EBML/Matroska/WebM)

    private enum ID: UInt32 {
        case ebmlHeader = 0x1A45DFA3
        case docType = 0x4282
        case segment = 0x18538067
        case info = 0x1549A966
        case timecodeScale = 0x2AD7B1
        case duration = 0x4489
        case tracks = 0x1654AE6B
        case trackEntry = 0xAE
        case trackNumber = 0xD7
        case trackType = 0x83
        case codecID = 0x86
        case codecPrivate = 0x63A2
        case video = 0xE0
        case pixelWidth = 0xB0
        case pixelHeight = 0xBA
        case alphaMode = 0x53C0
        case defaultDuration = 0x23E383
        case cluster = 0x1F43B675
        case clusterTimecode = 0xE7
        case simpleBlock = 0xA3
        case blockGroup = 0xA0
        case block = 0xA1
        case referenceBlock = 0xFB
        case blockDuration = 0x9B
        case blockAdditions = 0x75A1
        case blockMore = 0xA6
        case blockAddID = 0xEE
        case blockAdditional = 0xA5
    }

    fileprivate struct Element {
        let id: UInt32
        /// Absolute range of the element's payload in the source data.
        let content: Range<Int>
    }

    fileprivate final class Budget {
        let limit: Int
        var count = 0
        init(limit: Int) { self.limit = limit }
    }

    fileprivate struct Reader {
        let data: Data
        var offset = 0
        var end: Int
        let budget: Budget

        /// EBML element ID: 1–4 bytes, marker bit retained.
        mutating func readID() throws -> UInt32 {
            guard offset < end else { throw WebMContainerError.malformedVINT(offset: offset) }
            let first = data[offset]
            guard first != 0 else { throw WebMContainerError.malformedVINT(offset: offset) }
            var length = 1
            var mask: UInt8 = 0x80
            while first & mask == 0 {
                length += 1
                mask >>= 1
            }
            guard length <= 4, offset + length <= end else {
                throw WebMContainerError.malformedVINT(offset: offset)
            }
            var value: UInt32 = 0
            for index in 0..<length {
                value = value << 8 | UInt32(data[offset + index])
            }
            offset += length
            return value
        }

        /// EBML data size: 1–8 bytes, marker bit stripped; all data bits set
        /// means "unknown" (extends to the end of the parent), returned as nil.
        mutating func readSize() throws -> UInt64? {
            guard offset < end else { throw WebMContainerError.malformedVINT(offset: offset) }
            let first = data[offset]
            guard first != 0 else { throw WebMContainerError.malformedVINT(offset: offset) }
            var length = 1
            var mask: UInt8 = 0x80
            while first & mask == 0 {
                length += 1
                mask >>= 1
            }
            guard offset + length <= end else {
                throw WebMContainerError.malformedVINT(offset: offset)
            }
            var value = UInt64(first & (mask - 1))
            for index in 1..<length {
                value = value << 8 | UInt64(data[offset + index])
            }
            offset += length
            let allOnes = (UInt64(1) << (7 * length)) - 1
            return value == allOnes ? nil : value
        }

        mutating func readElement(remaining: Int, maxElements: Int) throws -> Element? {
            guard remaining > 0, offset < end else { return nil }
            budget.count += 1
            guard budget.count <= budget.limit else {
                throw WebMContainerError.elementLimitExceeded
            }
            let idOffset = offset
            let id = try readID()
            guard let declared = try readSize() else {
                // Unknown size: legal only for live-streamed Segments/Clusters;
                // treat as "to end of input".
                guard id == ID.segment.rawValue || id == ID.cluster.rawValue else {
                    throw WebMContainerError.truncatedElement(offset: idOffset)
                }
                let content = offset..<end
                offset = end
                return Element(id: id, content: content)
            }
            guard declared <= UInt64(end - offset) else {
                throw WebMContainerError.truncatedElement(offset: idOffset)
            }
            let end = offset + Int(declared)
            let element = Element(id: id, content: offset..<end)
            offset = end
            return element
        }

        func unsigned(_ range: Range<Int>) throws -> UInt64 {
            guard (1...8).contains(range.count) else { throw WebMContainerError.invalidValue("Invalid integer width.") }
            var value: UInt64 = 0
            for index in range { value = value << 8 | UInt64(data[index]) }
            return value
        }

        func string(_ range: Range<Int>) -> String {
            String(decoding: data[range], as: UTF8.self)
        }

        /// IEEE float, 4 or 8 bytes (EBML float width), as Double.
        func float(_ range: Range<Int>) throws -> Double? {
            switch range.count {
            case 4:
                let bits = UInt32(truncatingIfNeeded: try unsigned(range))
                return Double(Float(bitPattern: bits))
            case 8:
                return Double(bitPattern: try unsigned(range))
            default:
                return nil
            }
        }
    }

    private struct ParseState {
        let maxElements: Int
        var docType: String?
        var timecodeScaleNs: UInt64 = 1_000_000
        var durationNs: Double?
        var tracks: [WebMTrack] = []
        var frames: [WebMFrame] = []
    }

    // MARK: - Structural walk

    private static func parseTopLevel(reader: inout Reader,
                                      state: inout ParseState,
                                      end: Int) throws {
        while let element = try reader.readElement(remaining: end - reader.offset,
                                                   maxElements: state.maxElements) {
            switch ID(rawValue: element.id) {
            case .ebmlHeader:
                try parseEBMLHeader(reader: &reader, state: &state, element: element)
            case .segment:
                try parseSegment(reader: &reader, state: &state, element: element, depth: 1)
            default:
                break // Void, CRC-32, anything else: skipped by size.
            }
        }
    }

    private static func parseEBMLHeader(reader: inout Reader,
                                        state: inout ParseState,
                                        element: Element) throws {
        var sub = reader.slice(element.content)
        while sub.offset < element.content.upperBound {
            guard let child = try sub.readElement(remaining: element.content.upperBound - sub.offset,
                                                  maxElements: state.maxElements) else { break }
            if ID(rawValue: child.id) == .docType {
                state.docType = sub.string(child.content)
            }
        }

    }

    private static func parseSegment(reader: inout Reader,
                                     state: inout ParseState,
                                     element: Element,
                                     depth: Int) throws {
        guard depth < 12 else { throw WebMContainerError.nestingTooDeep }
        var sub = reader.slice(element.content)
        while sub.offset < element.content.upperBound {
            guard let child = try sub.readElement(remaining: element.content.upperBound - sub.offset,
                                                  maxElements: state.maxElements) else { break }
            switch ID(rawValue: child.id) {
            case .info:
                try parseInfo(reader: &sub, state: &state, element: child)
            case .tracks:
                try parseTracks(reader: &sub, state: &state, element: child)
            case .cluster:
                try parseCluster(reader: &sub, state: &state, element: child)
            default:
                break // SeekHead, Cues, Tags, Chapters, Attachments: skipped.
            }
        }

    }

    private static func parseInfo(reader: inout Reader,
                                  state: inout ParseState,
                                  element: Element) throws {
        var sub = reader.slice(element.content)
        while sub.offset < element.content.upperBound {
            guard let child = try sub.readElement(remaining: element.content.upperBound - sub.offset,
                                                  maxElements: state.maxElements) else { break }
            switch ID(rawValue: child.id) {
            case .timecodeScale:
                let scale = try sub.unsigned(child.content)
                guard scale > 0, scale <= UInt64(Int64.max) else {
                    throw WebMContainerError.invalidValue("Invalid timestamp scale.")
                }
                state.timecodeScaleNs = scale
            case .duration:
                if let seconds = try sub.float(child.content), seconds.isFinite, seconds >= 0 {
                    state.durationNs = seconds * Double(state.timecodeScaleNs)
                }
            default:
                break
            }
        }

    }

    private static func parseTracks(reader: inout Reader,
                                    state: inout ParseState,
                                    element: Element) throws {
        var sub = reader.slice(element.content)
        while sub.offset < element.content.upperBound {
            guard let child = try sub.readElement(remaining: element.content.upperBound - sub.offset,
                                                  maxElements: state.maxElements) else { break }
            if ID(rawValue: child.id) == .trackEntry {
                try parseTrackEntry(reader: &sub, state: &state, element: child)
            }
        }

    }

    private static func parseTrackEntry(reader: inout Reader,
                                        state: inout ParseState,
                                        element: Element) throws {
        var number: UInt64 = 0
        var type: WebMTrack.TrackType = .other
        var codecID = ""
        var codecPrivate: Range<Int>?
        var width: UInt64 = 0
        var height: UInt64 = 0
        var alphaMode = false
        var defaultDurationNs: UInt64?
        var sub = reader.slice(element.content)
        while sub.offset < element.content.upperBound {
            guard let child = try sub.readElement(remaining: element.content.upperBound - sub.offset,
                                                  maxElements: state.maxElements) else { break }
            switch ID(rawValue: child.id) {
            case .trackNumber:
                number = try sub.unsigned(child.content)
            case .trackType:
                type = WebMTrack.TrackType(rawValue: try sub.unsigned(child.content)) ?? .other
            case .codecID:
                codecID = sub.string(child.content)
            case .codecPrivate:
                codecPrivate = child.content
            case .defaultDuration:
                defaultDurationNs = try sub.unsigned(child.content)
            case .video:
                var video = sub.slice(child.content)
                while video.offset < child.content.upperBound {
                    guard let leaf = try video.readElement(
                        remaining: child.content.upperBound - video.offset,
                        maxElements: state.maxElements) else { break }
                    switch ID(rawValue: leaf.id) {
                    case .pixelWidth: width = try video.unsigned(leaf.content)
                    case .pixelHeight: height = try video.unsigned(leaf.content)
                    case .alphaMode: alphaMode = try video.unsigned(leaf.content) != 0
                    default: break
                    }
                }

            default:
                break
            }
        }

        state.tracks.append(WebMTrack(
            number: number,
            type: type,
            codecID: codecID,
            codecPrivate: codecPrivate,
            pixelWidth: width,
            pixelHeight: height,
            hasAlphaMode: alphaMode,
            defaultDurationNs: defaultDurationNs))
    }

    private static func parseCluster(reader: inout Reader,
                                     state: inout ParseState,
                                     element: Element) throws {
        var clusterTimecode: UInt64 = 0
        var sub = reader.slice(element.content)
        while sub.offset < element.content.upperBound {
            guard let child = try sub.readElement(remaining: element.content.upperBound - sub.offset,
                                                  maxElements: state.maxElements) else { break }
            switch ID(rawValue: child.id) {
            case .clusterTimecode:
                clusterTimecode = try sub.unsigned(child.content)
            case .simpleBlock:
                try parseSimpleBlock(reader: sub, state: &state,
                                     element: child, clusterTimecode: clusterTimecode)
            case .blockGroup:
                try parseBlockGroup(reader: &sub, state: &state,
                                    element: child, clusterTimecode: clusterTimecode)
            default:
                break
            }
        }

    }

    /// Block header: track number (EBML vint inside the payload), signed
    /// big-endian int16 timecode relative to the cluster, one flags byte.
    /// Returns the frame-data range and the parsed header fields.
    private static func parseBlockHeader(
        reader: Reader,
        content: Range<Int>,
        allowKeyframeFlag: Bool
    ) throws -> (trackNumber: UInt64, relativeTimecode: Int16, isKeyframe: Bool, frame: Range<Int>) {
        var cursor = content.lowerBound
        guard cursor < content.upperBound else {
            throw WebMContainerError.malformedVINT(offset: cursor)
        }
        let first = reader.data[cursor]
        guard first != 0 else { throw WebMContainerError.malformedVINT(offset: cursor) }
        var length = 1
        var mask: UInt8 = 0x80
        while first & mask == 0 {
            length += 1
            mask >>= 1
        }
        guard cursor + length + 3 <= content.upperBound else {
            throw WebMContainerError.truncatedElement(offset: content.lowerBound)
        }
        var trackNumber = UInt64(first & (mask - 1))
        for index in 1..<length {
            trackNumber = trackNumber << 8 | UInt64(reader.data[cursor + index])
        }
        cursor += length
        let high = Int16(bitPattern: UInt16(reader.data[cursor]))
        let relative = high << 8 | Int16(bitPattern: UInt16(reader.data[cursor + 1]))
        let flags = reader.data[cursor + 2]
        cursor += 3
        // Bits 2–1 are the lacing mode; only "no lacing" is supported.
        guard flags & 0x06 == 0 else {
            throw WebMContainerError.unsupportedLacing(offset: content.lowerBound)
        }
        return (trackNumber, relative, allowKeyframeFlag && flags & 0x80 != 0,
                cursor..<content.upperBound)
    }

    private static func parseSimpleBlock(reader: Reader,
                                         state: inout ParseState,
                                         element: Element,
                                         clusterTimecode: UInt64) throws {
        let block = try parseBlockHeader(reader: reader, content: element.content,
                                         allowKeyframeFlag: true)
        let timestamp = try timestamp(cluster: clusterTimecode, relative: block.relativeTimecode, scale: state.timecodeScaleNs)
        state.frames.append(WebMFrame(
            trackNumber: block.trackNumber,
            timestampNs: timestamp,
            isKeyframe: block.isKeyframe,
            durationNs: nil,
            payload: block.frame,
            alphaPayload: nil))
    }

    private static func parseBlockGroup(reader: inout Reader,
                                        state: inout ParseState,
                                        element: Element,
                                        clusterTimecode: UInt64) throws {
        var block: (range: Range<Int>, isKeyframe: Bool, track: UInt64, relative: Int16)?
        var durationNs: UInt64?
        var hasReference = false
        var alpha: Range<Int>?
        var sub = reader.slice(element.content)
        while sub.offset < element.content.upperBound {
            guard let child = try sub.readElement(remaining: element.content.upperBound - sub.offset,
                                                  maxElements: state.maxElements) else { break }
            switch ID(rawValue: child.id) {
            case .block:
                let parsed = try parseBlockHeader(reader: sub, content: child.content,
                                                  allowKeyframeFlag: false)
                block = (parsed.frame, parsed.isKeyframe, parsed.trackNumber, parsed.relativeTimecode)
            case .blockDuration:
                let product = try sub.unsigned(child.content).multipliedReportingOverflow(by: state.timecodeScaleNs)
                guard !product.overflow else { throw WebMContainerError.invalidValue("Duration overflow.") }
                durationNs = product.partialValue
            case .referenceBlock:
                hasReference = true
            case .blockAdditions:
                alpha = try parseBlockAdditions(reader: &sub, state: &state, element: child)
            default:
                break // ReferenceBlock, DiscardPadding: not needed to play.
            }
        }

        guard let block else { return }
        let timestamp = try timestamp(cluster: clusterTimecode, relative: block.relative, scale: state.timecodeScaleNs)
        state.frames.append(WebMFrame(
            trackNumber: block.track,
            timestampNs: timestamp,
            isKeyframe: !hasReference,
            durationNs: durationNs,
            payload: block.range,
            alphaPayload: alpha))
    }

    private static func timestamp(cluster: UInt64, relative: Int16, scale: UInt64) throws -> Int64 {
        guard cluster <= UInt64(Int64.max), scale > 0, scale <= UInt64(Int64.max) else {
            throw WebMContainerError.invalidValue("Invalid timestamp scale or cluster time.")
        }
        let sum = Int64(cluster).addingReportingOverflow(Int64(relative))
        let product = sum.partialValue.multipliedReportingOverflow(by: Int64(scale))
        guard !sum.overflow, !product.overflow else { throw WebMContainerError.invalidValue("Timestamp overflow.") }
        return product.partialValue
    }

    /// BlockAdditions → BlockMore → (BlockAddID, BlockAdditional); the alpha
    /// companion frame is the BlockAdditional whose BlockAddID is 1.
    private static func parseBlockAdditions(reader: inout Reader,
                                            state: inout ParseState,
                                            element: Element) throws -> Range<Int>? {
        var alpha: Range<Int>?
        var sub = reader.slice(element.content)
        while sub.offset < element.content.upperBound {
            guard let more = try sub.readElement(remaining: element.content.upperBound - sub.offset,
                                                 maxElements: state.maxElements) else { break }
            guard ID(rawValue: more.id) == .blockMore else { continue }
            var addID: UInt64 = 1
            var payload: Range<Int>?
            var inner = sub.slice(more.content)
            while inner.offset < more.content.upperBound {
                guard let leaf = try inner.readElement(
                    remaining: more.content.upperBound - inner.offset,
                    maxElements: state.maxElements) else { break }
                switch ID(rawValue: leaf.id) {
                case .blockAddID: addID = try inner.unsigned(leaf.content)
                case .blockAdditional: payload = leaf.content
                default: break
                }
            }

            if addID == 1 { alpha = payload }
        }

        return alpha
    }
}

private extension WebMContainerParser.Reader {
    /// A reader scoped to one element's payload (offsets stay absolute).
    func slice(_ content: Range<Int>) -> Self {
        var copy = self
        copy.offset = content.lowerBound
        copy.end = content.upperBound
        return copy
    }
}
