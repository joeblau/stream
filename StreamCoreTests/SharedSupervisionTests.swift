import Testing
import StreamCore

/// Tests for the shared reconnect/supervision decision logic (issue #20). These
/// PIN the RTMP publisher's exact resilience constants and rules — for the first
/// time — so extracting them and adopting them in the SRT/WHIP session publisher
/// cannot silently drift the hard-won RTMP behavior.

@Suite struct ReconnectBackoffTests {
    @Test("Starts at the 1s base")
    func base() {
        #expect(ReconnectBackoff().current == 1_000_000_000)
        #expect(ReconnectBackoff.base == 1_000_000_000)
        #expect(ReconnectBackoff.cap == 30_000_000_000)
    }

    @Test("Escalate doubles up to the 30s cap and holds")
    func escalateLadder() {
        var b = ReconnectBackoff()
        let expected: [UInt64] = [2, 4, 8, 16, 30, 30, 30].map { $0 * 1_000_000_000 }
        var seen: [UInt64] = []
        for _ in expected.indices { b.escalate(); seen.append(b.current) }
        #expect(seen == expected)
    }

    @Test("Reset returns to base from any escalated state")
    func reset() {
        var b = ReconnectBackoff()
        b.escalate(); b.escalate(); b.escalate()
        #expect(b.current > ReconnectBackoff.base)
        b.reset()
        #expect(b.current == ReconnectBackoff.base)
    }

    @Test("Jitter multiplies the current delay by the injected factor")
    func jitter() {
        var b = ReconnectBackoff()
        #expect(b.jittered { 0.8 } == 800_000_000)
        #expect(b.jittered { 1.2 } == 1_200_000_000)
        b.escalate()   // current = 2s
        #expect(b.jittered { 1.0 } == 2_000_000_000)
    }
}

@Suite struct PathTransitionTests {
    private func wifi(_ name: String = "en0",
                      satisfied: Bool = true,
                      expensive: Bool = false,
                      constrained: Bool = false) -> NetworkPathSnapshot {
        NetworkPathSnapshot(isSatisfied: satisfied, interface: .wifi, interfaceName: name,
                            isExpensive: expensive, isConstrained: constrained)
    }

    @Test("First emission is the baseline: seed ceiling, no reconnect, no clock bump")
    func baseline() {
        let r = classifyPathTransition(previous: nil, snapshot: wifi())
        #expect(r.transition == .baseline)
        #expect(r.isBaseline)
        #expect(r.shouldUpdateCeiling)
        #expect(!r.bumpsPathChangeClock)
    }

    @Test("An unchanged re-emit is a no-op")
    func noOp() {
        let p = wifi()
        let r = classifyPathTransition(previous: p, snapshot: p)
        #expect(r.transition == .none)
        #expect(!r.shouldUpdateCeiling)
        #expect(!r.bumpsPathChangeClock)
    }

    @Test("A metadata-only flip updates the ceiling but NEVER bumps the path clock")
    func metadataFlipDoesNotBumpClock() {
        // Same reachability + link identity, only isExpensive changed. This is the
        // critical false-recycle guard: it must not halve the watchdog budget.
        let r = classifyPathTransition(previous: wifi(expensive: false),
                                       snapshot: wifi(expensive: true))
        #expect(r.transition == .ceilingOnly)
        #expect(r.shouldUpdateCeiling)
        #expect(!r.bumpsPathChangeClock)
    }

    @Test("Reachability loss and restore bump the clock")
    func lossAndRestore() {
        let lost = classifyPathTransition(previous: wifi(satisfied: true),
                                          snapshot: wifi(satisfied: false))
        #expect(lost.transition == .pathLost)
        #expect(lost.bumpsPathChangeClock)

        let restored = classifyPathTransition(previous: wifi(satisfied: false),
                                              snapshot: wifi(satisfied: true))
        #expect(restored.transition == .pathRestored)
        #expect(restored.bumpsPathChangeClock)
    }

    @Test("A live link-identity change is a handoff (both satisfied)")
    func liveHandoff() {
        // Same interface type, different carrying interface name.
        let r = classifyPathTransition(previous: wifi("en0"), snapshot: wifi("en1"))
        #expect(r.transition == .liveHandoff(identity: "wifi/en1"))
        #expect(r.bumpsPathChangeClock)

        // Wi-Fi -> cellular is also a handoff.
        let cell = NetworkPathSnapshot(isSatisfied: true, interface: .cellular, interfaceName: "pdp_ip0")
        let r2 = classifyPathTransition(previous: wifi("en0"), snapshot: cell)
        #expect(r2.transition == .liveHandoff(identity: "cellular/pdp_ip0"))
    }
}

