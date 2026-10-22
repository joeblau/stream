import Foundation
import CoreGraphics
import CoreMedia
import CoreVideo
import StreamCore
import os.lock

/// One composited program frame, stamped on the engine's shared monotonic
/// media clock. `@unchecked Sendable`: the `CMSampleBuffer` is a retained
/// CoreFoundation object shared read-only across subscribers, exactly like the
/// capture pipelines share their buffers.
struct CompositedFrame: @unchecked Sendable {
    /// Composited BGRA video, timed on the engine clock (see below).
    let sampleBuffer: CMSampleBuffer
    /// Presentation timestamp from the shared timebase (same value as the
    /// sample buffer's PTS; exposed so sinks needn't unpack the buffer).
    let presentationTime: CMTime
    /// Nominal frame duration (1 / output fps).
    let frameDuration: CMTime
    /// 1-based tick counter since the engine last (re)started its clock.
    let sequence: Int64

    var pixelBuffer: CVPixelBuffer? {
        CMSampleBufferGetImageBuffer(sampleBuffer)
    }
}

/// Sealed operations only: arbitrary consumer code never runs while a source
/// buffer is borrowed. Geometry comes from the independently admitted bank.
enum FrameDeliveryTransfer: Sendable {
    case copyBGRA
    case aspectFitBGRA
    case virtualCameraBGRA(referenceCanvas: CGSize?, cadence: FrameDeliveryCameraCadence? = nil)
}

typealias FrameDeliverySink = @Sendable (CompositedFrame) -> Void

/// Owned by one pending/current admission. Cancellation retains no global
/// history; a late install observes the same object the owner revoked.
final class FrameDeliveryCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    init() {}
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

struct FrameDeliveryLease: Hashable, Sendable {
    let token: UUID
    let domain: StableFrameDomainID
    let generation: UUID
    let bankID: UUID
    let registrationID = UUID()
    fileprivate let finalReceipt = FrameDeliveryFinalReceipt()
    var finalStatistics: FrameDeliveryStatistics? { finalReceipt.snapshot() }
}

struct FrameDeliveryStatistics: Sendable, Codable, Equatable {
    var depth = 0
    var drops = 0
    var intentDrops = 0
    var privateQueueDrops = 0
    var retiredIntentDrops = 0
    var sourceUnavailable = 0
    var privateCapacityDrops = 0
    var allocationFailures = 0
    var filteredDrops = 0
    var cancelledDrops = 0
    var conversionFailures = 0
    var cadenceDrops = 0
    var unauthorizedDrops = 0
}

/// Final counters belong to the lease that the caller already owns. There is
/// no global retired-lease inventory, and old-token replacement cannot erase
/// a recorder's final receipt or let its late teardown remove the new lease.
final class FrameDeliveryFinalReceipt: @unchecked Sendable, Hashable {
    private let lock = NSLock()
    private var value: FrameDeliveryStatistics?
    static func == (lhs: FrameDeliveryFinalReceipt, rhs: FrameDeliveryFinalReceipt) -> Bool { lhs === rhs }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
    func freeze(_ statistics: FrameDeliveryStatistics) {
        lock.lock(); if value == nil { value = statistics }; lock.unlock()
    }
    func snapshot() -> FrameDeliveryStatistics? { lock.lock(); defer { lock.unlock() }; return value }
}

enum FrameDeliveryFailure: Error {
    case cancelled, invalidBank, duplicateDomain
}

/// Synchronous request preparation is separate from actor-side commit. A
/// proposed geometry never changes the active allocator. Metadata is bounded
/// to one current bank and one pending request for each of three planes.
final class EngineSourceResources: @unchecked Sendable {
    private struct Slot {
        var current: RawVideoResourceBank?
        var receipt: RawVideoResourceReceipt?
        var pending: RawVideoResourceRequest?
    }
    private let lock = NSLock()
    private let workspace = UUID()
    private var slots: [String: Slot] = [:]

