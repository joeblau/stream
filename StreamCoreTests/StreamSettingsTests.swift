import Testing
import CoreGraphics
import StreamCore

/// Unit tests for the pure, deterministic encode-geometry logic that decides the
/// broadcast's resolution. The short-edge ceiling is now supplied by the caller
/// (the device-derived `StreamCapability.maxShortEdge`) instead of a hard 720
/// constant, so 1080p is reachable on capable hardware while older devices stay
/// clamped.
@Suite struct StreamSettingsEncodeSizeTests {

    private func settings(videoQuality: Int = 720) -> StreamSettings {
        StreamSettings(videoQuality: videoQuality)
    }

    @Test("Tall portrait is capped to a 720px short edge on a 720-ceiling device")
    func capsShortEdgeForTallPortrait() {
        let size = settings().encodeSize(forOrientedWidth: 1170, height: 2532, maxShortEdge: 720)
        #expect(size.width == 720)
        #expect(size.height == 1558)   // 2532 * 720/1170, rounded to even
    }

    @Test("Never upscales a source smaller than the target short edge")
    func neverUpscales() {
        let size = settings().encodeSize(forOrientedWidth: 500, height: 900, maxShortEdge: 1080)
        #expect(size.width == 500)
        #expect(size.height == 900)
    }

    @Test("The device short-edge ceiling wins even when the user picks a higher quality")
    func capabilityCeilingWinsOverUserQuality() {
        // A 720-ceiling (older) device: a 1080p pick is honestly clamped to 720.
        let size = settings(videoQuality: 1080).encodeSize(forOrientedWidth: 1170, height: 2532, maxShortEdge: 720)
        #expect(size.width == 720)
        #expect(Int(size.width) <= 720)
    }

    @Test("1080p is reachable when the device capability allows it")
    func unlocksTrue1080pOnCapableDevice() {
        // A capable device (maxShortEdge 1080): the 720 hard cap no longer applies.
        let size = settings(videoQuality: 1080).encodeSize(forOrientedWidth: 1170, height: 2532, maxShortEdge: 1080)
        #expect(size.width == 1080)
        // Aspect preserved: 2532/1170 ≈ 2.164, so ~2336 tall (even).
        #expect(size.height == 2336)
    }

    @Test("A 720p pick stays 720 even on a 1080-capable device (user choice honored)")
    func userQualityBelowCeilingIsHonored() {
        let size = settings(videoQuality: 720).encodeSize(forOrientedWidth: 1170, height: 2532, maxShortEdge: 1080)
        #expect(size.width == 720)
    }

    @Test("Landscape caps the height (its short edge) instead of the width")
    func landscapeCapsHeight() {
        let size = settings().encodeSize(forOrientedWidth: 2532, height: 1170, maxShortEdge: 720)
        #expect(size.height == 720)
        #expect(size.width == 1558)
    }

    @Test("Both encoded edges are always even (H.264/HEVC requirement)")
    func dimensionsAlwaysEven() {
        for (w, h) in [(1179, 2556), (1290, 2796), (1125, 2436), (828, 1792)] {
            for ceiling in [720, 1080] {
                let size = settings(videoQuality: 1080).encodeSize(forOrientedWidth: w, height: h, maxShortEdge: ceiling)
                #expect(Int(size.width) % 2 == 0)
                #expect(Int(size.height) % 2 == 0)
            }
        }
    }

    @Test("Zero dimensions fall back to a 720×1280 portrait canvas")
    func zeroFallsBackToPortrait() {
        let size = settings().encodeSize(forOrientedWidth: 0, height: 0, maxShortEdge: 720)
        #expect(size.width == 720)
        #expect(size.height == 1280)
    }

    @Test("Zero-dimension fallback honors a 1080 ceiling (true 1080×1920 canvas)")
    func zeroFallbackAt1080Ceiling() {
        let size = settings(videoQuality: 1080).encodeSize(forOrientedWidth: 0, height: 0, maxShortEdge: 1080)
        #expect(size.width == 1080)
        #expect(size.height == 1920)
    }

    @Test("Zero-dimension fallback still clamps to the device ceiling")
    func zeroFallbackClampsToCeiling() {
        // A 1080p pick on a 720-ceiling device must fall back to 720×1280, proving
        // the ceiling clamps the fallback branch too (not just the scaled path).
        let size = settings(videoQuality: 1080).encodeSize(forOrientedWidth: 0, height: 0, maxShortEdge: 720)
        #expect(size.width == 720)
        #expect(size.height == 1280)
    }

