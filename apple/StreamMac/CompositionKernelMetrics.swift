import Foundation

/// Sampled Core Image render-task kernel time. This is actual task information,
/// not a wall timer or process-wide GPU utilization percentage.
struct CompositionKernelMetrics: Codable, Sendable {
    var backend = "unavailable"
    var samples = 0
    var unavailableSamples = 0
    var totalMilliseconds = 0.0
    var maximumMilliseconds = 0.0
    var unavailableReason: String? = "No completed Metal render-task sample."
    var meanMilliseconds: Double? { samples > 0 ? totalMilliseconds / Double(samples) : nil }
    mutating func record(seconds: Double) {
        guard seconds.isFinite, seconds > 0 else {
            unavailableSamples += 1; unavailableReason = "Core Image did not expose a positive kernel execution time."
            return
        }
        samples += 1; totalMilliseconds += seconds * 1_000
        maximumMilliseconds = max(maximumMilliseconds, seconds * 1_000)
        unavailableReason = nil
    }
}
