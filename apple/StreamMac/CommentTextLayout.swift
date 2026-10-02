import CoreGraphics
import CoreText
import Foundation
import StreamCore

struct CommentTextPage: Sendable {
    let bodyRange: NSRange
    let displayedText: String
}

struct CommentTextLayout: Sendable {
    let fontSize: CGFloat
    let pages: [CommentTextPage]
    let needsLargerBox: Bool

    /// Fit actual CoreText frames, then paginate at composed-character
    /// boundaries. Full provider text stays in the payload/queue/archive.
    /// A tiny box is reported explicitly instead of silently clipping text.
    static func make(text: String, headerLength: Int, requestedFontSize: CGFloat,
                     minimumFontSize: CGFloat, fontName: String?, box: CGSize,
                     alignment: TextHorizontalAlignment) -> Self {
        let value = text as NSString
        let headerCount = max(0, min(headerLength, value.length))
        let header = value.substring(to: headerCount)
        let body = value.substring(from: headerCount) as NSString
        let lower = max(1, min(requestedFontSize, minimumFontSize))
        let upper = max(lower, requestedFontSize)
        guard text.utf8.count <= 20_000, box.width >= 4, box.height >= 4 else {
            return .init(fontSize: lower, pages: [], needsLargerBox: true)
        }
        func framesetter(_ string: String, size: CGFloat) -> CTFramesetter {
            let font = TitleFontFallback.makeFont(requested: fontName, size: size)
            let attributes: [CFString: Any] = [kCTFontAttributeName: font,
                kCTParagraphStyleAttributeName: TextMeasurement.paragraphStyle(alignment: alignment, wraps: true, overflow: .clip)]
            return CTFramesetterCreateWithAttributedString(CFAttributedStringCreate(nil, string as CFString, attributes as CFDictionary)!)
        }
        func visible(_ setter: CTFramesetter, start: Int, size: CGSize) -> CFRange {
            let path = CGPath(rect: CGRect(origin: .zero, size: size), transform: nil)
            let frame = CTFramesetterCreateFrame(setter, CFRange(location: start, length: 0), path, nil)
            return CTFrameGetVisibleStringRange(frame)
        }
        func fits(_ size: CGFloat) -> Bool {
            visible(framesetter(text, size: size), start: 0, size: box).length >= value.length
        }
        if fits(lower) {
            var a = lower, b = upper
            for _ in 0..<10 { let midpoint = (a + b) / 2; if fits(midpoint) { a = midpoint } else { b = midpoint } }
            return .init(fontSize: a, pages: [.init(bodyRange: NSRange(location: 0, length: body.length), displayedText: text)], needsLargerBox: false)
        }
        let font = TitleFontFallback.makeFont(requested: fontName, size: lower)
        let headerSize = header.isEmpty ? .zero : TextMeasurement.measuredSize(text: header, font: font,
            maxWidth: box.width, alignment: alignment, wraps: true)
        let footerHeight = ceil(CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)) + 2
        var bodyBox = CGSize(width: box.width, height: box.height - headerSize.height - footerHeight - 2)
        let setter = framesetter(body as String, size: lower)
        // Mixed fallback fonts can have taller footer/newline metrics than
        // the primary font. Tighten the page body until its final composed
        // CoreText frame proves that every character fits.
        for _ in 0..<8 {
            guard bodyBox.height >= footerHeight else { break }
            var ranges: [NSRange] = [], start = 0
            while start < body.length, ranges.count < 256 {
                let visibleRange = visible(setter, start: start, size: bodyBox)
                var end = start + visibleRange.length
                if end < body.length, end > start {
                    let grapheme = body.rangeOfComposedCharacterSequence(at: end)
                    if grapheme.location < end { end = grapheme.location }
                }
                guard end > start else { return .init(fontSize: lower, pages: [], needsLargerBox: true) }
                ranges.append(NSRange(location: start, length: end - start)); start = end
            }
            guard start == body.length else { return .init(fontSize: lower, pages: [], needsLargerBox: true) }
            let pages = ranges.enumerated().map { index, range in
                let chunk = body.substring(with: range)
                return CommentTextPage(bodyRange: range, displayedText: header + chunk + (chunk.hasSuffix("\n") ? "" : "\n") + "\(index + 1) / \(ranges.count)")
            }
            if pages.allSatisfy({ visible(framesetter($0.displayedText, size: lower), start: 0, size: box).length >= ($0.displayedText as NSString).length }) {
                return .init(fontSize: lower, pages: pages, needsLargerBox: false)
            }
            bodyBox.height -= max(1, footerHeight / 4)
        }
        return .init(fontSize: lower, pages: [], needsLargerBox: true)
    }
}
