import CoreMedia
import CoreVideo
import Foundation
import StreamCore

/// A trusted closed-transfer result, never an attachment inferred from an
/// arbitrary caller's sample. The bank and session provenance travel with the
/// sample through the recorder router; the writer validates the exact bank.
struct RecordingPreparedVideoFrame: @unchecked Sendable {
    let sample: CMSampleBuffer
    let bank: RawVideoResourceBank
}

struct RecordingVideoTransferProgress: Codable, Sendable {
    var admissionFailures = 0
    var privateCapacityDrops = 0
    var conversionFailures = 0
    var provenanceDrops = 0
    /// Total broker dispositions; reason counters below overlap this total.
    /// They must not be added together as a second dropped-frame total.
    var brokerDrops = 0
    var sourceUnavailable = 0
    var lastError: String?
    var broker: FrameDeliveryStatistics?
    init() {}
    init(_ statistics: FrameDeliveryStatistics) {
        broker = statistics
        brokerDrops = statistics.drops
        privateCapacityDrops = statistics.privateCapacityDrops
        conversionFailures = statistics.conversionFailures
        sourceUnavailable = statistics.sourceUnavailable
        if hasFailure { lastError = "Recording frame delivery shed frames before writer enqueue." }
    }
    var hasFailure: Bool {
        admissionFailures + privateCapacityDrops + conversionFailures + provenanceDrops + brokerDrops + sourceUnavailable > 0
    }
}

enum RecordingVideoTransferFailure: Sendable {
    case admission(String), capacity, conversion(String)
    init(_ error: Error) {
        if (error as? RawVideoResourceFailure) == .capacityOccupied { self = .capacity }
        else { self = .conversion(error.localizedDescription) }
    }
    func record(in value: inout RecordingVideoTransferProgress) {
        switch self {
        case .admission(let error): value.admissionFailures += 1; value.lastError = error
        case .capacity: value.privateCapacityDrops += 1; value.lastError = "Recording private video capacity is occupied."
        case .conversion(let error): value.conversionFailures += 1; value.lastError = error
        }
    }
}

/// ISO source rendering has a separately admitted four-frame source bank.
/// Only a completed copy in privateBank crosses the native writer boundary.
struct RecordingVideoFrameDelivery: Sendable {
    let sourceBank: RawVideoResourceBank
    let privateBank: RawVideoResourceBank
}

/// Factory compatibility still admits the REAL renderer source pool and its
/// private transfer bank before the first render. Shipping injects the same
/// pair from the controller's all-track transaction instead.
final class RecordingIsolatedFrameDelivery: @unchecked Sendable {
    private var delivery: RecordingVideoFrameDelivery?
    private var ownedReceipt: RawVideoResourceReceipt?
    init(_ delivery: RecordingVideoFrameDelivery?) { self.delivery = delivery }
    func resources(size: CGSize) throws -> RecordingVideoFrameDelivery {
        if let delivery { return delivery }
        guard size.width.isFinite, size.height.isFinite, size.width >= 1, size.height >= 1,
              size.width <= 4096, size.height <= 4096 else { throw RawVideoResourceFailure.invalidRequest }
        let generation = UUID()
        let source = StableFrameDomainID(workspace: generation, kind: .rendererSource,
            outputID: "isolated-compatibility", plane: .isolated)
        let destination = StableFrameDomainID(workspace: generation, kind: .isolatedRecording,
            outputID: "isolated-compatibility", plane: .isolated)
        let receipt = try RawVideoResourceCoordinator.shared.reserveBatch([
            .init(domain: source, descriptor: .init(width: Int(size.width), height: Int(size.height), capacity: 4), sessionGeneration: generation),
            .init(domain: destination, descriptor: .init(width: Int(size.width), height: Int(size.height), capacityPolicy:
                .recording(videoCapacity: 6, maxQueuedBytes: 48_000_000, headroom: 2)), sessionGeneration: generation)])
        guard let sourceBank = receipt.bank(for: source), let privateBank = receipt.bank(for: destination) else {
            RawVideoResourceCoordinator.shared.rollback(receipt); throw RawVideoResourceFailure.invalidRequest
        }
        let result = RecordingVideoFrameDelivery(sourceBank: sourceBank, privateBank: privateBank)
        ownedReceipt = receipt; delivery = result; return result
    }
    deinit {
        if let ownedReceipt {
            ownedReceipt.banks.forEach { RawVideoResourceCoordinator.shared.retire(bankID: $0.id) }
            RawVideoResourceCoordinator.shared.rollback(ownedReceipt)
        }
    }
}

/// Source subscriptions survive rotation, but each renderer captures exactly
/// one segment's immutable banks when makeRenderer is called.
final class RecordingVideoDeliveryProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var current: [String: RecordingVideoFrameDelivery] = [:]
    func install(_ deliveries: [String: RecordingVideoFrameDelivery]) {
        lock.lock(); current = deliveries; lock.unlock()
    }
    func delivery(for target: String) -> RecordingVideoFrameDelivery? {
        lock.lock(); defer { lock.unlock() }; return current[target]
    }
}

