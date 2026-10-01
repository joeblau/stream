import Testing
@testable import StreamCore

/// A01 (issue #82): the position-addressed, bounded stereo ring every audio
/// channel buffers into. These pin the documented drop/underrun contract.
@Suite("AudioRingBuffer")
struct AudioRingBufferTests {
    /// Interleaved stereo ramp: frame i = [i, -i].
    private func stereo(_ frames: Int64, from start: Int64 = 0) -> [Float] {
        var out: [Float] = []
        for i in start..<(start + frames) {
            out.append(Float(i))
            out.append(-Float(i))
        }
        return out
    }

    @Test func writeThenReadAlignedPositions() {
        var ring = AudioRingBuffer(capacityFrames: 64)
        ring.write(stereo(8), at: 100)
        var out: [Float] = []
        ring.fill(at: 100, frameCount: 8, into: &out)
        #expect(out == stereo(8))
        #expect(ring.underrunFrames == 0)
        #expect(ring.droppedFrames == 0)
        #expect(ring.receivedFrames == 8)
    }

    @Test func readBeforeDataArrivesYieldsSilenceAndCountsUnderrun() {
        var ring = AudioRingBuffer(capacityFrames: 64)
        var out: [Float] = []
        ring.fill(at: 0, frameCount: 4, into: &out)
        #expect(out == [Float](repeating: 0, count: 8))
        #expect(ring.underrunFrames == 4)
    }

    @Test func gapBetweenWritesReadsBackAsSilence() {
        var ring = AudioRingBuffer(capacityFrames: 64)
        ring.write(stereo(2), at: 0)
        ring.write(stereo(2, from: 10), at: 6)
        var out: [Float] = []
        ring.fill(at: 0, frameCount: 8, into: &out)
        // Frames 0-1 real, 2-5 silence (the hole), 6-7 real.
        #expect(out[0] == 0 && out[2] == 1)
        #expect(out[4] == 0 && out[5] == 0)
        #expect(out[12] == 10 && out[13] == -10)
        #expect(ring.underrunFrames == 4)
    }

    @Test func overflowDropsOldestFrames() {
        var ring = AudioRingBuffer(capacityFrames: 8)
        ring.write(stereo(4), at: 0)
        ring.write(stereo(8, from: 4), at: 4)   // window would be 12 > 8
        #expect(ring.droppedFrames == 4)
        var out: [Float] = []
        ring.fill(at: 4, frameCount: 8, into: &out)
        #expect(out == stereo(8, from: 4))      // newest 8 frames survive
    }

    @Test func fullyStaleWriteIsDropped() {
        var ring = AudioRingBuffer(capacityFrames: 8)
        ring.write(stereo(4), at: 10)
        var out: [Float] = []
        ring.fill(at: 10, frameCount: 4, into: &out)   // consuming: base → 10
        ring.write(stereo(2), at: 4)                    // entirely before base
        #expect(ring.droppedFrames == 2)
    }

    @Test func readIsConsumingAndMonotonic() {
        var ring = AudioRingBuffer(capacityFrames: 16)
        ring.write(stereo(8), at: 0)
        var first: [Float] = []
        ring.fill(at: 0, frameCount: 4, into: &first)
        // Re-reading an earlier window must NOT replay old samples.
        var replay: [Float] = []
        ring.fill(at: 0, frameCount: 4, into: &replay)
        #expect(replay == [Float](repeating: 0, count: 8))
        var second: [Float] = []
        ring.fill(at: 4, frameCount: 4, into: &second)
        #expect(second == stereo(4, from: 4))
    }

    @Test func unpositionedAppendUsesNextWritePosition() {
        var ring = AudioRingBuffer(capacityFrames: 16)
        ring.write(stereo(4), at: ring.nextWritePosition)
        #expect(ring.nextWritePosition == 4)
        ring.write(stereo(4, from: 4), at: ring.nextWritePosition)
        var out: [Float] = []
        ring.fill(at: 0, frameCount: 8, into: &out)
        #expect(out == stereo(8))
    }

    @Test func resetClearsEverything() {
        var ring = AudioRingBuffer(capacityFrames: 8)
        ring.write(stereo(4), at: 0)
        ring.reset()
        #expect(ring.nextWritePosition == 0)
        #expect(ring.droppedFrames == 0)
        #expect(ring.underrunFrames == 0)
        #expect(ring.receivedFrames == 0)
    }
}
