import Testing
import Foundation
import StreamCore

/// Unit tests for E03 (issue #164): the background-effect settings model
/// (additive wire format, clamping, validation), the capability matrix
/// derivation (the published per-tier matrix), and the frame-cost governor
/// that protects output cadence at runtime.
@Suite struct BackgroundEffectsTests {

    // MARK: - BackgroundEffectSettings model

    @Test("The default settings are off — a render no-op")
    func defaultsAreOff() {
        let settings = BackgroundEffectSettings()
        #expect(settings.mode == .off)
        #expect(!settings.isEnabled)
        #expect(settings.quality == .balanced)
        #expect(settings.strength == 0.5)
        #expect(settings.validationError == nil)
    }

    @Test("Additive decode: an empty object yields defaults")
    func additiveDecodeEmpty() throws {
        let settings = try JSONDecoder().decode(BackgroundEffectSettings.self, from: Data("{}".utf8))
        #expect(settings == BackgroundEffectSettings())
    }

    @Test("Additive decode: a document predating E03 fields keeps loading")
    func additiveDecodePartial() throws {
        let settings = try JSONDecoder().decode(
            BackgroundEffectSettings.self,
            from: Data(#"{"mode": "blur"}"#.utf8))
        #expect(settings.mode == .blur)
        #expect(settings.isEnabled)
        #expect(settings.quality == .balanced)
        #expect(settings.strength == 0.5)
    }

    @Test("Full round-trip preserves every field")
    func roundTrip() throws {
        var settings = BackgroundEffectSettings()
        settings.mode = .replacement
        settings.quality = .accurate
        settings.strength = 0.75
        settings.replacementColorHex = "#336699"
        let decoded = try JSONDecoder().decode(
            BackgroundEffectSettings.self,
            from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
    }

    @Test("Clamping pins strength to 0...1")
    func clamping() {
        var settings = BackgroundEffectSettings()
        settings.strength = 4
        #expect(settings.clamped().strength == 1)
        settings.strength = -2
        #expect(settings.clamped().strength == 0)
    }

    @Test("Validation rejects out-of-range and non-finite strength")
    func validation() {
        var settings = BackgroundEffectSettings()
        settings.strength = 1.5
        #expect(settings.validationError != nil)
        settings.strength = .nan
        #expect(settings.validationError != nil)
        settings.strength = .infinity
        #expect(settings.validationError != nil)
        settings.strength = 0
        #expect(settings.validationError == nil)
        settings.strength = 1
        #expect(settings.validationError == nil)
    }

    @Test("Quality levels order cheapest to costliest for the governor's downgrade path")
    func qualityOrdering() {
        #expect(SegmentationQuality.accurate.cheaper == .balanced)
        #expect(SegmentationQuality.balanced.cheaper == .fast)
        #expect(SegmentationQuality.fast.cheaper == nil)
    }

    // MARK: - Capability matrix

    @Test("macOS before 12 is unsupported, with an explicit reason and no rows")
    func osGate() {
        let matrix = SegmentationCapabilityMatrix.evaluate(
            macOSMajorVersion: 11, processorCount: 8, physicalMemory: 16_000_000_000)
        #expect(!matrix.isSupported)
        #expect(matrix.unavailableReason != nil)
        #expect(matrix.rows.isEmpty)
        #expect(matrix.recommendedQuality == nil)
        #expect(!matrix.isOfferable)
    }

    @Test("High-tier Mac at 60 fps: balanced recommended (accurate exceeds half the frame)")
    func highTier60fps() {
        let matrix = SegmentationCapabilityMatrix.evaluate(
            macOSMajorVersion: 15, processorCount: 12, physicalMemory: 32_000_000_000,
            targetFrameRate: 60)
        #expect(matrix.isSupported)
        #expect(matrix.recommendedQuality == .balanced)
        #expect(matrix.isOfferable)
        // Every level RUNS (public API); over-budget ones carry the note.
        #expect(matrix.rows.count == 3)
        #expect(matrix.row(for: .fast)?.note == nil)
        #expect(matrix.row(for: .accurate)?.note != nil)
    }

    @Test("High-tier Mac at 30 fps: accurate fits the wider frame budget")
    func highTier30fps() {
        let matrix = SegmentationCapabilityMatrix.evaluate(
            macOSMajorVersion: 15, processorCount: 12, physicalMemory: 32_000_000_000,
            targetFrameRate: 30)
        #expect(matrix.recommendedQuality == .accurate)
    }

    @Test("Mid-tier Mac at 60 fps: only fast fits")
    func midTier60fps() {
        let matrix = SegmentationCapabilityMatrix.evaluate(
            macOSMajorVersion: 14, processorCount: 6, physicalMemory: 4_000_000_000,
            targetFrameRate: 60)
        #expect(matrix.isSupported)
        #expect(matrix.recommendedQuality == .fast)
        #expect(matrix.row(for: .balanced)?.note != nil)
    }

    @Test("Low-tier Mac at 60 fps: nothing fits — supported but not offerable")
    func lowTier60fps() {
        let matrix = SegmentationCapabilityMatrix.evaluate(
            macOSMajorVersion: 14, processorCount: 4, physicalMemory: 2_000_000_000,
            targetFrameRate: 60)
        #expect(matrix.isSupported)
        #expect(matrix.recommendedQuality == nil)
        #expect(!matrix.isOfferable)
        #expect(matrix.unavailableReason != nil)
    }

    @Test("Low-tier Mac at 30 fps: fast fits again — the frame rate is part of the capability")
    func lowTier30fps() {
        let matrix = SegmentationCapabilityMatrix.evaluate(
            macOSMajorVersion: 14, processorCount: 4, physicalMemory: 2_000_000_000,
            targetFrameRate: 30)
        #expect(matrix.recommendedQuality == .fast)
        #expect(matrix.isOfferable)
    }

    @Test("Every supported row is available — the API runs; cost, not support, differentiates")
    func rowsAllAvailableWhenSupported() {
        let matrix = SegmentationCapabilityMatrix.evaluate(
            macOSMajorVersion: 26, processorCount: 12, physicalMemory: 32_000_000_000)
        let allAvailable = matrix.rows.allSatisfy(\.isAvailable)
        #expect(allAvailable)
    }

    // MARK: - Frame governor

    @Test("Within-budget samples hold the requested quality")
    func governorHolds() {
        var governor = SegmentationFrameGovernor(requestedQuality: .accurate)
        for _ in 0..<10 {
            #expect(governor.record(costMs: 5, frameIntervalMs: 33.3) == .hold)
        }
        #expect(governor.effectiveQuality == .accurate)
        #expect(!governor.isSuspended)
    }

    @Test("Isolated over-budget spikes are tolerated; sustained overload downgrades")
    func governorDowngradesAfterTolerance() {
        var governor = SegmentationFrameGovernor(requestedQuality: .accurate,
                                                 overBudgetTolerance: 3)
        // A spike, then recovery: the counter resets.
        #expect(governor.record(costMs: 20, frameIntervalMs: 16.6) == .hold)
        #expect(governor.record(costMs: 2, frameIntervalMs: 16.6) == .hold)
        #expect(governor.effectiveQuality == .accurate)
        // Sustained overload: 3 consecutive over-budget samples step down.
        #expect(governor.record(costMs: 20, frameIntervalMs: 16.6) == .hold)
        #expect(governor.record(costMs: 20, frameIntervalMs: 16.6) == .hold)
        #expect(governor.record(costMs: 20, frameIntervalMs: 16.6) == .downgrade(to: .balanced))
        #expect(governor.effectiveQuality == .balanced)
        // Still over budget at balanced → fast, then suspend.
        for _ in 0..<2 { #expect(governor.record(costMs: 20, frameIntervalMs: 16.6) == .hold) }
        #expect(governor.record(costMs: 20, frameIntervalMs: 16.6) == .downgrade(to: .fast))
        for _ in 0..<2 { #expect(governor.record(costMs: 20, frameIntervalMs: 16.6) == .hold) }
        #expect(governor.record(costMs: 20, frameIntervalMs: 16.6) == .suspend)
        #expect(governor.isSuspended)
    }

    @Test("Suspension cools down, then resumes probing at fast")
    func governorSuspendResume() {
        var governor = SegmentationFrameGovernor(requestedQuality: .fast,
                                                 overBudgetTolerance: 1,
                                                 suspendCooldownFrames: 3)
        #expect(governor.record(costMs: 20, frameIntervalMs: 16.6) == .suspend)
        #expect(governor.record(costMs: 0, frameIntervalMs: 16.6) == .hold)
        #expect(governor.record(costMs: 0, frameIntervalMs: 16.6) == .hold)
        #expect(governor.record(costMs: 0, frameIntervalMs: 16.6) == .resume)
        #expect(!governor.isSuspended)
        #expect(governor.effectiveQuality == .fast)
    }

    @Test("A degenerate frame interval never divides the budget down to a false overload")
    func governorZeroInterval() {
        var governor = SegmentationFrameGovernor(requestedQuality: .accurate)
        #expect(governor.record(costMs: 100, frameIntervalMs: 0) == .hold)
        #expect(governor.effectiveQuality == .accurate)
    }
}
