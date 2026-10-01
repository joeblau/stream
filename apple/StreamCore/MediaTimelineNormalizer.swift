import CoreMedia

/// Which capture track a sample belongs to. Each track keeps its own last-seen
/// presentation time so a rebase measures the gap against the right timeline.
public enum MediaTimelineKind: Hashable, Sendable {
    case video
    case mic
    case app
    /// A01 (issue #82): the single pre-mixed program audio bus the macOS
    /// studio engine delivers (replaces per-track mic/app on that path).
    case program
}

/// Removes capture/reconnect wall-clock gaps before samples reach the encoder.
/// Without this, HaishinKit's audio ring buffer materializes a long pause as
/// thousands of silence buffers and its RTMP timestamp accumulator sends a large
/// first delta. Pure CoreMedia (no HaishinKit), so it lives in StreamCore and its
/// gap math is unit-tested on CI.
public struct MediaTimelineNormalizer {
    private var accumulatedOffset = CMTime.zero
    private var lastPresentationTime: [MediaTimelineKind: CMTime] = [:]
    private var needsRebase = false

    public init() {}

    public mutating func markDiscontinuity() {
        needsRebase = true
    }

    /// The pure rebase decision: given a new sample's source PTS, the current
    /// accumulated offset, the prior last-seen PTS, and the sample duration, return
    /// the (possibly grown) accumulated offset. The offset only ever GROWS to swallow
    /// a forward gap (`prospective > desired`); a zero/negative gap leaves it
    /// unchanged, so timestamps never move backwards. Exposed so the gap accounting
    /// is testable with plain `CMTime` (no `CMSampleBuffer` needed).
    public static func rebasedOffset(sourcePTS: CMTime,
                                     accumulatedOffset: CMTime,
                                     prior: CMTime,
                                     sampleDuration: CMTime) -> CMTime {
        let prospective = CMTimeSubtract(sourcePTS, accumulatedOffset)
        let desired = CMTimeAdd(prior, sampleDuration)
        let gap = CMTimeSubtract(prospective, desired)
        return CMTimeCompare(gap, .zero) > 0 ? CMTimeAdd(accumulatedOffset, gap) : accumulatedOffset
    }

    /// Normalizes a sample buffer's timing by the accumulated offset, growing the
    /// offset to swallow a discontinuity gap on the first sample after a
    /// `markDiscontinuity()`. Returns the input buffer unchanged while the offset is
    /// zero (the steady state for a whole broadcast until the first pause/reconnect),
    /// avoiding a per-buffer heap alloc + copy on the ~150 buffers/s hot path.
    public mutating func normalize(_ sampleBuffer: CMSampleBuffer,
                                   kind: MediaTimelineKind,
                                   fallbackDuration: CMTime) -> CMSampleBuffer {
        let sourcePTS = sampleBuffer.presentationTimeStamp
        guard sourcePTS.isValid, sourcePTS.isNumeric else { return sampleBuffer }

        let sampleDuration = sampleBuffer.duration.isValid && sampleBuffer.duration.isNumeric && sampleBuffer.duration > .zero
            ? sampleBuffer.duration
            : fallbackDuration

        if needsRebase {
            let prior = lastPresentationTime[kind]
                ?? lastPresentationTime.values.max(by: { CMTimeCompare($0, $1) < 0 })
            if let prior {
                accumulatedOffset = Self.rebasedOffset(sourcePTS: sourcePTS,
                                                       accumulatedOffset: accumulatedOffset,
                                                       prior: prior,
                                                       sampleDuration: sampleDuration)
            }
            needsRebase = false
        }

        // Steady-state fast path: with no accumulated offset the copy below would
        // produce a bit-identical buffer (PTS − 0 == PTS), so skip the per-buffer
        // heap alloc + CMSampleBuffer copy entirely.
        if accumulatedOffset == .zero {
            lastPresentationTime[kind] = sourcePTS
            return sampleBuffer
        }

        var entryCount: CMItemCount = 0
        guard CMSampleBufferGetSampleTimingInfoArray(
            sampleBuffer,
            entryCount: 0,
            arrayToFill: nil,
            entriesNeededOut: &entryCount
        ) == noErr, entryCount > 0 else {
            return sampleBuffer
        }

        var timings = [CMSampleTimingInfo](
            repeating: CMSampleTimingInfo(duration: .invalid,
                                          presentationTimeStamp: .invalid,
                                          decodeTimeStamp: .invalid),
            count: entryCount
        )
        let status = timings.withUnsafeMutableBufferPointer { buffer in
            CMSampleBufferGetSampleTimingInfoArray(
                sampleBuffer,
                entryCount: entryCount,
                arrayToFill: buffer.baseAddress,
                entriesNeededOut: nil
            )
        }
        guard status == noErr else { return sampleBuffer }

        for index in timings.indices {
            if timings[index].presentationTimeStamp.isValid {
                timings[index].presentationTimeStamp = CMTimeSubtract(
                    timings[index].presentationTimeStamp,
                    accumulatedOffset
                )
            }
            if timings[index].decodeTimeStamp.isValid {
                timings[index].decodeTimeStamp = CMTimeSubtract(
                    timings[index].decodeTimeStamp,
                    accumulatedOffset
                )
            }
        }

        var adjusted: CMSampleBuffer?
        let copyStatus = timings.withUnsafeMutableBufferPointer { buffer in
            CMSampleBufferCreateCopyWithNewTiming(
                allocator: kCFAllocatorDefault,
                sampleBuffer: sampleBuffer,
                sampleTimingEntryCount: entryCount,
                sampleTimingArray: buffer.baseAddress!,
                sampleBufferOut: &adjusted
            )
        }
        guard copyStatus == noErr, let adjusted else { return sampleBuffer }
        lastPresentationTime[kind] = adjusted.presentationTimeStamp
        return adjusted
    }
}
