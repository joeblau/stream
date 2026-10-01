import Testing
import StreamCore

/// G09 (issue #116): the animated-image frame-stepping math — delay
/// clamping, loop wrapping, finite-repeat end detection, seek mapping.
/// Test delays are exact binary fractions (0.25/0.5) so boundary
/// comparisons are exact.
@Suite struct AnimatedImageTimelineTests {
    private func timeline(delays: [Double],
                          loop: AnimatedImageLoopCount = .infinite) -> AnimatedImageTimeline {
        AnimatedImageTimeline(rawFrameDelays: delays, loopCount: loop)
    }

    @Test("GIF-spec delay floor: 0–10 ms clamps to 100 ms")
    func delayClamping() {
        #expect(AnimatedImageTimeline.clampedDelay(0) == AnimatedImageTimeline.minimumDelay)
        #expect(AnimatedImageTimeline.clampedDelay(0.01) == AnimatedImageTimeline.minimumDelay)
        #expect(AnimatedImageTimeline.clampedDelay(-3) == AnimatedImageTimeline.minimumDelay)
        #expect(AnimatedImageTimeline.clampedDelay(.nan) == AnimatedImageTimeline.minimumDelay)
        #expect(AnimatedImageTimeline.clampedDelay(0.25) == 0.25)
        let t = timeline(delays: [0, 0.25])
        #expect(t.frameDelays == [AnimatedImageTimeline.minimumDelay, 0.25])
        #expect(abs(t.duration - 0.35) < 1e-9)
    }

    @Test("Frame index within one pass follows cumulative delays")
    func frameIndexWithinPass() {
        let t = timeline(delays: [0.25, 0.5, 0.25])   // starts: 0, 0.25, 0.75, 1.0
        #expect(t.placement(atElapsed: 0) == .frame(0))
        #expect(t.placement(atElapsed: 0.249) == .frame(0))
        #expect(t.placement(atElapsed: 0.25) == .frame(1))
        #expect(t.placement(atElapsed: 0.74) == .frame(1))
        #expect(t.placement(atElapsed: 0.75) == .frame(2))
        #expect(t.placement(atElapsed: 0.99) == .frame(2))
    }

    @Test("Infinite loop wraps by the pass duration")
    func infiniteLoopWraps() {
        let t = timeline(delays: [0.25, 0.25])   // duration 0.5
        #expect(t.placement(atElapsed: 0.5) == .frame(0))
        #expect(t.placement(atElapsed: 0.6) == .frame(0))
        #expect(t.placement(atElapsed: 0.75) == .frame(1))
        #expect(t.placement(atElapsed: 1_000.25) == .frame(1))
    }

    @Test("Finite stored count N replays N times after the first pass")
    func finiteLoopCountsReplays() {
        // Stored count 2 → 3 total passes of a 0.5 s timeline → ends at 1.5.
        let t = timeline(delays: [0.25, 0.25], loop: .finite(storedCount: 2))
        #expect(AnimatedImageLoopCount.finite(storedCount: 2).totalPasses == 3)
        #expect(t.placement(atElapsed: 1.25) == .frame(1))
        #expect(t.placement(atElapsed: 1.5) == .ended)
        #expect(t.placement(atElapsed: 5) == .ended)
    }

    @Test("Play-once is a finite count of one pass")
    func playOnceEnds() {
        let t = timeline(delays: [0.25, 0.25], loop: .finite(storedCount: 0))
        #expect(AnimatedImageLoopCount.finite(storedCount: 0).totalPasses == 1)
        #expect(t.placement(atElapsed: 0.375) == .frame(1))
        #expect(t.placement(atElapsed: 0.5) == .ended)
    }

    @Test("Seek maps a frame index back to its start time")
    func seekMapping() {
        let t = timeline(delays: [0.25, 0.5, 0.25])
        #expect(t.elapsed(atFrameIndex: 0) == 0)
        #expect(t.elapsed(atFrameIndex: 1) == 0.25)
        #expect(t.elapsed(atFrameIndex: 2) == 0.75)
        #expect(t.elapsed(atFrameIndex: 99) == t.duration)
    }

