import Testing
@testable import StreamCore

@Suite struct DesktopResourceBudgetTests {
    private func sample(_ time: Double, cpu: Double = 0, memory: UInt64 = 0, misses: Double = 0, thermal: Int = 0) -> DesktopResourceBudget.Observation {
        .init(time: time, cpuFraction: cpu, physicalFootprintBytes: memory, programMissFraction: misses, thermalState: thermal)
    }
    @Test func sustainedPressureAndStagedRecovery() {
        var budget = DesktopResourceBudget(physicalMemory: 16 * 1_024 * 1_024 * 1_024)
        #expect(budget.update(sample(0, cpu: 0.9)) == .normal)
        #expect(budget.update(sample(2, cpu: 0.9)) == .normal)
        #expect(budget.update(sample(3, cpu: 0.9)) == .reduced)
        #expect(budget.update(sample(4, misses: 0.4)) == .reduced)
        #expect(budget.update(sample(5, misses: 0.4)) == .minimum)
        #expect(budget.update(sample(6)) == .minimum)
        #expect(budget.update(sample(35)) == .minimum)
        #expect(budget.update(sample(36)) == .reduced)
        #expect(budget.update(sample(66)) == .normal)
    }
    @Test func briefPressureAndInvalidSamplesCannotChangePolicy() {
        var budget = DesktopResourceBudget()
        #expect(budget.update(sample(0, misses: 0.2)) == .normal)
        #expect(budget.update(sample(1)) == .normal)
        #expect(budget.update(sample(2, thermal: 3)) == .minimum)
        #expect(budget.update(sample(100, cpu: .nan)) == .minimum)
        #expect(budget.update(sample(101, misses: .infinity)) == .minimum)
        #expect(budget.update(sample(0)) == .minimum)
        #expect(budget.update(sample(3)) == .minimum)
        #expect(budget.update(sample(33)) == .reduced)
    }
    @Test func memoryGateIsDerivedAndPreviewOnly() {
        var budget = DesktopResourceBudget(physicalMemory: 8 * 1_024 * 1_024 * 1_024)
        #expect(budget.footprintBudgetBytes == (8 * 1_024 * 1_024 * 1_024) / 5)
        _ = budget.update(sample(0, memory: budget.footprintBudgetBytes))
        #expect(budget.update(sample(3, memory: budget.footprintBudgetBytes)) == .reduced)
        #expect(budget.level.maximumFrameRate == 15 && budget.level.maximumLongEdge == 1_280)
        _ = budget.update(sample(4, thermal: 3))
        #expect(budget.level.maximumFrameRate == 5 && budget.level.maximumLongEdge == 640)
        #expect(budget.level.notice != nil)
    }
    @Test func idleGapsCannotCountAsSustainedPressureOrRecovery() {
        var budget = DesktopResourceBudget()
        _ = budget.update(sample(0, cpu: 0.9))
        _ = budget.update(sample(2, cpu: 0.9))
        budget.resetObservations()
        #expect(budget.update(sample(100, cpu: 0.9)) == .normal)
        #expect(budget.update(sample(103, cpu: 0.9)) == .reduced)
        _ = budget.update(sample(104))
        budget.resetObservations()
        #expect(budget.update(sample(500)) == .reduced)
        #expect(budget.update(sample(529)) == .reduced)
        #expect(budget.update(sample(530)) == .normal)
    }
}
