import CoreText
import Foundation

@main enum TextParagraphStyleHarness {
    @inline(never) static func stackPressure(_ seed: UInt64) -> UInt64 {
        withUnsafeTemporaryAllocation(of: UInt64.self, capacity: 1024) { buffer in
            for index in buffer.indices { buffer[index] = seed &+ UInt64(index) &* 0x9e3779b97f4a7c15 }
            var checksum = seed
            for index in buffer.indices { checksum ^= buffer[index] &* UInt64(index + 1) }
            return checksum
        }
    }

    @inline(never) static func createdStyles() -> [(CTParagraphStyle, CTTextAlignment, CTLineBreakMode)] {
        let alignments: [(TextHorizontalAlignment, CTTextAlignment)] = [
            (.leading, .left), (.center, .center), (.trailing, .right)
        ]
        let policies: [(Bool, TextOverflow, CTLineBreakMode)] = [
            (false, .clip, .byClipping), (true, .clip, .byWordWrapping),
            (false, .ellipsis, .byTruncatingTail), (true, .ellipsis, .byTruncatingTail),
            (false, .scaleDown, .byClipping), (true, .scaleDown, .byWordWrapping)
        ]
        return alignments.flatMap { alignment, expectedAlignment in
            policies.map { wraps, overflow, expectedBreak in
                (TextMeasurement.paragraphStyle(alignment: alignment, wraps: wraps, overflow: overflow), expectedAlignment, expectedBreak)
            }
        }
    }

    static func main() {
        // Both production locals and this non-inlined creator frame have exited.
        let styles = createdStyles()
        precondition(styles.count == 18)
        var checksum: UInt64 = 0
        for repetition in 0..<256 {
            checksum ^= stackPressure(UInt64(repetition))
            for (style, expectedAlignment, expectedBreak) in styles {
                var alignment = CTTextAlignment.natural
                var lineBreak = CTLineBreakMode.byCharWrapping
                precondition(CTParagraphStyleGetValueForSpecifier(style, .alignment, MemoryLayout<CTTextAlignment>.size, &alignment))
                precondition(CTParagraphStyleGetValueForSpecifier(style, .lineBreakMode, MemoryLayout<CTLineBreakMode>.size, &lineBreak))
                precondition(alignment == expectedAlignment && lineBreak == expectedBreak)
            }
        }
        print("PASS actual Core Text paragraph values:18 alignment/wrap/overflow combinations,256 post-return stack-pressure rounds; checksum=\(checksum)")
    }
}
