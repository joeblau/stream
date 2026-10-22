import CoreGraphics
import Foundation

/// One latest image and at most one scheduled MainActor drain per endpoint.
/// The scheduled work captures this mailbox weakly, never an image snapshot.
final class OptionalMonitorImageHandoff: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: CGImage?
    private var scheduled = false
    private var active = true
    private var queuedDrains = 0
    private var peakQueuedDrains = 0
    struct Snapshot: Sendable {
        let pendingImages: Int
        let queuedDrains: Int
        let peakQueuedDrains: Int
    }
    var snapshot: Snapshot {
        lock.lock(); defer { lock.unlock() }
        return .init(pendingImages: pending == nil ? 0 : 1, queuedDrains: queuedDrains, peakQueuedDrains: peakQueuedDrains)
    }
    private let receive: @MainActor @Sendable (CGImage) -> Void
    init(receive: @escaping @MainActor @Sendable (CGImage) -> Void) { self.receive = receive }

    func enqueue(_ image: CGImage) {
        lock.lock()
        guard active else { lock.unlock(); return }
        pending = image
        let schedule = !scheduled
        scheduled = true
        lock.unlock()
        if schedule { scheduleDrain() }
    }
    func finish() { lock.lock(); active = false; pending = nil; lock.unlock() }
    private func scheduleDrain() {
        lock.lock(); queuedDrains += 1; peakQueuedDrains = max(peakQueuedDrains, queuedDrains); lock.unlock()
        Task { @MainActor [weak self] in self?.drain() }
    }
    @MainActor private func drain() {
        beganDrain()
        if let image = take() { receive(image) }
        if needsAnotherDrain() { scheduleDrain() }
    }
    private func beganDrain() { lock.lock(); queuedDrains -= 1; lock.unlock() }
    private func take() -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        guard active else { return nil }
        let image = pending; pending = nil
        return image
    }
    private func needsAnotherDrain() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if active, pending != nil { return true }
        scheduled = false
        return false
    }
}