/// Serializes callback authorization with router activation. An old callback
/// cannot cross a rotation and resolve the next segment's finish boundary.
final class RecordingProgramFrameDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private let router: ProgramRecordingRouter
    private var bankID: UUID?
    init(router: ProgramRecordingRouter) { self.router = router }
    func activate(bank: RawVideoResourceBank, session: ProgramRecordingSession,
                  finishing previous: ProgramRecordingSession? = nil) {
        lock.lock(); defer { lock.unlock() }
        bankID = bank.id
        if let previous { router.rotate(to: session, finishing: previous) }
        else { router.install(session) }
    }
    func stop(_ session: ProgramRecordingSession) {
        lock.lock(); bankID = nil; router.stop(session); lock.unlock()
    }
    func receive(_ sample: CMSampleBuffer, bank: RawVideoResourceBank) {
        lock.lock(); defer { lock.unlock() }
        guard bankID == bank.id else { return }
        router.appendPreparedVideo(.init(sample: sample, bank: bank))
    }
}

/// One pre-writer transaction, including every selected ISO and the actual
/// compositor source pool. Shared compositor source ownership is transferred
/// to the Engine; this owner retires only its private and ISO source banks.
final class RecordingSegmentVideoResources: @unchecked Sendable {
    let generation: UUID
    let program: RawVideoResourceBank
    let source: RawVideoResourceBank
    let sourceReceipt: RawVideoResourceReceipt
    let isolated: [String: RecordingVideoFrameDelivery]
    private let receipt: RawVideoResourceReceipt
    private let owned: [RawVideoResourceBank]

    init(workspace: UUID, generation: UUID, canvas: OutputCanvas, size: CGSize,
         sourceRequest: RawVideoResourceRequest, selections: [IsolatedVideoSelection]) throws {
        guard size.width.isFinite, size.height.isFinite, size.width >= 1, size.height >= 1,
              size.width <= 4096, size.height <= 4096 else { throw RawVideoResourceFailure.invalidRequest }
        self.generation = generation
        let plane: StableFrameDomainID.Plane = canvas == .program ? .program : .secondary
        let domain = StableFrameDomainID(workspace: workspace, kind: .recording, outputID: "program", plane: plane)
        var requests = [sourceRequest, RawVideoResourceRequest(domain: domain,
            descriptor: .init(width: Int(size.width), height: Int(size.height), capacityPolicy:
                .recording(videoCapacity: 30, maxQueuedBytes: 128_000_000, headroom: 5)), sessionGeneration: generation)]
        var isoDomains: [String: (StableFrameDomainID, StableFrameDomainID)] = [:]
        for selection in selections {
            let source = StableFrameDomainID(workspace: workspace, kind: .rendererSource,
                outputID: "recording-" + selection.targetID, plane: .isolated)
            let destination = StableFrameDomainID(workspace: workspace, kind: .isolatedRecording,
                outputID: selection.targetID, plane: .isolated)
            isoDomains[selection.targetID] = (source, destination)
            requests.append(.init(domain: source, descriptor: .init(width: selection.resolution.width,
                height: selection.resolution.height, capacity: 4), sessionGeneration: generation))
            requests.append(.init(domain: destination, descriptor: .init(width: selection.resolution.width,
                height: selection.resolution.height, capacityPolicy:
                    .recording(videoCapacity: 6, maxQueuedBytes: 48_000_000, headroom: 2)), sessionGeneration: generation))
        }
        let receipt = try RawVideoResourceCoordinator.shared.reserveBatch(requests)
        do {
            guard let program = receipt.bank(for: domain), let source = receipt.bank(for: sourceRequest.domain) else {
                throw RawVideoResourceFailure.invalidRequest
            }
            var isolated: [String: RecordingVideoFrameDelivery] = [:]
            for (id, domains) in isoDomains {
                guard let source = receipt.bank(for: domains.0), let destination = receipt.bank(for: domains.1) else {
                    throw RawVideoResourceFailure.invalidRequest
                }
                isolated[id] = .init(sourceBank: source, privateBank: destination)
            }
            self.program = program; self.source = source; self.isolated = isolated
            self.sourceReceipt = try receipt.selecting(domain: sourceRequest.domain)
            self.receipt = receipt
            owned = receipt.banks.filter { $0.id != source.id }
        } catch { RawVideoResourceCoordinator.shared.rollback(receipt); throw error }
    }
    func rollback() {
        RawVideoResourceCoordinator.shared.rollback(receipt)
        RawVideoResourceCoordinator.shared.rollback(sourceReceipt)
    }
    func retire() {
        // Exposed pools remain quarantined and fully charged. Neither a
        // finish ACK nor destruction of CMSampleBuffer wrappers refunds them.
        owned.forEach { RawVideoResourceCoordinator.shared.retire(bankID: $0.id) }
        RawVideoResourceCoordinator.shared.rollback(receipt)
    }
}
