import Testing
import CoreGraphics
import StreamCore

/// Unit tests for the pure, deterministic encode-geometry logic that decides the
/// broadcast's resolution — the memory-critical policy that keeps the ~50 MB
/// extension under the jetsam budget.
@Suite struct StreamSettingsEncodeSizeTests {

    private func settings(videoQuality: Int = 720) -> StreamSettings {
        StreamSettings(videoQuality: videoQuality)
    }

    @Test("Tall portrait is capped to a 720px short edge, aspect preserved")
    func capsShortEdgeForTallPortrait() {
        let size = settings().encodeSize(forOrientedWidth: 1170, height: 2532)
        #expect(size.width == 720)
        #expect(size.height == 1558)   // 2532 * 720/1170, rounded to even
    }

    @Test("Never upscales a source smaller than the target short edge")
    func neverUpscales() {
        let size = settings().encodeSize(forOrientedWidth: 500, height: 900)
        #expect(size.width == 500)
        #expect(size.height == 900)
    }

    @Test("The 720 ceiling is enforced even when the user picks a higher quality")
    func hardCeilingWinsOverUserQuality() {
        let size = settings(videoQuality: 1080).encodeSize(forOrientedWidth: 1170, height: 2532)
        #expect(size.width == 720)
        #expect(Int(size.width) <= StreamSettings.maxStreamShortEdge)
    }

    @Test("Landscape caps the height (its short edge) instead of the width")
    func landscapeCapsHeight() {
        let size = settings().encodeSize(forOrientedWidth: 2532, height: 1170)
        #expect(size.height == 720)
        #expect(size.width == 1558)
    }

    @Test("Both encoded edges are always even (H.264/HEVC requirement)")
    func dimensionsAlwaysEven() {
        for (w, h) in [(1179, 2556), (1290, 2796), (1125, 2436), (828, 1792)] {
            let size = settings().encodeSize(forOrientedWidth: w, height: h)
            #expect(Int(size.width) % 2 == 0)
            #expect(Int(size.height) % 2 == 0)
        }
    }

    @Test("Zero dimensions fall back to a 720×1280 portrait canvas")
    func zeroFallsBackToPortrait() {
        let size = settings().encodeSize(forOrientedWidth: 0, height: 0)
        #expect(size.width == 720)
        #expect(size.height == 1280)
    }

    @Test("Aspect ratio is preserved within a pixel of rounding")
    func preservesAspectRatio() {
        let size = settings().encodeSize(forOrientedWidth: 1170, height: 2532)
        let source = 2532.0 / 1170.0
        let encoded = Double(size.height) / Double(size.width)
        #expect(abs(source - encoded) < 0.01)
    }
}

/// Sanity checks on the memory-conscious defaults.
@Suite struct StreamSettingsDefaultsTests {
    @Test("Defaults are the jetsam-safe 720p / 24fps profile")
    func memorySafeDefaults() {
        let s = StreamSettings()
        #expect(s.videoQuality == 720)
        #expect(s.frameRate == 24)
        #expect(s.selectedProtocol == .rtmps)
    }
}
