import CoreVideo
import Foundation
import StreamCore

private func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw NSError(domain: "RawVideoResources", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
private final class AllocationResult: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func succeeded() { lock.lock(); value = true; lock.unlock() }
    var success: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

@main struct RawVideoResourceHarness {
    static func main() throws {
        let coordinator = RawVideoResourceCoordinator.shared
        let workspace = UUID()
        func request(_ name: String, session: UUID = UUID(), capacity: Int = 2) -> RawVideoResourceRequest {
            .init(domain: .init(workspace: workspace, kind: .validation, outputID: name, plane: .program),
                  descriptor: .init(width: 16, height: 16, capacity: capacity), sessionGeneration: session)
        }
        let baseline = coordinator.snapshot().committedBytes

        let reuse = request("prepared-reuse")
        let first = try coordinator.reserveBatch([reuse]), second = try coordinator.reserveBatch([reuse])
        let bank = first.banks[0]
        try check(bank === second.banks[0], "Same active request did not reuse its bank")
        coordinator.rollback(first)
        try check(bank.isOpen && bank.validationHasPool, "First rollback closed the second prepared owner")
        coordinator.rollback(second)
        try check(!bank.isOpen && !bank.validationHasPool, "Retained receipts kept the refunded actual pool alive")
        try check(coordinator.snapshot().committedBytes == baseline, "Last never-exposed owner did not refund")
        print("PASS: prepared reuse has independent claims; retained receipt bank detaches actual pool before refund")

        let childRequest = request("child"), siblingRequest = request("sibling")
        let batch = try coordinator.reserveBatch([childRequest, siblingRequest])
        let child = try batch.selecting(domain: childRequest.domain)
        coordinator.rollback(batch)
        try check(child.banks[0].isOpen && !batch.banks[1].validationHasPool, "Stale parent rollback erased transferred child or kept unused sibling")
        do { _ = try batch.selecting(domain: childRequest.domain); throw NSError(domain: "DuplicateClaimTransfer", code: 1) }
        catch RawVideoResourceFailure.unknownReservation {}
        coordinator.rollback(child)
        try check(!child.banks[0].validationHasPool && coordinator.snapshot().committedBytes == baseline, "Transferred child did not retire its own actual pool")
        print("PASS: atomic domain-claim transfer fences copied parent receipts and sibling rollback")

        let neverExposed = try coordinator.reserveBatch([request("explicit-retire")]), retired = neverExposed.banks[0]
        coordinator.retire(bankID: retired.id)
        try check(!retired.isOpen && !retired.validationHasPool && coordinator.snapshot().committedBytes == baseline,
                  "Explicit retirement kept a never-exposed destroyed pool charged")
        coordinator.rollback(neverExposed)
        try check(coordinator.snapshot().committedBytes == baseline, "Stale rollback after explicit retirement changed credits")
        print("PASS: explicit never-exposed retirement destroys the retained pool before refund")

        let exposedRequest = request("exposed")
        let exposed = try coordinator.reserveBatch([exposedRequest]), exposedBank = exposed.banks[0]
        var images: [CVPixelBuffer] = [try exposedBank.allocatePixelBuffer(), try exposedBank.allocatePixelBuffer()]
        do { _ = try exposedBank.allocatePixelBuffer(); throw NSError(domain: "UnboundedPool", code: 1) }
        catch RawVideoResourceFailure.capacityOccupied {}
        withExtendedLifetime(images) {}
        let charged = coordinator.snapshot().committedBytes
        coordinator.rollback(exposed)
        try check(!exposedBank.validationHasPool && coordinator.snapshot().committedBytes == charged, "Exposed rollback refunded unknown native holders")
        images.removeAll()
        coordinator.retire(bankID: exposedBank.id)
        try check(coordinator.snapshot().committedBytes == charged, "Native buffer release fabricated a generic alias-quiescence proof")
        let restart = try coordinator.reserveBatch([request("exposed")])
        try check(restart.banks[0].id != exposedBank.id && coordinator.snapshot().committedBytes > charged, "New activation reused old alias backing or forgot old charge")
        coordinator.rollback(restart)
        try check(coordinator.snapshot().committedBytes == charged, "Never-exposed restart rollback removed old quarantine charge")
        print("PASS: actual pool threshold is bounded; exposed native holders stay charged across release and fresh restart")

        let race = try coordinator.reserveBatch([request("allocation-race")]), raceBank = race.banks[0]
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let allocated = DispatchSemaphore(value: 0), rolledBack = DispatchSemaphore(value: 0)
        let outcome = AllocationResult()
        raceBank.validationBeforeExpose {
            entered.signal()
            precondition(release.wait(timeout: .now() + 10) == .success, "Owned 16px allocation hold exceeded ten seconds")
        }
        DispatchQueue.global().async {
            defer { allocated.signal() }
            do { _ = try raceBank.allocatePixelBuffer(); outcome.succeeded() } catch {}
        }
        try check(entered.wait(timeout: .now() + 5) == .success, "Actual owned native allocation never entered")
        DispatchQueue.global().async { coordinator.rollback(race); rolledBack.signal() }
        let deadline = Date().addingTimeInterval(5)
        while raceBank.isOpen, Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
        try check(!raceBank.isOpen && raceBank.validationHasPool, "Rollback did not close authority before draining the entered allocation")
        try check(coordinator.snapshot().committedBytes > charged, "Entered allocation lost its charge before actual native pool destruction")
        try check(rolledBack.wait(timeout: .now()) == .timedOut, "Rollback acknowledged before the held allocation drained")
        release.signal()
        try check(allocated.wait(timeout: .now() + 5) == .success && rolledBack.wait(timeout: .now() + 5) == .success,
                  "Allocation/rollback lock ordering deadlocked")
        try check(!outcome.success && !raceBank.validationHasPool && coordinator.snapshot().committedBytes == charged,
                  "Racing allocation escaped or retained a refunded actual pool")
        print("PASS: held real allocation drains outside policy lock; closed pool is destroyed before never-exposed refund")

        let capacity = request("claim-cap")
        var receipts: [RawVideoResourceReceipt] = []
        for _ in 0..<32 { receipts.append(try coordinator.reserveBatch([capacity])) }
        do { _ = try coordinator.reserveBatch([capacity]); throw NSError(domain: "UnboundedClaims", code: 1) }
        catch RawVideoResourceFailure.busy {}
        for receipt in receipts.dropLast() { coordinator.rollback(receipt) }
        try check(receipts[0].banks[0].isOpen, "An old claim closed the final owner")
        coordinator.rollback(receipts.last!)
        try check(!receipts[0].banks[0].validationHasPool && coordinator.snapshot().committedBytes == charged,
                  "Last bounded claim did not destroy its native pool")
        print("PASS: claim metadata is bounded and duplicate rollback does not evict a current owner")

        let healthy = try coordinator.reserveBatch([request("healthy-active")]), healthyBank = healthy.banks[0]
        _ = try healthyBank.allocatePixelBuffer() // Actual first exposure.
        let policyEntered = DispatchSemaphore(value: 0), releasePolicy = DispatchSemaphore(value: 0)
        let policyFinished = DispatchSemaphore(value: 0), copied = DispatchSemaphore(value: 0)
        let healthyResult = AllocationResult()
        DispatchQueue.global().async {
            coordinator.validationWithTransactionHeld {
                policyEntered.signal()
                precondition(releasePolicy.wait(timeout: .now() + 10) == .success)
            }
            policyFinished.signal()
        }
        try check(policyEntered.wait(timeout: .now() + 5) == .success, "Owned policy barrier did not enter")
        DispatchQueue.global().async {
            defer { copied.signal() }
            do { _ = try healthyBank.allocatePixelBuffer(); healthyResult.succeeded() } catch {}
        }
        let copiedBeforeRelease = copied.wait(timeout: .now() + 5) == .success
        releasePolicy.signal()
        try check(policyFinished.wait(timeout: .now() + 5) == .success, "Owned policy barrier did not leave")
        try check(copiedBeforeRelease && healthyResult.success, "An active private bank blocked behind a new admission transaction")
        coordinator.rollback(healthy)
        print("PASS: an exposed active bank allocates while unrelated global admission is held")
        try check(coordinator.snapshot().pendingPreparations == 0, "Preparation metadata remained occupied")
        print("PASS: owned 16x16 CoreVideo resource lifecycle; no renderer, SDK, capture, device, network, window or output graph")
    }
}