    @Test("Degenerate timelines never crash and report ended")
    func degenerate() {
        let empty = timeline(delays: [])
        #expect(empty.duration == 0)
        #expect(empty.placement(atElapsed: 0) == .ended)
        let t = timeline(delays: [0.25, 0.25])
        #expect(t.placement(atElapsed: -1) == .frame(0))
        #expect(t.placement(atElapsed: .nan) == .frame(0))
    }
}

/// G09 (issue #116): the import-time format gates — unsupported animated
/// images and non-alpha codecs are rejected before the asset is registered.
@Suite struct MediaOverlayValidatorTests {
    @Test("Animated-image type identifiers")
    func animatedImageTypes() {
        #expect(MediaOverlayValidator.isAnimatedImageTypeIdentifier("com.compuserve.gif"))
        #expect(MediaOverlayValidator.isAnimatedImageTypeIdentifier("public.png"))
        #expect(MediaOverlayValidator.isAnimatedImageTypeIdentifier("public.heic"))
        #expect(!MediaOverlayValidator.isAnimatedImageTypeIdentifier("public.jpeg"))
        #expect(!MediaOverlayValidator.isAnimatedImageTypeIdentifier("com.apple.quicktime-movie"))
    }

    @Test("Animated-image validation requires a supported type with 2+ frames")
    func animatedImageValidation() {
        if case .failure = MediaOverlayValidator.validateAnimatedImage(
            typeIdentifier: "com.compuserve.gif", frameCount: 4) {
            Issue.record("a multi-frame GIF must pass the animated-image gate")
        }
        switch MediaOverlayValidator.validateAnimatedImage(typeIdentifier: "public.png", frameCount: 1) {
        case .failure(let error):
            #expect(error.message.contains("single frame"))
        case .success:
            Issue.record("a one-frame PNG must be rejected")
        }
        switch MediaOverlayValidator.validateAnimatedImage(typeIdentifier: "public.jpeg", frameCount: 5) {
        case .failure(let error):
            #expect(error.message.contains("Unsupported animated-image format"))
        case .success:
            Issue.record("JPEG is not an animated-image type")
        }
        switch MediaOverlayValidator.validateAnimatedImage(typeIdentifier: "com.compuserve.gif", frameCount: 0) {
        case .failure(let error):
            #expect(error.message.contains("could not be decoded"))
        case .success:
            Issue.record("an undecodable file must be rejected")
        }
    }

    @Test("Alpha-video codecs: ProRes 4444/4444XQ and HEVC-alpha pass, H.264 fails")
    func alphaVideoCodecs() {
        #expect(MediaOverlayValidator.isAlphaVideoCodec("ap4h"))
        #expect(MediaOverlayValidator.isAlphaVideoCodec("ap4x"))
        #expect(MediaOverlayValidator.isAlphaVideoCodec("hvt1"))
        #expect(!MediaOverlayValidator.isAlphaVideoCodec("avc1"))
        #expect(!MediaOverlayValidator.isAlphaVideoCodec("apcn"))
        switch MediaOverlayValidator.validateAlphaVideo(codecFourCC: "avc1") {
        case .failure(let error):
            #expect(error.message.contains("avc1"))
        case .success:
            Issue.record("H.264 has no alpha channel")
        }
        switch MediaOverlayValidator.validateAlphaVideo(codecFourCC: nil) {
        case .failure(let error):
            #expect(error.message.contains("no video track"))
        case .success:
            Issue.record("a file with no video track must be rejected")
        }
        if case .failure = MediaOverlayValidator.validateAlphaVideo(codecFourCC: "ap4h") {
            Issue.record("ProRes 4444 must pass the alpha gate")
        }
    }
}
