import Foundation
import Testing
@testable import StreamCore

@Suite struct RawVideoResourceBudgetTests {
    private let workspace = UUID()
    private func request(_ name: String = "output", session: UUID = UUID(), capacity: Int = 4, width: Int = 16) -> RawVideoResourceRequest {
        .init(domain: .init(workspace: workspace, kind: .rawPublisher, outputID: name, plane: .program),
              descriptor: .init(width: width, height: 16, capacity: capacity), sessionGeneration: session)
    }
    private func sample(_ bytes: UInt64 = 100, time: Double = 10) -> RawVideoProcessFootprint { .init(uptime: time, physicalFootprintBytes: bytes) }
    private func claim(_ request: RawVideoResourceRequest, bytes: UInt64 = 100) -> RawVideoResourceClaim { .init(request: request, bytesPerBuffer: bytes) }

    @Test func batchIsAtomicAndWholeProcessSignalIsNotAnExtraAllowance() throws {
        var budget = RawVideoResourceBudget(admissionCeilingBytes: 1_000)
        let first = try budget.reserveBatch([claim(request("first"))], footprint: sample(), now: 10)
        #expect(budget.committedBytes == 400)
        #expect(throws: RawVideoResourceFailure.budgetExceeded) {
            try budget.reserveBatch([claim(request("second")), claim(request("third"))], footprint: sample(), now: 10)
        }
        #expect(budget.bankCount == 1 && budget.committedBytes == 400)
        // Resident storage is deliberately counted again, not subtracted.
        #expect(throws: RawVideoResourceFailure.budgetExceeded) {
            try budget.reserveBatch([claim(request("second"))], footprint: sample(601), now: 10)
        }
        #expect(budget.entries.first?.reservation == first[0])
    }
    @Test func missingStaleFutureAndInvalidSnapshotsDenyWithoutMutating() throws {
        var budget = RawVideoResourceBudget(admissionCeilingBytes: 10_000)
        for observation in [nil, sample(0)] {
            #expect(throws: RawVideoResourceFailure.unknownFootprint) { try budget.reserveBatch([claim(request())], footprint: observation, now: 10) }
        }
        for observation in [sample(time: 7.999), sample(time: 11), sample(time: .nan), sample(time: -1)] {
            #expect(throws: RawVideoResourceFailure.staleFootprint) { try budget.reserveBatch([claim(request())], footprint: observation, now: 10) }
        }
        #expect(budget.bankCount == 0)
        _ = try budget.reserveBatch([claim(request())], footprint: sample(time: 8), now: 10)
        #expect(budget.bankCount == 1)
    }
    @Test func onlySameActiveSessionAndExactDescriptorReusesCredit() throws {
        var budget = RawVideoResourceBudget(admissionCeilingBytes: 100_000)
        let session = UUID(), original = request(session: session)
        let first = try budget.reserveBatch([claim(original)], footprint: sample(), now: 10)[0]
        let exposed = budget.markExposed(first)
        #expect(exposed)
        let again = try budget.reserveBatch([claim(original)], footprint: sample(), now: 10)[0]
        #expect(first == again && budget.bankCount == 1)
        #expect(throws: RawVideoResourceFailure.sessionConflict) {
            try budget.reserveBatch([claim(request(session: session, width: 32))], footprint: sample(), now: 10)
        }
        budget.retire(first)
        let retiredRefund = budget.rollbackNeverExposed(first)
        #expect(!retiredRefund)
        let restart = try budget.reserveBatch([claim(request())], footprint: sample(), now: 10)[0]
        #expect(restart.bankGeneration != first.bankGeneration && budget.committedBytes == 800)
        budget.retire(restart)
        let resized = try budget.reserveBatch([claim(request(width: 32), bytes: 200)], footprint: sample(), now: 10)[0]
        #expect(resized.reservedBytes == 800 && budget.committedBytes == 1_600)
        #expect(budget.entries.filter { $0.state == .quarantined }.count == 2)
    }
    @Test func rollbackDoesNotRefundExposedOrReusedBanks() throws {
        var budget = RawVideoResourceBudget(admissionCeilingBytes: 100_000)
        let reservations = try budget.reserveBatch([claim(request("a")), claim(request("b"))], footprint: sample(), now: 10)
        let exposed = budget.markExposed(reservations[0])
        let exposedRefund = budget.rollbackNeverExposed(reservations[0])
        let ownedRefund = budget.rollbackNeverExposed(reservations[1])
        let duplicateRefund = budget.rollbackNeverExposed(reservations[1])
        #expect(exposed && !exposedRefund && ownedRefund && !duplicateRefund)
        #expect(budget.committedBytes == 400)
    }
    @Test func duplicateGroupClaimsHaveOneBackingLiability() throws {
        var budget = RawVideoResourceBudget(admissionCeilingBytes: 100_000)
        let group = request("shared-group")
        let result = try budget.reserveBatch([claim(group), claim(group)], footprint: sample(), now: 10)
        #expect(result.count == 2 && result[0] == result[1])
        #expect(budget.bankCount == 1 && budget.committedBytes == 400)
    }
    @Test func overflowingCostsAndZeroBytesNeverInsertMetadata() throws {
        var budget = RawVideoResourceBudget(admissionCeilingBytes: .max)
        #expect(throws: RawVideoResourceFailure.invalidMeasurement) { try budget.reserveBatch([claim(request(), bytes: 0)], footprint: sample(), now: 10) }
        #expect(throws: RawVideoResourceFailure.invalidMeasurement) { try budget.reserveBatch([claim(request(), bytes: .max)], footprint: sample(), now: 10) }
        #expect(throws: RawVideoResourceFailure.budgetExceeded) { try budget.check(additionalBytes: .max, footprint: sample(), now: 10) }
        #expect(budget.bankCount == 0 && budget.committedBytes == 0)
    }
    @Test func allPlanesAndSurfacePaddingAreMeasuredWithCheckedArithmetic() throws {
        let planes: [RawVideoBufferStorage.Plane] = [.init(bytesPerRow: 128, height: 64), .init(bytesPerRow: 128, height: 32)]
        #expect(try RawVideoBufferStorage.measuredBytes(dataSize: 1, planes: planes, surfaceAllocationBytes: nil) == 12_288)
        #expect(try RawVideoBufferStorage.measuredBytes(dataSize: 16_384, planes: planes, surfaceAllocationBytes: 20_480) == 20_480)
        #expect(throws: RawVideoResourceFailure.invalidMeasurement) { try RawVideoBufferStorage.measuredBytes(dataSize: 1, planes: [.init(bytesPerRow: .max, height: 2)], surfaceAllocationBytes: nil) }
        #expect(throws: RawVideoResourceFailure.invalidMeasurement) { try RawVideoBufferStorage.measuredBytes(dataSize: 1, planes: [], surfaceAllocationBytes: nil) }
    }
    @Test func recordingCapacityUsesActualDecimalQueuePolicyAndHeadroom() throws {
        let descriptor = RawVideoBankDescriptor(width: 1920, height: 1080,
            capacityPolicy: .recording(videoCapacity: 30, maxQueuedBytes: 128_000_000, headroom: 2))
        #expect(try descriptor.allocationThreshold(bytesPerBuffer: 8_294_400) == 17)
        #expect(try descriptor.allocationThreshold(bytesPerBuffer: 3_686_400) == 32)
        #expect(try descriptor.allocationThreshold(bytesPerBuffer: 33_177_600) == 5)
        #expect(try descriptor.allocationThreshold(bytesPerBuffer: 200_000_000) == 3)
        let brokerQueue = RawVideoBankDescriptor(width: 1920, height: 1080,
            capacityPolicy: .recording(videoCapacity: 30, maxQueuedBytes: 128_000_000, headroom: 5))
        #expect(try brokerQueue.allocationThreshold(bytesPerBuffer: 8_294_400) == 20)
    }
    @Test func queueCostAndBackingPaddingRemainDistinct() throws {
        var budget = RawVideoResourceBudget(admissionCeilingBytes: 1_000_000_000)
        let descriptor = RawVideoBankDescriptor(width: 16, height: 16,
            capacityPolicy: .recording(videoCapacity: 30, maxQueuedBytes: 128_000_000, headroom: 5))
        let request = RawVideoResourceRequest(domain: request().domain, descriptor: descriptor, sessionGeneration: UUID())
        let reservation = try budget.reserveBatch([.init(request: request, bytesPerBuffer: 9_000_000,
            queueCostBytes: 8_294_400)], footprint: sample(), now: 10)[0]
        #expect(reservation.allocationThreshold == 20)
        #expect(reservation.reservedBytes == 180_000_000 && reservation.queueCostBytes == 8_294_400)
    }
    @Test func metadataIsFiniteAndRejectedRequestsDoNotAccumulate() throws {
        var budget = RawVideoResourceBudget(admissionCeilingBytes: 1_000_000)
        for index in 0..<RawVideoResourceBudget.maximumBanks {
            let reservation = try budget.reserveBatch([claim(request("bank-\(index)", capacity: 1), bytes: 1)], footprint: sample(), now: 10)[0]
            _ = budget.markExposed(reservation); budget.retire(reservation)
        }
        for _ in 0..<1_000 {
            #expect(throws: RawVideoResourceFailure.bankLimit) { try budget.reserveBatch([claim(request("rejected"))], footprint: sample(), now: 10) }
        }
        #expect(budget.bankCount == 256 && budget.committedBytes == 256)
        #expect(throws: RawVideoResourceFailure.invalidRequest) { try budget.reserveBatch([], footprint: sample(), now: 10) }
        #expect(throws: RawVideoResourceFailure.invalidRequest) { try budget.reserveBatch((0..<33).map { claim(request("batch-\($0)")) }, footprint: sample(), now: 10) }
    }
    @Test func softwareAdmissionAmountMatchesButDoesNotMutatePreviewPolicy() {
        for memory: UInt64 in [1, 8 * 1_024 * 1_024 * 1_024, .max] {
            #expect(RawVideoResourceBudget(physicalMemory: memory).admissionCeilingBytes == StreamCapability.desktopPreviewFootprintBudget(physicalMemory: memory))
        }
    }
}
