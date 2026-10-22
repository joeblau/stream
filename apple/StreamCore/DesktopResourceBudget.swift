import Foundation

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
        public var thermalState: Int
        public init(time: Double, cpuFraction: Double, physicalFootprintBytes: UInt64,
                    programMissFraction: Double, thermalState: Int) {
            self.time = time; self.cpuFraction = cpuFraction
            self.physicalFootprintBytes = physicalFootprintBytes
            self.programMissFraction = programMissFraction; self.thermalState = thermalState
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
    @discardableResult public mutating func update(_ sample: Observation) -> PreviewLevel {
        guard sample.time.isFinite, sample.cpuFraction.isFinite, sample.cpuFraction >= 0,
              sample.programMissFraction.isFinite, (0...1).contains(sample.programMissFraction),
              lastTime.map({ sample.time > $0 }) ?? true else { return level }
        lastTime = sample.time
        let pressure = sample.thermalState >= 2 || sample.cpuFraction >= 0.8
            || sample.physicalFootprintBytes >= footprintBudgetBytes || sample.programMissFraction >= 0.10
        let severe = sample.thermalState >= 3 || sample.physicalFootprintBytes >= footprintBudgetBytes + footprintBudgetBytes / 4
            || sample.programMissFraction >= 0.35
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
