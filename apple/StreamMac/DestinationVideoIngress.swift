import CoreMedia
import Foundation
import StreamCore

/// Only completed private frames cross this interface. Source borrowing and
/// the sealed transfer finish inside the broker before a client is invoked.
struct DestinationFrameDeliveryAdapter: Sendable {
    var sourceRequest: @Sendable (CGSize, OutputCanvas) throws -> RawVideoResourceRequest?
    var install: @Sendable (UUID, StableFrameDomainID, UUID, RawVideoResourceBank, RawVideoResourceBank?, RawVideoResourceReceipt?, FrameDeliveryTransfer,
        OutputCanvas, FrameDeliveryCancellation, @escaping @Sendable () -> Bool, @escaping FrameDeliverySink) async throws -> FrameDeliveryLease
    var remove: @Sendable (FrameDeliveryLease, OutputCanvas) async -> Void
    var cancel: @Sendable (UUID, OutputCanvas) async -> Void
    var statistics: @Sendable (FrameDeliveryLease, OutputCanvas) async -> FrameDeliveryStatistics

    static func standalone(fanout: DestinationMediaFanout) -> Self {
        .init(sourceRequest: { _, _ in nil }, install: { token, domain, generation, bank, _, _, transfer, canvas, cancellation, authorized, sink in
            try Task.checkCancellation()
            return try fanout.broker(for: canvas).install(token: token, domain: domain, generation: generation,
                bank: bank, transfer: transfer, capacity: 2, cancellation: cancellation, authorized: authorized, sink: sink)
        }, remove: { lease, canvas in fanout.broker(for: canvas).remove(lease) },
           cancel: { token, canvas in fanout.broker(for: canvas).cancel(token: token) },
           statistics: { lease, canvas in fanout.broker(for: canvas).statistics(for: lease) })
    }
}

/// One batch may offer the same source claim to several private domains. It
/// stays owned until an Engine ACK adopts it or every pending offer disappears.
/// Endpoint cleanup never retires the Engine's shared source bank.
final class DestinationSourceVideoResources: @unchecked Sendable {
    let bank: RawVideoResourceBank
    let receipt: RawVideoResourceReceipt
    private let lock = NSLock()
    private var adopted = false
    init(bank: RawVideoResourceBank, receipt: RawVideoResourceReceipt) { self.bank = bank; self.receipt = receipt }
    func didInstall() { lock.withLock { adopted = true } }
    deinit {
        if !lock.withLock({ adopted }) { RawVideoResourceCoordinator.shared.rollback(receipt) }
    }
}

/// A group shares this single ingress; raw endpoints each own a distinct one.
/// Closing revokes authority synchronously. Late installation receives only its
/// captured token's cancellation and cannot remove a replacement generation.
final class DestinationVideoIngress: @unchecked Sendable {
    private let lock = NSLock()
    let bank: RawVideoResourceBank
    private let receipt: RawVideoResourceReceipt
    private let adapter: DestinationFrameDeliveryAdapter
    private let canvas: OutputCanvas
    private let transfer: FrameDeliveryTransfer
    private let sink: FrameDeliverySink
    private let sourceResources: DestinationSourceVideoResources?
    private let token = UUID()
    private let cancellation = FrameDeliveryCancellation()
    private var installation: Task<FrameDeliveryLease, Error>?
    private var closed = false
    private var lease: FrameDeliveryLease?

    init(bank: RawVideoResourceBank, receipt: RawVideoResourceReceipt, canvas: OutputCanvas,
         transfer: FrameDeliveryTransfer, sourceResources: DestinationSourceVideoResources?, adapter: DestinationFrameDeliveryAdapter, sink: @escaping FrameDeliverySink) {
        self.bank = bank; self.receipt = receipt; self.canvas = canvas
        self.transfer = transfer; self.sourceResources = sourceResources; self.adapter = adapter; self.sink = sink
    }

    func install() async throws {
        let task = try lock.withLock { () throws -> Task<FrameDeliveryLease, Error> in
            guard !closed else { throw CancellationError() }
            if let installation { return installation }
            let token = token, bank = bank, adapter = adapter, canvas = canvas, transfer = transfer
            let cancellation = cancellation, sink = sink, sourceResources = sourceResources
            let task = Task {
                try Task.checkCancellation()
                let lease = try await adapter.install(token, bank.reservation.request.domain,
                    bank.reservation.request.sessionGeneration, bank, sourceResources?.bank, sourceResources?.receipt,
                    transfer, canvas, cancellation, { !cancellation.isCancelled }, sink)
                sourceResources?.didInstall()
                return lease
            }
            installation = task
            return task
        }
        let installed = try await task.value
        lock.withLock { if !closed { lease = installed } }
        guard !cancellation.isCancelled else { throw CancellationError() }
    }

    func statistics() async -> FrameDeliveryStatistics? {
        guard let lease = lock.withLock({ closed ? nil : lease }) else { return nil }
        return await adapter.statistics(lease, canvas)
    }

    deinit { close() }

    func close() {
        let closing = lock.withLock { () -> (Bool, Task<FrameDeliveryLease, Error>?) in
            guard !closed else { return (false, nil) }
            closed = true; cancellation.cancel()
            return (true, installation)
        }
        guard closing.0 else { return }
        let installation = closing.1, adapter = adapter, token = token, canvas = canvas
        installation?.cancel()
        // Cancellation/removal does not prove all external native aliases are
        // released. Refund is permitted only if nothing was ever exposed.
        RawVideoResourceCoordinator.shared.rollback(receipt)
        RawVideoResourceCoordinator.shared.retire(bankID: bank.id)
        Task {
            await adapter.cancel(token, canvas)
            if let lease = try? await installation?.value { await adapter.remove(lease, canvas) }
        }
    }
}
