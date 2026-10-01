import Foundation
import Testing
import StreamCore

@Suite struct RundownTests {
    private func cue(_ duration: Double? = 10, media: Bool = false, group: String = "") -> RundownCue {
        RundownCue(sceneID: UUID(), durationSeconds: duration, advanceOnMediaEnd: media, randomGroup: group)
    }
    @Test func timingPauseResumeAndOneAdvancePerTick() {
        let a = cue(), b = cue(), c = cue()
        var runtime = RundownPlayback()
        #expect(runtime.start(cues: [a,b,c], loop: false, at: 100) == a)
        #expect(runtime.remaining(at: 104) == 6)
        runtime.pause(at: 104)
        runtime.pause(at: 110)
        #expect(runtime.remaining(at: 200) == 6)
        #expect(runtime.tick(at: 200) == nil)
        runtime.resume(at: 200)
        runtime.resume(at: 202)
        #expect(runtime.tick(at: 205) == nil)
        #expect(runtime.tick(at: 206) == b)
        // A delayed tick advances once, rather than cascading through a show.
        #expect(runtime.tick(at: 500) == c)
        #expect(runtime.current == c)
        #expect(runtime.remaining(at: 500) == 10)
        #expect(runtime.tick(at: 510) == nil)
        #expect(runtime.phase == .finished)
        #expect(runtime.current == nil)
    }
    @Test func mediaAndTimeoutCannotDoubleAdvance() {
        let a = cue(5, media: true), b = cue(nil, media: true), c = cue(nil)
        var runtime = RundownPlayback()
        _ = runtime.start(cues: [a,b,c], loop: false, at: 100)
        #expect(runtime.tick(at: 105, mediaEndedAt: 104) == b)
        #expect(runtime.tick(at: 106, mediaEndedAt: 104) == nil)
        #expect(runtime.tick(at: 106, mediaEndedAt: 105) == nil)
        #expect(runtime.tick(at: 106, mediaEndedAt: 200) == nil)
        #expect(runtime.tick(at: 106, mediaEndedAt: .nan) == nil)
        #expect(runtime.tick(at: 106, mediaEndedAt: 105.1) == c)
        #expect(runtime.tick(at: 107, mediaEndedAt: 106.5) == nil)
    }
    @Test func pausedSkipKeepsNextCuePausedAndStopClearsState() {
        let a = cue(), b = cue()
        var runtime = RundownPlayback()
        _ = runtime.start(cues: [a,b], loop: false, at: 0)
        runtime.pause(at: 3)
        #expect(runtime.skip(at: 100) == b)
        #expect(runtime.phase == .paused)
        #expect(runtime.remaining(at: 200) == 10)
        runtime.stop()
        #expect(runtime.phase == .idle)
        #expect(runtime.current == nil)
        #expect(runtime.next == nil)
        #expect(runtime.tick(at: 1000) == nil)
        #expect(runtime.skip(at: 1000) == nil)
        #expect(runtime.start(cues: [b], loop: false, at: 1000) == b)
    }
    @Test func loopNextMatchesUpcomingShuffledLapAndFixedSlotsStayFixed() {
        let fixed1 = cue(), fixed2 = cue()
        let group = (0..<5).map { _ in cue(1, group: "interviews") }
        let input = [fixed1] + group + [fixed2]
        var runtime = RundownPlayback(), copy = RundownPlayback()
        _ = runtime.start(cues: input, loop: true, at: 0, seed: 87)
        _ = copy.start(cues: input, loop: true, at: 0, seed: 87)
        #expect(runtime.cues == copy.cues)
        #expect(runtime.cues.first == fixed1)
        #expect(runtime.cues.last == fixed2)
        #expect(Set(runtime.cues.map(\.id)) == Set(input.map(\.id)))
        for i in 1..<input.count { _ = runtime.skip(at: Double(i)) }
        let expected = runtime.next
        #expect(runtime.skip(at: 10) == expected)
        #expect(runtime.lap == 1)
        #expect(runtime.cues.first == fixed1)
        #expect(runtime.cues.last == fixed2)
        #expect(Set(runtime.cues.map(\.id)) == Set(input.map(\.id)))
    }
    @Test func rejectsMalformedDocumentsWithoutStarting() throws {
        var runtime = RundownPlayback()
        #expect(runtime.start(cues: [], loop: false, at: 0) == nil)
        let valid = cue()
        #expect(runtime.start(cues: [valid,valid], loop: false, at: 0) == nil)
        #expect(runtime.start(cues: [cue(.infinity)], loop: false, at: 0) == nil)
        #expect(runtime.start(cues: [cue(.nan)], loop: false, at: 0) == nil)
        #expect(runtime.start(cues: [cue(0)], loop: false, at: 0) == nil)
        #expect(runtime.start(cues: [cue(group: String(repeating: "x", count: 129))], loop: false, at: 0) == nil)
        #expect(runtime.start(cues: [valid], loop: false, at: .nan) == nil)
        #expect(runtime.start(cues: (0..<501).map { _ in cue() }, loop: false, at: 0) == nil)
        #expect(runtime.phase == .idle)
        let data = try JSONEncoder().encode(valid)
        #expect(try JSONDecoder().decode(RundownCue.self, from: data) == valid)
    }
}
