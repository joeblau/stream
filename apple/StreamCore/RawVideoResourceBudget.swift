import Foundation

/// An output identity, not an ephemeral frame-sink registration token. A shared
/// encoder has one domain; independent raw endpoints have separate domains.
public struct StableFrameDomainID: Hashable, Sendable {
    public enum Kind: String, Sendable { case rawPublisher, sharedEncoder, recording, isolatedRecording, rendererSource, monitor, virtualCamera, externalDisplay, guestReturn, validation }
    public enum Plane: String, Sendable { case program, secondary, clean, preview, isolated }
    public let workspace: UUID
    public let kind: Kind
    public let outputID: String
    public let plane: Plane
    public init(workspace: UUID, kind: Kind, outputID: String, plane: Plane) {
        self.workspace = workspace; self.kind = kind; self.outputID = outputID; self.plane = plane
    }
    fileprivate var isValid: Bool { !outputID.isEmpty && outputID.utf8.count <= 128 }
}

public struct RawVideoBankDescriptor: Hashable, Sendable {
    public enum PixelFormat: String, Sendable { case bgra8 }
    public enum CapacityPolicy: Hashable, Sendable {
        case fixed(Int)
        /// The queue's original count/byte policy, plus the dequeued native
        /// append and the incoming completed copy. Bytes are decimal if the
        /// original queue policy is decimal; no implicit MiB conversion.
        case recording(videoCapacity: Int, maxQueuedBytes: UInt64, headroom: Int)
    }
    public let width: Int
    public let height: Int
    public let pixelFormat: PixelFormat
    public let capacityPolicy: CapacityPolicy
    public init(width: Int, height: Int, capacity: Int, pixelFormat: PixelFormat = .bgra8) {
        self.width = width; self.height = height; self.pixelFormat = pixelFormat
        capacityPolicy = .fixed(capacity)
    }
    public init(width: Int, height: Int, capacityPolicy: CapacityPolicy, pixelFormat: PixelFormat = .bgra8) {
        self.width = width; self.height = height; self.pixelFormat = pixelFormat; self.capacityPolicy = capacityPolicy
    }
    public func allocationThreshold(bytesPerBuffer: UInt64) throws -> Int {
        guard width > 0, height > 0, bytesPerBuffer > 0 else { throw RawVideoResourceFailure.invalidRequest }
        switch capacityPolicy {
        case .fixed(let count):
            guard (1...64).contains(count) else { throw RawVideoResourceFailure.invalidRequest }
            return count
        case .recording(let count, let bytes, let headroom):
            guard (1...63).contains(count), bytes > 0, (1...63).contains(headroom), count + headroom <= 64 else { throw RawVideoResourceFailure.invalidRequest }
            let queued = max(1, min(UInt64(count), bytes / bytesPerBuffer))
            return Int(queued) + headroom
        }
    }
}

public struct RawVideoResourceRequest: Hashable, Sendable {
    public let domain: StableFrameDomainID
    public let descriptor: RawVideoBankDescriptor
    public let sessionGeneration: UUID
    public init(domain: StableFrameDomainID, descriptor: RawVideoBankDescriptor, sessionGeneration: UUID) {
        self.domain = domain; self.descriptor = descriptor; self.sessionGeneration = sessionGeneration
    }
}

public struct RawVideoProcessFootprint: Sendable {
    public let uptime: Double
    public let physicalFootprintBytes: UInt64
    public init(uptime: Double, physicalFootprintBytes: UInt64) {
        self.uptime = uptime; self.physicalFootprintBytes = physicalFootprintBytes
    }
}

public enum RawVideoResourceFailure: String, Error, LocalizedError, Sendable {
    case invalidRequest, invalidMeasurement, unknownFootprint, staleFootprint
    case budgetExceeded, bankLimit, busy, allocationFailed, capacityOccupied, sessionConflict, unknownReservation
    public var errorDescription: String? {
        switch self {
        case .invalidRequest: "The requested video resource configuration is unsupported."
        case .invalidMeasurement: "The actual video buffer storage could not be bounded."
        case .unknownFootprint: "Current process memory is unavailable. Retry the output after diagnostics recover."
        case .staleFootprint: "Current process memory is stale. Retry the output after diagnostics recover."
        case .budgetExceeded: "Video memory admission is unavailable. Existing or draining outputs retain their reservations. Stop an output or restart the app after reviewing pending outputs."
        case .bankLimit: "Video bank capacity is occupied by active or draining outputs. Restart the app after reviewing pending outputs."
        case .busy: "Another output is preparing video resources. Retry after preparation finishes."
        case .allocationFailed: "The output's bounded video buffers could not be prepared."
        case .capacityOccupied: "The output's private video buffers are occupied. This output dropped a frame."
        case .sessionConflict: "The output resource session changed. Retry with the current output settings."
        case .unknownReservation: "The output no longer owns its video resource reservation."
        }
    }
}

