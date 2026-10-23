import Dispatch
import Foundation

private struct ProofFailure: Error, CustomStringConvertible { let description: String }
private final class SnapshotBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [String: Any]?
    func store(_ value: [String: Any]) { lock.lock(); self.value = value; lock.unlock() }
    func load() -> [String: Any]? { lock.lock(); defer { lock.unlock() }; return value }
}

@main private enum CycleTraceNativeHarness {
    static func require(_ condition: @autoclosure () throws -> Bool, _ reason: String) throws {
        if try !condition() { throw ProofFailure(description: reason) }
    }
    static func integer(_ value: [String: Any], _ name: String) -> Int {
        if let native = value[name] as? Int { return native }
        if let wide = value[name] as? Int64, let exact = Int(exactly: wide) { return exact }
        return -1
    }
    static func boolean(_ value: [String: Any], _ name: String) -> Bool { value[name] as? Bool ?? false }
    static func bytes(_ snapshot: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys])
    }
    static func span(_ d: ContinuousClock.Instant, _ s: Int64, _ e: Int64,
                     authority: Bool = true, attempted: Bool = true) -> CompositionCycleTraceRun.TickSpan {
        .init(started: d.advanced(by: .milliseconds(s)), ended: d.advanced(by: .milliseconds(e)),
              passedAuthority: authority, attempted: attempted)
    }
    static func fresh(_ interval: Duration = .milliseconds(10)) -> CompositionCycleTraceRun {
        .init(authority: UUID(), interval: interval)
    }
    static func main() throws {
        let d = ContinuousClock.now.advanced(by: .seconds(-10))
        let interval = Duration.milliseconds(10)
        var outcomes: [String] = []
        func passed(_ name: String) {
            outcomes.append(name)
            FileHandle.standardOutput.write(Data(("PASS " + name + "\n").utf8))
        }
        try require(integer(["owned": Int(1)], "owned") == 1
                    && integer(["owned": Int64(1)], "owned") == 1, "fixture exact Int/Int64 adapter")
        passed("fixture adapter accepts Int and exact Int64")

        let edgeOffsets: [Int64] = [-1, 0, 9, 10, 19, 20, 29, 30, 65]
        let edgeExpected = [0, 0, 0, 0, 0, 1, 1, 2, 5]
        for (offset, expected) in zip(edgeOffsets, edgeExpected) {
            try require(CompositionFrameSchedule.next(after: d, interval: interval,
                completedAt: d.advanced(by: .milliseconds(offset))).skipped == expected,
                "actual scheduler exact edge \(offset)")
        }
        passed("actual unchanged scheduler negative/due/exact-equality edges")

        let accepted = fresh(); accepted.started()
        accepted.cycle(iteration: 1, deadline: d, span: span(d, 25, 45),
                       checkedAt: d.advanced(by: .milliseconds(65)), skipped: 5)
        accepted.committed(5); accepted.resolvedCommit(iteration: 1); accepted.exited()
        let a = accepted.snapshot()
        try require(boolean(a, "traceComplete") && boolean(a, "observedCommittedCategoriesConsistent"), "accepted complete")
        try require(integer(a, "committedBeforeBodySkips") == 1 && integer(a, "committedDuringBodySkips") == 2
                    && integer(a, "committedAfterBodySkips") == 2 && integer(a, "committedSkips") == 5,
                    "actual helper telescoping 1+2+2=5")
        passed("real helper accepted committed categories telescope 1+2+2=5")

        for hasSelf in [false, true] {
            let rejected = fresh(); rejected.started()
            rejected.cycle(iteration: 1, deadline: d,
                span: hasSelf ? span(d, 25, 45, authority: false, attempted: false) : nil,
                checkedAt: d.advanced(by: .milliseconds(65)), skipped: 5)
            rejected.resolvedCommit(iteration: 1); rejected.exited()
            let value = rejected.snapshot()
            try require(boolean(value, "traceComplete") && integer(value, "proposedSkips") == 5
                        && integer(value, "committedSkips") == 0, "rejected/no-self proposals not committed")
            let row = (value["events"] as! [[String: Any]])[0]
            try require(boolean(row, "hasSelf") == hasSelf && !boolean(row, "passedAuthority"), "explicit rejected span")
        }
        passed("supplied rejected/stale and nil-self spans never fabricate commits")

        let separateEpoch = fresh(); separateEpoch.started(); separateEpoch.exited()
        let separateFrozen = separateEpoch.snapshot()
        try require((separateFrozen["authority"] as? String) != (a["authority"] as? String)
                    && integer(separateFrozen, "committedSkips") == 0, "independent run authority/count")
        accepted.committed(7)
        try require(try bytes(separateEpoch.snapshot()) == bytes(separateFrozen), "old run wrote into separate epoch")
        passed("distinct run authorities and counters never cross epochs")

        let unresolved = fresh(); unresolved.started()
        unresolved.cycle(iteration: 1, deadline: d, span: span(d, 25, 45),
                         checkedAt: d.advanced(by: .milliseconds(65)), skipped: 5)
        unresolved.exited()
        let unresolvedValue = unresolved.snapshot()
        try require(!boolean(unresolvedValue, "traceComplete") && integer(unresolvedValue, "pendingCommitIteration") == 1,
                    "unresolved commit must be incomplete")
        passed("unresolved commit remains incomplete even with exit observation")

        let neverStarted = fresh().snapshot()
        try require(!boolean(neverStarted, "taskStartedObserved") && !boolean(neverStarted, "traceComplete"), "never-started incomplete")
        let unexited = fresh(); unexited.started()
        try require(!boolean(unexited.snapshot(), "traceComplete"), "unexited incomplete")
        passed("never-started and unexited runs cannot report complete")

        let sleeping = fresh(); sleeping.started()
        sleeping.cycle(iteration: 1, deadline: d, span: span(d, 1, 2), checkedAt: d.advanced(by: .milliseconds(3)), skipped: 0)
        sleeping.resolvedCommit(iteration: 1)
        sleeping.sleep(iteration: 1, deadline: d.advanced(by: interval), requestedAt: ContinuousClock.now)
        let frozen = sleeping.snapshot()
        try require(!boolean(frozen, "traceComplete")
                    && (frozen["sleepRequestsWithoutObservedReturnAtFreeze"] as? [Int64]) == [1], "pending sleep unknown")
        let beforeLateWrites = try bytes(frozen)
        sleeping.resumed(iteration: 1, deadline: d.advanced(by: interval), at: ContinuousClock.now, completed: false)
        sleeping.committed(99); sleeping.resolvedCommit(iteration: 1); sleeping.exited(); sleeping.started()
        sleeping.cycle(iteration: 2, deadline: d, span: nil, checkedAt: ContinuousClock.now, skipped: 0)
        try require(try bytes(sleeping.snapshot()) == beforeLateWrites, "late writes changed frozen snapshot")
        passed("pending sleep explicit; post-freeze canceled/commit/cycle/exit writes immutable")

        for completed in [false, true] {
            let sleepReturn = fresh(); sleepReturn.started()
            sleepReturn.cycle(iteration: 1, deadline: d, span: span(d, 1, 2), checkedAt: d.advanced(by: .milliseconds(3)), skipped: 0)
            sleepReturn.resolvedCommit(iteration: 1)
            sleepReturn.sleep(iteration: 1, deadline: d.advanced(by: interval), requestedAt: ContinuousClock.now)
            sleepReturn.resumed(iteration: 1, deadline: d.advanced(by: interval), at: ContinuousClock.now, completed: completed)
            sleepReturn.exited()
            try require(boolean(sleepReturn.snapshot(), "traceComplete"), "paired sleep return complete")
        }
        passed("actual helper paired successful/canceled sleep endpoints")

        let duplicate = fresh(); duplicate.started()
        for _ in 0..<2 { duplicate.cycle(iteration: 1, deadline: d, span: span(d, 1, 2), checkedAt: d.advanced(by: .milliseconds(3)), skipped: 0) }
        duplicate.exited()
        try require((duplicate.snapshot()["status"] as? String) == "invalid", "duplicate cycle accepted")
        let unordered = fresh(); unordered.started()
        unordered.cycle(iteration: 1, deadline: d, span: span(d, 5, 2), checkedAt: d.advanced(by: .milliseconds(3)), skipped: 0)
        unordered.exited()
        try require((unordered.snapshot()["status"] as? String) == "invalid", "nonmonotonic span accepted")
        let orphan = fresh(); orphan.started(); orphan.committed(1); orphan.exited()
        try require((orphan.snapshot()["status"] as? String) == "invalid", "orphan commit accepted")
        let orphanSleep = fresh(); orphanSleep.started()
        orphanSleep.resumed(iteration: 1, deadline: d, at: ContinuousClock.now, completed: true); orphanSleep.exited()
        try require((orphanSleep.snapshot()["status"] as? String) == "invalid", "orphan sleep accepted")
        let duplicateCommit = fresh(); duplicateCommit.started()
        duplicateCommit.cycle(iteration: 1, deadline: d, span: span(d, 25, 45), checkedAt: d.advanced(by: .milliseconds(65)), skipped: 5)
        duplicateCommit.committed(5); duplicateCommit.committed(5); duplicateCommit.resolvedCommit(iteration: 1); duplicateCommit.exited()
        try require((duplicateCommit.snapshot()["status"] as? String) == "invalid", "duplicate commit accepted")
        let duplicateSleep = fresh(); duplicateSleep.started()
        duplicateSleep.cycle(iteration: 1, deadline: d, span: span(d, 1, 2), checkedAt: d.advanced(by: .milliseconds(3)), skipped: 0)
        duplicateSleep.resolvedCommit(iteration: 1)
        for _ in 0..<2 { duplicateSleep.sleep(iteration: 1, deadline: d.advanced(by: interval), requestedAt: ContinuousClock.now) }
        duplicateSleep.resumed(iteration: 1, deadline: d.advanced(by: interval), at: ContinuousClock.now, completed: true); duplicateSleep.exited()
        try require((duplicateSleep.snapshot()["status"] as? String) == "invalid", "duplicate sleep accepted")
        passed("duplicate/nonmonotonic/orphan cycle/commit/sleep evidence refused")

        let overflow = fresh(); overflow.started()
        for _ in 0..<65_537 { overflow.resumed(iteration: 1, deadline: d, at: d, completed: true) }
        overflow.exited()
        let overflowValue = overflow.snapshot()
        try require(integer(overflowValue, "eventsRecorded") == 65_536 && integer(overflowValue, "omittedEvents") == 1
                    && !boolean(overflowValue, "traceComplete") && (overflowValue["status"] as? String) == "invalid", "overflow not explicit invalid")
        passed("fixed 65536 event capacity; omission invalidates completeness")

        let racing = fresh(); racing.started()
        let box = SnapshotBox(), ready = DispatchSemaphore(value: 0), go = DispatchSemaphore(value: 0)
        let group = DispatchGroup(), queue = DispatchQueue(label: "owned-cycle-trace-race", attributes: .concurrent)
        group.enter()
        queue.async {
            ready.signal(); go.wait()
            for index in 1...1024 {
                racing.cycle(iteration: Int64(index), deadline: d,
                    span: span(d, 1, 2), checkedAt: d.advanced(by: .milliseconds(3)), skipped: 0)
                racing.resolvedCommit(iteration: Int64(index))
            }
            racing.exited(); group.leave()
        }
        group.enter()
        queue.async { ready.wait(); go.signal(); box.store(racing.snapshot()); group.leave() }
        group.wait()
        guard let raced = box.load() else { throw ProofFailure(description: "concurrent snapshot missing") }
        try require(try bytes(raced) == bytes(racing.snapshot()), "concurrent postfreeze data mutated")
        passed("bounded concurrent append/snapshot freeze under ThreadSanitizer")

        let calibration = fresh(), clock = ContinuousClock()
        let iterations = 10_000
        let baselineStart = clock.now
        for _ in 0..<iterations { _ = ContinuousClock.now }
        let baseline = baselineStart.duration(to: clock.now).components
        let observerStart = clock.now
        for index in 0..<iterations {
            calibration.cycle(iteration: Int64(index + 1), deadline: d,
                span: span(d, 1, 2), checkedAt: d.advanced(by: .milliseconds(3)), skipped: 0)
        }
        let observer = observerStart.duration(to: clock.now).components
        func nanos(_ value: (seconds: Int64, attoseconds: Int64)) -> Double {
            Double(value.seconds) * 1e9 + Double(value.attoseconds) / 1e9
        }
        let result: [String: Any] = ["result": "PASS", "outcomes": outcomes,
            "scope": "Actual frozen helper and unchanged scheduler only. Supplied spans exercise diagnostics; actual Engine authority/scheduling and full target typecheck are not executed. No rendering/media/device/network/workload or capacity qualification.",
            "calibration": ["iterations": iterations, "clockReadLoopNanoseconds": nanos(baseline),
                "observerLoopNanoseconds": nanos(observer), "observerPerIterationNanoseconds": nanos(observer) / Double(iterations),
                "scope": "Helper-only scalar/lock/store plus synthetic span construction; ThreadSanitizer/optimizer perturbed. Not representative frame cost, pure lock cost or subtraction-based throughput estimate."]]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        if CommandLine.arguments.count == 2 { try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1])) }
        FileHandle.standardOutput.write(data + Data([10]))
    }
}
