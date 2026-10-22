import AVFoundation
import Foundation
import ImageIO
import CoreGraphics
import StreamCore

/// Immutable decoded PCM handed between this fixture's owned delivery threads.
final class FixtureSample: @unchecked Sendable {
    let value: CMSampleBuffer
    init(_ value: CMSampleBuffer) { self.value = value }
}

/// Exact transport and late-pull source-grid cases control time only after
/// native decoder preparation. Independent real-host PCM coverage stays real.
final class FixtureClock: @unchecked Sendable {
    static let shared = FixtureClock()
    private let lock = NSLock()
    private var controlled: CMTime?
    func now() -> CMTime { lock.withLock { controlled } ?? CMClockGetTime(CMClockGetHostTimeClock()) }
    var isControlled: Bool { lock.withLock { controlled != nil } }
    func freeze() { lock.withLock { controlled = CMClockGetTime(CMClockGetHostTimeClock()) } }
    func freezeOnNativePCMGrid() {
        lock.withLock {
            controlled = CMTimeConvertScale(CMClockGetTime(CMClockGetHostTimeClock()),
                timescale: 48_000, method: .roundTowardZero)
        }
    }
    func advanceNativePCMFrames(_ frames: Int64) {
        lock.withLock {
            precondition(controlled != nil && frames >= 0)
            controlled = controlled! + CMTime(value: frames, timescale: 48_000)
        }
    }
    func advance(seconds: Double) {
        lock.withLock {
            precondition(controlled != nil && seconds >= 0)
            controlled = controlled! + CMTime(seconds: seconds, preferredTimescale: 1_000_000_000)
        }
    }
    func restoreHostClock() { lock.withLock { controlled = nil } }
}

/// A controlled external-file ownership boundary and post-metadata suspension.
/// Asset metadata, AVPlayer, audio decoder, observers and retirement are real.
final class FixtureState: @unchecked Sendable {
    static let shared = FixtureState()
    private let lock = NSLock()
    private var root: URL!
    private var blocked: Set<String> = []
    private var entered: Set<String> = []
    private var waiting: [String: CheckedContinuation<Void, Never>] = [:]
    private var activeScopes = 0
    private var current: Data?
    private var options = MediaSourcePayload(autoplay: false)
    func configure(loops: Bool, end: MediaEndAction, trimIn: Double?, trimOut: Double?) {
        lock.withLock { options.loops = loops; options.endAction = end; options.trimInSeconds = trimIn; options.trimOutSeconds = trimOut }
    }
    private var callbacks = 0
    private var delivering = false
    private var drained = false
    func didDeliver() { lock.withLock { callbacks += 1 } }
    var deliveries: Int { lock.withLock { callbacks } }
    func beganDelivery() { lock.withLock { delivering = true } }
    var hasBegunDelivery: Bool { lock.withLock { delivering } }
    func didDrain() { lock.withLock { drained = true } }
    var hasDrained: Bool { lock.withLock { drained } }
    func install(_ root: URL) { lock.withLock { self.root = root } }
    func acquire() { lock.withLock { activeScopes += 1 } }
    func release() { lock.withLock { activeScopes -= 1; precondition(activeScopes >= 0) } }
    var scopes: Int { lock.withLock { activeScopes } }
    func block(_ name: String) { lock.withLock { _ = blocked.insert(name); entered.remove(name) } }
    func didEnter(_ name: String) -> Bool { lock.withLock { entered.contains(name) } }
    func unblock(_ name: String) {
        let pending = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            blocked.remove(name); return waiting.removeValue(forKey: name)
        }
        pending?.resume()
    }
    func waitAfterMetadata(_ name: String) async {
        await withCheckedContinuation { continuation in
            let resume = lock.withLock {
                entered.insert(name)
                if blocked.contains(name) { waiting[name] = continuation; return false }
                return true
            }
            if resume { continuation.resume() }
        }
    }
    func resolve(_ data: Data) throws -> URL {
        guard let name = String(data: data, encoding: .utf8), ["first.wav", "second.wav", "mono.aiff", "compressed.m4a", "ramp.wav", "animated.gif"].contains(name) else {
            throw CocoaError(.fileReadNoPermission)
        }
        return lock.withLock { root.appendingPathComponent(name) }
    }
    func select(_ name: String) { lock.withLock { current = Data(name.utf8) } }
    func payload() -> MediaSourcePayload? {
        lock.withLock { current.map { var payload = options; payload.bookmarkData = $0; return payload } }
    }
}