@Suite struct WatchdogEvaluatorTests {
    @Test("A frozen-equal queue at/above the limit NEVER recycles (backgrounding guard)")
    func frozenEqualQueueNeverRecycles() {
        // Seed lastQueueBytes at the depth so subsequent equal reads are not "growing".
        var state = WatchdogState(lastQueueBytes: 4_000_000)
        for _ in 0..<20 {
            let d = WatchdogEvaluator.evaluate(queueBytes: 4_000_000, zeroOutputSeconds: 0,
                                               recentPathChange: false, state: &state)
            #expect(!d.shouldRecycle)
        }
        #expect(state.stalledTicks == 0)
    }

    @Test("A strictly-growing queue recycles after exactly 6 ticks")
    func growingQueueRecyclesAtSix() {
        var state = WatchdogState()
        var recycledAt: Int?
        for tick in 1...6 {
            let q = 4_000_000 + tick * 500_000   // strictly growing, all >= 4MB
            let d = WatchdogEvaluator.evaluate(queueBytes: q, zeroOutputSeconds: 0,
                                               recentPathChange: false, state: &state)
            if d.shouldRecycle { recycledAt = tick; break }
        }
        #expect(recycledAt == 6)
    }

    @Test("After a recent path change, tolerance halves — recycle at 3 ticks / 2MB")
    func recentPathChangeRecyclesAtThree() {
        var state = WatchdogState()
        var recycledAt: Int?
        for tick in 1...3 {
            let q = 2_000_000 + tick * 300_000   // growing, all >= 2MB
            let d = WatchdogEvaluator.evaluate(queueBytes: q, zeroOutputSeconds: 0,
                                               recentPathChange: true, state: &state)
            if d.shouldRecycle { recycledAt = tick; break }
        }
        #expect(recycledAt == 3)
    }

    @Test("Sustained zero-output is an independent stall signal")
    func zeroOutputStall() {
        var state = WatchdogState()
        var recycledAt: Int?
        for tick in 1...6 {
            let d = WatchdogEvaluator.evaluate(queueBytes: 0, zeroOutputSeconds: 4,
                                               recentPathChange: false, state: &state)
            if d.shouldRecycle { recycledAt = tick; break }
        }
        #expect(recycledAt == 6)
    }

    @Test("A draining queue resets the stall streak")
    func drainingResets() {
        var state = WatchdogState()
        // Build up two stalled ticks on a growing queue...
        _ = WatchdogEvaluator.evaluate(queueBytes: 4_000_000, zeroOutputSeconds: 0, recentPathChange: false, state: &state)
        _ = WatchdogEvaluator.evaluate(queueBytes: 5_000_000, zeroOutputSeconds: 0, recentPathChange: false, state: &state)
        #expect(state.stalledTicks == 2)
        // ...then a healthy small queue clears it.
        let d = WatchdogEvaluator.evaluate(queueBytes: 100_000, zeroOutputSeconds: 0, recentPathChange: false, state: &state)
        #expect(!d.shouldRecycle)
        #expect(state.stalledTicks == 0)
    }
}

@Suite struct MicStallEvaluatorTests {
    @Test("App audio fresh + mic silent past 4s promotes app to the mix clock")
    func promotesWhenMicStalls() {
        #expect(MicStallEvaluator.shouldPromoteApp(now: 10_000_000_000,
                                                   lastMicAppendAt: 5_000_000_000,   // 5s ago
                                                   lastAppAppendAt: 9_000_000_000))  // 1s ago
    }

    @Test("A mic quiet for under 4s does not promote")
    func micNotYetStalled() {
        #expect(!MicStallEvaluator.shouldPromoteApp(now: 10_000_000_000,
                                                    lastMicAppendAt: 7_000_000_000,   // 3s ago
                                                    lastAppAppendAt: 9_000_000_000))
    }

    @Test("Stale app audio does not promote (nothing to promote to)")
    func appNotFresh() {
        #expect(!MicStallEvaluator.shouldPromoteApp(now: 10_000_000_000,
                                                    lastMicAppendAt: 5_000_000_000,
                                                    lastAppAppendAt: 7_000_000_000))  // 3s ago > 2s
    }

    @Test("Thresholds are exclusive at the exact boundary")
    func boundaries() {
        // micAge exactly 4s -> not stalled (strict >); appAge exactly 2s -> not fresh (strict <).
        #expect(!MicStallEvaluator.shouldPromoteApp(now: 10_000_000_000,
                                                    lastMicAppendAt: 6_000_000_000,   // exactly 4s
                                                    lastAppAppendAt: 9_000_000_000))
        #expect(!MicStallEvaluator.shouldPromoteApp(now: 10_000_000_000,
                                                    lastMicAppendAt: 5_000_000_000,
                                                    lastAppAppendAt: 8_000_000_000))  // exactly 2s
    }
}

