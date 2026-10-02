import Foundation

public enum SourceFailureMode: String, Codable, CaseIterable, Sendable {
    case freeze, blank, offline, standby
    public var label: String {
        switch self {
        case .freeze: return "Freeze last frame"
        case .blank: return "Blank source"
        case .offline: return "Offline card"
        case .standby: return "Standby video source"
        }
    }
}
public struct SourceFailoverRule: Codable, Equatable, Sendable {
    public var sourceID: UUID
    public var mode: SourceFailureMode
    public var standbySourceID: UUID?
    public init(sourceID: UUID, mode: SourceFailureMode = .offline, standbySourceID: UUID? = nil) {
        self.sourceID = sourceID; self.mode = mode; self.standbySourceID = standbySourceID
    }
}
public struct DesktopResiliencePolicy: Codable, Equatable, Sendable {
    public enum LockAction: String, Codable, CaseIterable, Sendable {
        case stopOutputs, continueWithOfflineSlate
        public var label: String { self == .stopOutputs ? "Stop outputs; restart manually" : "Keep existing outputs on a silent offline slate" }
    }
    public var defaultSourceMode: SourceFailureMode = .offline
    public var sourceRules: [SourceFailoverRule] = []
    public var standbySceneID: UUID?
    public var automaticallyRestoreSources = false
    public var lockAction: LockAction = .stopOutputs
    public var previewAfterWake = false
    public var failureGraceSeconds = 2.0
    public init() {}
}

/// Bounded retained-frame policy shared by the native source wrapper and tests.
/// All pixel buffers are immutable after ingestion. A failed source cannot leak
/// an old raw provider frame through blank/offline/standby mode.
public final class SourceFailoverCache<Key: Hashable & Sendable, Frame: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: [Key: Frame] = [:]
    private var active: Set<Key> = []
    private var modes: [Key: SourceFailureMode] = [:]
    private var failed: Set<Key> = []
    public init() {}
    public var retainedCount: Int { lock.lock(); defer { lock.unlock() }; return latest.count }
    public func configure(active: Set<Key>, modes: [Key: SourceFailureMode], failed: Set<Key>) {
        lock.lock(); defer { lock.unlock() }
        self.active = active
        latest = latest.filter { active.contains($0.key) }
        self.modes = modes
        self.failed = failed
    }
    public func frame(for key: Key, live: () -> Frame?, standby: () -> Frame?, offline: () -> Frame?) -> Frame? {
        lock.lock()
        let mode = modes[key] ?? .offline
        let isFailed = failed.contains(key)
        let held = latest[key]
        lock.unlock()
        if !isFailed, let fresh = live() {
            lock.lock(); if active.contains(key) { latest[key] = fresh }; lock.unlock()
            return fresh
        }
        switch mode {
        case .freeze: return held ?? offline()
        case .blank: return nil
        case .offline: return offline()
        case .standby: return standby() ?? offline()
        }
    }
    public func clear() { lock.lock(); latest = [:]; active = []; failed = []; modes = [:]; lock.unlock() }
}

/// Monotonic health fold: reported errors fail immediately; an empty fresh-frame
/// observation must outlast startup grace. Recovery is operator-controlled unless
/// the project explicitly enables automatic restoration.
public struct SourceFailureTracker<Key: Hashable & Sendable>: Sendable {
    private var unavailableSince: [Key: Double] = [:]
    public private(set) var latched: Set<Key> = []
    public init() {}
    @discardableResult
    public mutating func update(active: Set<Key>, unavailable: Set<Key>, reportedFailures: Set<Key>,
                                now: Double, graceSeconds: Double, automaticallyRestore: Bool) -> Set<Key> {
        unavailableSince = unavailableSince.filter { active.contains($0.key) && unavailable.contains($0.key) }
        for key in unavailable.intersection(active) where unavailableSince[key] == nil { unavailableSince[key] = now }
        let expired = Set(unavailableSince.compactMap { now - $0.value >= max(0, graceSeconds) ? $0.key : nil })
        let current = expired.union(reportedFailures.intersection(active))
        latched = automaticallyRestore ? current : latched.intersection(active).union(current)
        return latched
    }
    public mutating func restore() { latched = [] }
    public mutating func resetObservations() { unavailableSince = [:] }
}
