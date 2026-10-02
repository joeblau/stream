import Foundation
import Testing
@testable import StreamCore

@Suite struct DesktopResilienceTests {
    @Test("Safe defaults persist and never authorize output resume")
    func policy() throws {
        let policy = DesktopResiliencePolicy()
        #expect(policy.lockAction == .stopOutputs)
        #expect(policy.defaultSourceMode == .offline)
        #expect(!policy.previewAfterWake && !policy.automaticallyRestoreSources)
        #expect(try JSONDecoder().decode(DesktopResiliencePolicy.self, from: JSONEncoder().encode(policy)) == policy)
    }
    @Test("Warmup grace, immediate unplug, independent healthy source and explicit restore")
    func tracker() {
        var tracker = SourceFailureTracker<String>()
        let active: Set<String> = ["camera", "screen"]
        #expect(tracker.update(active: active, unavailable: ["camera"], reportedFailures: [], now: 0, graceSeconds: 2, automaticallyRestore: false).isEmpty)
        #expect(tracker.update(active: active, unavailable: ["camera"], reportedFailures: [], now: 2, graceSeconds: 2, automaticallyRestore: false) == ["camera"])
        #expect(tracker.update(active: active, unavailable: [], reportedFailures: [], now: 3, graceSeconds: 2, automaticallyRestore: false) == ["camera"])
        tracker.restore()
        #expect(tracker.update(active: active, unavailable: [], reportedFailures: [], now: 4, graceSeconds: 2, automaticallyRestore: false).isEmpty)
        #expect(tracker.update(active: active, unavailable: [], reportedFailures: ["screen"], now: 4, graceSeconds: 2, automaticallyRestore: false) == ["screen"])
        #expect(tracker.update(active: active, unavailable: [], reportedFailures: [], now: 5, graceSeconds: 2, automaticallyRestore: true).isEmpty)
    }
    @Test("Removing a source prunes its retained latch")
    func removed() {
        var tracker = SourceFailureTracker<String>()
        _ = tracker.update(active: ["old"], unavailable: [], reportedFailures: ["old"], now: 0, graceSeconds: 2, automaticallyRestore: false)
        #expect(tracker.update(active: ["new"], unavailable: [], reportedFailures: [], now: 3, graceSeconds: 2, automaticallyRestore: false).isEmpty)
    }
    @Test("All fallback modes suppress stale raw frames and healthy sources flow")
    func frames() {
        let cache = SourceFailoverCache<String, Int>()
        let active: Set<String> = ["failed", "healthy"]
        cache.configure(active: active, modes: ["failed": .freeze], failed: [])
        #expect(cache.frame(for: "failed", live: { 1 }, standby: { 7 }, offline: { 9 }) == 1)
        for (mode, expected) in [(SourceFailureMode.freeze, Optional(1)), (.blank, nil), (.offline, 9), (.standby, 7)] {
            cache.configure(active: active, modes: ["failed": mode], failed: ["failed"])
            #expect(cache.frame(for: "failed", live: { Issue.record("failed raw provider must not be read"); return 2 }, standby: { 7 }, offline: { 9 }) == expected)
            #expect(cache.frame(for: "healthy", live: { 3 }, standby: { nil }, offline: { 9 }) == 3)
        }
        cache.configure(active: active, modes: ["failed": .standby], failed: ["failed"])
        #expect(cache.frame(for: "failed", live: { 2 }, standby: { nil }, offline: { 9 }) == 9)
        #expect(cache.retainedCount == 2)
        cache.configure(active: ["healthy"], modes: [:], failed: [])
        #expect(cache.retainedCount == 1)
        // A late tick for a removed source cannot grow retained memory.
        _ = cache.frame(for: "removed", live: { 4 }, standby: { nil }, offline: { nil })
        #expect(cache.retainedCount == 1)
        cache.clear(); #expect(cache.retainedCount == 0)
    }
}