    @Test("Aspect ratio is preserved within a pixel of rounding")
    func preservesAspectRatio() {
        let size = settings().encodeSize(forOrientedWidth: 1170, height: 2532, maxShortEdge: 1080)
        let source = 2532.0 / 1170.0
        let encoded = Double(size.height) / Double(size.width)
        #expect(abs(source - encoded) < 0.01)
    }
}

/// The frame-rate clamp that replaced the hard `min(frameRate, 30)` on every
/// encode/repeat path. The ceiling is the device-derived `maxFrameRate`.
@Suite struct StreamSettingsFrameRateTests {
    private func settings(frameRate: Int) -> StreamSettings {
        StreamSettings(frameRate: frameRate)
    }

    @Test("60 fps is reachable when the device capability allows it")
    func unlocks60OnCapableDevice() {
        #expect(settings(frameRate: 60).encodeFrameRate(maxFrameRate: 60) == 60)
    }

    @Test("60 fps is clamped to 30 on a 30-fps-ceiling device")
    func clamps60To30OnLimitedDevice() {
        #expect(settings(frameRate: 60).encodeFrameRate(maxFrameRate: 30) == 30)
    }

    @Test("A rate below the ceiling is left untouched")
    func belowCeilingUnchanged() {
        #expect(settings(frameRate: 24).encodeFrameRate(maxFrameRate: 60) == 24)
        #expect(settings(frameRate: 30).encodeFrameRate(maxFrameRate: 60) == 30)
    }

    @Test("Frame rate never drops below 1 fps")
    func neverBelowOne() {
        #expect(settings(frameRate: 0).encodeFrameRate(maxFrameRate: 60) == 1)
        #expect(settings(frameRate: -5).encodeFrameRate(maxFrameRate: 60) == 1)
    }
}

/// The device-capability derivation. Pure and injectable, so these pin the
/// resolution/fps tiering without depending on the CI runner's hardware.
@Suite struct StreamCapabilityTests {
    @Test("6 GB / 6-core devices unlock 1080p60 (the headline target)")
    func highTierGets1080p60() {
        let cap = StreamCapability.device(processorCount: 6, physicalMemory: 6_000_000_000)
        #expect(cap.maxShortEdge == 1080)
        #expect(cap.maxFrameRate == 60)
    }

    @Test("8 GB Pro-class devices also get 1080p60")
    func proTierGets1080p60() {
        let cap = StreamCapability.device(processorCount: 6, physicalMemory: 8_000_000_000)
        #expect(cap.maxShortEdge == 1080)
        #expect(cap.maxFrameRate == 60)
    }

    @Test("4 GB devices get 1080p but stay at 30 fps")
    func midTierGets1080p30() {
        let cap = StreamCapability.device(processorCount: 6, physicalMemory: 3_700_000_000)
        #expect(cap.maxShortEdge == 1080)
        #expect(cap.maxFrameRate == 30)
    }

    @Test("3 GB devices stay at the safe 720p30 profile")
    func lowTierGets720p30() {
        let cap = StreamCapability.device(processorCount: 6, physicalMemory: 2_900_000_000)
        #expect(cap.maxShortEdge == 720)
        #expect(cap.maxFrameRate == 30)
    }

    @Test("60 fps requires the full core complement, not just the memory")
    func lowCoreCountGatesFrameRate() {
        // Ample memory but a fictional low core count: 1080p allowed, 60 fps not.
        let cap = StreamCapability.device(processorCount: 4, physicalMemory: 8_000_000_000)
        #expect(cap.maxShortEdge == 1080)
        #expect(cap.maxFrameRate == 30)
    }

    @Test("The core-count boundary sits exactly at 6 (5 cores + ample RAM → 30 fps)")
    func coreCountBoundaryPinnedAtSix() {
        // Pins the >= 6 gate to the exact edge so a regression to >= 5 is caught.
        let cap = StreamCapability.device(processorCount: 5, physicalMemory: 8_000_000_000)
        #expect(cap.maxShortEdge == 1080)
        #expect(cap.maxFrameRate == 30)
    }

    @Test("Memory-tier boundaries map to the intended profile")
    func memoryBoundaries() {
        // Exactly at the high floor → 1080p60.
        let high = StreamCapability.device(processorCount: 6, physicalMemory: 5_000_000_000)
        #expect(high.maxShortEdge == 1080)
        #expect(high.maxFrameRate == 60)
        // Exactly at the mid floor → 1080p30.
        let mid = StreamCapability.device(processorCount: 6, physicalMemory: 3_300_000_000)
        #expect(mid.maxShortEdge == 1080)
        #expect(mid.maxFrameRate == 30)
        // Just below the mid floor → 720p30.
        let low = StreamCapability.device(processorCount: 6, physicalMemory: 3_299_999_999)
        #expect(low.maxShortEdge == 720)
        #expect(low.maxFrameRate == 30)
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
