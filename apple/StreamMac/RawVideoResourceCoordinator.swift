import CoreVideo
import Darwin
import Foundation
import IOSurface
import StreamCore

/// One actual private pool. Allocations must use this method, never a second
/// uncharged pool or a nil allocation-threshold call. The pool stays retained
/// by the process ledger after unknown external references have escaped.
final class RawVideoResourceBank: @unchecked Sendable {
    let reservation: RawVideoResourceReservation
    var id: UUID { reservation.bankGeneration }
    var descriptor: RawVideoBankDescriptor { reservation.request.descriptor }
    var bytesPerBuffer: UInt64 { reservation.bytesPerBuffer }
    var queueCostBytes: UInt64 { reservation.queueCostBytes }
    var allocationThreshold: Int { reservation.allocationThreshold }
    private let condition = NSCondition()
    private var pool: CVPixelBufferPool?
    private var closed = false
    private var allocations = 0
    private var exposed = false
    var isOpen: Bool { condition.lock(); defer { condition.unlock() }; return !closed && pool != nil }
    #if STREAM_NATIVE_VALIDATION
    private var beforeExpose: (@Sendable () -> Void)?
    func validationBeforeExpose(_ callback: @escaping @Sendable () -> Void) {
        condition.lock(); beforeExpose = callback; condition.unlock()
    }
    var validationHasPool: Bool { condition.lock(); defer { condition.unlock() }; return pool != nil }
    #endif
    private let expose: @Sendable (RawVideoResourceReservation) -> Bool
    fileprivate init(reservation: RawVideoResourceReservation, pool: CVPixelBufferPool,
                     expose: @escaping @Sendable (RawVideoResourceReservation) -> Bool) {
        self.reservation = reservation; self.pool = pool; self.expose = expose
    }
    func allocatePixelBuffer() throws -> CVPixelBuffer {
        condition.lock()
        guard !closed, pool != nil else { condition.unlock(); throw RawVideoResourceFailure.unknownReservation }
        allocations += 1
        var selectedPool = pool
        condition.unlock()
        var result = Result { try allocate(from: selectedPool!) }
        // Drop the temporary native pool owner BEFORE publishing allocation
        // completion. closeAndDetach never runs with the coordinator lock held.
        selectedPool = nil
        condition.lock()
        if closed { result = .failure(RawVideoResourceFailure.unknownReservation) }
        allocations -= 1; condition.broadcast(); condition.unlock()
        return try result.get()
    }
    private func allocate(from pool: CVPixelBufferPool) throws -> CVPixelBuffer {
        var image: CVPixelBuffer?
        let attributes = [kCVPixelBufferPoolAllocationThresholdKey as String: allocationThreshold] as CFDictionary
        let result = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, attributes, &image)
        guard result == kCVReturnSuccess, let image else {
            throw result == kCVReturnWouldExceedAllocationThreshold ? RawVideoResourceFailure.capacityOccupied : .allocationFailed
        }
        let measurement = try RawVideoResourceCoordinator.measure(image, descriptor: descriptor)
        guard measurement.backing <= bytesPerBuffer, measurement.queueCost == queueCostBytes else { throw RawVideoResourceFailure.invalidMeasurement }
        condition.lock(); let alreadyExposed = exposed; condition.unlock()
        if !alreadyExposed {
            #if STREAM_NATIVE_VALIDATION
            condition.lock(); let hook = beforeExpose; condition.unlock()
            hook?()
            #endif
            // Charge exposure BEFORE returning any native buffer. Afterwards
            // the monotonic bank state avoids the global admission lock on the
            // active frame path: a new pool probe must not block healthy output.
            guard expose(reservation) else { throw RawVideoResourceFailure.unknownReservation }
            condition.lock(); exposed = true; condition.unlock()
        }
        return image
    }
    /// Deny allocation first, then drain every admitted native allocation and
    /// destroy the actual pool even when stale receipts still retain this bank.
    /// No caller may hold the coordinator lock while entering this barrier.
    fileprivate func closeAndDetach() {
        condition.lock(); closed = true
        while allocations > 0 { condition.wait() }
        pool = nil
        condition.unlock()
    }
}

struct RawVideoResourceReceipt: Sendable {
    let banks: [RawVideoResourceBank]
    fileprivate let claimID: UUID
    var claimIdentity: UUID { claimID }
    fileprivate let coordinator: RawVideoResourceCoordinator
    func bank(for domain: StableFrameDomainID) -> RawVideoResourceBank? {
        banks.first { $0.reservation.request.domain == domain }
    }
    /// Transfer this domain's claim to a child receipt. The parent can no
    /// longer roll it back, including if it retains its original bank array.
    func selecting(domain: StableFrameDomainID) throws -> RawVideoResourceReceipt {
        try coordinator.select(self, domain: domain)
    }
}