public enum RawVideoBufferStorage {
    public struct Plane: Sendable {
        public let bytesPerRow: UInt64
        public let height: UInt64
        public init(bytesPerRow: UInt64, height: UInt64) { self.bytesPerRow = bytesPerRow; self.height = height }
    }
    /// Count actual backing bytes once, not once per queue/sample wrapper.
    /// A nonplanar buffer supplies one stride/height entry. IOSurface padding
    /// and allocation metadata can exceed the visible plane storage.
    public static func measuredBytes(dataSize: UInt64, planes: [Plane], surfaceAllocationBytes: UInt64?) throws -> UInt64 {
        guard !planes.isEmpty, planes.count <= 16 else { throw RawVideoResourceFailure.invalidMeasurement }
        var planeBytes: UInt64 = 0
        for plane in planes {
            guard plane.bytesPerRow > 0, plane.height > 0 else { throw RawVideoResourceFailure.invalidMeasurement }
            let (bytes, overflow1) = plane.bytesPerRow.multipliedReportingOverflow(by: plane.height)
            let (sum, overflow2) = planeBytes.addingReportingOverflow(bytes)
            guard !overflow1, !overflow2 else { throw RawVideoResourceFailure.invalidMeasurement }
            planeBytes = sum
        }
        return max(dataSize, max(planeBytes, surfaceAllocationBytes ?? 0))
    }
}

public struct RawVideoResourceReservation: Hashable, Sendable {
    public let request: RawVideoResourceRequest
    public let bankGeneration: UUID
    public let bytesPerBuffer: UInt64
    /// Existing queue eviction cost (CVPixelBufferGetDataSize), distinct from
    /// actual backing including IOSurface padding used for byte reservations.
    public let queueCostBytes: UInt64
    public let allocationThreshold: Int
    public let reservedBytes: UInt64
    fileprivate let transaction: UUID
}

/// A cost claim from an actual owned pool measurement. The pure ledger does
/// not infer allocation bytes from a width/height or certify native geometry.
public struct RawVideoResourceClaim: Sendable {
    public let request: RawVideoResourceRequest
    public let bankGeneration: UUID
    public let bytesPerBuffer: UInt64
    public let queueCostBytes: UInt64
    public init(request: RawVideoResourceRequest, bankGeneration: UUID = UUID(), bytesPerBuffer: UInt64, queueCostBytes: UInt64? = nil) {
        self.request = request; self.bankGeneration = bankGeneration; self.bytesPerBuffer = bytesPerBuffer
        self.queueCostBytes = queueCostBytes ?? bytesPerBuffer
    }
}

public struct RawVideoResourceBudget: Sendable {
    public static let maximumBanks = 256
    public static let maximumBatch = 32
    public static let provisionalProbeBytes: UInt64 = 64 * 1_024 * 1_024
    public static let maximumSnapshotAge: Double = 2
    public enum BankState: String, Sendable { case prepared, exposed, quarantined }
    public struct Entry: Sendable {
        public let reservation: RawVideoResourceReservation
        public fileprivate(set) var state: BankState
    }
    public let admissionCeilingBytes: UInt64
    private var banks: [UUID: Entry] = [:]
    public var entries: [Entry] { Array(banks.values) }
    public var bankCount: Int { banks.count }
    public var committedBytes: UInt64 { banks.values.reduce(0) { $0 + $1.reservation.reservedBytes } }

    /// An explicit conservative software admission policy, separate from the
    /// optional-preview guard even though both use the same numerical amount.
    /// P + ALL committed raw ceilings + proposed bytes intentionally double
    /// counts resident raw memory. This is not available RAM, a process hard
    /// cap, a codec/scratch bound, or a hardware throughput qualification.
    public init(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) {
        admissionCeilingBytes = StreamCapability.desktopPreviewFootprintBudget(physicalMemory: physicalMemory)
    }
    public init(admissionCeilingBytes: UInt64) { self.admissionCeilingBytes = admissionCeilingBytes }

    public func reservation(for request: RawVideoResourceRequest) -> RawVideoResourceReservation? {
        banks.values.first { $0.state != .quarantined && $0.reservation.request == request }?.reservation
    }

