import Testing
import StreamCore

/// Unit tests for the adaptive-bitrate reduction / probe / floor policy — the
/// live-bitrate control that previously rested on manual device testing (issue #21).
/// These pin the exact arithmetic so the extraction from the publisher's actor, and
/// any future tuning, can't silently drift it.
@Suite struct AdaptiveBitRateStateTests {

    // MARK: - Floor + ceilings

    @Test("Minimum floor is the larger of 300 kbps and max/10")
    func minimumFloor() {
        #expect(AdaptiveBitRateState(maximumBitRate: 1_000_000, frameRate: 30).minimumBitRate == 300_000)
        #expect(AdaptiveBitRateState(maximumBitRate: 10_000_000, frameRate: 30).minimumBitRate == 1_000_000)
    }

    @Test("effectiveMaximum folds the path ceiling and the thermal scale live")
    func effectiveMaximumFolds() {
        var s = AdaptiveBitRateState(maximumBitRate: 6_000_000, frameRate: 30)
        _ = s.onPathProfile(ceiling: 4_000_000, interface: .wifi, isBaseline: true)
        s.onThermalCeiling(bitRateScale: 0.5, frameRateCap: .max)   // thermal ceiling = 3.0M
        #expect(s.effectiveMaximum == 3_000_000)                     // min(min(6M,4M),3M)
        // Lower the path below the thermal ceiling → path wins.
        _ = s.onPathProfile(ceiling: 2_000_000, interface: .wifi, isBaseline: false)
        #expect(s.effectiveMaximum == 2_000_000)
    }

    // MARK: - Insufficient-bandwidth reduction

    @Test("Reduction with throughput targets 65% of the available headroom")
    func reductionWithThroughput() {
        var s = AdaptiveBitRateState(maximumBitRate: 6_000_000, frameRate: 30)
        // available = 500_001*8 - 128_000 = 3_872_008; reduced = Int(3_872_008*0.65) = 2_516_805.
        let d = s.onInsufficientBandwidth(bytesOutPerSecond: 500_001, queueBytesOut: 0, audioBitRate: 128_000)
        #expect(s.targetBitRate == 2_516_805)
        #expect(d == ABRDecision(shouldApply: true, severe: false))
        #expect(s.zeroOutputSeconds == 0)
    }

    @Test("Zero throughput halves the target and flags severe")
    func reductionZeroThroughput() {
        var s = AdaptiveBitRateState(maximumBitRate: 6_000_000, frameRate: 30)
        let d = s.onInsufficientBandwidth(bytesOutPerSecond: 0, queueBytesOut: 500_000, audioBitRate: 128_000)
        #expect(s.targetBitRate == 3_000_000)   // max(600k, 6M/2)
        #expect(d.severe)
        #expect(s.zeroOutputSeconds == 1)
    }

    @Test("Reduction never drops below the minimum floor")
    func reductionClampsToFloor() {
        var s = AdaptiveBitRateState(maximumBitRate: 6_000_000, frameRate: 30)
        // bytesOut*8 <= audio → available 0 → reduced 0 → clamps to floor.
        _ = s.onInsufficientBandwidth(bytesOutPerSecond: 10_000, queueBytesOut: 0, audioBitRate: 128_000)
        #expect(s.targetBitRate == s.minimumBitRate)   // 600_000
    }

    // MARK: - Status stall + probe

    @Test("A sustained zero-output stall halves the target on the 2nd tick")
    func statusStallHalving() {
        var s = AdaptiveBitRateState(maximumBitRate: 6_000_000, frameRate: 30)
        let start = s.targetBitRate
        let first = s.onStatus(bytesOutPerSecond: 0, queueBytesOut: 50_000)
        #expect(s.zeroOutputSeconds == 1)
        #expect(first.shouldApply == false)
        #expect(s.targetBitRate == start)   // not yet
        let second = s.onStatus(bytesOutPerSecond: 0, queueBytesOut: 50_000)
        #expect(s.zeroOutputSeconds == 2)
        #expect(s.targetBitRate == start / 2)
        #expect(second == ABRDecision(shouldApply: true, severe: true))
    }

    @Test("The upward probe fires only after 30 clean ticks, one step at a time")
    func statusProbeSteps() {
        var s = AdaptiveBitRateState(maximumBitRate: 6_000_000, frameRate: 30)
        // Reduce below effMax first: available = 400_000*8 - 128_000 = 3_072_000; reduced = 1_996_800.
        _ = s.onInsufficientBandwidth(bytesOutPerSecond: 400_000, queueBytesOut: 1_000_000, audioBitRate: 128_000)
        let reduced = s.targetBitRate
        #expect(reduced == 1_996_800)
        // 29 clean ticks: no apply, just accrue health.
        for _ in 0..<29 {
            #expect(s.onStatus(bytesOutPerSecond: 100, queueBytesOut: 1_000).shouldApply == false)
        }
        #expect(s.healthySeconds == 29)
        // 30th: one probe step of max(75k, effMax/20 = 300k).
        let d = s.onStatus(bytesOutPerSecond: 100, queueBytesOut: 1_000)
        #expect(d == ABRDecision(shouldApply: true, severe: false))
        #expect(s.targetBitRate == reduced + 300_000)
        #expect(s.healthySeconds == 0)
    }