    func request(size: CGSize, canvas: OutputCanvas, clean: Bool) throws -> RawVideoResourceRequest {
        guard size.width.isFinite, size.height.isFinite, size.width >= 1, size.height >= 1,
              size.width <= 4096, size.height <= 4096 else { throw RawVideoResourceFailure.invalidRequest }
        let key = clean ? "clean" : canvas == .program ? "program" : "secondary"
        let descriptor = RawVideoBankDescriptor(width: Int(size.width), height: Int(size.height), capacity: 4)
        lock.lock(); defer { lock.unlock() }
        var slot = slots[key] ?? Slot()
        if let bank = slot.current, bank.descriptor == descriptor { return bank.reservation.request }
        if let pending = slot.pending, pending.descriptor == descriptor { return pending }
        let domain = StableFrameDomainID(workspace: workspace, kind: .rendererSource, outputID: key,
            plane: clean ? .clean : canvas == .program ? .program : .secondary)
        let request = RawVideoResourceRequest(domain: domain, descriptor: descriptor, sessionGeneration: UUID())
        slot.pending = request; slots[key] = slot
        return request
    }
    func current(size: CGSize, canvas: OutputCanvas, clean: Bool) -> RawVideoResourceBank? {
        let key = clean ? "clean" : canvas == .program ? "program" : "secondary"
        lock.lock(); defer { lock.unlock() }
        guard let bank = slots[key]?.current, CGFloat(bank.descriptor.width) == size.width,
              CGFloat(bank.descriptor.height) == size.height else { return nil }
        return bank
    }
    func commit(_ bank: RawVideoResourceBank, receipt: RawVideoResourceReceipt,
                size: CGSize, canvas: OutputCanvas, clean: Bool) throws -> RawVideoResourceBank {
        guard receipt.banks.count == 1, receipt.banks.first?.id == bank.id,
              CGFloat(bank.descriptor.width) == size.width, CGFloat(bank.descriptor.height) == size.height,
              bank.allocationThreshold == 4 else { throw FrameDeliveryFailure.invalidBank }
        let key = clean ? "clean" : canvas == .program ? "program" : "secondary"
        lock.lock()
        let expectedDomain = StableFrameDomainID(workspace: workspace, kind: .rendererSource, outputID: key,
            plane: clean ? .clean : canvas == .program ? .program : .secondary)
        guard bank.reservation.request.domain == expectedDomain else {
            lock.unlock(); throw FrameDeliveryFailure.invalidBank
        }
        var slot = slots[key] ?? Slot()
        if let current = slot.current, current.descriptor == bank.descriptor, let owned = slot.receipt {
            lock.unlock()
            // Keep the already committed exact-geometry allocator. A late
            // preparation cannot flip it back to an obsolete pool generation.
            if owned.claimIdentity != receipt.claimIdentity { RawVideoResourceCoordinator.shared.rollback(receipt) }
            return current
        }
        let adopted: RawVideoResourceReceipt
        do { adopted = try receipt.selecting(domain: bank.reservation.request.domain) }
        catch { lock.unlock(); throw error }
        guard RawVideoResourceCoordinator.shared.markExposed(bankID: bank.id) else {
            lock.unlock(); RawVideoResourceCoordinator.shared.rollback(adopted)
            throw FrameDeliveryFailure.invalidBank
        }
        let old = slot.current, oldReceipt = slot.receipt
        slot.current = bank; slot.receipt = adopted
        if slot.pending == bank.reservation.request { slot.pending = nil }
        slots[key] = slot
        lock.unlock()
        if let old, old.id != bank.id { RawVideoResourceCoordinator.shared.retire(bankID: old.id) }
        if let oldReceipt { RawVideoResourceCoordinator.shared.rollback(oldReceipt) }
        return bank
    }
    deinit {
        for slot in slots.values { if let receipt = slot.receipt { RawVideoResourceCoordinator.shared.rollback(receipt) } }
    }
}

