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

private final class FixtureAudioEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var status = MediaSourceStatus()
    private var count = 0
    private var statusUpdates = 0
    private var ends = 0
    private var first: Float?
    private var malformed = false
    private var rate: Double = 0
    private var channels: UInt32 = 0
    func note(_ value: MediaSourceStatus) { lock.withLock { status = value; statusUpdates += 1 } }
    func end() { lock.withLock { ends += 1 } }
    func resetFirst() { lock.withLock { first = nil } }
    func sample(_ sample: CMSampleBuffer) {
        guard let data = sample.dataBuffer else { preconditionFailure("Actual decoder PCM has no bytes") }
        var value: Float = 0
        precondition(CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: 4, destination: &value) == noErr)
        let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        let frames = CMSampleBufferGetNumSamples(sample)
        guard let format = sample.formatDescription, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format) else {
            preconditionFailure("Actual PCM has no audio format")
        }
        let actualRate = asbd.pointee.mSampleRate, actualChannels = asbd.pointee.mChannelsPerFrame
        let valid = frames > 0 && frames <= 4096 && abs(sample.duration.seconds - Double(frames) / actualRate) < 0.000001
            && sample.presentationTimeStamp.seconds > now - 0.03 && sample.presentationTimeStamp.seconds < now + 0.16
        lock.withLock { count += 1; rate = actualRate; channels = actualChannels; if first == nil { first = value }; if !valid { malformed = true } }
    }
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
        let events = FixtureAudioEvents()
        transport.onStatus = { _, status in events.note(status) }
        transport.onReachedEnd = { _, _ in events.end() }
        transport.onAudioSample = { events.sample($0) }
        transport.load()
        try await until("trimmed offline PCM ready") { events.snapshot.status.phase == .ready }
        precondition(!transport.lifecycleState().videoPlayer && transport.lifecycleState().decoder)
        transport.play(); _ = transport.pullFrame()
        precondition(abs((events.snapshot.first ?? 9) - 0.1 * sin(Float(14_400) * 0.0576)) < 0.001, "Trim-in PCM did not start at source frame14400")
        for _ in 0..<12 { _ = transport.pullFrame(); try await Task.sleep(for: .milliseconds(10)) }
        transport.pause()
        let paused = events.snapshot
        precondition((0.39...0.49).contains(paused.status.positionSeconds))
        for _ in 0..<10 { _ = transport.pullFrame(); try await Task.sleep(for: .milliseconds(10)) }
        precondition(events.snapshot.count == paused.count && events.snapshot.status.positionSeconds == paused.status.positionSeconds,
            "Paused offline source advanced its clock or emitted PCM")
        events.resetFirst(); transport.play(); _ = transport.pullFrame()
        let resumedFrame = Float((paused.status.positionSeconds * 48_000).rounded(.down))
        precondition(abs((events.snapshot.first ?? 9) - 0.1 * sin(resumedFrame * 0.0576)) < 0.001,
            "Resume skipped the source PCM buffered under the old host anchor")
        transport.pause()
        transport.seek(toSeconds: 0.65); events.resetFirst(); transport.play(); _ = transport.pullFrame()
        precondition(abs((events.snapshot.first ?? 9) - 0.1 * sin(Float(31_200) * 0.0576)) < 0.001, "Seek did not change the actual decoded source frame")
        for _ in 0..<40 { _ = transport.pullFrame(); if events.snapshot.status.phase == .ended { break }; try await Task.sleep(for: .milliseconds(10)) }
        precondition(events.snapshot.status.phase == .ended && abs(events.snapshot.status.positionSeconds - 0.9) < 0.00001 && events.snapshot.ends == 1)
        precondition(!events.snapshot.malformed, "PCM duration/frame count or shared-host-clock PTS was invalid")
        transport.play(); _ = transport.pullFrame(); transport.stop()
        precondition(events.snapshot.status.phase == .ready && events.snapshot.status.positionSeconds == 0.3)
        transport.restart(); transport.restorePausedPosition(seconds: 0.7)
        precondition(events.snapshot.status.phase == .paused && events.snapshot.status.positionSeconds == 0.7)
        fixture.configure(loops: true, end: .hold, trimIn: 0.3, trimOut: 0.9)
        transport.seek(toSeconds: 0.88); transport.play()
        for _ in 0..<8 { _ = transport.pullFrame(); try await Task.sleep(for: .milliseconds(10)) }
        precondition(events.snapshot.status.phase == .playing && events.snapshot.status.positionSeconds == 0.3 && events.snapshot.ends == 1,
            "Looping changed terminal action or failed to rewind")
        fixture.configure(loops: false, end: .stop, trimIn: 0.3, trimOut: 0.9)
        transport.seek(toSeconds: 0.88)
        for _ in 0..<20 { _ = transport.pullFrame(); if events.snapshot.status.phase == .ready { break }; try await Task.sleep(for: .milliseconds(10)) }
        precondition(events.snapshot.status.phase == .ready && events.snapshot.status.positionSeconds == 0.3 && events.snapshot.ends == 2)
        transport.play(); transport.seek(toSeconds: 0.88)
        try await until("unreferenced audition reaches end without pulling or a device player") { events.snapshot.status.phase == .ready && events.snapshot.ends == 3 }
        transport.shutdown()
        precondition(fixture.scopes == 0)
        fixture.configure(loops: true, end: .hold, trimIn: nil, trimOut: nil)
        print("PASS offline transport: actual source-frame trim/seek, paused clock/PCM hold, recovery, restart/stop, looping/HOLD/STOP and host-PTS/frame durations without AVPlayer")

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
        fixture.configure(loops: false, end: .hold, trimIn: nil, trimOut: nil); fixture.select("ramp.wav")
        let late = MediaSourcePlayback(sourceID: SourceDefinitionID()) { fixture.payload() }, lateEvents = FixtureAudioEvents()
        late.onStatus = { _, status in lateEvents.note(status) }; late.onAudioSample = { lateEvents.sample($0) }
        late.load(); try await until("delayed-pull real decoder") { lateEvents.snapshot.status.phase == .ready }
        late.play()
        for interval in [120, 250, 120] {
            if interval == 120 && lateEvents.snapshot.count > 0 { late.pause(); try await Task.sleep(for: .milliseconds(100)); late.play() }
            try await Task.sleep(for: .milliseconds(interval))
            lateEvents.resetFirst()
            let before = late.lifecycleItemPosition()!
            _ = late.pullFrame()
            let after = late.lifecycleItemPosition()!
            let sourceFrame = Double(lateEvents.snapshot.first ?? -1) * 384_000
            precondition(sourceFrame >= (before - 0.0201) * 48_000 && sourceFrame <= (after - 0.019) * 48_000 + 2,
                "Delayed pull/catch-up dropped a whole valid PCM chunk at the20ms admission boundary: frame\(sourceFrame), clock\(before)...\(after)")
            precondition(!lateEvents.snapshot.malformed)
        }
        late.shutdown(); precondition(fixture.scopes == 0)
        fixture.configure(loops: true, end: .hold, trimIn: nil, trimOut: nil)
        print("PASS delayed pulls: actual ramp PCM/source-frame and host-PTS proof covers120ms first pull,250ms starvation and delayed pause/resume without dropping a4096-frame chunk")

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
