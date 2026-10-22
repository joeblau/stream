import Foundation
import StreamCore

/// Synchronous cancellation is independent of the Engine actor's install ACK.
/// An installation owns its receipt until it either adopts its exact lease or
/// finishes stale cleanup; removal never releases a replacement's resources.
final class GuestReturnFrameDelivery: @unchecked Sendable {
    final class Preparation: @unchecked Sendable {
        let token: UUID
        let generation: UUID
        let domain: StableFrameDomainID
        let receipt: RawVideoResourceReceipt
        let sourceReceipt: RawVideoResourceReceipt
        let bank: RawVideoResourceBank
        let resources: GuestReturnVideoResources
        let cancellation = FrameDeliveryCancellation()
        var lease: FrameDeliveryLease?
        init(token: UUID, generation: UUID, domain: StableFrameDomainID,
             receipt: RawVideoResourceReceipt, sourceReceipt: RawVideoResourceReceipt,
             bank: RawVideoResourceBank, resources: GuestReturnVideoResources) {
            self.token = token; self.generation = generation; self.domain = domain
            self.receipt = receipt; self.sourceReceipt = sourceReceipt
            self.bank = bank; self.resources = resources
        }
    }
    private let lock = NSLock()
    private var current: Preparation?

    var isVacant: Bool { lock.lock(); defer { lock.unlock() }; return current == nil }

    func begin(_ preparation: Preparation) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard current == nil else { return false }
        current = preparation; return true
    }
    func adopt(_ lease: FrameDeliveryLease, preparation: Preparation) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard current === preparation else { return false }
        preparation.lease = lease; return true
    }
    func resources(for token: UUID) -> GuestReturnVideoResources? {
        lock.lock(); defer { lock.unlock() }
        return current?.token == token ? current?.resources : nil
    }
    func remove(token: UUID) -> Preparation? {
        lock.lock()
        guard let preparation = current, preparation.token == token else { lock.unlock(); return nil }
        current = nil
        lock.unlock()
        preparation.cancellation.cancel()
        return preparation
    }
}
