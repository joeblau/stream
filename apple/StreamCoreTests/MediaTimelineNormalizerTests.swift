import Testing
import CoreMedia
import StreamCore

/// Tests the timeline-rebasing math that removes capture/reconnect wall-clock gaps
/// before samples reach the encoder — previously untestable inside the app target.
@Suite struct MediaTimelineRebaseTests {
    // Milliseconds timescale keeps the arithmetic exact and readable.
    private func ms(_ v: Int64) -> CMTime { CMTime(value: v, timescale: 1000) }
    private func same(_ a: CMTime, _ b: CMTime) -> Bool { CMTimeCompare(a, b) == 0 }

    @Test("A forward gap grows the offset to swallow it")
    func forwardGapSwallowed() {
        // source jumped to 10s; last sample ended at 1s + 33ms → gap ≈ 8.967s.
        let offset = MediaTimelineNormalizer.rebasedOffset(
            sourcePTS: ms(10_000), accumulatedOffset: .zero, prior: ms(1_000), sampleDuration: ms(33))
        #expect(same(offset, ms(8_967)))
    }

    @Test("A perfectly continuous sample leaves the offset unchanged")
    func continuousNoOp() {
        // source == prior + duration → gap 0 → no change.
        let offset = MediaTimelineNormalizer.rebasedOffset(
            sourcePTS: ms(1_033), accumulatedOffset: .zero, prior: ms(1_000), sampleDuration: ms(33))
        #expect(same(offset, .zero))
    }

    @Test("A backward jump never moves the offset (timestamps can't go back)")
    func backwardJumpIgnored() {
        let offset = MediaTimelineNormalizer.rebasedOffset(
            sourcePTS: ms(500), accumulatedOffset: .zero, prior: ms(1_000), sampleDuration: ms(33))
        #expect(same(offset, .zero))
    }

    @Test("A second gap accumulates on top of the existing offset")
    func gapAccumulates() {
        // offset already 8.967s; source now 20s, prior 1.033s (post-offset), dur 33ms.
        let offset = MediaTimelineNormalizer.rebasedOffset(
            sourcePTS: ms(20_000), accumulatedOffset: ms(8_967), prior: ms(1_033), sampleDuration: ms(33))
        // prospective 20000-8967=11033; desired 1033+33=1066; gap 9967 → 8967+9967=18934.
        #expect(same(offset, ms(18_934)))
    }
}

/// Full-path tests through the CMSampleBuffer machinery (steady-state passthrough
/// and a real rebase after a discontinuity).
@Suite struct MediaTimelineNormalizerBufferTests {
    private func ms(_ v: Int64) -> CMTime { CMTime(value: v, timescale: 1000) }

    /// A timing-only CMSampleBuffer (no data/format) — enough for the timing path.
    private func buffer(pts: CMTime, duration: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(duration: duration,
                                        presentationTimeStamp: pts,
                                        decodeTimeStamp: .invalid)
        var out: CMSampleBuffer?
        let status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: nil,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &out)
        return status == noErr ? out : nil
    }

    @Test("Steady state returns the buffer unchanged (no discontinuity)")
    func steadyStatePassthrough() throws {
        var n = MediaTimelineNormalizer()
        let sb = try #require(buffer(pts: ms(1_000), duration: ms(33)))
        let out = n.normalize(sb, kind: .video, fallbackDuration: ms(33))
        #expect(CMTimeCompare(out.presentationTimeStamp, ms(1_000)) == 0)
    }

    @Test("After a discontinuity the gap is removed from the sample's PTS")
    func rebaseRemovesGap() throws {
        var n = MediaTimelineNormalizer()
        // Prime the last-PTS at 1s.
        let first = try #require(buffer(pts: ms(1_000), duration: ms(33)))
        _ = n.normalize(first, kind: .video, fallbackDuration: ms(33))
        // Discontinuity, then a sample that jumped to 10s — should be pulled back so
        // it continues ~1.033s (gap of ~8.967s removed).
        n.markDiscontinuity()
        let jumped = try #require(buffer(pts: ms(10_000), duration: ms(33)))
        let out = n.normalize(jumped, kind: .video, fallbackDuration: ms(33))
        #expect(CMTimeCompare(out.presentationTimeStamp, ms(1_033)) == 0)
    }
}
