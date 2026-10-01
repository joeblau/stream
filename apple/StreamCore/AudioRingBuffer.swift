import Foundation

/// A bounded, position-addressed ring of interleaved stereo Float32 samples —
/// the per-channel buffering primitive of the A01 audio engine (issue #82).
///
/// Every channel's samples live at ABSOLUTE frame positions on the engine's
/// shared host-clock timeline (position 0 = the engine's clock anchor), so the
/// mix loop aligns channels sample-accurately by reading the same position
/// window from every ring. Capture timestamps are preserved end-to-end: a
/// source writes at the position its capture PTS maps to; the mixer reads at
/// the position its output chunk's PTS maps to; nothing is ever retimed by
/// counting buffers.
///
/// Holes are explicit: unwritten slots hold NaN, and a write that skips
/// forward NaN-fills the gap it jumped. A read therefore knows exactly which
/// frames were real — hole and not-yet-arrived frames read back as zeros and
/// count as underrun, never as stale data from an older window.
///
/// Bounded-buffer policy (documented A01 drop/underrun contract):
///
/// - **Overflow (source ran ahead > capacity):** drop OLDEST frames — the base
///   advances so the newest samples always land. Dropped frames are counted in
///   `droppedFrames`. This is the only lossy path and it bounds latency: a
///   stalled consumer can never grow the buffer past `capacityFrames`.
/// - **Underrun (samples missing at read time):** the reader gets ZEROS
///   (silence) for the hole and `underrunFrames` counts the inserted silence.
///   A late buffer that arrives after its window was already read lands at a
///   stale position and is trimmed against the base — it is never played out
///   of order.
/// - **Reads are consuming and single-reader:** `fill` advances the base past
///   the whole requested window, so consumed frames can never be re-read.
///
/// Pure value type (no locks, no CoreMedia): the owning channel confines it.
public struct AudioRingBuffer: Sendable {
    /// Frames of stereo history the ring holds (the latency bound).
    public let capacityFrames: Int
    /// Frames dropped because a write ran more than `capacityFrames` ahead of
    /// the oldest unread sample (drop-oldest overflow policy), or because a
    /// write arrived entirely behind the read base (late/stale).
    public private(set) var droppedFrames: Int64 = 0
    /// Frames of silence inserted by reads that found no samples (holes and
    /// not-yet-arrived data).
    public private(set) var underrunFrames: Int64 = 0
    /// Total real frames ever written (post-trimming).
    public private(set) var receivedFrames: Int64 = 0

    /// Interleaved L/R storage, `capacityFrames * 2` samples. NaN = unwritten.
    private var storage: [Float]
    /// Absolute frame position of the oldest sample still readable.
    private var base: Int64 = 0
    /// Absolute frame position one past the newest contiguous sample written.
    private var end: Int64 = 0

    public init(capacityFrames: Int) {
        self.capacityFrames = max(1, capacityFrames)
        self.storage = [Float](repeating: .nan, count: max(1, capacityFrames) * 2)
    }

    /// The absolute position the next unpositioned write should append at
    /// (contiguous with everything written so far).
    public var nextWritePosition: Int64 { end }

    /// Writes `samples` (interleaved stereo, `samples.count / 2` frames) at
    /// absolute frame `position`. Handles every overlap case: fully stale
    /// writes are counted and ignored; partially stale writes are trimmed;
    /// writes leaving a gap NaN-fill the hole; writes over capacity drop the
    /// oldest frames. A write to an EMPTY ring starts a fresh window at the
    /// write position (no spurious overflow accounting for the gap between
    /// the clock anchor and a late-starting source's first buffer).
    public mutating func write(_ samples: [Float], at position: Int64) {
        let frameCount = Int64(samples.count / 2)
        guard frameCount > 0 else { return }
        var start = position
        var offset = 0
        if start < base {
            // Partially/fully stale: only the tail past the base can still land.
            let stale = min(frameCount, base - start)
            droppedFrames += stale
            start += stale
            offset += Int(stale) * 2
        }
        let remaining = Int64(samples.count / 2 - offset / 2)
        guard remaining > 0 else { return }
        if end <= base {
            // Empty ring: the window starts here.
            base = start
            end = start
        }
        let newEnd = start + remaining
        if newEnd - base > Int64(capacityFrames) {
            // Overflow: drop the OLDEST frames so the newest always fit.
            let overflow = newEnd - base - Int64(capacityFrames)
            base += overflow
            droppedFrames += overflow
        }
        if start > end {
            // The hole between the last write and this one is unwritten:
            // NaN-fill it (capped at the window) so reads see counted silence.
            nanFill(from: max(end, base), to: min(start, base + Int64(capacityFrames)))
        }
        for index in 0..<Int(remaining) * 2 {
            storage[slot(start + Int64(index / 2), channel: index % 2)] = samples[offset + index]
        }
        end = max(end, newEnd)
        receivedFrames += remaining
    }

    /// Reads `frameCount` frames starting at absolute `position` into `output`
    /// (resized to `frameCount * 2`). Holes and not-yet-arrived frames read
    /// back as zeros and count as underrun; frames before the base (already
    /// consumed) read as zeros without counting. Consuming: the base advances
    /// past the requested window.
    public mutating func fill(at position: Int64, frameCount: Int, into output: inout [Float]) {
        if output.count != frameCount * 2 {
            output = [Float](repeating: 0, count: frameCount * 2)
        }
        for frame in 0..<frameCount {
            let absolute = position + Int64(frame)
            if absolute < base {
                output[frame * 2] = 0
                output[frame * 2 + 1] = 0
            } else if absolute >= end {
                output[frame * 2] = 0
                output[frame * 2 + 1] = 0
                underrunFrames += 1
            } else {
                let left = storage[slot(absolute, channel: 0)]
                let right = storage[slot(absolute, channel: 1)]
                if left.isNaN || right.isNaN {
                    output[frame * 2] = 0
                    output[frame * 2 + 1] = 0
                    underrunFrames += 1
                } else {
                    output[frame * 2] = left
                    output[frame * 2 + 1] = right
                }
            }
        }
        if position + Int64(frameCount) > base {
            base = position + Int64(frameCount)
        }
    }

    /// Resets all state (pipeline restart): positions, counters, and samples.
    public mutating func reset() {
        base = 0
        end = 0
        droppedFrames = 0
        underrunFrames = 0
        receivedFrames = 0
        for index in storage.indices { storage[index] = .nan }
    }

    private func slot(_ position: Int64, channel: Int) -> Int {
        Int(position % Int64(capacityFrames)) * 2 + channel
    }

    private mutating func nanFill(from: Int64, to: Int64) {
        guard to > from else { return }
        for position in from..<to {
            storage[slot(position, channel: 0)] = .nan
            storage[slot(position, channel: 1)] = .nan
        }
    }
}