/// One producer plane's bounded source ownership. Exactly two global latest
/// source frames and at most one synchronous trusted transfer borrow survive
/// publication. All queued jobs and per-domain intents contain identity only.
/// Consumer queues own exclusively completed, independently backed packets.
final class FrameDeliveryBroker: @unchecked Sendable {
    private struct PublicationID: Equatable {
        let epoch: UUID
        let counter: UInt64
    }
    private struct Intent {
        let publication: PublicationID
        let sequence: Int64
    }
    private struct Publication {
        let id: PublicationID
        let frame: CompositedFrame
    }
    private final class Registration: @unchecked Sendable {
        let lease: FrameDeliveryLease
        let bank: RawVideoResourceBank
        let transfer: FrameDeliveryTransfer
        let capacity: Int
        let authorized: @Sendable () -> Bool
        let shouldTransfer: @Sendable () -> Bool
        let cancellation: FrameDeliveryCancellation
        let mailbox: FrameMailbox
        var intents: [Intent] = []
        var retired = false
        var statistics = FrameDeliveryStatistics()
        init(lease: FrameDeliveryLease, bank: RawVideoResourceBank, transfer: FrameDeliveryTransfer,
             capacity: Int, authorized: @escaping @Sendable () -> Bool,
             shouldTransfer: @escaping @Sendable () -> Bool, cancellation: FrameDeliveryCancellation, mailbox: FrameMailbox) {
            self.lease = lease; self.bank = bank; self.transfer = transfer
            self.capacity = max(1, min(2, capacity)); self.authorized = authorized
            self.shouldTransfer = shouldTransfer; self.cancellation = cancellation; self.mailbox = mailbox
        }
    }
    private let lock = NSLock()
    private let worker = DispatchQueue(label: "com.joeblau.Stream.frame-transfer", qos: .userInitiated)
    private let converter = FrameDeliveryConverter()
    private var ring: [Publication] = []
    private var publicationEpoch = UUID()
    private var nextPublication: UInt64 = 0
    private var registrations: [UUID: Registration] = [:]
    private var order: [UUID] = []
    private var cursor = 0
    private var scheduled = false
    #if STREAM_NATIVE_VALIDATION
    private var beforeTransfer: (@Sendable () -> Void)?
    func validationBeforeTransfer(_ hook: (@Sendable () -> Void)?) {
        lock.lock(); beforeTransfer = hook; lock.unlock()
    }
    #endif

    @discardableResult
    func install(token: UUID, domain: StableFrameDomainID, generation: UUID,
                 bank: RawVideoResourceBank, transfer: FrameDeliveryTransfer = .copyBGRA,
                 capacity: Int = 2, cancellation: FrameDeliveryCancellation = FrameDeliveryCancellation(),
                 authorized: @escaping @Sendable () -> Bool = { true },
                 shouldTransfer: @escaping @Sendable () -> Bool = { true },
                 sink: @escaping FrameDeliverySink) throws -> FrameDeliveryLease {
        guard !cancellation.isCancelled else { throw FrameDeliveryFailure.cancelled }
        guard (1...2).contains(capacity) else { throw FrameDeliveryFailure.invalidBank }
        guard bank.reservation.request.domain == domain,
              bank.reservation.request.sessionGeneration == generation else { throw FrameDeliveryFailure.invalidBank }
        let lease = FrameDeliveryLease(token: token, domain: domain, generation: generation, bankID: bank.id)
        let mailbox = FrameMailbox(capacity: capacity, token: token) { [weak self] frame in
            guard !cancellation.isCancelled, self?.isCurrent(lease) == true, authorized() else { return }
            sink(frame)
        }
        let registration = Registration(lease: lease, bank: bank, transfer: transfer, capacity: capacity,
            authorized: authorized, shouldTransfer: shouldTransfer, cancellation: cancellation, mailbox: mailbox)
        lock.lock()
        if cancellation.isCancelled { lock.unlock(); throw FrameDeliveryFailure.cancelled }
        if let existing = registrations[token], existing.lease.domain == domain,
           existing.lease.generation == generation, existing.lease.bankID == bank.id,
           existing.cancellation === cancellation {
            lock.unlock(); return existing.lease
        }
        // A domain is a logical endpoint, not an invitation to multiply pools
        // or active delivery sessions under a different registration token.
        let sameDomain = registrations.values.filter { $0.lease.domain == domain && $0.lease.token != token }
        guard sameDomain.allSatisfy({ $0.cancellation.isCancelled }) else {
            lock.unlock(); throw FrameDeliveryFailure.duplicateDomain
        }
        // A synchronously revoked admission can be replaced before its actor
        // removal ACK arrives. The old lease cannot remove this registration.
        for old in sameDomain {
            retireIntents(old)
            registrations[old.lease.token] = nil
            order.removeAll { $0 == old.lease.token }
        }
        let old = registrations.updateValue(registration, forKey: token)
        if let old { retireIntents(old) }
        if old == nil { order.append(token) }
        lock.unlock()
        for retired in sameDomain + (old.map { [$0] } ?? []) {
            retired.mailbox.close()
            freeze(retired)
            if retired.bank.id != bank.id { RawVideoResourceCoordinator.shared.retire(bankID: retired.bank.id) }
        }
        return lease
    }

