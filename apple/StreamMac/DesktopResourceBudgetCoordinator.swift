import Darwin
import Foundation
import Metal
import StreamCore

struct DesktopResourceSnapshot: Codable, Sendable {
    var uptime: Double
    var processCPUSeconds: Double
    var cpuFraction: Double
    var residentBytes: UInt64?
    var physicalFootprintBytes: UInt64?
    var thermalState: Int
    var mainActorDelayMilliseconds: Double
    var metalAllocatedBytes: Int?
    /// Optional for compatibility with reports written before render health.
    var programHealth: DesktopProgramHealth?
}

struct DesktopMetalCapabilities: Codable, Sendable {
    var device: String?
    var unifiedMemory: Bool?
    var recommendedWorkingSetBytes: UInt64?
    var counterSets: [String]
    var utilizationUnavailableReason = "Metal does not expose process-wide GPU utilization through this collector."
}

/// Lightweight actual process/device observations. CPU time is normalized to
/// the Mac's logical capacity; Metal allocation is never labeled utilization.
@MainActor final class DesktopResourceSampler {
    nonisolated static var architecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "other"
        #endif
    }
    nonisolated static var isTranslated: Bool {
        var value: Int32 = 0, size = MemoryLayout<Int32>.size
        return sysctlbyname("sysctl.proc_translated", &value, &size, nil, 0) == 0 && value == 1
    }
    private let device = MTLCreateSystemDefaultDevice()
    private var previous: (time: Double, cpu: Double)?
    func reset() { previous = nil }
    var metalCapabilities: DesktopMetalCapabilities {
        .init(device: device.map { String($0.name.prefix(128)) }, unifiedMemory: device?.hasUnifiedMemory,
              recommendedWorkingSetBytes: device?.recommendedMaxWorkingSetSize,
              counterSets: Array((device?.counterSets ?? []).prefix(16)).map { String($0.name.prefix(128)) })
    }
    func sample(mainActorDelayMilliseconds: Double = 0) -> DesktopResourceSnapshot {
        let time = ProcessInfo.processInfo.systemUptime
        var usage = rusage()
        let cpu: Double
        if getrusage(RUSAGE_SELF, &usage) == 0 {
            cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        } else { cpu = previous?.cpu ?? 0 }
        let fraction = previous.map {
            max(0, cpu - $0.cpu) / max(0.001, time - $0.time) / Double(max(1, ProcessInfo.processInfo.activeProcessorCount))
        } ?? 0
        previous = (time, cpu)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return .init(uptime: time, processCPUSeconds: cpu, cpuFraction: fraction,
            residentBytes: status == KERN_SUCCESS ? info.resident_size : nil,
            physicalFootprintBytes: status == KERN_SUCCESS ? info.phys_footprint : nil,
            thermalState: ProcessInfo.processInfo.thermalState.rawValue,
            mainActorDelayMilliseconds: max(0, mainActorDelayMilliseconds), metalAllocatedBytes: device?.currentAllocatedSize)
    }
}

private actor DesktopResourceReportStore {
    let url: URL
    init(url: URL) { self.url = url }
    func write(_ report: DesktopResourceBudgetCoordinator.Report) throws {
        let bytes = try JSONEncoder().encode(report)
        guard bytes.count <= 1_048_576 else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url, options: .atomic)
    }
}

