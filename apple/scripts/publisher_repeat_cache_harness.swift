import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import HaishinKit
import StreamCore

/// No timers order this proof. A real publisher actor suspends at its existing
/// mixer-configuration await, replaced only in the generated fixture copy.
final class RepeatCacheLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var ready = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        await withCheckedContinuation { next in
            lock.lock()
            if ready { lock.unlock(); next.resume() }
            else { waiting.append(next); lock.unlock() }
        }
    }
    func signal() {
        lock.lock(); ready = true; let pending = waiting; waiting.removeAll(); lock.unlock()
        for next in pending { next.resume() }
    }
}
final class RepeatCacheGate: Sendable {
    let entered = RepeatCacheLatch()
    let released = RepeatCacheLatch()
}
actor OwnedRepeatMedia {
    static let shared = OwnedRepeatMedia()
    struct Event: Codable, Equatable, Sendable {
        var kind: String
        var pts: Double? = nil
        var duration: Double? = nil
        var durationIsNumeric: Bool? = nil
        var frames: Int? = nil
        var program: Bool? = nil
        var cache: Bool? = nil
    }
    private var events: [String: [Event]] = [:]
    private var gates: [String: RepeatCacheGate] = [:]
    func reset(_ publisher: String) { events[publisher] = []; gates[publisher] = nil }
    func arm(_ publisher: String) -> RepeatCacheGate {
        let gate = RepeatCacheGate(); gates[publisher] = gate; return gate
    }
    func configure(_ publisher: String, program: Bool, cache: Bool) async {
        events[publisher, default: []].append(.init(kind: "configuration", program: program, cache: cache))
        if let gate = gates[publisher] { gate.entered.signal(); await gate.released.wait() }
    }
    func video(_ publisher: String, pts: Double, duration: Double) {
        events[publisher, default: []].append(.init(kind: "video", pts: pts,
            duration: duration.isFinite ? duration : nil, durationIsNumeric: duration.isFinite))
    }
    func audio(_ publisher: String, pts: Double, frames: Int, planar: Bool) {
        events[publisher, default: []].append(.init(kind: planar ? "planar-audio" : "audio", pts: pts, frames: frames))
    }
    func snapshot(_ publisher: String) -> [Event] { events[publisher] ?? [] }
}

/// Satisfies the production SessionPublisher's actual stream-presence guard.
/// No method may be used: the selected SDK media effects are separately inert.
actor RepeatCacheInertStream: StreamConvertible {
    var readyState: StreamReadyState { preconditionFailure("Unexpected stream state read") }
    var soundTransform: SoundTransform? { get async { preconditionFailure("Unexpected sound transform") } }
    var audioSettings: AudioCodecSettings { preconditionFailure("Unexpected codec settings") }
    var videoSettings: VideoCodecSettings { preconditionFailure("Unexpected codec settings") }
    var videoTrackId: UInt8? { get async { preconditionFailure("Unexpected track read") } }
    var audioTrackId: UInt8? { get async { preconditionFailure("Unexpected track read") } }
    func setBitRateStrategy(_ value: (some StreamBitRateStrategy)?) { preconditionFailure("Unexpected strategy") }
    func setAudioSettings(_ value: AudioCodecSettings) throws { preconditionFailure("Unexpected audio settings") }
    func setVideoSettings(_ value: VideoCodecSettings) throws { preconditionFailure("Unexpected video settings") }
    func setSoundTransform(_ value: SoundTransform) async { preconditionFailure("Unexpected sound transform") }
    func setVideoInputBufferCounts(_ value: Int) { preconditionFailure("Unexpected input change") }
    func append(_ value: CMSampleBuffer) { preconditionFailure("Unexpected stream append") }
    func append(_ value: AVAudioBuffer, when: AVAudioTime) { preconditionFailure("Unexpected stream append") }
    func attachAudioPlayer(_ value: AudioPlayer?) async { preconditionFailure("Unexpected player") }
    func addOutput(_ value: some StreamOutput) { preconditionFailure("Unexpected observer") }
    func removeOutput(_ value: some StreamOutput) { preconditionFailure("Unexpected observer") }
    func dispatch(_ value: NetworkMonitorEvent) async { preconditionFailure("Unexpected network event") }
    nonisolated func mixer(_ mixer: MediaMixer, didOutput sampleBuffer: CMSampleBuffer) { preconditionFailure("Unexpected mixer") }
    nonisolated func mixer(_ mixer: MediaMixer, didOutput buffer: AVAudioPCMBuffer, when: AVAudioTime) { preconditionFailure("Unexpected mixer") }
    func selectTrack(_ id: UInt8?, mediaType: CMFormatDescription.MediaType) async { preconditionFailure("Unexpected track selection") }
}