final class FixtureAudioPullTiming: @unchecked Sendable {
    static let shared = FixtureAudioPullTiming()
    private let lock = NSLock()
    private var interval: (Double, Double)?
    func note(start: CMTime, ready: CMTime) { lock.withLock { interval = (start.seconds, ready.seconds) } }
    var snapshot: (Double, Double)? { lock.withLock { interval } }
}

/// Advance the owned timeline only after the real native PCM read completed.
/// A real sleep is a minimum delay and cannot promise a partially live chunk.
final class FixtureOfflineDecodeDelay: @unchecked Sendable {
    static let shared = FixtureOfflineDecodeDelay()
    private let lock = NSLock()
    private var advanceSeconds: Double?
    func arm(seconds: Double = 0.040) { lock.withLock { advanceSeconds = seconds } }
    func afterRead() {
        let advance = lock.withLock { let value = advanceSeconds; advanceSeconds = nil; return value }
        guard let advance else { return }
        precondition(FixtureClock.shared.isControlled)
        let before = FixtureClock.shared.now()
        let frames = Int64((advance * 48_000).rounded())
        precondition(Double(frames) / 48_000 == advance)
        FixtureClock.shared.advanceNativePCMFrames(frames)
        let elapsed = (FixtureClock.shared.now() - before).seconds
        precondition(abs(elapsed - advance) < 0.000000001)
        FileHandle.standardError.write(Data("PCM OWNED DECODE ADVANCE: \(elapsed) seconds after actual native read; controlled timeline\n".utf8))
    }
}

private final class FixtureAudioEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var status = MediaSourceStatus()
    private var count = 0
    private var statusUpdates = 0
    private var ends = 0
    private var first: Float?
    private var malformed = false
    private var malformedEvidence: String?
    private var rate: Double = 0
    private var channels: UInt32 = 0
    private let usesFixtureClock: Bool
    init(usesFixtureClock: Bool = false) { self.usesFixtureClock = usesFixtureClock }
    func note(_ value: MediaSourceStatus) { lock.withLock { status = value; statusUpdates += 1 } }
    func end() { lock.withLock { ends += 1 } }
    func resetFirst() { lock.withLock { first = nil } }
    func sample(_ sample: CMSampleBuffer) {
        let entered = (usesFixtureClock ? FixtureClock.shared.now() : CMClockGetTime(CMClockGetHostTimeClock())).seconds
        guard let data = sample.dataBuffer else { preconditionFailure("Actual decoder PCM has no bytes") }
        var value: Float = 0
        precondition(CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: 4, destination: &value) == noErr)
        let now = (usesFixtureClock ? FixtureClock.shared.now() : CMClockGetTime(CMClockGetHostTimeClock())).seconds
        let frames = CMSampleBufferGetNumSamples(sample)
        guard let format = sample.formatDescription, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format) else {
            preconditionFailure("Actual PCM has no audio format")
        }
        let actualRate = asbd.pointee.mSampleRate, actualChannels = asbd.pointee.mChannelsPerFrame
        let valid = frames > 0 && frames <= 4096 && abs(sample.duration.seconds - Double(frames) / actualRate) < 0.000001
            && sample.presentationTimeStamp.seconds > now - 0.03 && sample.presentationTimeStamp.seconds < now + 0.16
        let evidence = "frames=\(frames), rate=\(actualRate), duration=\(sample.duration.seconds), expectedDuration=\(Double(frames) / actualRate), pts=\(sample.presentationTimeStamp.seconds), callbackEntry=\(entered), checkHost=\(now), ptsMinusCheck=\(sample.presentationTimeStamp.seconds - now), pullStartReady=\(String(describing: FixtureAudioPullTiming.shared.snapshot))"
        let firstFailure = lock.withLock {
            count += 1; rate = actualRate; channels = actualChannels
            if first == nil { first = value }
            guard !valid else { return false }
            malformed = true
            guard malformedEvidence == nil else { return false }
            malformedEvidence = evidence
            return true
        }
        if firstFailure { FileHandle.standardError.write(Data(("PCM FIRST MALFORMED: " + evidence + "\n").utf8)) }
    }
    var failureEvidence: String? { lock.withLock { malformedEvidence } }
    var snapshot: (status: MediaSourceStatus, count: Int, ends: Int, first: Float?, malformed: Bool, rate: Double, channels: UInt32, updates: Int) {
        lock.withLock { (status, count, ends, first, malformed, rate, channels, statusUpdates) }
    }
}