    func isCurrent(_ lease: FrameDeliveryLease) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return registrations[lease.token]?.lease == lease
    }

    @discardableResult
    func remove(_ lease: FrameDeliveryLease) -> FrameDeliveryStatistics {
        lock.lock()
        guard registrations[lease.token]?.lease == lease else { lock.unlock(); return lease.finalStatistics ?? FrameDeliveryStatistics() }
        let retired = registrations.removeValue(forKey: lease.token)
        if let retired { retireIntents(retired) }
        order.removeAll { $0 == lease.token }
        let oldRing: [Publication]
        if registrations.isEmpty { oldRing = ring; ring = [] } else { oldRing = [] }
        lock.unlock()
        retired?.mailbox.close()
        if let retired { freeze(retired); RawVideoResourceCoordinator.shared.retire(bankID: retired.bank.id) }
        withExtendedLifetime(oldRing) {}
        return lease.finalStatistics ?? FrameDeliveryStatistics()
    }

    /// Called only under the broker lock: later in-flight failures cannot
    /// mutate the final receipt after this retirement linearization point.
    private func retireIntents(_ registration: Registration) {
        registration.retired = true
        registration.statistics.drops += registration.intents.count
        registration.statistics.retiredIntentDrops += registration.intents.count
        registration.intents = []
    }
    private func freeze(_ registration: Registration) {
        let mailbox = registration.mailbox.statistics()
        var final = registration.statistics
        final.depth = 0; final.drops += mailbox.drops; final.privateQueueDrops = mailbox.drops
        registration.lease.finalReceipt.freeze(final)
    }

    func remove(token: UUID) {
        lock.lock(); let lease = registrations[token]?.lease
        lock.unlock()
        if let lease { remove(lease) }
    }
    func cancel(token: UUID) { remove(token: token) }

    /// Publication keeps only the common newest two source packets. No frame
    /// is captured by the scheduled worker block or copied into intent queues.
    func offer(_ frame: CompositedFrame) {
        lock.lock()
        guard !registrations.isEmpty else { lock.unlock(); return }
        var retired: Publication?
        if ring.count == 2 { retired = ring.removeFirst() }
        // Clock sequence is intentionally reset on restart; publication identity
        // must not collide with a still-pending frame from the previous run.
        let publication = PublicationID(epoch: publicationEpoch, counter: nextPublication)
        if nextPublication == UInt64.max { publicationEpoch = UUID(); nextPublication = 0 }
        else { nextPublication += 1 }
        let intent = Intent(publication: publication, sequence: frame.sequence)
        ring.append(Publication(id: publication, frame: frame))
        for registration in registrations.values {
            if registration.intents.count == registration.capacity {
                registration.intents.removeFirst(); registration.statistics.drops += 1; registration.statistics.intentDrops += 1
            }
            registration.intents.append(intent)
        }
        let start = !scheduled
        if start { scheduled = true }
        lock.unlock()
        withExtendedLifetime(retired) {}
        if start { worker.async { self.drain() } }
    }

    func statistics(for lease: FrameDeliveryLease? = nil) -> FrameDeliveryStatistics {
        lock.lock(); defer { lock.unlock() }
        var result = FrameDeliveryStatistics()
        if let lease, registrations[lease.token]?.lease != lease { return lease.finalStatistics ?? result }
        for registration in registrations.values where lease == nil || registration.lease == lease {
            let mailbox = registration.mailbox.statistics()
            result.depth += registration.intents.count + mailbox.depth
            result.drops += registration.statistics.drops + mailbox.drops
            result.intentDrops += registration.statistics.intentDrops
            result.privateQueueDrops += mailbox.drops
            result.retiredIntentDrops += registration.statistics.retiredIntentDrops
            result.allocationFailures += registration.statistics.allocationFailures
            result.filteredDrops += registration.statistics.filteredDrops
            result.cancelledDrops += registration.statistics.cancelledDrops
            result.sourceUnavailable += registration.statistics.sourceUnavailable
            result.privateCapacityDrops += registration.statistics.privateCapacityDrops
            result.conversionFailures += registration.statistics.conversionFailures
            result.cadenceDrops += registration.statistics.cadenceDrops
            result.unauthorizedDrops += registration.statistics.unauthorizedDrops
        }
        return result
    }

    private func next() -> (Registration, Intent)? {
        lock.lock(); defer { lock.unlock() }
        guard !order.isEmpty else { scheduled = false; return nil }
        for _ in 0..<order.count {
            cursor %= order.count
            let token = order[cursor]; cursor = (cursor + 1) % order.count
            if let registration = registrations[token], !registration.intents.isEmpty {
                return (registration, registration.intents.removeFirst())
            }
        }
        scheduled = false
        return nil
    }

    private func noteDrop(_ registration: Registration, reason: Int) {
        lock.lock(); defer { lock.unlock() }
        guard !registration.retired else { return }
        registration.statistics.drops += 1
        switch reason {
        case 0: registration.statistics.sourceUnavailable += 1
        case 1: registration.statistics.privateCapacityDrops += 1
        case 2: registration.statistics.conversionFailures += 1
        case 4: registration.statistics.cadenceDrops += 1
        case 5: registration.statistics.allocationFailures += 1
        case 6: registration.statistics.filteredDrops += 1
        case 7: registration.statistics.cancelledDrops += 1
        default: registration.statistics.unauthorizedDrops += 1
        }
    }

    private func drain() {
        while let (registration, intent) = next() {
            // These owned fast eligibility checks have no source payload and
            // run outside both locks and the closed source-borrowing helper.
            guard !registration.cancellation.isCancelled, isCurrent(registration.lease) else { noteDrop(registration, reason: 7); continue }
            guard registration.authorized() else { noteDrop(registration, reason: 3); continue }
            guard registration.shouldTransfer() else { noteDrop(registration, reason: 6); continue }
            #if STREAM_NATIVE_VALIDATION
            lock.lock(); let hook = beforeTransfer; lock.unlock()
            hook?() // Metadata-only gate: no source borrow or consumer callback.
            #endif
            let packet: CompositedFrame? = autoreleasepool {
                prepare(registration, intent: intent)
            }
            // prepare has returned and its ONLY source reference is gone.
            // No SDK or consumer closure executes on this transfer worker.
            if let packet, !registration.cancellation.isCancelled, isCurrent(registration.lease), registration.authorized() {
                registration.mailbox.post(packet)
            }
        }
    }

    /// The only source borrow. Allocation happens first so a full recipient
    /// bank cannot hold a source while failing/waiting for its own storage.
    /// This synchronous helper returns only independent pixels and safe values.
    @inline(never)
    private func prepare(_ registration: Registration, intent: Intent) -> CompositedFrame? {
        let output: CVPixelBuffer
        do { output = try registration.bank.allocatePixelBuffer() }
        catch RawVideoResourceFailure.capacityOccupied { noteDrop(registration, reason: 1); return nil }
        catch { noteDrop(registration, reason: 5); return nil }
        lock.lock()
        let source = registrations[registration.lease.token]?.lease == registration.lease
            ? ring.first(where: { $0.id == intent.publication })?.frame : nil
        lock.unlock()
        guard let source else { noteDrop(registration, reason: 0); return nil }
        do {
            let sample = try converter.prepare(source.sampleBuffer, into: output, transfer: registration.transfer)
            return CompositedFrame(sampleBuffer: sample,
                presentationTime: CMSampleBufferGetPresentationTimeStamp(sample),
                frameDuration: CMSampleBufferGetDuration(sample), sequence: source.sequence)
        } catch FrameDeliveryTransferError.cadenceSkipped {
            noteDrop(registration, reason: 4); return nil
        } catch {
            noteDrop(registration, reason: 2); return nil
        }
    }

    #if STREAM_NATIVE_VALIDATION
    func validationProbe(token: UUID) -> CompositionMailboxValidationProbe? {
        lock.lock(); let mailbox = registrations[token]?.mailbox; lock.unlock()
        guard let mailbox else { return nil }
        return .init(snapshot: { mailbox.validationSnapshot() }, barrier: { await mailbox.validationBarrier() }, close: { mailbox.close() })
    }
    func validationTransferBarrier() async {
        await withCheckedContinuation { continuation in worker.async { continuation.resume() } }
    }
    #endif
}

