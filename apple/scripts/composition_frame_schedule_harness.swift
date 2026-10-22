import Foundation

private func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw NSError(domain: "CompositionFrameSchedule", code: 1,
        userInfo: [NSLocalizedDescriptionKey: message]) }
}

@main struct CompositionFrameScheduleHarness {
    struct Simulation { var frames = 0, skipped = 0; var starts: [ContinuousClock.Instant] = [] }
    static let interval = Duration.nanoseconds(1_000_000_000 / 30)

    static func simulate(render: Duration, oldScheduler: Bool = false) -> Simulation {
        let start = ContinuousClock.now
        let end = start + .seconds(600)
        var now = start, deadline = start
        var result = Simulation()
        while now < end {
            result.starts.append(now); result.frames += 1
            now += render
            if oldScheduler {
                deadline += interval
                while deadline < now { deadline += interval; result.skipped += 1 }
            } else {
                let next = CompositionFrameSchedule.next(after: deadline, interval: interval, completedAt: now)
                deadline = next.deadline; result.skipped += next.skipped
            }
            // Deterministic wake jitter, not a real 600-second benchmark.
            if deadline > now { now = deadline + .microseconds(500) }
        }
        return result
    }

    static func main() throws {
        let minimum = 30 * (600 - 5) // Original nominal qualification unchanged.
        let old = simulate(render: .milliseconds(33), oldScheduler: true)
        let fixed = simulate(render: .milliseconds(33))
        try require(old.frames < minimum && fixed.frames >= minimum,
            "Small wake jitter must not halve30fps capacity: old\(old.frames), new\(fixed.frames), required\(minimum)")
        try require(fixed.starts.last!.duration(to: fixed.starts.first!) < .zero,
            "Simulation must preserve monotonic actual start timestamps")
        for (earlier, later) in zip(fixed.starts, fixed.starts.dropFirst()) {
            try require(later > earlier, "Due-tick recovery cannot duplicate or reverse timestamps")
        }
        let overloaded = simulate(render: .milliseconds(40))
        try require(overloaded.frames < minimum && overloaded.frames >= 14_999,
            "A real40ms renderer should use available25fps capacity and still FAIL30fps qualification")
        let fast = simulate(render: .milliseconds(10))
        try require(fast.frames == 18_000 && fast.skipped == 0, "Fast rendering must retain30fps cap and phase")
        let base = ContinuousClock.now
        let afterStall = CompositionFrameSchedule.next(after: base, interval: interval,
            completedAt: base + .seconds(59))
        try require(afterStall.skipped > 1_700 && afterStall.deadline <= base + .seconds(59)
            && afterStall.deadline + interval > base + .seconds(59),
            "A long stall must skip expired slots and retain only one due opportunity, without replaying a backlog")
        print("PASS production cadence helper:33ms render +0.5ms wake jitter old\(old.frames)/new\(fixed.frames) frames per virtual600s; unchanged minimum\(minimum)")
        print("PASS actual overload remains failed qualification:40ms renderer\(overloaded.frames) frames; fast renderer\(fast.frames); monotonic starts and59s stall backlog bound")
        print("Scope: deterministic virtual clock and shipping scheduling helper; no GPU, media decode, hardware capacity or resolution qualification")
    }
}