    @Test("The probe caps at effectiveMaximum and then clears congestion")
    func statusProbeCapsAndClears() {
        var s = AdaptiveBitRateState(maximumBitRate: 6_000_000, frameRate: 30)
        _ = s.onInsufficientBandwidth(bytesOutPerSecond: 400_000, queueBytesOut: 1_000_000, audioBitRate: 128_000)
        // Drive many probe cycles; target must never exceed effMax.
        for _ in 0..<40 {
            for _ in 0..<30 { _ = s.onStatus(bytesOutPerSecond: 100, queueBytesOut: 1_000) }
            #expect(s.targetBitRate <= s.effectiveMaximum)
        }
        #expect(s.targetBitRate == s.effectiveMaximum)   // 6_000_000
        #expect(s.congestionActive == false)             // cleared once pinned at the ceiling
    }

    @Test("A single status tick never both halves AND probes")
    func statusStallProbeMutuallyExclusive() {
        var s = AdaptiveBitRateState(maximumBitRate: 6_000_000, frameRate: 30)
        // Force a stall on a tick — it must reset health so the probe can't fire same-tick.
        _ = s.onStatus(bytesOutPerSecond: 0, queueBytesOut: 50_000)   // zeroOut=1
        let d = s.onStatus(bytesOutPerSecond: 0, queueBytesOut: 50_000)  // zeroOut=2 -> halve
        #expect(d.severe)                    // halving apply
        #expect(s.healthySeconds == 0)       // probe cannot have run
    }

    // MARK: - Path profile seeding

    @Test("An interface switch remembers the old target and seeds the new one")
    func pathProfileInterfaceSwitch() {
        var s = AdaptiveBitRateState(maximumBitRate: 6_000_000, frameRate: 30)
        _ = s.onPathProfile(ceiling: 6_000_000, interface: .wifi, isBaseline: true)
        // Learn a Wi-Fi target via a reduction.
        _ = s.onInsufficientBandwidth(bytesOutPerSecond: 400_000, queueBytesOut: 0, audioBitRate: 128_000)
        let wifiTarget = s.targetBitRate
        // Switch to cellular: seed = 0.6 * clamped (no prior cellular target).
        _ = s.onPathProfile(ceiling: 3_000_000, interface: .cellular, isBaseline: false)
        #expect(s.lastGoodTarget[.wifi] == wifiTarget)
        #expect(s.currentInterface == .cellular)
        #expect(s.targetBitRate == max(s.minimumBitRate, min(Int(Double(3_000_000) * 0.6), 3_000_000)))  // 1_800_000
        #expect(s.healthySeconds == 0)
        // Switch back to Wi-Fi: seed from the remembered target, not 0.6*clamped.
        _ = s.onPathProfile(ceiling: 6_000_000, interface: .wifi, isBaseline: false)
        #expect(s.targetBitRate == min(wifiTarget, s.effectiveMaximum))
    }

    @Test("A raised path ceiling restarts the probe (raised uses the OLD ceiling)")
    func pathProfileRaisedRestartsProbe() {
        var s = AdaptiveBitRateState(maximumBitRate: 6_000_000, frameRate: 30)
        _ = s.onPathProfile(ceiling: 3_000_000, interface: .wifi, isBaseline: true)
        _ = s.onInsufficientBandwidth(bytesOutPerSecond: 300_000, queueBytesOut: 0, audioBitRate: 128_000)
        for _ in 0..<10 { _ = s.onStatus(bytesOutPerSecond: 100, queueBytesOut: 1_000) }
        #expect(s.healthySeconds > 0)
        _ = s.onPathProfile(ceiling: 5_000_000, interface: .wifi, isBaseline: false)   // raised
        #expect(s.healthySeconds == 0)
    }

    @Test("An interface switch cannot defeat an active thermal cap")
    func pathProfileRespectsThermalCap() {
        var s = AdaptiveBitRateState(maximumBitRate: 6_000_000, frameRate: 30)
        _ = s.onPathProfile(ceiling: 6_000_000, interface: .wifi, isBaseline: true)
        s.onThermalCeiling(bitRateScale: 0.5, frameRateCap: .max)   // effMax = 3M
        // Pretend the cellular last-good was full rate, then switch to it.
        _ = s.onPathProfile(ceiling: 6_000_000, interface: .cellular, isBaseline: false)
        #expect(s.targetBitRate <= s.effectiveMaximum)   // 3M cap holds
    }

    // MARK: - Thermal + capture-paused + reset

