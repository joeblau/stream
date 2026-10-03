import Foundation

@main
struct NativeGuestReturnVideoBudgetHarness {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }

    static func main() {
        var budget = NativeGuestReturnVideoBudget()
        require(budget.profile == .low, "start at the lowest bounded profile")
        require(!budget.observe(monotonicMilliseconds: 10_000, estimatedAvailableBitsPerSecond: 8_000_000,
                                bufferedBytes: 0, droppedFrames: 0, sentFrames: 30), "one good observation does not upshift")
        require(!budget.observe(monotonicMilliseconds: 10_100, estimatedAvailableBitsPerSecond: 8_000_000,
                                bufferedBytes: 0, droppedFrames: 0, sentFrames: 30), "too-close observation is rejected")

        var changed: [NativeGuestReturnVideoProfile] = []
        for time in stride(from: 10_500, through: 14_000, by: 500) {
            if budget.observe(monotonicMilliseconds: UInt64(time), estimatedAvailableBitsPerSecond: 8_000_000,
                              bufferedBytes: 0, droppedFrames: 0, sentFrames: 30) { changed.append(budget.profile) }
        }
        require(changed == [.balanced], "stable headroom raises one profile after hysteresis")
        for time in stride(from: 14_500, through: 18_000, by: 500) {
            if budget.observe(monotonicMilliseconds: UInt64(time), estimatedAvailableBitsPerSecond: 8_000_000,
                              bufferedBytes: 0, droppedFrames: 0, sentFrames: 30) { changed.append(budget.profile) }
        }
        require(changed == [.balanced, .high], "recovery raises only one profile at a time")
        require(budget.profile.width <= 1280 && budget.profile.height <= 720
                && budget.profile.framesPerSecond <= 30 && budget.profile.maximumBitrate <= 1_500_000,
                "all profiles remain within the declared resource ceiling")

        for time in [20_000, 20_500, 21_000] {
            let accepted = budget.observe(monotonicMilliseconds: UInt64(time), estimatedAvailableBitsPerSecond: 50_000,
                                          bufferedBytes: 128 * 1_024, droppedFrames: 5, sentFrames: 30)
            require(accepted == (time == 21_000), "sustained congestion lowers one level after three windows")
        }
        require(budget.profile == .balanced, "congestion lowers high to balanced only")
        require(!budget.observe(monotonicMilliseconds: 21_500, estimatedAvailableBitsPerSecond: 50_000,
                                bufferedBytes: 128 * 1_024, droppedFrames: 5, sentFrames: 30), "dwell prevents immediate second downshift")
        require(!budget.observe(monotonicMilliseconds: 21_400, estimatedAvailableBitsPerSecond: 100_000,
                                bufferedBytes: 0, droppedFrames: 0, sentFrames: 30), "nonmonotonic sample is rejected")
        require(!budget.observe(monotonicMilliseconds: 22_000, estimatedAvailableBitsPerSecond: 100_000_001,
                                bufferedBytes: 0, droppedFrames: 0, sentFrames: 30), "out-of-range estimate is rejected")
        print("PASS guest return video budget transitions=3 max=1280x720@30/1500000 stable-up=8/3500ms down=3 dwell=2000ms invalidSamples=2")
    }
}