@main struct MediaPlaybackLifecycleHarness {
    @MainActor static func until(_ label: String, _ predicate: () -> Bool) async throws {
        for _ in 0..<500 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("Deadline: \(label)")
    }
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let fixture = FixtureState.shared; fixture.install(root)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 192_000)!
        pcm.frameLength = pcm.frameCapacity
        for channel in 0..<2 {
            for frame in 0..<Int(pcm.frameLength) { pcm.floatChannelData![channel][frame] = 0.1 * sin(Float(frame) * 0.0576) }
        }
        for name in ["first.wav", "second.wav"] {
            var settings = format.settings; settings[AVLinearPCMIsNonInterleaved] = false
            let file = try AVAudioFile(forWriting: root.appendingPathComponent(name), settings: settings)
            try file.write(from: pcm)
        }
        fixture.select("first.wav"); fixture.block("first.wav")
        let pending = MediaSourcePlayback(sourceID: SourceDefinitionID()) { fixture.payload() }
        pending.load(); pending.play()
        try await until("real metadata loaded") { fixture.didEnter("first.wav") }
        precondition(fixture.scopes == 1)
        pending.shutdown(); pending.shutdown()
        fixture.unblock("first.wav")
        try await until("retired asynchronous load releases its local scope") { fixture.scopes == 0 }
        pending.load(); pending.play(); pending.restart(); _ = pending.pullFrame()
        try await Task.sleep(for: .milliseconds(100))
        let dead = pending.lifecycleState()
        precondition(dead.retired && !dead.loaded && !dead.videoPlayer && !dead.decoder && !dead.pending)
        print("PASS pending retirement: real loaded metadata cannot install a player/reader or reacquire access")

        fixture.block("first.wav")
        var playback: MediaSourcePlayback? = MediaSourcePlayback(sourceID: SourceDefinitionID()) { fixture.payload() }
        playback!.load()
        try await until("relink metadata gate") { fixture.didEnter("first.wav") }
        fixture.select("second.wav"); fixture.unblock("first.wav")
        try await until("stale bookmark released") { fixture.scopes == 0 && !playback!.lifecycleState().pending }
        precondition(!playback!.lifecycleState().loaded && !playback!.lifecycleState().videoPlayer)
        playback!.load()
        try await until("replacement real offline decoder") { playback!.lifecycleState().loaded && !playback!.lifecycleState().pending }
        let live = playback!.lifecycleState()
        precondition(!live.videoPlayer && live.decoder && fixture.scopes == 1)
        playback!.onAudioSample = { _ in fixture.didDeliver() }
        let held = playback!.lifecycleHeldDelivery()!
        playback!.shutdown()
        held()
        precondition(fixture.deliveries == 0, "A captured PCM handler ran after terminal retirement")
        let stopped = playback!.lifecycleState()
        precondition(!stopped.videoPlayer && !stopped.decoder && fixture.scopes == 0)
        playback = nil
        print("PASS relink/terminal cleanup: stale asset rejected; replacement offline PCM decoder accepted then released")

        var released: MediaSourcePlayback? = MediaSourcePlayback(sourceID: SourceDefinitionID()) { fixture.payload() }
        released!.load()
        try await until("deinit real offline decoder") { released!.lifecycleState().loaded && !released!.lifecycleState().pending }
        weak var observed = released
        released = nil
        try await until("deinit releases observers and scoped resource") { observed == nil && fixture.scopes == 0 }
        print("PASS deinit: real playback and counted external-resource ownership release without explicit shutdown")

        let draining = MediaSourcePlayback(sourceID: SourceDefinitionID()) { fixture.payload() }
        let releaseDelivery = DispatchSemaphore(value: 0)
        draining.onAudioSample = { _ in
            fixture.beganDelivery(); releaseDelivery.wait(); fixture.didDeliver()
        }
        draining.load()
        try await until("drain real decoder") { draining.lifecycleState().loaded && !draining.lifecycleState().pending }
        let inFlight = draining.lifecycleHeldDelivery()!
        let emission = Task.detached { inFlight() }
        try await until("delivery begins") { fixture.hasBegunDelivery }
        let retirement = Task.detached { draining.shutdown(); fixture.didDrain() }
        try await until("retirement entered") { draining.lifecycleState().retired }
        precondition(!fixture.hasDrained, "Retirement returned before in-flight delivery drained")
        releaseDelivery.signal()
        await emission.value; await retirement.value
        inFlight()
        precondition(fixture.deliveries == 1 && fixture.scopes == 0)
        print("PASS audio drain: already-started actual PCM delivery completes before shutdown returns; held delivery cannot resurrect a channel")

        fixture.configure(loops: false, end: .hold, trimIn: 0.3, trimOut: 0.9)
        let transport = MediaSourcePlayback(sourceID: SourceDefinitionID()) { fixture.payload() }
        let events = FixtureAudioEvents(usesFixtureClock: true)
        transport.onStatus = { _, status in events.note(status) }
        transport.onReachedEnd = { _, _ in events.end() }
        transport.onAudioSample = { events.sample($0) }
        transport.load()
        try await until("trimmed offline PCM ready") { events.snapshot.status.phase == .ready }
        precondition(!transport.lifecycleState().videoPlayer && transport.lifecycleState().decoder)
        FixtureClock.shared.freeze()
        transport.play(); _ = transport.pullFrame()
        precondition(abs((events.snapshot.first ?? 9) - 0.1 * sin(Float(14_400) * 0.0576)) < 0.001, "Trim-in PCM did not start at source frame14400")
        for _ in 0..<12 { _ = transport.pullFrame(); FixtureClock.shared.advance(seconds: 0.01); await Task.yield() }
        transport.pause()
        let paused = events.snapshot
        precondition((0.39...0.49).contains(paused.status.positionSeconds))
        precondition(abs(paused.status.positionSeconds - 0.42) < 0.000001, "Exact120ms controlled clock did not freeze source at0.42s")
        print("TRACE controlled pause: original0.39...0.49 bound retained; source=\(paused.status.positionSeconds), elapsed=0.12s")
        for _ in 0..<10 { _ = transport.pullFrame(); FixtureClock.shared.advance(seconds: 0.01); await Task.yield() }
        precondition(events.snapshot.count == paused.count && events.snapshot.status.positionSeconds == paused.status.positionSeconds,
            "Paused offline source advanced its clock or emitted PCM")
        events.resetFirst(); transport.play(); _ = transport.pullFrame()
        let resumedFrame = Float((paused.status.positionSeconds * 48_000).rounded(.down))
        precondition(abs((events.snapshot.first ?? 9) - 0.1 * sin(resumedFrame * 0.0576)) < 0.001,
            "Resume skipped the source PCM buffered under the old host anchor")
        transport.pause()
        transport.seek(toSeconds: 0.65); events.resetFirst(); transport.play(); _ = transport.pullFrame()
        precondition(abs((events.snapshot.first ?? 9) - 0.1 * sin(Float(31_200) * 0.0576)) < 0.001, "Seek did not change the actual decoded source frame")
        for _ in 0..<40 { _ = transport.pullFrame(); if events.snapshot.status.phase == .ended { break }; FixtureClock.shared.advance(seconds: 0.01); await Task.yield() }
        precondition(events.snapshot.status.phase == .ended && abs(events.snapshot.status.positionSeconds - 0.9) < 0.00001 && events.snapshot.ends == 1)
        precondition(!events.snapshot.malformed, "PCM duration/frame count or shared-host-clock PTS was invalid")
        transport.play(); _ = transport.pullFrame(); transport.stop()
        precondition(events.snapshot.status.phase == .ready && events.snapshot.status.positionSeconds == 0.3)
        transport.restart(); transport.restorePausedPosition(seconds: 0.7)
        precondition(events.snapshot.status.phase == .paused && events.snapshot.status.positionSeconds == 0.7)
        fixture.configure(loops: true, end: .hold, trimIn: 0.3, trimOut: 0.9)
        transport.seek(toSeconds: 0.88); transport.play()
        FixtureClock.shared.advance(seconds: 0.03); _ = transport.pullFrame()
        precondition(events.snapshot.status.phase == .playing && events.snapshot.status.positionSeconds == 0.3 && events.snapshot.ends == 1,
            "Looping changed terminal action or failed to rewind")
        fixture.configure(loops: false, end: .stop, trimIn: 0.3, trimOut: 0.9)
        transport.seek(toSeconds: 0.88)
        for _ in 0..<20 { _ = transport.pullFrame(); if events.snapshot.status.phase == .ready { break }; FixtureClock.shared.advance(seconds: 0.01); await Task.yield() }
        precondition(events.snapshot.status.phase == .ready && events.snapshot.status.positionSeconds == 0.3 && events.snapshot.ends == 2)
        transport.shutdown()
        FixtureClock.shared.restoreHostClock()
        precondition(fixture.scopes == 0 && !FixtureClock.shared.isControlled)
        fixture.configure(loops: true, end: .hold, trimIn: nil, trimOut: nil)
        print("PASS offline transport: actual source-frame trim/seek, paused clock/PCM hold, recovery, restart/stop, looping/HOLD/STOP and host-PTS/frame durations without AVPlayer")

        // Real-clock qualification is independent of the exact controlled
        // transport assertions above. Task.sleep supplies a minimum delay;
        // observed play/pause host-time brackets define the correct position.
        fixture.configure(loops: false, end: .stop, trimIn: 0.3, trimOut: nil)
        let real = MediaSourcePlayback(sourceID: SourceDefinitionID()) { fixture.payload() }, realEvents = FixtureAudioEvents()
        real.onStatus = { _, status in realEvents.note(status) }; real.onAudioSample = { realEvents.sample($0) }
        real.onReachedEnd = { _, _ in realEvents.end() }
        real.load(); try await until("independent real-host decoder") { realEvents.snapshot.status.phase == .ready }
        precondition(!FixtureClock.shared.isControlled)
        let playHostBefore = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        real.play()
        let playHostAfter = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        _ = real.pullFrame()
        for _ in 0..<12 { _ = real.pullFrame(); try await Task.sleep(for: .milliseconds(10)) }
        let pauseHostBefore = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        real.pause()
        let pauseHostAfter = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        let realPaused = realEvents.snapshot
        let lower = 0.3 + pauseHostBefore - playHostAfter, upper = 0.3 + pauseHostAfter - playHostBefore
        print("TRACE real host pause: source=\(realPaused.status.positionSeconds), expected=\(lower)...\(upper), elapsed=\(pauseHostBefore-playHostAfter)...\(pauseHostAfter-playHostBefore)")
        precondition(realPaused.status.phase == .paused && realPaused.status.positionSeconds >= lower - 0.000001 && realPaused.status.positionSeconds <= upper + 0.000001,
            "Offline pause does not match the measured real host clock")
        for _ in 0..<10 { _ = real.pullFrame(); try await Task.sleep(for: .milliseconds(10)) }
        precondition(realEvents.snapshot.count == realPaused.count && realEvents.snapshot.status.positionSeconds == realPaused.status.positionSeconds,
            "Real-host pause advanced source position or emitted PCM")
        real.play(); _ = real.pullFrame()
        precondition(realEvents.snapshot.count > realPaused.count && !realEvents.snapshot.malformed,
            "Actual real-host resume supplied no correctly timed PCM")
        real.stop(); real.play(); real.seek(toSeconds: realEvents.snapshot.status.durationSeconds - 0.02)
        try await until("real-host unreferenced audition reaches end without pulling or a device player") {
            realEvents.snapshot.status.phase == .ready && realEvents.snapshot.ends == 1
        }
        precondition(realEvents.snapshot.status.positionSeconds == 0.3 && !FixtureClock.shared.isControlled)
        real.shutdown(); precondition(fixture.scopes == 0)
        print("PASS independent real clock: measured pause brackets, frozen position/PCM, resumed native PCM PTS/duration and unreferenced end observer")

        fixture.configure(loops: false, end: .hold, trimIn: nil, trimOut: nil)
        for name in ["mono.aiff", "compressed.m4a"] {
            let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
            let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 11_025)!
            pcm.frameLength = pcm.frameCapacity
            for frame in 0..<Int(pcm.frameLength) { pcm.floatChannelData![0][frame] = 0.2 * sin(Float(frame) * 0.08) }
            do {
                let settings: [String: Any] = name.hasSuffix("m4a")
                    ? [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000]
                    : [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: true]
                let file = try AVAudioFile(forWriting: root.appendingPathComponent(name), settings: settings)
                try file.write(from: pcm)
            }
            fixture.select(name)
            let playback = MediaSourcePlayback(sourceID: SourceDefinitionID()) { fixture.payload() }, samples = FixtureAudioEvents()
            playback.onStatus = { _, status in samples.note(status) }; playback.onAudioSample = { samples.sample($0) }
            playback.load(); playback.play()
            for _ in 0..<100 {
                _ = playback.pullFrame()
                if samples.snapshot.status.phase == .ended { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let receipt = samples.snapshot
            precondition(receipt.status.phase == .ended && receipt.count > 0 && !receipt.malformed && receipt.rate == 44_100 && receipt.channels == 1,
                "Actual offline compressed/AIFF decoder did not preserve native-rate mono PCM")
            precondition(!playback.lifecycleState().videoPlayer)
            playback.shutdown(); precondition(fixture.scopes == 0)
        }
        fixture.configure(loops: true, end: .hold, trimIn: nil, trimOut: nil)
        print("PASS offline formats: actual44.1k mono AIFF and AAC/M4A emit native-rate PCM and end without AVPlayer")

        do {
            let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
            let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 192_000)!
            pcm.frameLength = pcm.frameCapacity
            for frame in 0..<Int(pcm.frameLength) {
                for channel in 0..<2 { pcm.floatChannelData![channel][frame] = Float(frame) / 384_000 }
            }
            var settings = format.settings; settings[AVLinearPCMIsNonInterleaved] = false
            let file = try AVAudioFile(forWriting: root.appendingPathComponent("ramp.wav"), settings: settings)
            try file.write(from: pcm)
        }
        let admission = try MediaSourcePlayback.lifecyclePCMAdmission(root.appendingPathComponent("ramp.wav"))
        func bytes(_ sample: CMSampleBuffer) -> Data {
            let block = sample.dataBuffer!
            var data = Data(count: CMBlockBufferGetDataLength(block))
            let result = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
            precondition(result == noErr)
            return data
        }
        let original = admission.original, fresh = admission.fresh!, partial = admission.partial!
        let nativeBytes = bytes(original), bytesPerFrame = 2 * MemoryLayout<Float>.stride
        precondition(CMSampleBufferGetNumSamples(original) == 4_096 && CMSampleBufferGetNumSamples(fresh) == 4_096)
        precondition(bytes(fresh) == nativeBytes && CMTimeCompare(fresh.presentationTimeStamp, original.presentationTimeStamp) == 0)
        precondition(CMSampleBufferGetNumSamples(partial) == 2_656
            && bytes(partial) == nativeBytes.subdata(in: (1_440 * bytesPerFrame)..<nativeBytes.count),
            "PCM admission discarded or changed surviving native stereo source frames")
        precondition(CMTimeCompare(partial.presentationTimeStamp, original.presentationTimeStamp + CMTime(value: 1_440, timescale: 48_000)) == 0
            && CMTimeCompare(partial.duration, CMTime(value: 2_656, timescale: 48_000)) == 0
            && partial.decodeTimeStamp.isValid == original.decodeTimeStamp.isValid,
            "PCM range clipping changed the source time grid, native DTS validity or duration")
        let partialASBD = CMAudioFormatDescriptionGetStreamBasicDescription(partial.formatDescription!)!.pointee
        precondition(partialASBD.mSampleRate == 48_000 && partialASBD.mChannelsPerFrame == 2 && partialASBD.mBytesPerFrame == UInt32(bytesPerFrame))
        precondition(admission.expired == nil && admission.invalidClock == nil && admission.distantClock == nil)
        print("PASS PCM admission: actual4096-frame stereo ramp retains fresh native bytes; partial1440-frame removal preserves2656frames bit-for-bit and exact sourcePTS/duration/rate/channelgrid; fullyexpired/invalid/overflow clocks emit nothing")
        fixture.configure(loops: false, end: .hold, trimIn: nil, trimOut: nil); fixture.select("ramp.wav")
        let late = MediaSourcePlayback(sourceID: SourceDefinitionID()) { fixture.payload() }, lateEvents = FixtureAudioEvents(usesFixtureClock: true)
        late.onStatus = { _, status in lateEvents.note(status) }; late.onAudioSample = { lateEvents.sample($0) }
        late.load(); try await until("delayed-pull real decoder") { lateEvents.snapshot.status.phase == .ready }
        // Decoder preparation and actual file access are complete. The exact
        // source-grid regression now owns time, independently of host load.
        precondition(!FixtureClock.shared.isControlled)
        FixtureClock.shared.freezeOnNativePCMGrid()
        late.play()
        func checkFirstNativeFrame(_ label: String) {
            let itemTime = late.lifecycleItemTime()!
            let edge = itemTime - CMTime(value: 960, timescale: 48_000)
            let expected = CMTimeConvertScale(edge, timescale: 48_000, method: .roundTowardPositiveInfinity).value
            guard let first = lateEvents.snapshot.first else { preconditionFailure("\(label): no surviving PCM callback") }
            let actual = Int64((Double(first) * 384_000).rounded())
            precondition(actual == expected,
                "\(label): fresh admission lost exact native source grid: frame\(actual), expected\(expected), item\(itemTime.seconds)")
            precondition(!lateEvents.snapshot.malformed, lateEvents.failureEvidence ?? "No PCM failure evidence")
        }
        if CommandLine.arguments.contains("--decode-delay") { FixtureOfflineDecodeDelay.shared.arm() }
        for (index, interval) in [120, 250, 120, 250].enumerated() {
            if interval == 120 && lateEvents.snapshot.count > 0 {
                late.pause()
                let paused = late.lifecycleItemTime()!
                FixtureClock.shared.advanceNativePCMFrames(4_800)
                precondition(CMTimeCompare(late.lifecycleItemTime()!, paused) == 0)
                late.play()
            }
            FixtureClock.shared.advanceNativePCMFrames(Int64(interval * 48))
            lateEvents.resetFirst()
            if index == 3 { FixtureOfflineDecodeDelay.shared.arm() }
            _ = late.pullFrame()
            checkFirstNativeFrame("Controlled \(interval)ms pull/40ms partial admission")
        }
        // A 200ms decode advance expires the entire precomputed 150ms horizon.
        // Correct delivery emits nothing, then the next pull catches up on the
        // same native source grid instead of rebasing expired source samples.
        FixtureClock.shared.advanceNativePCMFrames(12_000)
        lateEvents.resetFirst()
        let countBeforeExpiry = lateEvents.snapshot.count
        let expiryStart = late.lifecycleItemTime()!
        FixtureOfflineDecodeDelay.shared.arm(seconds: 0.200)
        _ = late.pullFrame()
        precondition(CMTimeCompare(late.lifecycleItemTime()! - CMTime(value: 960, timescale: 48_000),
            expiryStart + CMTime(value: 7_200, timescale: 48_000)) > 0)
        precondition(lateEvents.snapshot.count == countBeforeExpiry && lateEvents.snapshot.first == nil,
            "Controlled 200ms decode delivered PCM after its entire 150ms horizon expired")
        _ = late.pullFrame()
        checkFirstNativeFrame("Controlled whole-horizon expiry recovery")
        late.shutdown(); precondition(fixture.scopes == 0)
        FixtureClock.shared.restoreHostClock()
        precondition(!FixtureClock.shared.isControlled)
        fixture.configure(loops: true, end: .hold, trimIn: nil, trimOut: nil)
        print("PASS controlled late pulls: actual native ramp decode;120/250ms starvation,100ms pause,40ms partial admission exact source grid;200ms whole-horizon expiry emits nothing and next pull recovers; unchanged30/160ms PTS and1us duration gates")

        fixture.configure(loops: true, end: .hold, trimIn: 0, trimOut: 0); fixture.select("first.wav")
        let empty = MediaSourcePlayback(sourceID: SourceDefinitionID()) { fixture.payload() }, emptyEvents = FixtureAudioEvents()
        empty.onStatus = { _, status in emptyEvents.note(status) }; empty.onAudioSample = { emptyEvents.sample($0) }
        empty.load(); empty.play()
        try await until("zero trim is a readable error") { emptyEvents.snapshot.status.phase == .error }
        let emptyUpdates = emptyEvents.snapshot.updates
        for _ in 0..<12 { empty.play(); empty.restart(); _ = empty.pullFrame(); try await Task.sleep(for: .milliseconds(10)) }
        precondition(emptyEvents.snapshot.status.phase == .error && emptyEvents.snapshot.count == 0 && emptyEvents.snapshot.updates == emptyUpdates
            && !empty.lifecycleState().observing && !empty.lifecycleState().decoder && fixture.scopes == 0,
            "Zero trim created decoder/clock task/status churn or retained file access")
        fixture.configure(loops: false, end: .hold, trimIn: 0, trimOut: 0.5); _ = empty.pullFrame()
        try await until("corrected trim repairs the existing source") { emptyEvents.snapshot.status.phase == .playing }
        _ = empty.pullFrame(); precondition(emptyEvents.snapshot.count > 0)
        empty.shutdown(); precondition(fixture.scopes == 0)
        fixture.configure(loops: true, end: .hold, trimIn: nil, trimOut: nil)
        print("PASS zero trim: stable readable error has no PCM/observer/status churn or retained scope; editing trim repairs the same source")

        let gifURL = root.appendingPathComponent("animated.gif")
        let destination = CGImageDestinationCreateWithURL(gifURL as CFURL, "com.compuserve.gif" as CFString, 2, nil)!
        for red in [0.2, 0.8] {
            let context = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(red: red, green: 0.1, blue: 0.3, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
            CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary)
        }
        precondition(CGImageDestinationFinalize(destination))
        fixture.select("animated.gif")
        let animated = MediaSourcePlayback(sourceID: SourceDefinitionID()) { fixture.payload() }
        animated.load()
        try await until("real animated decoder") { animated.lifecycleState().loaded && !animated.lifecycleState().pending }
        let old = animated.lifecycleAnimatedCallbacks()
        precondition(old.0 != nil && old.1 != nil)
        fixture.select("first.wav"); _ = animated.pullFrame()
        try await until("replacement after animated") { animated.lifecycleState().loaded && animated.lifecycleState().decoder && !animated.lifecycleState().pending }
        animated.onStatus = { _, _ in fixture.didDeliver() }
        animated.onReachedEnd = { _, _ in fixture.didDeliver() }
        let before = fixture.deliveries
        old.0?(animated.sourceID, MediaSourceStatus(phase: .error))
        old.1?(animated.sourceID, 1)
        precondition(fixture.deliveries == before, "Retired animated callbacks crossed the new file generation")
        animated.shutdown()
        precondition(fixture.scopes == 0)
        print("PASS animated relink: actual decoder's held status/end callbacks cannot affect replacement playback")
    }
}
