import Testing
import CoreGraphics
import StreamCore

/// Unit tests for the local HD backup's encode geometry. The backup taps the
/// mixer output independently of the network stream, so its resolution logic
/// (clamp to chosen quality, never upscale past the real source, preserve the
/// stream's aspect + orientation, keep both edges even) is its own pure function.
@Suite struct BackupEncodeSizeTests {

    /// One row = (stream size, real source short edge, chosen quality) → expected
    /// encoded (width, height). Values hand-derived from `backupEncodeSize`.
    private struct Case {
        let streamW, streamH, source: Int
        let quality: BackupQuality
        let expW, expH: Int
    }

    @Test("Backup geometry across quality, orientation, and source clamping")
    func backupGeometry() {
        let cases: [Case] = [
            // hd1080 on a 720p portrait stream with a 1170px source → reaches 1080.
            Case(streamW: 720, streamH: 1280, source: 1170, quality: .hd1080, expW: 1080, expH: 1920),
            // hd1080 but the source is only 720 → cannot upscale past the source.
            Case(streamW: 720, streamH: 1280, source: 720,  quality: .hd1080, expW: 720,  expH: 1280),
            // matchStream keeps the stream's own short edge.
            Case(streamW: 720, streamH: 1560, source: 1170, quality: .matchStream, expW: 720, expH: 1560),
            // hd720 downscales a 1080p stream to a 720 short edge.
            Case(streamW: 1080, streamH: 1920, source: 1080, quality: .hd720, expW: 720, expH: 1280),
            // native uses the full source short edge (1170), aspect from the stream.
            Case(streamW: 720, streamH: 1280, source: 1170, quality: .native, expW: 1170, expH: 2080),
            // native with a source SMALLER than the stream floors at the stream short edge.
            Case(streamW: 720, streamH: 1280, source: 500,  quality: .native, expW: 720, expH: 1280),
            // Landscape stream: the short edge is the HEIGHT, and the output stays landscape.
            Case(streamW: 1280, streamH: 720, source: 800,  quality: .hd1080, expW: 1422, expH: 800),
        ]

        for c in cases {
            let settings = StreamSettings(backupQuality: c.quality)
            let size = settings.backupEncodeSize(
                streamSize: CGSize(width: c.streamW, height: c.streamH),
                sourceShortEdge: c.source)
            #expect(Int(size.width) == c.expW,
                    "width for \(c.quality) \(c.streamW)x\(c.streamH) src \(c.source)")
            #expect(Int(size.height) == c.expH,
                    "height for \(c.quality) \(c.streamW)x\(c.streamH) src \(c.source)")
        }
    }

    @Test("Both backup edges are always even, and the stream aspect is preserved")
    func evenAndAspectPreserved() {
        // Odd stream dimensions must still yield even encoded edges (H.264/HEVC),
        // while staying within a pixel of the stream's real aspect ratio.
        let settings = StreamSettings(backupQuality: .matchStream)
        let size = settings.backupEncodeSize(
            streamSize: CGSize(width: 721, height: 1281), sourceShortEdge: 1170)
        #expect(Int(size.width) % 2 == 0)
        #expect(Int(size.height) % 2 == 0)
        let streamAspect = 1281.0 / 721.0
        let encodedAspect = Double(size.height) / Double(size.width)
        #expect(abs(streamAspect - encodedAspect) < 0.01)
    }

    @Test("Backup never inverts orientation relative to the stream")
    func orientationMatchesStream() {
        let settings = StreamSettings(backupQuality: .hd1080)
        let portrait = settings.backupEncodeSize(
            streamSize: CGSize(width: 720, height: 1280), sourceShortEdge: 1170)
        #expect(portrait.height > portrait.width)

        let landscape = settings.backupEncodeSize(
            streamSize: CGSize(width: 1280, height: 720), sourceShortEdge: 1170)
        #expect(landscape.width > landscape.height)
    }
}

/// Unit tests for the backup bitrate heuristic: ~0.12 bits/pixel scaled by frame
/// rate, clamped to a 4–16 Mbps HD window, independent of the network bitrate.
@Suite struct BackupVideoBitrateTests {

    @Test("Small frames clamp up to the 4 Mbps floor")
    func floor() {
        let s = StreamSettings(frameRate: 24)
        #expect(s.backupVideoBitrate(for: CGSize(width: 720, height: 1280)) == 4_000_000)
    }

    @Test("Mid-size frames scale linearly with pixels and frame rate")
    func linearInRange() {
        // 1080x1920 @ 24: 2_073_600 * 24 * 0.12 = 5_971_968.
        #expect(StreamSettings(frameRate: 24)
            .backupVideoBitrate(for: CGSize(width: 1080, height: 1920)) == 5_971_968)
        // Same size @ 30: 2_073_600 * 30 * 0.12 = 7_464_960.
        #expect(StreamSettings(frameRate: 30)
            .backupVideoBitrate(for: CGSize(width: 1080, height: 1920)) == 7_464_960)
    }

    @Test("Large frames clamp down to the 16 Mbps ceiling")
    func ceiling() {
        let s = StreamSettings(frameRate: 24)
        #expect(s.backupVideoBitrate(for: CGSize(width: 2160, height: 3840)) == 16_000_000)
    }

    @Test("A zero frame rate is treated as at least 1 fps (no zero bitrate)")
    func zeroFrameRateFloored() {
        // max(1, frameRate) => 1 fps: 2_073_600 * 1 * 0.12 = 248_832 -> clamps to floor.
        let s = StreamSettings(frameRate: 0)
        #expect(s.backupVideoBitrate(for: CGSize(width: 1080, height: 1920)) == 4_000_000)
    }
}
