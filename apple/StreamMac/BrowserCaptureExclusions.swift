import Foundation

/// Authority from a particular capture owner, never a configured bundle-name claim.
/// State changes run on the owner actor before any asynchronous capture work.
@MainActor final class BrowserCaptureExclusionOwner {
    enum State: Equatable { case stopped, pending, ready, installed(Int32), failed, unsupported }
    let id = UUID()
    private(set) var revision = UUID()
    private(set) var state: State = .stopped
    private(set) var attemptedHelperPID: Int32?
    var changed: (@MainActor () -> Void)?
    @discardableResult func publish(_ state: State) -> UUID {
        revision = UUID(); self.state = state
        if state == .ready || state == .stopped { attemptedHelperPID = nil }
        changed?(); return revision
    }
    func beginInstallation(helperPID: Int32) -> UUID {
        attemptedHelperPID = helperPID; return publish(.pending)
    }
    func beginRetirement() -> UUID {
        attemptedHelperPID = nil; return publish(.pending)
    }
    func needsFreshHelper(_ pid: Int32) -> Bool {
        if case .installed(let previous) = state { return previous != pid }
        if state == .failed || state == .unsupported { return attemptedHelperPID.map { $0 != pid } ?? false }
        return false
    }
    /// The same transaction is used by SCStream owners and controlled held-driver tests.
    /// Failed/stale install cannot skip the input and mixer-history barrier.
    func finishInstallation(revision expected: UUID, helperPID: Int32,
                            install: @MainActor () async throws -> Bool,
                            drain: @MainActor () async -> Void,
                            current: @MainActor () -> Bool,
                            reopen: @MainActor () -> Void) async {
        do {
            let installed = try await install()
            guard revision == expected, current() else { return }
            await drain()
            guard revision == expected, current() else { return }
            reopen()
            publish(installed ? .installed(helperPID) : .unsupported)
        } catch {
            guard revision == expected, current() else { return }
            await drain()
            guard revision == expected, current() else { return }
            reopen(); publish(.failed)
        }
    }
    func finishRetirement(revision expected: UUID,
                          stop: @MainActor () async -> Bool,
                          drain: @MainActor () async -> Void,
                          current: @MainActor () -> Bool) async -> Bool {
        let stopped = await stop()
        await drain()
        if revision == expected, current() { publish(stopped ? .stopped : .failed) }
        return stopped
    }
    func accepts(helperPID: Int32, demanded: Bool) -> Bool {
        if !demanded && state == .stopped { return true }
        return state == .installed(helperPID)
    }
}

/// A runtime/demand/owner snapshot. Its live validator is checked before capture,
/// before page Resume and immediately before the final mixer gate opens.
@MainActor struct BrowserCaptureExclusionPermit {
    let id: UUID
    let helperPID: Int32
    let isCurrent: @MainActor () -> Bool
    func allows(_ pid: Int32) -> Bool { pid == helperPID && isCurrent() }
}

/// The real SCStream callbacks remain on their serial sample queue. Closing this
/// gate is synchronous; owners then queue a fence on that exact queue and reset
/// only their mixer channel before reopening. Video delivery is independent.
final class CaptureAudioDeliveryGate: @unchecked Sendable {
    private let lock = NSLock()
    private var open = true
    private var epoch = UUID()
    var isOpen: Bool { lock.lock(); defer { lock.unlock() }; return open }
    var token: UUID? { lock.lock(); defer { lock.unlock() }; return open ? epoch : nil }
    func accepts(_ token: UUID) -> Bool { lock.lock(); defer { lock.unlock() }; return open && epoch == token }
    func setOpen(_ value: Bool) {
        lock.lock(); if !value { epoch = UUID() }; open = value; lock.unlock()
    }
}

/// Distinct capture keys can feed one application channel. An old completion may
/// release only its own boundary, never another owner or a newer operation.
@MainActor final class CaptureAudioBoundaryOwners {
    private var pending: [UUID: UUID] = [:]
    var isEmpty: Bool { pending.isEmpty }
    func close(owner: UUID, revision: UUID) { pending[owner] = revision }
    func release(owner: UUID, revision: UUID) {
        guard pending[owner] == revision else { return }; pending[owner] = nil
    }
    func revision(for owner: UUID) -> UUID? { pending[owner] }
}

/// Retirement owns SCStream.stopCapture. A late successful start only releases
/// its occupancy; it must not stop a stream a second time behind that owner.
@MainActor final class CaptureAudioPendingStarts {
    private var active: Set<UUID> = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func begin() -> UUID { let id = UUID(); active.insert(id); return id }
    func finish(_ id: UUID) {
        guard active.remove(id) != nil, active.isEmpty else { return }
        let pending = waiters; waiters = []; for waiter in pending { waiter.resume() }
    }
    func waitUntilDrained() async {
        if !active.isEmpty { await withCheckedContinuation { waiters.append($0) } }
    }
}
