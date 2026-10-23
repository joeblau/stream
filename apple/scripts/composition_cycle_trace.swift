import Foundation

/// Generated-tool-only storage shared by the original weak-self clock Task and
/// Engine actor. A per-run lock covers bounded scalar/event access. No assumption
/// of actor inheritance, CF payloads, callbacks, I/O or per-event JSON is needed.
final class CompositionCycleTraceRun: @unchecked Sendable {
    private let lock = NSLock()
    struct TickSpan: Sendable {
        let started: ContinuousClock.Instant
        let ended: ContinuousClock.Instant
        let passedAuthority: Bool
        let attempted: Bool
    }
    private struct Event {
        var kind: Int
        var iteration: Int64
        var deadline: ContinuousClock.Instant
        var first: ContinuousClock.Instant
        var second: ContinuousClock.Instant
        var third: ContinuousClock.Instant
        var skipped: Int = 0
        var authority: Bool = false
        var attempted: Bool = false
        var hasSelf: Bool = false
    }
    let authority: UUID
    let interval: Duration
    private let origin = ContinuousClock.now
    private var events = [Event?](repeating: nil, count: 65_536)
    private var count = 0
    private var omitted = 0
    private var frozen = false
    private var lastIteration: Int64 = 0
    private var taskStarted = false
    private var taskExited = false
    private var pendingCommit: Int64?
    init(authority: UUID, interval: Duration) {
        self.authority = authority; self.interval = interval
    }
    /// All callers hold lock. Snapshot freezes before releasing its copy.
    private func append(_ event: Event) {
        guard !frozen else { return }
        guard count < events.count else { omitted += 1; return }
        events[count] = event; count += 1
    }
    func started() { lock.lock(); defer { lock.unlock() }; if !frozen { taskStarted = true } }
    func exited() { lock.lock(); defer { lock.unlock() }; if !frozen { taskExited = true } }
    func cycle(iteration: Int64, deadline: ContinuousClock.Instant,
               span: TickSpan?, checkedAt: ContinuousClock.Instant, skipped: Int) {
        lock.lock(); defer { lock.unlock() }
        guard !frozen else { return }
        lastIteration = iteration
        if skipped > 0 { pendingCommit = iteration }
        append(.init(kind: 0, iteration: iteration, deadline: deadline,
            first: span?.started ?? checkedAt, second: span?.ended ?? checkedAt,
            third: checkedAt, skipped: skipped,
            authority: span?.passedAuthority ?? false, attempted: span?.attempted ?? false,
            hasSelf: span != nil))
    }
    func resolvedCommit(iteration: Int64) {
        lock.lock(); defer { lock.unlock() }
        if !frozen, pendingCommit == iteration { pendingCommit = nil }
    }
    func committed(_ count: Int) {
        lock.lock(); defer { lock.unlock() }
        let now = ContinuousClock.now
        append(.init(kind: 1, iteration: lastIteration, deadline: now,
                     first: now, second: now, third: now, skipped: count))
    }
    func sleep(iteration: Int64, deadline: ContinuousClock.Instant,
               requestedAt: ContinuousClock.Instant) {
        lock.lock(); defer { lock.unlock() }
        append(.init(kind: 2, iteration: iteration, deadline: deadline,
                     first: requestedAt, second: requestedAt, third: requestedAt))
    }
    func resumed(iteration: Int64, deadline: ContinuousClock.Instant,
                 at now: ContinuousClock.Instant, completed: Bool) {
        lock.lock(); defer { lock.unlock() }
        append(.init(kind: completed ? 3 : 4, iteration: iteration, deadline: deadline,
                     first: now, second: now, third: now))
    }
    private func milliseconds(_ from: ContinuousClock.Instant, _ to: ContinuousClock.Instant) -> Double {
        let value = from.duration(to: to).components
        return Double(value.seconds) * 1_000 + Double(value.attoseconds) / 1e15
    }
    /// Freeze before serialization: a canceled old task may subsequently resume,
    /// but its captured run can never publish into another case or this snapshot.
    func snapshot() -> [String: Any] {
        lock.lock()
        frozen = true
        let events = self.events
        let count = self.count
        let omitted = self.omitted
        let taskStarted = self.taskStarted
        let taskExited = self.taskExited
        let pendingCommit = self.pendingCommit
        lock.unlock()
        // The frozen array can no longer mutate; all validation/serialization
        // allocations occur outside the lock and original live media interval.
        var rows: [[String: Any]] = []
        var committedByIteration: [Int64: Int] = [:]
        var openSleepIterations = Set<Int64>()
        var structuralErrors: [String] = []
        var cycles: [Int64: Event] = [:]
        var commitIterations = Set<Int64>()
        var requestedIterations = Set<Int64>()
        var pendingSleep: Event?
        var previousCycle: Event?
        var previousEventTime: ContinuousClock.Instant?
        // Validation and dictionary/set work occur only after sampling.
        for event in events.prefix(count).compactMap({ $0 }) {
            let eventTime = event.kind == 0 ? event.third : event.first
            if let previousEventTime, eventTime < previousEventTime {
                structuralErrors.append("nonmonotonic event time")
            }
            previousEventTime = eventTime
            switch event.kind {
            case 0:
                if event.iteration != (previousCycle?.iteration ?? 0) + 1 {
                    structuralErrors.append("duplicate/nonconsecutive cycle iteration")
                }
                if let previousCycle {
                    let expected = CompositionFrameSchedule.next(after: previousCycle.deadline,
                        interval: interval, completedAt: previousCycle.third).deadline
                    if event.deadline != expected || event.first < previousCycle.third {
                        structuralErrors.append("cycle deadline/time discontinuity")
                    }
                }
                if pendingSleep != nil { structuralErrors.append("cycle before sleep return") }
                cycles[event.iteration] = event; previousCycle = event
            case 1:
                if let cycle = cycles[event.iteration] {
                    if !cycle.hasSelf || !cycle.authority
                        || event.iteration != previousCycle?.iteration || event.skipped <= 0
                        || event.skipped != cycle.skipped || !commitIterations.insert(event.iteration).inserted {
                        structuralErrors.append("duplicate/invalid commit")
                    }
                } else { structuralErrors.append("orphan commit") }
            case 2:
                if let cycle = previousCycle {
                    let expected = CompositionFrameSchedule.next(after: cycle.deadline,
                        interval: interval, completedAt: cycle.third).deadline
                    if event.iteration != cycle.iteration || event.deadline != expected
                        || !requestedIterations.insert(event.iteration).inserted || pendingSleep != nil {
                        structuralErrors.append("duplicate/invalid sleep request")
                    }
                } else { structuralErrors.append("sleep without cycle") }
                pendingSleep = event
            case 3, 4:
                if let request = pendingSleep {
                    if event.iteration != request.iteration || event.deadline != request.deadline
                        || event.first < request.first { structuralErrors.append("invalid sleep return") }
                } else { structuralErrors.append("orphan sleep return") }
                pendingSleep = nil
            default: structuralErrors.append("unknown event kind")
            }
        }
        for event in events.prefix(count).compactMap({ $0 }) where event.kind == 1 {
            committedByIteration[event.iteration, default: 0] += event.skipped
        }
        var proposedTotal = 0, committedTotal = 0
        var beforeTotal = 0, bodyTotal = 0, continuationTotal = 0
        var checksPass = true
        for event in events.prefix(count).compactMap({ $0 }) {
            if event.kind == 2 { openSleepIterations.insert(event.iteration) }
            if event.kind == 3 || event.kind == 4 { openSleepIterations.remove(event.iteration) }
            var row: [String: Any] = ["kind": event.kind, "iteration": event.iteration,
                "deadlineMilliseconds": milliseconds(origin, event.deadline),
                "firstMilliseconds": milliseconds(origin, event.first)]
            if event.kind == 0 {
                let before = CompositionFrameSchedule.next(after: event.deadline,
                    interval: interval, completedAt: event.first).skipped
                let atEnd = CompositionFrameSchedule.next(after: event.deadline,
                    interval: interval, completedAt: event.second).skipped
                let atCheck = CompositionFrameSchedule.next(after: event.deadline,
                    interval: interval, completedAt: event.third).skipped
                let committed = committedByIteration[event.iteration, default: 0]
                let ordered = event.first <= event.second && event.second <= event.third
                let telescope = before + (atEnd - before) + (atCheck - atEnd) == event.skipped
                checksPass = checksPass && ordered && telescope && atCheck == event.skipped
                    && (committed == 0 || committed == event.skipped)
                proposedTotal += event.skipped; committedTotal += committed
                if committed > 0 {
                    beforeTotal += before; bodyTotal += atEnd - before
                    continuationTotal += atCheck - atEnd
                }
                row.merge(["secondMilliseconds": milliseconds(origin, event.second),
                    "thirdMilliseconds": milliseconds(origin, event.third),
                    "hasSelf": event.hasSelf,
                    "passedAuthority": event.authority, "attempted": event.attempted,
                    "proposedSkips": event.skipped, "committedSkips": committed,
                    "beforeBodySkips": before, "duringBodySkips": atEnd - before,
                    "afterBodySkips": atCheck - atEnd, "ordered": ordered,
                    "telescope": telescope], uniquingKeysWith: { _, new in new })
            } else if event.kind == 1 { row["committedSkips"] = event.skipped }
            rows.append(row)
        }
        let consistent = checksPass && omitted == 0 && structuralErrors.isEmpty
            && beforeTotal + bodyTotal + continuationTotal == committedTotal
        let complete = consistent && taskStarted && taskExited
            && openSleepIterations.isEmpty && pendingCommit == nil
        return ["authority": authority.uuidString, "frozen": true,
            "taskStartedObserved": taskStarted, "taskExitObserved": taskExited,
            "status": !consistent ? "invalid" : complete ? "complete" : "incomplete",
            "pendingCommitIteration": pendingCommit.map { $0 as Any } ?? NSNull(),
            "structuralErrors": structuralErrors, "traceComplete": complete,
            "intervalMilliseconds": milliseconds(origin, origin.advanced(by: interval)),
            "eventCapacity": events.count, "eventsRecorded": count, "omittedEvents": omitted,
            "sleepRequestsWithoutObservedReturnAtFreeze": openSleepIterations.sorted(),
            "kindLegend": ["0": "cycle D/S/E/C", "1": "guarded metrics commit",
                           "2": "sleep request", "3": "sleep resumed", "4": "sleep canceled"],
            "proposedSkips": proposedTotal, "committedSkips": committedTotal,
            "committedBeforeBodySkips": beforeTotal, "committedDuringBodySkips": bodyTotal,
            "committedAfterBodySkips": continuationTotal,
            "observedCommittedCategoriesConsistent": consistent,
            "events": rows]
    }
}