struct RepeatCacheState: Codable, Sendable {
    var program: Bool
    var cached: Bool
    var lastPTS: Double?
}
protocol RepeatCachePublisher: Publisher {
    func cacheFixtureReady()
    func cacheFixtureReject(_ reason: String)
    func cacheFixtureState() -> RepeatCacheState
    func cacheFixtureRepeat() async
    func cacheFixtureClear()
    func appendProgram(_ sample: CMSampleBuffer) async
}

/// Each probe owns a one-buffer actual Core Video pool. Successful allocation
/// after an append proves the source image is reusable, not merely cache=nil.
final class RepeatCachePool: @unchecked Sendable {
    private let pool: CVPixelBufferPool
    init() {
        var value: CVPixelBufferPool?
        precondition(CVPixelBufferPoolCreate(nil, nil, [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: 16, kCVPixelBufferHeightKey: 16
        ] as CFDictionary, &value) == kCVReturnSuccess)
        pool = value!
    }
    private func allocate() -> (CVReturn, CVPixelBuffer?) {
        var value: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool,
            [kCVPixelBufferPoolAllocationThresholdKey: 1] as CFDictionary, &value)
        return (status, value)
    }
    func available() -> Bool {
        let (status, pixel) = allocate()
        precondition(status == kCVReturnSuccess || status == kCVReturnWouldExceedAllocationThreshold,
                     "Unexpected owned pixel pool result")
        return status == kCVReturnSuccess && pixel != nil
    }
    func frame(at pts: Double) -> CMSampleBuffer {
        let (status, pixel) = allocate(); precondition(status == kCVReturnSuccess)
        var format: CMVideoFormatDescription?
        precondition(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixel!, formatDescriptionOut: &format) == noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(seconds: pts, preferredTimescale: 48_000), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        precondition(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixel!,
            formatDescription: format!, sampleTiming: &timing, sampleBufferOut: &sample) == noErr)
        return sample!
    }
}

