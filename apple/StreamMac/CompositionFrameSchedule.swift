import Foundation

/// Keep one due opportunity instead of rounding every late completion up to
/// another future slot. Rendering just over a deadline must not cause a whole
/// additional idle frame interval. Completely elapsed opportunities are skipped.
enum CompositionFrameSchedule {
    struct Next {
        var deadline: ContinuousClock.Instant
        var skipped: Int
    }

    static func next(after previous: ContinuousClock.Instant, interval: Duration,
                     completedAt now: ContinuousClock.Instant) -> Next {
        precondition(interval > .zero)
        var deadline = previous.advanced(by: interval)
        var skipped = 0
        while deadline.advanced(by: interval) <= now {
            deadline = deadline.advanced(by: interval)
            skipped += 1
        }
        return Next(deadline: deadline, skipped: skipped)
    }
}
