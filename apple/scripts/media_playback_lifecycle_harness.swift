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
        guard let name = String(data: data, encoding: .utf8), ["first.wav", "second.wav", "animated.gif"].contains(name) else {
            throw CocoaError(.fileReadNoPermission)
        }
        return lock.withLock { root.appendingPathComponent(name) }
    }
    func select(_ name: String) { lock.withLock { current = Data(name.utf8) } }
    func payload() -> MediaSourcePayload? {
        lock.withLock { current.map { MediaSourcePayload(bookmarkData: $0, autoplay: false) } }
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
        precondition(dead.retired && !dead.loaded && !dead.player && !dead.reader && !dead.pending)
        print("PASS pending retirement: real loaded metadata cannot install a player/reader or reacquire access")

        fixture.block("first.wav")
        var playback: MediaSourcePlayback? = MediaSourcePlayback(sourceID: SourceDefinitionID()) { fixture.payload() }
        playback!.load()
        try await until("relink metadata gate") { fixture.didEnter("first.wav") }
        fixture.select("second.wav"); fixture.unblock("first.wav")
        try await until("stale bookmark released") { fixture.scopes == 0 && !playback!.lifecycleState().pending }
        precondition(!playback!.lifecycleState().loaded && !playback!.lifecycleState().player)
        playback!.load()
        try await until("replacement real player and decoder") { playback!.lifecycleState().loaded && !playback!.lifecycleState().pending }
        let live = playback!.lifecycleState()
        precondition(live.player && live.reader && fixture.scopes == 1)
        playback!.onAudioSample = { _ in fixture.didDeliver() }
        let held = playback!.lifecycleHeldDelivery()!
        playback!.shutdown()
        held()
        precondition(fixture.deliveries == 0, "A captured PCM handler ran after terminal retirement")
        let stopped = playback!.lifecycleState()
        precondition(!stopped.player && !stopped.reader && fixture.scopes == 0)
        playback = nil
        print("PASS relink/terminal cleanup: stale asset rejected; replacement AVPlayer/reader accepted then released")

        var released: MediaSourcePlayback? = MediaSourcePlayback(sourceID: SourceDefinitionID()) { fixture.payload() }
        released!.load()
        try await until("deinit real player") { released!.lifecycleState().loaded && !released!.lifecycleState().pending }
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
        try await until("replacement after animated") { animated.lifecycleState().loaded && animated.lifecycleState().player && !animated.lifecycleState().pending }
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
