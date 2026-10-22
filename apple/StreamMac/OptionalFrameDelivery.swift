import CoreGraphics
import Foundation
import StreamCore

/// Trusted eligibility only. No image, source frame, or owner escapes this gate.
private final class OptionalFrameDeliveryGate: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    func finish() { lock.lock(); active = false; lock.unlock() }
    var isActive: Bool { lock.lock(); defer { lock.unlock() }; return active }
}

/// One optional endpoint's admitted private storage and exact broker identity.
/// Five slots cover transfer, mailbox, callback, pending image and current image.
/// Opaque additional holds exhaust this endpoint's bank instead of growing it.
final class OptionalFrameDelivery: @unchecked Sendable {
    let token = UUID()
    let generation: UUID
    let descriptor: RawVideoBankDescriptor
    private let engine: CompositionEngine
    private let domain: StableFrameDomainID
    private let receipt: RawVideoResourceReceipt
    private let bank: RawVideoResourceBank
    private let sourceBank: RawVideoResourceBank
    private let sourceReceipt: RawVideoResourceReceipt
    private let cancellation = FrameDeliveryCancellation()
    private let transfer: FrameDeliveryTransfer
    private let canvas: OutputCanvas
    private let clean: Bool
    private let gate = OptionalFrameDeliveryGate()
    private let authorized: @Sendable () -> Bool
    private let lock = NSLock()
    private var installStarted = false
    private var lease: FrameDeliveryLease?
    private var finished = false
    private var removalTask: Task<Void, Never>?

    init(engine: CompositionEngine, domain: StableFrameDomainID, width: Int, height: Int, sourceSize: CGSize? = nil,
         transfer: FrameDeliveryTransfer = .copyBGRA, canvas: OutputCanvas = .program,
         clean: Bool = false, authorized: @escaping @Sendable () -> Bool = { true }) throws {
        self.engine = engine; self.domain = domain; self.transfer = transfer
        self.canvas = canvas; self.clean = clean; self.authorized = authorized
        let generation = UUID()
        self.generation = generation
        let descriptor = RawVideoBankDescriptor(width: width, height: height, capacity: 5)
        self.descriptor = descriptor
        let sourceRequest = try engine.sourceFrameResourceRequest(
            canvasSize: sourceSize ?? CGSize(width: width, height: height), canvas: canvas, clean: clean)
        let batch = try RawVideoResourceCoordinator.shared.reserveBatch([sourceRequest,
            .init(domain: domain, descriptor: descriptor, sessionGeneration: generation)])
        var privateChild: RawVideoResourceReceipt?, sourceChild: RawVideoResourceReceipt?
        do {
            privateChild = try batch.selecting(domain: domain)
            sourceChild = try batch.selecting(domain: sourceRequest.domain)
            guard let privateChild, let sourceChild,
                  let bank = privateChild.bank(for: domain), let sourceBank = sourceChild.bank(for: sourceRequest.domain) else {
                throw RawVideoResourceFailure.unknownReservation
            }
            receipt = privateChild; sourceReceipt = sourceChild
            self.bank = bank; self.sourceBank = sourceBank
            RawVideoResourceCoordinator.shared.rollback(batch)
        } catch {
            if let privateChild { RawVideoResourceCoordinator.shared.rollback(privateChild) }
            if let sourceChild { RawVideoResourceCoordinator.shared.rollback(sourceChild) }
            RawVideoResourceCoordinator.shared.rollback(batch)
            throw error
        }
    }

    func install(shouldTransfer: @escaping @Sendable () -> Bool = { true },
                 sink: @escaping @Sendable (CompositedFrame) -> Void) async throws {
        guard beginInstall() else { throw CancellationError() }
        let gate = gate, authorized = authorized
        try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                guard bank.isOpen, sourceBank.isOpen else { throw RawVideoResourceFailure.unknownReservation }
                let installed = try await engine.installFrameDelivery(token: token, domain: domain,
                    generation: generation, bank: bank, sourceBank: sourceBank, sourceReceipt: sourceReceipt,
                    transfer: transfer, capacity: 1, cancellation: cancellation,
                    canvas: canvas, clean: clean, authorized: { gate.isActive && authorized() },
                    shouldTransfer: shouldTransfer, sink: sink)
                guard accept(installed), !Task.isCancelled else {
                    finish()
                    await engine.removeFrameDelivery(installed)
                    throw CancellationError()
                }
            } catch {
                finish()
                throw error
            }
        } onCancel: { self.finish() }
    }

    private func beginInstall() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !finished, !installStarted else { return false }
        installStarted = true
        return true
    }
    private func accept(_ installed: FrameDeliveryLease) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return false }
        lease = installed
        return true
    }

    /// Close eligibility synchronously before any callback/removal actor hop.
    /// The single cleanup barrier retains charges until pool detachment; exposed
    /// banks stay charged and only never-exposed preparation can be refunded.
    func finish() {
        cancellation.cancel()
        gate.finish()
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let lease = lease
        self.lease = nil
        let engine = engine, token = token, receipt = receipt, sourceReceipt = sourceReceipt, bankID = bank.id
        // Publish the one cleanup barrier under the same lock as retirement.
        // Every concurrent Stop sees it, including while pool detachment waits.
        removalTask = Task {
            RawVideoResourceCoordinator.shared.rollback(receipt)
            // Adoption moved authority to the engine; this stale child can
            // release only a source preparation that was never adopted.
            RawVideoResourceCoordinator.shared.rollback(sourceReceipt)
            RawVideoResourceCoordinator.shared.retire(bankID: bankID)
            if let lease { await engine.removeFrameDelivery(lease) }
            else { await engine.cancelFrameDelivery(token: token) }
        }
        lock.unlock()
    }
    private func removal() -> Task<Void, Never>? { lock.lock(); defer { lock.unlock() }; return removalTask }
    func finishAndWait() async { finish(); await removal()?.value }
    deinit { finish() }
}

/// MainActor lifecycle holder; no frame or image is captured by its install task.
@MainActor final class OptionalMonitorDelivery {
    let id: UUID
    let width: Int
    let height: Int
    var delivery: OptionalFrameDelivery?
    let handoff: OptionalMonitorImageHandoff
    let converter = PreviewImageConverter()
    var installTask: Task<Void, Never>?
    init(id: UUID, width: Int, height: Int, receive: @escaping @MainActor @Sendable (CGImage) -> Void) {
        self.id = id; self.width = width; self.height = height
        handoff = OptionalMonitorImageHandoff(receive: receive)
    }
    func finish() { handoff.finish(); installTask?.cancel(); installTask = nil; delivery?.finish() }
    deinit { handoff.finish(); installTask?.cancel(); delivery?.finish() }
}

struct OptionalFrameDeliveryFailure: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

/// Return exactly one cancellation action, including late startup failures.
@MainActor final class OptionalOutputCancellation {
    private var action: (@MainActor () -> Void)?
    init(_ action: @escaping @MainActor () -> Void) { self.action = action }
    func finish() { let action = action; self.action = nil; action?() }
}