/// This mailbox is private-pixel storage ONLY. Original source frames never
/// enter it, including while a consumer retains an extracted native object.
private final class FrameMailbox: @unchecked Sendable {
    private let capacity: Int
    private let sink: FrameDeliverySink
    private let queue: DispatchQueue
    private var lock = os_unfair_lock_s()
    private var pending: [CompositedFrame] = []
    private var isDraining = false
    private var drops = 0
    private var closed = false
    func statistics() -> (depth: Int, drops: Int) {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return (pending.count, drops)
    }
    init(capacity: Int, token: UUID, sink: @escaping FrameDeliverySink) {
        self.capacity = max(1, min(2, capacity)); self.sink = sink
        queue = DispatchQueue(label: "com.joeblau.StreamMac.engine.sink.\(token.uuidString)", qos: .userInitiated)
    }
    func post(_ frame: CompositedFrame) {
        os_unfair_lock_lock(&lock)
        guard !closed else { os_unfair_lock_unlock(&lock); return }
        var retired: CompositedFrame?
        if pending.count >= capacity { drops += 1; retired = pending.removeFirst() }
        pending.append(frame)
        let shouldSchedule = !isDraining
        if shouldSchedule { isDraining = true }
        os_unfair_lock_unlock(&lock)
        withExtendedLifetime(retired) {}
        if shouldSchedule { queue.async { self.drain() } }
    }
    func close() {
        os_unfair_lock_lock(&lock)
        guard !closed else { os_unfair_lock_unlock(&lock); return }
        closed = true
        let retired = pending; drops += retired.count; pending = []
        os_unfair_lock_unlock(&lock)
        withExtendedLifetime(retired) {}
    }
    private func drain() {
        while true {
            os_unfair_lock_lock(&lock)
            guard !closed, !pending.isEmpty else {
                isDraining = false; os_unfair_lock_unlock(&lock); return
            }
            let frame = pending.removeFirst()
            os_unfair_lock_unlock(&lock)
            sink(frame)
        }
    }
    #if STREAM_NATIVE_VALIDATION
    func validationSnapshot() -> CompositionMailboxValidationProbe.Snapshot {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return .init(pendingSequences: pending.map(\.sequence), drops: drops, closed: closed)
    }
    func validationBarrier() async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }
    #endif
}

#if STREAM_NATIVE_VALIDATION
/// Holds only the mailbox, never a snapshot of its retained frames. Fixtures
/// can observe retirement and fence the existing serial queue after releasing
/// an already-dequeued callback; shipping removal never waits for that queue.
struct CompositionMailboxValidationProbe: Sendable {
    struct Snapshot: Equatable, Sendable, Codable {
        var pendingSequences: [Int64]
        var drops: Int
        var closed: Bool
    }
    var snapshot: @Sendable () -> Snapshot
    var barrier: @Sendable () async -> Void
    var close: @Sendable () -> Void
}
#endif
