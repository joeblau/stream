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
        _ = s.onPathProfile(ceiling: 4_000_000, seed: 4_000_000, interface: .wifi, isBaseline: true)
        s.onThermalCeiling(bitRateScale: 0.5, frameRateCap: .max)   // thermal ceiling = 3.0M
        #expect(s.effectiveMaximum == 3_000_000)                     // min(min(6M,4M),3M)
        // Lower the path below the thermal ceiling → path wins.
        _ = s.onPathProfile(ceiling: 2_000_000, seed: 2_000_000, interface: .wifi, isBaseline: false)
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
        _ = s.onPathProfile(ceiling: 6_000_000, seed: 6_000_000, interface: .wifi, isBaseline: true)
        // Learn a Wi-Fi target via a reduction.
        _ = s.onInsufficientBandwidth(bytesOutPerSecond: 400_000, queueBytesOut: 0, audioBitRate: 128_000)
        let wifiTarget = s.targetBitRate
        // Switch to cellular: cold seed = min(2.5M seed, 0.6 * clamped) = min(2.5M, 1.8M) = 1.8M.
        _ = s.onPathProfile(ceiling: 3_000_000, seed: 2_500_000, interface: .cellular, isBaseline: false)
        #expect(s.lastGoodTarget[.wifi] == wifiTarget)
        #expect(s.currentInterface == .cellular)
        #expect(s.targetBitRate == min(min(2_500_000, Int(Double(3_000_000) * 0.6)), 3_000_000))  // 1_800_000
        #expect(s.healthySeconds == 0)
        // Switch back to Wi-Fi: seed from the remembered target, not the cold seed.
        _ = s.onPathProfile(ceiling: 6_000_000, seed: 6_000_000, interface: .wifi, isBaseline: false)
        #expect(s.targetBitRate == min(wifiTarget, s.effectiveMaximum))
    }

    @Test("A raised path ceiling restarts the probe (raised uses the OLD ceiling)")
    func pathProfileRaisedRestartsProbe() {
        var s = AdaptiveBitRateState(maximumBitRate: 6_000_000, frameRate: 30)
        _ = s.onPathProfile(ceiling: 3_000_000, seed: 3_000_000, interface: .wifi, isBaseline: true)
        _ = s.onInsufficientBandwidth(bytesOutPerSecond: 300_000, queueBytesOut: 0, audioBitRate: 128_000)
        for _ in 0..<10 { _ = s.onStatus(bytesOutPerSecond: 100, queueBytesOut: 1_000) }
        #expect(s.healthySeconds > 0)
        _ = s.onPathProfile(ceiling: 5_000_000, seed: 5_000_000, interface: .wifi, isBaseline: false)   // raised
        #expect(s.healthySeconds == 0)
    }

    @Test("An interface switch cannot defeat an active thermal cap")
    func pathProfileRespectsThermalCap() {
        var s = AdaptiveBitRateState(maximumBitRate: 6_000_000, frameRate: 30)
        _ = s.onPathProfile(ceiling: 6_000_000, seed: 6_000_000, interface: .wifi, isBaseline: true)
        s.onThermalCeiling(bitRateScale: 0.5, frameRateCap: .max)   // effMax = 3M
        // Switch to a cellular link; even its conservative seed is clamped by thermal.
        _ = s.onPathProfile(ceiling: 6_000_000, seed: 2_500_000, interface: .cellular, isBaseline: false)
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

    // MARK: - EWMA throughput estimator (issue #24)

    @Test("Reduction targets raw current capacity, unaffected by a demand-inflated EWMA")
    func reductionUsesRawCapacityNotEWMA() {
        var s = AdaptiveBitRateState(maximumBitRate: 6_000_000, frameRate: 30)
        _ = s.onPathProfile(ceiling: 6_000_000, seed: 6_000_000, interface: .wifi, isBaseline: true)
        // 20 healthy ticks at ~6 Mbps (750_000 B/s * 8) drive the EWMA to the target —
        // healthy egress reflects encoder DEMAND, not link capacity.
        for _ in 0..<20 { _ = s.onStatus(bytesOutPerSecond: 750_000, queueBytesOut: 1_000) }
        #expect(s.throughput.bitsPerSecond == 6_000_000)
        // The link then collapses to 2 Mbps (250_000 B/s). The cut targets the RAW current
        // drain (true capacity during congestion), NOT the demand-inflated EWMA:
        // available = 2_000_000 - 128_000 = 1_872_000; reduced = Int(*0.65) = 1_216_800.
        // Using the EWMA here would have under-reduced to ~2.78 Mbps — the exact multi-second
        // lag issue #24 set out to eliminate (caught in adversarial review).
        let d = s.onInsufficientBandwidth(bytesOutPerSecond: 250_000, queueBytesOut: 500_000, audioBitRate: 128_000)
        #expect(s.targetBitRate == 1_216_800)
        #expect(d == ABRDecision(shouldApply: true, severe: false))
    }

    @Test("Cellular opens at the 2.5 Mbps seed with the ceiling left at the user max")
    func cellularSeedsButCeilingIsUserMax() {
        var s = AdaptiveBitRateState(maximumBitRate: 6_000_000, frameRate: 30)
        _ = s.onPathProfile(ceiling: 6_000_000, seed: 2_500_000, interface: .cellular, isBaseline: true)
        #expect(s.targetBitRate == 2_500_000)      // conservative opening bid
        #expect(s.pathSeed == 2_500_000)
        #expect(s.effectiveMaximum == 6_000_000)   // the probe MAY climb toward the user max
    }

    @Test("At the seed, the probe HOLDS without measured-throughput evidence")
    func probeHoldsAtSeedWithoutThroughput() {
        var s = AdaptiveBitRateState(maximumBitRate: 6_000_000, frameRate: 30)
        _ = s.onPathProfile(ceiling: 6_000_000, seed: 2_500_000, interface: .cellular, isBaseline: true)
        // 30 clean ticks but a low-motion encoder sends far below the target (1 KB/s).
        for _ in 0..<30 { _ = s.onStatus(bytesOutPerSecond: 1_000, queueBytesOut: 1_000) }
        #expect(s.targetBitRate == 2_500_000)   // no blind climb above the cellular seed
    }

    @Test("A strong 5G uplink lets the probe climb ABOVE the 2.5 Mbps cellular seed")
    func probeExceedsSeedWithThroughput() {
        var s = AdaptiveBitRateState(maximumBitRate: 6_000_000, frameRate: 30)
        _ = s.onPathProfile(ceiling: 6_000_000, seed: 2_500_000, interface: .cellular, isBaseline: true)
        // Sustain a clean queue AND real throughput at ~2.5 Mbps (312_500 B/s * 8).
        for _ in 0..<30 { _ = s.onStatus(bytesOutPerSecond: 312_500, queueBytesOut: 1_000) }
        #expect(s.throughput.bitsPerSecond == 2_500_000)
        // ewma (2.5M) >= 0.9*target → one step above the seed: max(75k, 6M/20 = 300k) = 300k.
        #expect(s.targetBitRate == 2_800_000)   // exceeds the old 2.5 Mbps hard cap
    }

    @Test("The above-seed probe gate nets out audio (video-vs-video)")
    func probeGateNetsAudio() {
        var s = AdaptiveBitRateState(maximumBitRate: 6_000_000, frameRate: 30)
        _ = s.onPathProfile(ceiling: 6_000_000, seed: 2_500_000, interface: .cellular, isBaseline: true)
        // Total egress 2.5 Mbps but 500 kbps is audio → video ≈ 2.0 Mbps < 0.9*2.5M = 2.25M.
        // Netting audio out, the gate HOLDS (with audio ignored it would wrongly climb).
        for _ in 0..<30 { _ = s.onStatus(bytesOutPerSecond: 312_500, queueBytesOut: 1_000, audioBitRate: 500_000) }
        #expect(s.throughput.bitsPerSecond == 2_500_000)
        #expect(s.targetBitRate == 2_500_000)   // held: video-only throughput below the bar
    }

    @Test("A 60 fps cellular stream held at the seed still restores full fps once the queue is clean")
    func cellularHeldAtSeedRestoresFrameRate() {
        var s = AdaptiveBitRateState(maximumBitRate: 6_000_000, frameRate: 60)
        _ = s.onPathProfile(ceiling: 6_000_000, seed: 2_500_000, interface: .cellular, isBaseline: true)
        // Congestion at high egress leaves the target pinned at the 2.5M seed but flags
        // congestion → 60 fps drops to 30. (reduced = 0.65*(4M-128k) = 2_516_800 ≥ seed.)
        _ = s.onInsufficientBandwidth(bytesOutPerSecond: 500_000, queueBytesOut: 500_000, audioBitRate: 128_000)
        #expect(s.targetBitRate == 2_500_000)
        #expect(s.congestionActive)
        #expect(s.currentFrameRate() == 30)
        // 30 clean low-motion ticks: the probe HOLDS at the seed (target < effMax forever),
        // but congestion must clear so fps returns to 60 — the regression the review caught.
        var clearing = ABRDecision(shouldApply: false, severe: false)
        for _ in 0..<30 { clearing = s.onStatus(bytesOutPerSecond: 1_000, queueBytesOut: 1_000) }
        #expect(s.targetBitRate == 2_500_000)          // still held at the seed
        #expect(s.targetBitRate < s.effectiveMaximum)  // below the ceiling
        #expect(s.congestionActive == false)           // cleared despite not reaching effMax
        #expect(s.currentFrameRate() == 60)            // full frame rate restored (pure state)
        // The clearing tick MUST signal an apply, or the actor never re-applies the 60 fps
        // interval and the encoder stays at 30 fps while state/HUD say 60 (review Defect B).
        #expect(clearing == ABRDecision(shouldApply: true, severe: false))
        // A subsequent held cycle should NOT keep re-applying (congestion already clear).
        var next = ABRDecision(shouldApply: false, severe: false)
        for _ in 0..<30 { next = s.onStatus(bytesOutPerSecond: 1_000, queueBytesOut: 1_000) }
        #expect(next.shouldApply == false)
    }

    @Test("A handoff to a new link drops the stale throughput estimate")
    func handoffResetsThroughput() {
        var s = AdaptiveBitRateState(maximumBitRate: 6_000_000, frameRate: 30)
        _ = s.onPathProfile(ceiling: 6_000_000, seed: 6_000_000, interface: .wifi, isBaseline: true)
        for _ in 0..<3 { _ = s.onStatus(bytesOutPerSecond: 500_000, queueBytesOut: 1_000) }
        #expect(s.throughput.bitsPerSecond > 0)
        _ = s.onPathProfile(ceiling: 6_000_000, seed: 2_500_000, interface: .cellular, isBaseline: false)
        #expect(s.throughput.bitsPerSecond == 0)      // wifi estimate can't justify probing the cell
        #expect(s.throughput.hasSample == false)
        #expect(s.pathSeed == 2_500_000)
    }
}
