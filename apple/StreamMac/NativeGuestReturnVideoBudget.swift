import Foundation

/// Bounded targets for measured guest return adaptation. Capacity estimates
/// come only from negotiated, authenticated receiver feedback.
struct NativeGuestReturnVideoProfile: Equatable, Sendable {
    let width: Int
    let height: Int
    let framesPerSecond: Int
    let maximumBitrate: Int

    static let low = Self(width: 320, height: 180, framesPerSecond: 15, maximumBitrate: 250_000)
    static let balanced = Self(width: 640, height: 360, framesPerSecond: 24, maximumBitrate: 650_000)
    static let high = Self(width: 1280, height: 720, framesPerSecond: 30, maximumBitrate: 1_500_000)
    static let all = [low, balanced, high]
    /// Quantized ceilings avoid replacing VT for every small REMB update.
    /// The codec has a4kbps floor. Actual RTP byte admission independently
    /// enforces receiver capacity, even below that encoder target.
    func constrained(capacityBitsPerSecond capacity: UInt64) -> Self? {
        guard capacity > 0 else { return nil }
        let allowed = Int(min(capacity, 100_000_000)) * 8 / 10
        let tiers = [4_000, 6_000, 8_000, 12_000, 16_000, 24_000, 32_000, 48_000, 64_000, 96_000, 128_000, 192_000, 250_000, 320_000, 480_000, 650_000, 960_000, 1_500_000]
        return Self(width: width, height: height, framesPerSecond: framesPerSecond,
            maximumBitrate: min(maximumBitrate, tiers.last(where: { $0 <= allowed }) ?? 4_000))
    }
}

/// Three bad observations lower quality one step. Eight good observations over
/// three seconds raise it one step. A two-second dwell prevents rapid toggling.
/// Observations are bounded and separated by at least 250ms. A statistics gap
/// longer than two seconds starts new stability/congestion windows.
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
                          observedFrames: Int,
                          receiverLossFraction: Double = 0,
                          senderBlocked: Bool = false) -> Bool {
        guard receiverLossFraction.isFinite, receiverLossFraction >= 0, receiverLossFraction <= 1,
              estimatedAvailableBitsPerSecond >= 0,
              estimatedAvailableBitsPerSecond <= 100_000_000,
              bufferedBytes >= 0, bufferedBytes <= 1_048_576,
              observedFrames > 0, observedFrames <= 300,
              droppedFrames >= 0, droppedFrames <= observedFrames,
              lastObservation.map({ monotonicMilliseconds > $0 && monotonicMilliseconds - $0 >= 250 }) ?? true else {
            return false
        }
        // Sampling can pause during a disconnected transport or a suspended
        // app. Advance the baseline after that gap; keeping the old baseline
        // would reject every future sample and freeze adaptation permanently.
        if let previous = lastObservation, monotonicMilliseconds - previous > 2_000 {
            badWindows = 0; goodWindows = 0; goodBegan = nil
        }
        lastObservation = monotonicMilliseconds
        let loss = max(receiverLossFraction, Double(droppedFrames) / Double(observedFrames))
        let profiles = NativeGuestReturnVideoProfile.all
        guard let index = profiles.firstIndex(of: profile) else { return false }
        let canChange = monotonicMilliseconds >= lastChange && monotonicMilliseconds - lastChange >= 2_000
        let congested = estimatedAvailableBitsPerSecond < profile.maximumBitrate
            || bufferedBytes >= 16 * 1_024 || loss >= 0.08 || senderBlocked
        if congested {
            badWindows = min(badWindows + 1, 3); goodWindows = 0; goodBegan = nil
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
        goodWindows = min(goodWindows + 1, 8)
        guard canChange, goodWindows >= 8,
              let began = goodBegan, monotonicMilliseconds - began >= 3_000 else { return false }
        profile = next
        lastChange = monotonicMilliseconds; goodWindows = 0; goodBegan = nil
        return true
    }
}

/// Whole access units consume exact packetizer RTP payload+header bytes before
/// the SDK sees any packet. This bounds attempted bytes, including failed AUs.
/// A2second burst admits a small recovery IDR without borrowing unlimited debt.
struct NativeGuestReturnVideoByteBudget: Sendable {
    private var rate: Double = 0, balance: Double = 0
    private var lastTime: UInt64?
    private(set) var limited = false
    private var maximum: Double { min(16_384, rate * 2) }
    private mutating func advance(_ now: UInt64) {
        if let lastTime, now >= lastTime { balance = min(maximum, balance + Double(now - lastTime) * rate / 1000) }
        lastTime = now
    }
    mutating func constrain(capacityBitsPerSecond: UInt64, at now: UInt64) {
        advance(now)
        rate = Double(min(capacityBitsPerSecond, 100_000_000)) / 10 //80% /8bits.
        if !limited { limited = true; balance = maximum }
        else { balance = min(balance, maximum) }
    }
    func canFit(rtpBytes: UInt32) -> Bool { !limited || Double(rtpBytes) <= maximum }
    mutating func admit(rtpBytes: UInt32, at now: UInt64) -> Bool {
        guard rtpBytes > 0 else { return false }
        guard limited else { return true }
        advance(now)
        guard Double(rtpBytes) <= balance else { return false }
        balance -= Double(rtpBytes); return true
    }
}