/// Only the optional-preview callback can act on the policy. Publisher/source/
/// recorder state is read for health but never restarted or reconfigured here.
@MainActor final class DesktopResourceBudgetCoordinator {
    struct Report: Codable, Sendable {
        var version = 1
        var sampledAt = Date()
        var os = ProcessInfo.processInfo.operatingSystemVersionString
        var hardwareModel = StudioDiagnosticSnapshot.machineModel()
        var processors = ProcessInfo.processInfo.processorCount
        var physicalMemoryBytes = ProcessInfo.processInfo.physicalMemory
        var architecture = DesktopResourceSampler.architecture
        var processTranslated = DesktopResourceSampler.isTranslated
        var hardwareCanvasCeiling = OutputCapabilities.current.hardwareTier.displayName
        var hardwareFPSCeiling = OutputCapabilities.current.hardwareMaxFrameRate
        var qualification = "Runtime preview guard; no workload, physical-device or sustained thermal certification."
        var footprintBudgetBytes: UInt64
        var previewLevel: DesktopResourceBudget.PreviewLevel
        var metal: DesktopMetalCapabilities
        var samples: [DesktopResourceSnapshot]
    }
    private var policy = DesktopResourceBudget()
    private let sampler = DesktopResourceSampler()
    private let store: DesktopResourceReportStore?
    private let metrics: @MainActor () async -> CompositionMetrics
    private let apply: @MainActor (DesktopResourceBudget.PreviewLevel) -> Void
    private var previous: DesktopProgramHealth.Counters?
    private var samples: [DesktopResourceSnapshot] = []
    private var task: Task<Void, Never>?
    init(reportURL: URL?, metrics: @escaping @MainActor () async -> CompositionMetrics,
         apply: @escaping @MainActor (DesktopResourceBudget.PreviewLevel) -> Void) {
        store = reportURL.map(DesktopResourceReportStore.init(url:))
        self.metrics = metrics; self.apply = apply
    }
    var latestSnapshot: DesktopResourceSnapshot? { samples.last }
    var hasCPUDelta: Bool { samples.count > 1 }
    var metalCapabilities: DesktopMetalCapabilities { sampler.metalCapabilities }
    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            var expected = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                do {
                    guard let self else { return }
                    let current = await self.metrics()
                    guard !Task.isCancelled else { return }
                    var sample = self.sampler.sample(mainActorDelayMilliseconds: max(0, ProcessInfo.processInfo.systemUptime - expected) * 1_000)
                    let counters = DesktopProgramHealth.Counters(startedAt: current.startedAt,
                        attempts: current.attempts, failed: current.failed, missedDeadlines: current.missedDeadlines)
                    let health = DesktopProgramHealth.measure(counters, since: self.previous)
                    self.previous = counters
                    sample.programHealth = health
                    // A counter lifecycle boundary cannot extend either a
                    // pressure or recovery window across unrelated epochs.
                    if health.isDiscontinuous { self.policy.resetObservations() }
                    let old = self.policy.level
                    let level = self.policy.update(.init(time: sample.uptime, cpuFraction: sample.cpuFraction,
                        physicalFootprintBytes: sample.physicalFootprintBytes ?? 0,
                        programMissFraction: health.programMissFraction ?? 0, thermalState: sample.thermalState,
                        programRenderFailureFraction: health.programRenderFailureFraction))
                    self.samples.append(sample); self.samples = Array(self.samples.suffix(120))
                    if level != old { self.apply(level) }
                    if let store = self.store, self.samples.count == 1 || Int(sample.uptime) % 30 == 0 || level != old {
                        let report = Report(footprintBudgetBytes: self.policy.footprintBudgetBytes, previewLevel: level,
                            metal: self.sampler.metalCapabilities, samples: self.samples)
                        try? await store.write(report)
                    }
                }
                expected = ProcessInfo.processInfo.systemUptime + 1
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }
    func stop() {
        task?.cancel(); task = nil; previous = nil
        policy.resetObservations(); sampler.reset(); samples.removeAll()
    }
    deinit { task?.cancel() }
}

/// Monitor conversions read this from their delivery queues, without actor hops.
final class DesktopPreviewThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var level: DesktopResourceBudget.PreviewLevel = .normal
    func set(_ value: DesktopResourceBudget.PreviewLevel) { lock.lock(); level = value; lock.unlock() }
    var nanoseconds: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return level == .normal ? 33_000_000 : (level == .reduced ? 66_666_667 : 200_000_000)
    }
}