    @Test("Thermal ceiling clamps the target and never touches healthySeconds")
    func thermalClampKeepsHealth() {
        var s = AdaptiveBitRateState(maximumBitRate: 6_000_000, frameRate: 30)
        _ = s.onInsufficientBandwidth(bytesOutPerSecond: 400_000, queueBytesOut: 0, audioBitRate: 128_000)
        for _ in 0..<5 { _ = s.onStatus(bytesOutPerSecond: 100, queueBytesOut: 1_000) }
        let health = s.healthySeconds
        s.onThermalCeiling(bitRateScale: 0.4, frameRateCap: 24)
        s.onThermalCeiling(bitRateScale: 0.4, frameRateCap: 24)
        #expect(s.healthySeconds == health)         // untouched across thermal calls
        #expect(s.targetBitRate <= s.effectiveMaximum)
        // Scale + cap clamp into range.
        var s2 = AdaptiveBitRateState(maximumBitRate: 6_000_000, frameRate: 30)
        s2.onThermalCeiling(bitRateScale: 5.0, frameRateCap: -3)
        #expect(s2.thermalBitRateScale == 1.0)
        #expect(s2.thermalFrameRateCap == 1)
    }

    @Test("Capture-paused events reset counters and never apply")
    func capturePausedNoApply() {
        var s = AdaptiveBitRateState(maximumBitRate: 6_000_000, frameRate: 30)
        let start = s.targetBitRate
        s.onCapturePaused(true)
        let a = s.onInsufficientBandwidth(bytesOutPerSecond: 0, queueBytesOut: 500_000, audioBitRate: 128_000)
        let b = s.onStatus(bytesOutPerSecond: 0, queueBytesOut: 500_000)
        #expect(a == ABRDecision(shouldApply: false, severe: false))
        #expect(b == ABRDecision(shouldApply: false, severe: false))
        #expect(s.targetBitRate == start)   // unchanged while paused
        #expect(s.zeroOutputSeconds == 0)
        #expect(s.healthySeconds == 0)
    }

    @Test("Reset keeps the learned target and zeroes the counters")
    func resetKeepsLearnedTarget() {
        var s = AdaptiveBitRateState(maximumBitRate: 6_000_000, frameRate: 30)
        _ = s.onInsufficientBandwidth(bytesOutPerSecond: 400_000, queueBytesOut: 500_000, audioBitRate: 128_000)
        let reduced = s.targetBitRate
        let d = s.onReset()
        #expect(s.targetBitRate == reduced)   // learned rate retained
        #expect(s.healthySeconds == 0)
        #expect(s.zeroOutputSeconds == 0)
        #expect(s.queueBytes == 0)
        #expect(d == ABRDecision(shouldApply: true, severe: false))
    }

    // MARK: - Frame interval + rate

    @Test("Severe congestion drops to the 10 fps interval")
    func frameIntervalSevere() {
        let s = AdaptiveBitRateState(maximumBitRate: 6_000_000, frameRate: 30)
        #expect(s.frameInterval(severe: true) == (1.0 / 10.0) - 0.001)
    }

    @Test("Congestion drops a 60 fps stream to the 30 fps interval, but leaves 30 fps alone")
    func frameIntervalCongestionTier() {
        var hi = AdaptiveBitRateState(maximumBitRate: 6_000_000, frameRate: 60)
        _ = hi.onInsufficientBandwidth(bytesOutPerSecond: 400_000, queueBytesOut: 0, audioBitRate: 128_000)  // congestion on
        #expect(hi.frameInterval(severe: false) == (1.0 / 30.0) - 0.001)

        var lo = AdaptiveBitRateState(maximumBitRate: 6_000_000, frameRate: 30)
        _ = lo.onInsufficientBandwidth(bytesOutPerSecond: 400_000, queueBytesOut: 0, audioBitRate: 128_000)
        #expect(lo.frameInterval(severe: false) == lo.preferredFrameInterval)   // 30fps: no >30 drop
    }

    @Test("A thermal fps cap dominates when it is more restrictive")
    func frameIntervalThermalDominates() {
        var s = AdaptiveBitRateState(maximumBitRate: 6_000_000, frameRate: 60)
        s.onThermalCeiling(bitRateScale: 1.0, frameRateCap: 5)
        #expect(s.frameInterval(severe: false) == (1.0 / 5.0) - 0.001)
    }

    @Test("currentFrameRate folds congestion + thermal caps (most restrictive wins)")
    func currentFrameRateFolds() {
        var s = AdaptiveBitRateState(maximumBitRate: 6_000_000, frameRate: 60)
        #expect(s.currentFrameRate() == 60)                    // clean
        _ = s.onInsufficientBandwidth(bytesOutPerSecond: 400_000, queueBytesOut: 0, audioBitRate: 128_000)
        #expect(s.currentFrameRate() == 30)                    // congestion drops 60 -> 30
        s.onThermalCeiling(bitRateScale: 1.0, frameRateCap: 24)
        #expect(s.currentFrameRate() == 24)                    // thermal cap wins
    }
}
