import Foundation

/// A bounded encoding target for a future guest return video sender. The
/// controller consumes caller-supplied transport observations; it does not
/// measure network capacity or create an encoder itself.
struct NativeGuestReturnVideoProfile: Equatable, Sendable {
    let width: Int
    let height: Int
    let framesPerSecond: Int
    let maximumBitrate: Int

    static let low = Self(width: 320, height: 180, framesPerSecond: 15, maximumBitrate: 250_000)
    static let balanced = Self(width: 640, height: 360, framesPerSecond: 24, maximumBitrate: 650_000)
    static let high = Self(width: 1280, height: 720, framesPerSecond: 30, maximumBitrate: 1_500_000)
    static let all = [low, balanced, high]
}

/// Three bad observations lower quality one step. Eight good observations over
/// three seconds raise it one step. A two-second dwell prevents rapid toggling.
/// Each observation is bounded and must arrive on a monotonic 250ms–2s window.
struct NativeGuestReturnVideoBudget: Sendable {
    private(set) var profile: NativeGuestReturnVideoProfile = .low
    private var lastObservation: UInt64?
    private var lastChange: UInt64 = 0
    private var badWindows = 0
    private var goodWindows = 0
    private var goodBegan: UInt64?

    @discardableResult
    mutating func observe(monotonicMilliseconds: UInt64,
                          estimatedAvailableBitsPerSecond: Int,
                          bufferedBytes: Int,
                          droppedFrames: Int,
                          sentFrames: Int) -> Bool {
        guard estimatedAvailableBitsPerSecond >= 0,
              estimatedAvailableBitsPerSecond <= 100_000_000,
              bufferedBytes >= 0, bufferedBytes <= 1_048_576,
              sentFrames > 0, sentFrames <= 300,
              droppedFrames >= 0, droppedFrames <= sentFrames,
              lastObservation.map({ monotonicMilliseconds > $0 && (250...2_000).contains(monotonicMilliseconds - $0) }) ?? true else {
            return false
        }
        lastObservation = monotonicMilliseconds
        let loss = Double(droppedFrames) / Double(sentFrames)
        let profiles = NativeGuestReturnVideoProfile.all
        guard let index = profiles.firstIndex(of: profile) else { return false }
        let canChange = monotonicMilliseconds >= lastChange && monotonicMilliseconds - lastChange >= 2_000
        let congested = estimatedAvailableBitsPerSecond < profile.maximumBitrate
            || bufferedBytes >= 96 * 1_024 || loss >= 0.08
        if congested {
            badWindows += 1; goodWindows = 0; goodBegan = nil
            guard canChange, badWindows >= 3, index > 0 else { return false }
            profile = profiles[index - 1]
            lastChange = monotonicMilliseconds; badWindows = 0
            return true
        }

        badWindows = 0
        guard index + 1 < profiles.count else { goodWindows = 0; goodBegan = nil; return false }
        let next = profiles[index + 1]
        let headroom = estimatedAvailableBitsPerSecond >= next.maximumBitrate * 17 / 10
            && bufferedBytes <= 16 * 1_024 && loss <= 0.005
        guard headroom else { goodWindows = 0; goodBegan = nil; return false }
        if goodWindows == 0 { goodBegan = monotonicMilliseconds }
        goodWindows += 1
        guard canChange, goodWindows >= 8,
              let began = goodBegan, monotonicMilliseconds - began >= 3_000 else { return false }
        profile = next
        lastChange = monotonicMilliseconds; goodWindows = 0; goodBegan = nil
        return true
    }
}
