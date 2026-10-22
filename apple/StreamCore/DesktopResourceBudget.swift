import Foundation

/// Independent interval measurements from the Program compositor's cumulative
/// counters. A render attempt that produces no Program frame is not a skipped
/// clock deadline; the two ratios deliberately retain different denominators.
public struct DesktopProgramHealth: Codable, Equatable, Sendable {
    public struct Counters: Sendable {
        public let startedAt: Double
        public let attempts: Int
        public let failed: Int
        public let missedDeadlines: Int
        public init(startedAt: Double, attempts: Int, failed: Int, missedDeadlines: Int) {
            self.startedAt = startedAt; self.attempts = attempts
            self.failed = failed; self.missedDeadlines = missedDeadlines
        }
        fileprivate var isValid: Bool {
            startedAt.isFinite && startedAt >= 0 && attempts >= 0 && failed >= 0
                && failed <= attempts && missedDeadlines >= 0
        }
    }
    public enum Status: String, Codable, Sendable { case baseline, reset, invalid, observed }
    public let status: Status
    public let attempts: Int?
    public let failed: Int?
    public let missedDeadlines: Int?
    public let programMissFraction: Double?
    public let programRenderFailureFraction: Double?
    public var isDiscontinuous: Bool { status != .observed }

    private init(status: Status, attempts: Int? = nil, failed: Int? = nil, missedDeadlines: Int? = nil,
                 programMissFraction: Double? = nil, programRenderFailureFraction: Double? = nil) {
        self.status = status; self.attempts = attempts; self.failed = failed; self.missedDeadlines = missedDeadlines
        self.programMissFraction = programMissFraction; self.programRenderFailureFraction = programRenderFailureFraction
    }
    public static func measure(_ current: Counters, since previous: Counters?) -> Self {
        guard current.isValid else { return .init(status: .invalid) }
        guard let previous, previous.isValid else { return .init(status: .baseline) }
        guard current.startedAt == previous.startedAt,
              current.attempts >= previous.attempts, current.failed >= previous.failed,
              current.missedDeadlines >= previous.missedDeadlines else { return .init(status: .reset) }
        let attempts = current.attempts - previous.attempts
        let failed = current.failed - previous.failed
        let missed = current.missedDeadlines - previous.missedDeadlines
        guard failed <= attempts else { return .init(status: .invalid) }
        // Convert before addition: valid large cumulative counters cannot make
        // the denominator overflow an Int. Zero opportunities are unavailable.
        let opportunities = Double(attempts) + Double(missed)
        return .init(status: .observed, attempts: attempts, failed: failed, missedDeadlines: missed,
                     programMissFraction: opportunities > 0 ? Double(missed) / opportunities : nil,
                     programRenderFailureFraction: attempts > 0 ? Double(failed) / Double(attempts) : nil)
    }
}

/// Runtime protection for optional desktop previews. This is a conservative
/// guard derived from existing device signals, not workload certification.
/// It has no publisher, recording, source-enable or program-profile controls.
public struct DesktopResourceBudget: Sendable {
    public enum PreviewLevel: String, Codable, CaseIterable, Sendable {
        case normal, reduced, minimum
        public var maximumFrameRate: Int { switch self { case .normal: .max; case .reduced: 15; case .minimum: 5 } }
        public var maximumLongEdge: Int { switch self { case .normal: .max; case .reduced: 1_280; case .minimum: 640 } }
        public var notice: String? {
            switch self {
            case .normal: nil
            case .reduced: "Preview detail and cadence reduced to protect active outputs."
            case .minimum: "Preview at minimum detail and cadence to protect active outputs."
            }
        }
    }
    public struct Observation: Sendable {
        public var time: Double
        /// Fraction of this Mac's logical CPU capacity, not percent of one core.
        public var cpuFraction: Double
        public var physicalFootprintBytes: UInt64
        public var programMissFraction: Double
        /// nil means no valid render-attempt interval; it cannot prove recovery.
        public var programRenderFailureFraction: Double?
        public var thermalState: Int
        public init(time: Double, cpuFraction: Double, physicalFootprintBytes: UInt64,
                    programMissFraction: Double, thermalState: Int, programRenderFailureFraction: Double? = 0) {
            self.time = time; self.cpuFraction = cpuFraction
            self.physicalFootprintBytes = physicalFootprintBytes
            self.programMissFraction = programMissFraction; self.thermalState = thermalState
            self.programRenderFailureFraction = programRenderFailureFraction
        }
    }
    public let footprintBudgetBytes: UInt64
    public private(set) var level: PreviewLevel = .normal
    private var pressureSince: Double?
    private var severeSince: Double?
    private var clearSince: Double?
    private var lastTime: Double?
    public init(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) {
        // Existing StreamCapability hardware ceilings remain authoritative.
        // Spend at most a fifth of RAM (4 GiB ceiling) before shedding preview.
        footprintBudgetBytes = StreamCapability.desktopPreviewFootprintBudget(physicalMemory: physicalMemory)
    }
    /// Idle time is not observed pressure or observed recovery. Preserve the
    /// last safe preview level, then require fresh evidence after restart.
    public mutating func resetObservations() {
        pressureSince = nil; severeSince = nil; clearSince = nil; lastTime = nil
    }
    @discardableResult public mutating func update(_ sample: Observation) -> PreviewLevel {
        guard sample.time.isFinite, sample.cpuFraction.isFinite, sample.cpuFraction >= 0,
              sample.programMissFraction.isFinite, (0...1).contains(sample.programMissFraction),
              sample.programRenderFailureFraction.map({ $0.isFinite && (0...1).contains($0) }) ?? true,
              lastTime.map({ sample.time > $0 }) ?? true else { return level }
        lastTime = sample.time
        let programPressure = max(sample.programMissFraction, sample.programRenderFailureFraction ?? 0)
        let pressure = sample.thermalState >= 2 || sample.cpuFraction >= 0.8
            || sample.physicalFootprintBytes >= footprintBudgetBytes || programPressure >= 0.10
        let severe = sample.thermalState >= 3 || sample.physicalFootprintBytes >= footprintBudgetBytes + footprintBudgetBytes / 4
            || programPressure >= 0.35
        if pressure {
            clearSince = nil
            if pressureSince == nil { pressureSince = sample.time }
            if severe {
                if severeSince == nil { severeSince = sample.time }
                if sample.thermalState >= 3 || sample.time - severeSince! >= 1 { level = .minimum }
            } else { severeSince = nil }
            if level == .normal, sample.time - pressureSince! >= 3 { level = .reduced }
        } else {
            pressureSince = nil; severeSince = nil
            // No attempted frames is not measured healthy rendering. CPU,
            // memory, thermal and deadline pressure above still act while idle.
            guard sample.programRenderFailureFraction != nil else { clearSince = nil; return level }
            if clearSince == nil { clearSince = sample.time }
            // Recovery is deliberately slow and staged: brief relief must not
            // repeatedly rebuild optional raster pools during a live session.
            if sample.time - clearSince! >= 30 {
                if level == .minimum { level = .reduced }
                else if level == .reduced { level = .normal }
                clearSince = sample.time
            }
        }
        return level
    }
}