    public func check(additionalBytes: UInt64, footprint: RawVideoProcessFootprint?, now: Double) throws {
        guard let footprint, footprint.physicalFootprintBytes > 0 else { throw RawVideoResourceFailure.unknownFootprint }
        guard now.isFinite, footprint.uptime.isFinite, footprint.uptime >= 0,
              now >= footprint.uptime, now - footprint.uptime <= Self.maximumSnapshotAge else { throw RawVideoResourceFailure.staleFootprint }
        let (known, overflow1) = committedBytes.addingReportingOverflow(additionalBytes)
        let (total, overflow2) = footprint.physicalFootprintBytes.addingReportingOverflow(known)
        guard !overflow1, !overflow2, total <= admissionCeilingBytes else { throw RawVideoResourceFailure.budgetExceeded }
    }

    /// All-or-nothing. Idempotence is limited to the SAME active session and
    /// exact descriptor. Geometry alone cannot authorize reuse after restart:
    /// an old legal bare IOSurface/Metal alias may still observe its backing.
    public mutating func reserveBatch(_ claims: [RawVideoResourceClaim], footprint: RawVideoProcessFootprint?, now: Double) throws -> [RawVideoResourceReservation] {
        guard !claims.isEmpty, claims.count <= Self.maximumBatch else { throw RawVideoResourceFailure.invalidRequest }
        var candidate = self
        var result: [RawVideoResourceReservation] = []
        let transaction = UUID()
        for claim in claims {
            guard claim.request.domain.isValid else { throw RawVideoResourceFailure.invalidRequest }
            guard claim.bytesPerBuffer > 0, claim.queueCostBytes > 0, claim.queueCostBytes <= claim.bytesPerBuffer else { throw RawVideoResourceFailure.invalidMeasurement }
            let threshold = try claim.request.descriptor.allocationThreshold(bytesPerBuffer: claim.queueCostBytes)
            if let existing = candidate.reservation(for: claim.request) {
                guard existing.bytesPerBuffer == claim.bytesPerBuffer, existing.queueCostBytes == claim.queueCostBytes else { throw RawVideoResourceFailure.invalidMeasurement }
                result.append(existing); continue
            }
            guard !candidate.banks.values.contains(where: {
                $0.reservation.request.domain == claim.request.domain && $0.reservation.request.sessionGeneration == claim.request.sessionGeneration
            }) else { throw RawVideoResourceFailure.sessionConflict }
            guard candidate.bankCount < Self.maximumBanks else { throw RawVideoResourceFailure.bankLimit }
            guard candidate.banks[claim.bankGeneration] == nil else { throw RawVideoResourceFailure.invalidRequest }
            let (bytes, overflow) = claim.bytesPerBuffer.multipliedReportingOverflow(by: UInt64(threshold))
            guard !overflow, bytes > 0 else { throw RawVideoResourceFailure.invalidMeasurement }
            try candidate.check(additionalBytes: bytes, footprint: footprint, now: now)
            let reservation = RawVideoResourceReservation(request: claim.request, bankGeneration: claim.bankGeneration,
                bytesPerBuffer: claim.bytesPerBuffer, queueCostBytes: claim.queueCostBytes, allocationThreshold: threshold, reservedBytes: bytes, transaction: transaction)
            candidate.banks[claim.bankGeneration] = .init(reservation: reservation, state: .prepared)
            result.append(reservation)
        }
        // Even an idempotent new admission requires a current actual snapshot.
        try candidate.check(additionalBytes: 0, footprint: footprint, now: now)
        self = candidate
        return result
    }

    @discardableResult public mutating func markExposed(_ reservation: RawVideoResourceReservation) -> Bool {
        guard var entry = banks[reservation.bankGeneration], entry.reservation == reservation, entry.state != .quarantined else { return false }
        entry.state = .exposed; banks[reservation.bankGeneration] = entry; return true
    }
    /// Exposed banks keep their FULL ceiling forever in this initial contract.
    /// Stop ACKs, callback returns, pool flushes and all-N checkouts are not a
    /// proof that legal bare-surface/texture aliases have ceased to exist.
    public mutating func retire(_ reservation: RawVideoResourceReservation) {
        guard var entry = banks[reservation.bankGeneration], entry.reservation == reservation else { return }
        entry.state = .quarantined; banks[reservation.bankGeneration] = entry
    }
    /// Only a bank that has NEVER escaped its owned preparation transaction
    /// may be refunded. No rejection/history record is inserted on failure.
    @discardableResult public mutating func rollbackNeverExposed(_ reservation: RawVideoResourceReservation) -> Bool {
        guard let entry = banks[reservation.bankGeneration], entry.reservation == reservation, entry.state == .prepared else { return false }
        banks[reservation.bankGeneration] = nil; return true
    }
}