/// Process-wide: new controllers/workspaces and retry UUIDs cannot erase old
/// raw backing liabilities. No callbacks/SDKs/awaits run under its transaction
/// lock. Only bounded native pool preparation and actual process measurement.
final class RawVideoResourceCoordinator: @unchecked Sendable {
    static let shared = RawVideoResourceCoordinator()
    struct Snapshot: Sendable {
        let admissionCeilingBytes: UInt64
        let committedBytes: UInt64
        let banks: [RawVideoResourceBudget.Entry]
        let pendingPreparations: Int
    }
    private let lock = NSLock()
    private let pendingLock = NSLock()
    private var pending = 0
    private var budget: RawVideoResourceBudget
    private var banks: [UUID: RawVideoResourceBank] = [:]
    // At most 32 claims per bank, 256 banks: finite ownership metadata. Receipt
    // copies/subsets do not create claims; explicit reserve creates one.
    private var owners: [UUID: Set<UUID>] = [:]
    private var closing: Set<UUID> = []
    private init() { budget = RawVideoResourceBudget() }
    #if STREAM_NATIVE_VALIDATION
    func validationWithTransactionHeld(_ body: () -> Void) {
        lock.lock(); defer { lock.unlock() }; body()
    }
    #endif

    /// Synchronous admission precedes publisher/writer factories. The caller
    /// must still await the broker's installation ACK before starting media.
    /// At most 32 concurrent preparation calls (including the sole active
    /// transaction) are retained; there is no rejection/history inventory.
    func reserveBatch(_ requests: [RawVideoResourceRequest]) throws -> RawVideoResourceReceipt {
        guard !requests.isEmpty, requests.count <= RawVideoResourceBudget.maximumBatch else { throw RawVideoResourceFailure.invalidRequest }
        pendingLock.lock()
        guard pending < 32 else { pendingLock.unlock(); throw RawVideoResourceFailure.busy }
        pending += 1; pendingLock.unlock()
        defer { pendingLock.lock(); pending -= 1; pendingLock.unlock() }
        lock.lock(); defer { lock.unlock() }
        var candidate = budget
        var prepared: [UUID: RawVideoResourceBank] = [:]
        var result: [RawVideoResourceBank] = []
        var candidateOwners = owners
        let claimID = UUID()
        for request in requests {
            _ = try request.descriptor.allocationThreshold(bytesPerBuffer: 1)
            guard request.descriptor.width > 0, request.descriptor.height > 0,
                  OutputCapabilities.ResolutionTier.uhd4K.fits(width: request.descriptor.width, height: request.descriptor.height) else {
                throw RawVideoResourceFailure.invalidRequest
            }
            if let existing = candidate.reservation(for: request), let bank = prepared[existing.bankGeneration] ?? banks[existing.bankGeneration] {
                guard !closing.contains(bank.id) else { throw RawVideoResourceFailure.busy }
                var claims = candidateOwners[bank.id] ?? []
                guard claims.contains(claimID) || claims.count < 32 else { throw RawVideoResourceFailure.busy }
                claims.insert(claimID); candidateOwners[bank.id] = claims
                result.append(bank); continue
            }
            // The 64 MiB probe is INCLUDED, not added outside the admission
            // ceiling. It is never exposed and only one probe exists at once.
            try candidate.check(additionalBytes: RawVideoResourceBudget.provisionalProbeBytes,
                                footprint: Self.processFootprint(), now: ProcessInfo.processInfo.systemUptime)
            let (pool, measurement) = try Self.preparePool(request.descriptor)
            let claim = RawVideoResourceClaim(request: request, bytesPerBuffer: measurement.backing, queueCostBytes: measurement.queueCost)
            let reservations = try candidate.reserveBatch([claim], footprint: Self.processFootprint(), now: ProcessInfo.processInfo.systemUptime)
            guard let reservation = reservations.first else { throw RawVideoResourceFailure.unknownReservation }
            let bank = RawVideoResourceBank(reservation: reservation, pool: pool) { [weak self] reservation in
                self?.markExposed(reservation) ?? false
            }
            prepared[bank.id] = bank; result.append(bank)
            candidateOwners[bank.id] = [claimID]
        }
        // The batch is committed only after a fresh actual final measurement.
        // An earlier candidate failure only destroys never-exposed owned pools.
        try candidate.check(additionalBytes: 0, footprint: Self.processFootprint(), now: ProcessInfo.processInfo.systemUptime)
        budget = candidate
        owners = candidateOwners
        for (id, bank) in prepared { banks[id] = bank }
        return .init(banks: result, claimID: claimID, coordinator: self)
    }

