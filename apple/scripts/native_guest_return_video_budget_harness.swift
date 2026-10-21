import Foundation

@main
struct NativeGuestReturnVideoBudgetHarness {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }

    static func main() {
        require(NativeGuestReturnVideoProfile.low.constrained(capacityBitsPerSecond: 0) == nil,
            "zero capacity cannot authorize an encoding target")
        require(NativeGuestReturnVideoProfile.low.constrained(capacityBitsPerSecond: 9_968)?.maximumBitrate == 6_000,
            "application-limited static receiver capacity constrains codec without retiring usable video")
        var admission = NativeGuestReturnVideoByteBudget()
        admission.constrain(capacityBitsPerSecond: 10_000, at: 0)
        require(admission.admit(rtpBytes: 1800, at: 0), "bounded2second recovery burst")
        require(!admission.admit(rtpBytes: 300, at: 0), "a whole AU is refused before any packet overdraw")
        require(admission.admit(rtpBytes: 1000, at: 1000), "capacity replenishes only at80% of estimated bits")
        admission.constrain(capacityBitsPerSecond: 10_000, at: 1000)
        require(!admission.admit(rtpBytes: 300, at: 1000), "repeated reports do not refill the bucket")
        require(!admission.admit(rtpBytes: 2001, at: 10_000), "long idle never accumulates an unbounded burst")
        admission.constrain(capacityBitsPerSecond: 1_000, at: 10_000)
        require(!admission.admit(rtpBytes: 201, at: 10_000), "a smaller estimate immediately constrains a minimum recovery AU")
        for capacity: UInt64 in [64_000, 99_209, 250_000, 1_105_000, 3_000_000] {
            for original in NativeGuestReturnVideoProfile.all {
                let bounded = original.constrained(capacityBitsPerSecond: capacity)!
                require(bounded.maximumBitrate <= Int(capacity) * 8 / 10 && bounded.maximumBitrate <= original.maximumBitrate,
                    "encoding target leaves20% receiver capacity headroom")
                require(bounded.width == original.width && bounded.height == original.height && bounded.framesPerSecond == original.framesPerSecond,
                    "capacity constraint never increases raster or cadence")
            }
        }
        var budget = NativeGuestReturnVideoBudget()
        require(budget.profile == .low, "start at the lowest bounded profile")
        require(!budget.observe(monotonicMilliseconds: 10_000, estimatedAvailableBitsPerSecond: 8_000_000,
                                bufferedBytes: 0, droppedFrames: 0, observedFrames: 30), "one good observation does not upshift")
        require(!budget.observe(monotonicMilliseconds: 10_100, estimatedAvailableBitsPerSecond: 8_000_000,
                                bufferedBytes: 0, droppedFrames: 0, observedFrames: 30), "too-close observation is rejected")

        var changed: [NativeGuestReturnVideoProfile] = []
        for time in stride(from: 10_500, through: 14_000, by: 500) {
            if budget.observe(monotonicMilliseconds: UInt64(time), estimatedAvailableBitsPerSecond: 8_000_000,
                              bufferedBytes: 0, droppedFrames: 0, observedFrames: 30) { changed.append(budget.profile) }
        }
        require(changed == [.balanced], "stable headroom raises one profile after hysteresis")
        for time in stride(from: 14_500, through: 18_000, by: 500) {
            if budget.observe(monotonicMilliseconds: UInt64(time), estimatedAvailableBitsPerSecond: 8_000_000,
                              bufferedBytes: 0, droppedFrames: 0, observedFrames: 30) { changed.append(budget.profile) }
        }
        require(changed == [.balanced, .high], "recovery raises only one profile at a time")
        require(budget.profile.width <= 1280 && budget.profile.height <= 720
                && budget.profile.framesPerSecond <= 30 && budget.profile.maximumBitrate <= 1_500_000,
                "all profiles remain within the declared resource ceiling")

        for time in [20_000, 20_500, 21_000] {
            let accepted = budget.observe(monotonicMilliseconds: UInt64(time), estimatedAvailableBitsPerSecond: 50_000,
                                          bufferedBytes: 128 * 1_024, droppedFrames: 5, observedFrames: 30)
            require(accepted == (time == 21_000), "sustained congestion lowers one level after three windows")
        }
        require(budget.profile == .balanced, "congestion lowers high to balanced only")
        require(!budget.observe(monotonicMilliseconds: 21_500, estimatedAvailableBitsPerSecond: 50_000,
                                bufferedBytes: 128 * 1_024, droppedFrames: 5, observedFrames: 30), "dwell prevents immediate second downshift")
        require(!budget.observe(monotonicMilliseconds: 21_400, estimatedAvailableBitsPerSecond: 100_000,
                                bufferedBytes: 0, droppedFrames: 0, observedFrames: 30), "nonmonotonic sample is rejected")
        require(!budget.observe(monotonicMilliseconds: 22_000, estimatedAvailableBitsPerSecond: 100_000_001,
                                bufferedBytes: 0, droppedFrames: 0, observedFrames: 30), "out-of-range estimate is rejected")

        // A transport statistics pause must not permanently lock the controller
        // to its last observation, nor count earlier samples toward recovery.
        var resumed = NativeGuestReturnVideoBudget()
        for time in stride(from: 1_000, through: 4_000, by: 500) {
            require(!resumed.observe(monotonicMilliseconds: UInt64(time), estimatedAvailableBitsPerSecond: 8_000_000,
                                     bufferedBytes: 0, droppedFrames: 0, observedFrames: 30), "seven observations do not raise quality")
        }
        for time in stride(from: 10_000, through: 13_000, by: 500) {
            require(!resumed.observe(monotonicMilliseconds: UInt64(time), estimatedAvailableBitsPerSecond: 8_000_000,
                                     bufferedBytes: 0, droppedFrames: 0, observedFrames: 30), "a long gap starts a new stable window")
        }
        require(resumed.observe(monotonicMilliseconds: 13_500, estimatedAvailableBitsPerSecond: 8_000_000,
                                bufferedBytes: 0, droppedFrames: 0, observedFrames: 30), "fresh observations recover after a long gap")
        require(resumed.profile == .balanced, "a resumed sequence raises exactly one profile")
        for time in [14_000, 14_500, 20_000, 20_500] {
            require(!resumed.observe(monotonicMilliseconds: UInt64(time), estimatedAvailableBitsPerSecond: 50_000,
                                     bufferedBytes: 128 * 1_024, droppedFrames: 5, observedFrames: 30), "a pause resets the congestion streak")
        }
        require(resumed.observe(monotonicMilliseconds: 21_000, estimatedAvailableBitsPerSecond: 50_000,
                                bufferedBytes: 128 * 1_024, droppedFrames: 5, observedFrames: 30), "fresh congestion lowers quality after a pause")
        require(resumed.profile == .low, "congestion after resumption respects the minimum profile")
        var wireLoss = NativeGuestReturnVideoBudget()
        for time in stride(from: 30_000, through: 33_500, by: 500) {
            _ = wireLoss.observe(monotonicMilliseconds: UInt64(time), estimatedAvailableBitsPerSecond: 8_000_000,
                bufferedBytes: 0, droppedFrames: 0, observedFrames: 30)
        }
        require(wireLoss.profile == .balanced, "fresh capacity admits balanced after stability")
        for time in [36_000, 36_500, 37_000] {
            _ = wireLoss.observe(monotonicMilliseconds: UInt64(time), estimatedAvailableBitsPerSecond: 8_000_000,
                bufferedBytes: 0, droppedFrames: 0, observedFrames: 30, receiverLossFraction: 0.10)
        }
        require(wireLoss.profile == .low, "actual RR loss lowers quality despite a high capacity estimate")
        var blocked = NativeGuestReturnVideoBudget()
        for time in stride(from: 40_000, through: 43_500, by: 500) {
            _ = blocked.observe(monotonicMilliseconds: UInt64(time), estimatedAvailableBitsPerSecond: 8_000_000,
                bufferedBytes: 0, droppedFrames: 0, observedFrames: 30)
        }
        require(blocked.profile == .balanced, "sender blocked test reached balanced")
        for time in [46_000, 46_500, 47_000] {
            _ = blocked.observe(monotonicMilliseconds: UInt64(time), estimatedAvailableBitsPerSecond: 8_000_000,
                bufferedBytes: 0, droppedFrames: 0, observedFrames: 30, senderBlocked: true)
        }
        require(blocked.profile == .low, "actual SDK send backpressure lowers quality without fabricated loss")
        require(!blocked.observe(monotonicMilliseconds: 48_000, estimatedAvailableBitsPerSecond: 8_000_000,
            bufferedBytes: 0, droppedFrames: 0, observedFrames: 30, receiverLossFraction: .nan), "nonfinite wire loss rejected")
        print("PASS guest return video budget transitions=5 max=1280x720@30/1500000 stable-up=8/3500ms down=3 dwell=2000ms invalidSamples=3 resumedWindows=2")
    }
}
