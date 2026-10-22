import Foundation
import Testing
@testable import StreamCore

@Suite struct DesktopResourceBudgetTests {
    private func sample(_ time: Double, cpu: Double = 0, memory: UInt64 = 0, misses: Double = 0, thermal: Int = 0, failures: Double? = 0) -> DesktopResourceBudget.Observation {
        .init(time: time, cpuFraction: cpu, physicalFootprintBytes: memory, programMissFraction: misses, thermalState: thermal, programRenderFailureFraction: failures)
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
    private func counters(_ attempts: Int, failed: Int = 0, missed: Int = 0, epoch: Double = 1) -> DesktopProgramHealth.Counters {
        .init(startedAt: epoch, attempts: attempts, failed: failed, missedDeadlines: missed)
    }
    @Test func actualCounterConversionSeparatesFailedRendersFromSkippedDeadlines() {
        let health = DesktopProgramHealth.measure(counters(110, failed: 24, missed: 45),
                                                  since: counters(100, failed: 20, missed: 40))
        #expect(health.status == .observed && !health.isDiscontinuous)
        #expect(health.attempts == 10 && health.failed == 4 && health.missedDeadlines == 5)
        #expect(health.programRenderFailureFraction == 0.4)
        #expect(health.programMissFraction == 1.0 / 3.0)
    }
    @Test func fastRenderFailuresWithNoDeadlineMissesActuallyDegradePreview() {
        var budget = DesktopResourceBudget()
        var previous: DesktopProgramHealth.Counters?
        var levels: [DesktopResourceBudget.PreviewLevel] = []
        for second in 0...2 {
            let current = counters(second * 60, failed: second * 60)
            let health = DesktopProgramHealth.measure(current, since: previous)
            previous = current
            if health.isDiscontinuous { budget.resetObservations() }
            levels.append(budget.update(sample(Double(second), misses: health.programMissFraction ?? 0,
                                                failures: health.programRenderFailureFraction)))
            if second > 0 {
                #expect(health.programMissFraction == 0 && health.programRenderFailureFraction == 1)
            }
        }
        #expect(levels == [.normal, .normal, .minimum])
    }
    @Test func sustainedModerateFailurePressureUsesExistingThresholdAndHysteresis() {
        var budget = DesktopResourceBudget()
        var previous = counters(0)
        for second in 0...3 {
            let current = counters((second + 1) * 10, failed: (second + 1) * 2)
            let health = DesktopProgramHealth.measure(current, since: previous)
            previous = current
            let level = budget.update(sample(Double(second), misses: health.programMissFraction ?? 0,
                                               failures: health.programRenderFailureFraction))
            #expect(level == (second < 3 ? .normal : .reduced))
        }
        // Distinct ratios are combined by maximum, never added together.
        var combined = DesktopResourceBudget()
        #expect(combined.update(sample(0, misses: 0.06, failures: 0.06)) == .normal)
        #expect(combined.update(sample(4, misses: 0.06, failures: 0.06)) == .normal)
        #expect(combined.update(sample(5, failures: 0.10)) == .normal)
        #expect(combined.update(sample(8, failures: 0.10)) == .reduced)
    }
    @Test func unavailableRenderingInterruptsRecoveryButOtherIdlePressureStillActs() {
        var budget = DesktopResourceBudget()
        #expect(budget.update(sample(0, thermal: 3)) == .minimum)
        #expect(budget.update(sample(1)) == .minimum)
        #expect(budget.update(sample(30)) == .minimum) // 29 measured-clear seconds.
        #expect(budget.update(sample(31, failures: nil)) == .minimum)
        #expect(budget.update(sample(32)) == .minimum)
        #expect(budget.update(sample(61)) == .minimum) // Fresh 29 seconds after nil.
        #expect(budget.update(sample(62)) == .reduced)
        var idle = DesktopResourceBudget()
        #expect(idle.update(sample(0, cpu: 0.9, failures: nil)) == .normal)
        #expect(idle.update(sample(3, cpu: 0.9, failures: nil)) == .reduced)
        #expect(idle.update(sample(4, thermal: 3, failures: nil)) == .minimum)
        #expect(idle.update(sample(100, failures: nil)) == .minimum)
        #expect(idle.update(sample(130, failures: nil)) == .minimum)
        #expect(idle.update(sample(131)) == .minimum)
        #expect(idle.update(sample(161)) == .reduced)
    }
    @Test func baselinesEpochsAndCounterRollbacksCannotPretendToBeHealthyIntervals() {
        let old = counters(10, failed: 1, missed: 2)
        let baseline = DesktopProgramHealth.measure(old, since: nil)
        #expect(baseline.status == .baseline && baseline.attempts == nil)
        #expect(baseline.programMissFraction == nil && baseline.programRenderFailureFraction == nil)
        let restarted = counters(100, failed: 10, missed: 20, epoch: 2)
        let reset = DesktopProgramHealth.measure(restarted, since: old)
        #expect(reset.status == .reset && reset.programRenderFailureFraction == nil)
        let resumed = DesktopProgramHealth.measure(counters(110, failed: 11, missed: 20, epoch: 2), since: restarted)
        #expect(resumed.programRenderFailureFraction == 0.1 && resumed.programMissFraction == 0)
        for rollback in [counters(9, failed: 1, missed: 2), counters(11, failed: 0, missed: 2), counters(11, failed: 1, missed: 1)] {
            let health = DesktopProgramHealth.measure(rollback, since: old)
            #expect(health.status == .reset && health.attempts == nil)
        }
        var budget = DesktopResourceBudget()
        _ = budget.update(sample(0, thermal: 3))
        _ = budget.update(sample(1)); _ = budget.update(sample(30))
        if reset.isDiscontinuous { budget.resetObservations() }
        #expect(budget.update(sample(31, failures: reset.programRenderFailureFraction)) == .minimum)
        #expect(budget.update(sample(32)) == .minimum)
        #expect(budget.update(sample(61)) == .minimum)
        #expect(budget.update(sample(62)) == .reduced)
    }
    @Test func emptyAndMissedOnlyIntervalsDoNotInventAttemptedFrames() {
        let previous = counters(60, failed: 3, missed: 2)
        let idle = DesktopProgramHealth.measure(previous, since: previous)
        #expect(idle.status == .observed && idle.attempts == 0 && idle.failed == 0)
        #expect(idle.programRenderFailureFraction == nil && idle.programMissFraction == nil)
        let missed = DesktopProgramHealth.measure(counters(60, failed: 3, missed: 7), since: previous)
        #expect(missed.attempts == 0 && missed.missedDeadlines == 5)
        #expect(missed.programRenderFailureFraction == nil && missed.programMissFraction == 1)
        var budget = DesktopResourceBudget()
        #expect(budget.update(sample(0, misses: missed.programMissFraction!, failures: missed.programRenderFailureFraction)) == .normal)
        #expect(budget.update(sample(1, misses: missed.programMissFraction!, failures: missed.programRenderFailureFraction)) == .minimum)
    }
    @Test func malformedAndExtremeCountersHaveBoundedTruthfulResults() throws {
        for invalid in [counters(-1), counters(1, failed: -1), counters(1, failed: 2), counters(1, missed: -1),
                        counters(1, epoch: .nan), counters(1, epoch: .infinity), counters(1, epoch: -1)] {
            let health = DesktopProgramHealth.measure(invalid, since: counters(0))
            #expect(health.status == .invalid && health.programRenderFailureFraction == nil)
        }
        let impossible = DesktopProgramHealth.measure(counters(101, failed: 2), since: counters(100))
        #expect(impossible.status == .invalid && impossible.programMissFraction == nil)
        let large = DesktopProgramHealth.measure(counters(.max, failed: .max, missed: .max), since: counters(0))
        #expect(large.status == .observed && large.attempts == Int.max)
        #expect(large.programMissFraction == 0.5 && large.programRenderFailureFraction == 1)
        let encoded = try JSONEncoder().encode(DesktopProgramHealth.measure(counters(0), since: nil))
        let decoded = try JSONDecoder().decode(DesktopProgramHealth.self, from: encoded)
        #expect(decoded.status == .baseline && decoded.programRenderFailureFraction == nil)
    }
    @Test func invalidFailureFractionsCannotAdvancePolicyAndOldInitializersRemainCompatible() {
        let oldCall = DesktopResourceBudget.Observation(time: 0, cpuFraction: 0, physicalFootprintBytes: 0,
                                                       programMissFraction: 0, thermalState: 0)
        #expect(oldCall.programRenderFailureFraction == 0)
        var budget = DesktopResourceBudget()
        _ = budget.update(sample(0, thermal: 3))
        for (index, value) in [Double.nan, .infinity, -0.1, 1.1].enumerated() {
            #expect(budget.update(sample(100 + Double(index), failures: value)) == .minimum)
        }
        #expect(budget.update(sample(1)) == .minimum)
        #expect(budget.update(sample(30)) == .minimum)
        #expect(budget.update(sample(31)) == .reduced)
    }

}