    @discardableResult private func markExposed(_ reservation: RawVideoResourceReservation) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closing.contains(reservation.bankGeneration), !(owners[reservation.bankGeneration]?.isEmpty ?? true) else { return false }
        return budget.markExposed(reservation)
    }
    @discardableResult func markExposed(bankID: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closing.contains(bankID), !(owners[bankID]?.isEmpty ?? true), let bank = banks[bankID] else { return false }
        return budget.markExposed(bank.reservation)
    }
    func retire(bankID: UUID) {
        lock.lock()
        guard !closing.contains(bankID), let bank = banks[bankID] else { lock.unlock(); return }
        closing.insert(bankID); owners[bankID] = nil
        lock.unlock()
        bank.closeAndDetach()
        lock.lock()
        if budget.rollbackNeverExposed(bank.reservation) { banks[bankID] = nil }
        else { budget.retire(bank.reservation) }
        closing.remove(bankID); lock.unlock()
    }
    /// Does not touch reused banks or any bank that returned a native buffer.
    func rollback(_ receipt: RawVideoResourceReceipt) {
        var detached: [RawVideoResourceBank] = []
        lock.lock()
        for bank in receipt.banks {
            guard var claims = owners[bank.id], claims.remove(receipt.claimID) != nil else { continue }
            owners[bank.id] = claims
            if claims.isEmpty, !closing.contains(bank.id) {
                closing.insert(bank.id); detached.append(bank)
            }
        }
        lock.unlock()
        for bank in detached {
            bank.closeAndDetach()
            lock.lock()
            if budget.rollbackNeverExposed(bank.reservation) { banks[bank.id] = nil; owners[bank.id] = nil }
            else { budget.retire(bank.reservation); owners[bank.id] = nil }
            closing.remove(bank.id)
            lock.unlock()
        }
    }
    fileprivate func select(_ receipt: RawVideoResourceReceipt, domain: StableFrameDomainID) throws -> RawVideoResourceReceipt {
        lock.lock(); defer { lock.unlock() }
        let selected = receipt.banks.filter { $0.reservation.request.domain == domain }
        guard !selected.isEmpty else { throw RawVideoResourceFailure.unknownReservation }
        let child = UUID()
        for bank in selected {
            guard !closing.contains(bank.id), owners[bank.id]?.contains(receipt.claimID) == true else { throw RawVideoResourceFailure.unknownReservation }
        }
        for bank in selected {
            owners[bank.id]?.remove(receipt.claimID); owners[bank.id]?.insert(child)
        }
        return .init(banks: selected, claimID: child, coordinator: self)
    }
    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        pendingLock.lock(); let pending = pending; pendingLock.unlock()
        return .init(admissionCeilingBytes: budget.admissionCeilingBytes, committedBytes: budget.committedBytes,
                     banks: budget.entries, pendingPreparations: pending)
    }

    private static func preparePool(_ descriptor: RawVideoBankDescriptor) throws -> (CVPixelBufferPool, (backing: UInt64, queueCost: UInt64)) {
        // BGRA is the only admitted format in this initial closed-copy path.
        let attributes: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: descriptor.width, kCVPixelBufferHeightKey as String: descriptor.height,
            kCVPixelBufferMetalCompatibilityKey as String: true, kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess, let pool else {
            throw RawVideoResourceFailure.allocationFailed
        }
        var probe: CVPixelBuffer?
        let threshold = [kCVPixelBufferPoolAllocationThresholdKey as String: 1] as CFDictionary
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, threshold, &probe) == kCVReturnSuccess, let image = probe else {
            throw RawVideoResourceFailure.allocationFailed
        }
        let measurement = try measure(image, descriptor: descriptor)
        guard measurement.backing <= RawVideoResourceBudget.provisionalProbeBytes else { throw RawVideoResourceFailure.invalidMeasurement }
        // Release the local probe before the next probe. Its cached backing is
        // part of this real admitted pool, not an extra unaccounted dummy pool.
        return (pool, measurement)
    }

    fileprivate static func measure(_ image: CVPixelBuffer, descriptor: RawVideoBankDescriptor) throws -> (backing: UInt64, queueCost: UInt64) {
        guard CVPixelBufferGetWidth(image) == descriptor.width, CVPixelBufferGetHeight(image) == descriptor.height,
              CVPixelBufferGetPixelFormatType(image) == kCVPixelFormatType_32BGRA else { throw RawVideoResourceFailure.invalidMeasurement }
        let count = CVPixelBufferGetPlaneCount(image)
        guard count <= 16 else { throw RawVideoResourceFailure.invalidMeasurement }
        let planes: [RawVideoBufferStorage.Plane]
        if count == 0 {
            planes = [.init(bytesPerRow: UInt64(CVPixelBufferGetBytesPerRow(image)), height: UInt64(CVPixelBufferGetHeight(image)))]
        } else {
            planes = (0..<count).map { .init(bytesPerRow: UInt64(CVPixelBufferGetBytesPerRowOfPlane(image, $0)), height: UInt64(CVPixelBufferGetHeightOfPlane(image, $0))) }
        }
        let surface = CVPixelBufferGetIOSurface(image)?.takeUnretainedValue()
        let dataSize = UInt64(CVPixelBufferGetDataSize(image))
        let backing = try RawVideoBufferStorage.measuredBytes(dataSize: dataSize, planes: planes,
            surfaceAllocationBytes: surface.map { UInt64(IOSurfaceGetAllocSize($0)) })
        return (backing, max(1, dataSize))
    }
    private static func processFootprint() -> RawVideoProcessFootprint? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return .init(uptime: ProcessInfo.processInfo.systemUptime, physicalFootprintBytes: info.phys_footprint)
    }
}