@main enum PublisherRepeatCacheHarness {
    struct Receipt: Codable {
        var publisher: String
        var test: String
        var sourcePoolAvailable: Bool
        var state: RepeatCacheState
        var events: [OwnedRepeatMedia.Event]
    }
    static func save(_ publisher: String, _ test: String, pool: RepeatCachePool,
                     actor: any RepeatCachePublisher) async throws {
        guard let root = ProcessInfo.processInfo.environment["PUBLISHER_REPEAT_RECEIPT_DIR"] else { return }
        let receipt = Receipt(publisher: publisher, test: test, sourcePoolAvailable: pool.available(),
            state: await actor.cacheFixtureState(), events: await OwnedRepeatMedia.shared.snapshot(publisher))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(receipt).write(to: URL(fileURLWithPath: root).appendingPathComponent("\(publisher)-\(test).json"), options: .atomic)
    }
    static func make(_ name: String) async -> any RepeatCachePublisher {
        await OwnedRepeatMedia.shared.reset(name)
        let publisher: any RepeatCachePublisher = name == "rtmp" ? RTMPPublisher() : SessionPublisher(protocol: .srt)
        await publisher.cacheFixtureReady()
        return publisher
    }
    static func append(_ pool: RepeatCachePool, to publisher: any RepeatCachePublisher, pts: Double) async {
        // The source sample's only fixture owner disappears when this returns.
        await publisher.appendVideo(pool.frame(at: pts))
    }
    static func audio() -> CMSampleBuffer {
        var description = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8,
            mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        precondition(CMAudioFormatDescriptionCreate(allocator: nil, asbd: &description, layoutSize: 0,
            layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr)
        var block: CMBlockBuffer?
        precondition(CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: 512 * 8,
            blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: 512 * 8,
            flags: 0, blockBufferOut: &block) == noErr)
        precondition(CMBlockBufferFillDataBytes(with: 0, blockBuffer: block!, offsetIntoDestination: 0, dataLength: 512 * 8) == noErr)
        var sample: CMSampleBuffer?
        precondition(CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block!,
            formatDescription: format!, sampleCount: 512, presentationTimeStamp: CMTime(seconds: 12, preferredTimescale: 48_000),
            packetDescriptions: nil, sampleBufferOut: &sample) == noErr)
        return sample!
    }
    static func legacy(_ name: String) async throws {
        let publisher = await make(name), first = RepeatCachePool(), replacement = RepeatCachePool()
        await append(first, to: publisher, pts: 10)
        precondition(!first.available(), "Legacy capture must retain its repeat source")
        await publisher.cacheFixtureRepeat()
        let repeats = await OwnedRepeatMedia.shared.snapshot(name)
        precondition(repeats.count == 2 && repeats.allSatisfy { $0.kind == "video" }, "Actual legacy repeat must append one new timed video")
        precondition(repeats[1].pts! > repeats[0].pts!, "Legacy repeat must advance its actual host timestamp")
        // The existing restampVideoBuffer deliberately specifies .invalid
        // duration. Preserve that behavior rather than inventing a new duration.
        precondition(repeats[0].duration == 1.0 / 30 && repeats[0].durationIsNumeric == true
            && repeats[1].duration == nil && repeats[1].durationIsNumeric == false,
            "Legacy repeat must retain its existing unspecified-duration semantics")
        await append(replacement, to: publisher, pts: CMClockGetTime(CMClockGetHostTimeClock()).seconds + 1)
        precondition(first.available() && !replacement.available(), "Legacy replacement must release only its previous source")
        try await save(name, "legacy", pool: replacement, actor: publisher)
        await publisher.cacheFixtureClear()
        precondition(replacement.available(), "Legacy cache cleanup did not release source")
        print("PASS \(name) legacy: actual append/repeat/cache replacement preserve source lifetime and timed repeat")
    }
    static func entry(_ name: String) async throws {
        let publisher = await make(name), pool = RepeatCachePool()
        await append(pool, to: publisher, pts: 10)
        for reason in ["stopped", "paused", "encoded"] {
            await publisher.cacheFixtureReject(reason)
            await publisher.appendProgram(audio())
            let state = await publisher.cacheFixtureState()
            precondition(!state.program && state.cached && !pool.available(), "Rejected Program call changed repeat mode or source ownership")
            await publisher.cacheFixtureReady()
        }
        let gate = await OwnedRepeatMedia.shared.arm(name)
        let job = Task { await publisher.appendProgram(audio()) }
        await gate.entered.wait()
        let state = await publisher.cacheFixtureState()
        try await save(name, "entry-before-config-return", pool: pool, actor: publisher)
        let available = pool.available()
        gate.released.signal(); await job.value
        precondition(state.program && !state.cached && available,
            "Program entry must release legacy repeat buffer before mixer configuration returns")
        let beforeRepeat = await OwnedRepeatMedia.shared.snapshot(name)
        await publisher.cacheFixtureRepeat()
        let afterRepeat = await OwnedRepeatMedia.shared.snapshot(name)
        precondition(afterRepeat == beforeRepeat, "Program mode entered the legacy repeat path")
        precondition(beforeRepeat.map(\.kind) == ["video", "configuration", "planar-audio"]
            && beforeRepeat.last?.pts == 12 && beforeRepeat.last?.frames == 512,
            "Program configuration/audio order or actual normalized source time changed")
        await publisher.cacheFixtureClear()
        print("PASS \(name) entry: rejected calls retain legacy cache; accepted Program releases source before held config await and preserves audio order")
    }
    static func future(_ name: String) async throws {
        let publisher = await make(name), pool = RepeatCachePool()
        await publisher.appendProgram(audio())
        await append(pool, to: publisher, pts: 13)
        try await save(name, "future", pool: pool, actor: publisher)
        let state = await publisher.cacheFixtureState()
        precondition(state.program && !state.cached && pool.available(), "Program video must not retain repeat source buffer")
        let events = await OwnedRepeatMedia.shared.snapshot(name)
        precondition(events.map(\.kind) == ["configuration", "planar-audio", "video"]
            && events.last?.pts == 13 && events.last?.duration == 1.0 / 30,
            "Actual Program video admission/normalization/duration changed")
        await publisher.cacheFixtureRepeat()
        let afterRepeat = await OwnedRepeatMedia.shared.snapshot(name)
        precondition(afterRepeat == events, "Future Program video enabled legacy repeat")
        await publisher.cacheFixtureClear()
        print("PASS \(name) future: actual Program video reaches inert media with unchanged PTS/duration and releases its source pool")
    }
    static func main() async throws {
        if CommandLine.arguments.count == 3 {
            if CommandLine.arguments[2] == "entry" { try await entry(CommandLine.arguments[1]) }
            else { try await future(CommandLine.arguments[1]) }
        } else {
            for name in ["rtmp", "session"] { try await legacy(name); try await entry(name); try await future(name) }
        }
    }
}