@Suite struct VideoFrameAdmissionTests {
    private func admitRatio(queueBytes: Int, over count: Int = 60) -> Int {
        let a = VideoFrameAdmission()
        a.setQueueDepth(queueBytes)
        var kept = 0
        for _ in 0..<count where a.admit() { kept += 1 }
        return kept
    }

    @Test("Below 0.5 MB every frame is admitted")
    func keepsAllWhenShallow() {
        #expect(admitRatio(queueBytes: 0) == 60)
        #expect(admitRatio(queueBytes: 524_287) == 60)
    }

    @Test("0.5–1 MB keeps 2 of every 3")
    func shedsOneInThree() {
        #expect(admitRatio(queueBytes: 524_288) == 40)   // 2/3 of 60
    }

    @Test("1–2 MB keeps 1 of every 2")
    func shedsHalf() {
        #expect(admitRatio(queueBytes: 1_048_576) == 30)
    }

    @Test("Above 2 MB keeps 1 of every 3")
    func shedsTwoInThree() {
        #expect(admitRatio(queueBytes: 2_097_152) == 20)
    }

    @Test("reset() returns to keep-all")
    func resetKeepsAll() {
        let a = VideoFrameAdmission()
        a.setQueueDepth(3_000_000)
        a.reset()
        var kept = 0
        for _ in 0..<30 where a.admit() { kept += 1 }
        #expect(kept == 30)
    }
}

@Suite struct NetworkPathSnapshotPolicyTests {
    private func snap(_ interface: NetworkPathSnapshot.Interface = .wifi,
                      satisfied: Bool = true,
                      name: String = "en0",
                      expensive: Bool = false,
                      constrained: Bool = false,
                      ultra: Bool = false,
                      minimal: Bool = false) -> NetworkPathSnapshot {
        NetworkPathSnapshot(isSatisfied: satisfied, interface: interface, interfaceName: name,
                            isExpensive: expensive, isConstrained: constrained,
                            isUltraConstrained: ultra, linkQualityIsMinimal: minimal)
    }

    @Test("An unsatisfied path never caps the configured maximum")
    func unsatisfiedPassesThrough() {
        #expect(snap(satisfied: false).videoBitRateCeiling(configuredMaximum: 5_000_000) == 5_000_000)
    }

    @Test("Cellular and expensive links cap at 2.5 Mbps")
    func cellularCap() {
        #expect(snap(.cellular, name: "pdp_ip0").videoBitRateCeiling(configuredMaximum: 5_000_000) == 2_500_000)
        #expect(snap(expensive: true).videoBitRateCeiling(configuredMaximum: 5_000_000) == 2_500_000)
    }

    @Test("Low Data Mode and iOS 26 link signals cap harder")
    func constrainedCaps() {
        #expect(snap(constrained: true).videoBitRateCeiling(configuredMaximum: 5_000_000) == 1_200_000)
        #expect(snap(ultra: true).videoBitRateCeiling(configuredMaximum: 5_000_000) == 800_000)
        // Minimal link quality halves the running ceiling (floored at 300k).
        #expect(snap(minimal: true).videoBitRateCeiling(configuredMaximum: 5_000_000) == 2_500_000)
    }

    @Test("linkIdentity encodes interface + carrying name; metadata flips are unequal")
    func identityAndEquality() {
        #expect(snap(name: "en0").linkIdentity == "wifi/en0")
        #expect(snap(expensive: false) != snap(expensive: true))
        #expect(snap(name: "en0") != snap(name: "en1"))
    }
}
