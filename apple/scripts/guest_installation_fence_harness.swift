import Foundation

private actor ControlledReturnSource {
    private var pending: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var entered: Set<UUID> = []
    private var removals: [UUID: Int] = [:]
    func install(_ token: UUID) async -> Bool {
        entered.insert(token)
        return await withCheckedContinuation { pending[token] = $0 }
    }
    func hasEntered(_ token: UUID) -> Bool { entered.contains(token) }
    func acknowledge(_ token: UUID) { pending.removeValue(forKey: token)?.resume(returning: true) }
    func remove(_ token: UUID) { removals[token, default: 0] += 1 }
    func count(_ token: UUID) -> Int { removals[token, default: 0] }
}

private func require(_ value: Bool, _ message: String) throws {
    if !value { throw NSError(domain: "GuestInstallationFence", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

@main struct GuestInstallationFenceHarness {
    static func wait(_ message: String, until condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(6)
        while !(await condition()) {
            try require(ContinuousClock.now < deadline, message)
            try await Task.sleep(for: .milliseconds(2))
        }
    }
    static func main() async {
        do { try await run() }
        catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
    }
    static func run() async throws {
        // Actual constructor only: empty registry/dictionaries and primitive
        // scratch arrays. No run/registerGuest/addChannel/PCM/DSP/device calls.
        let audio = AudioMixEngine(), video = GuestVideoFrameStore()
        let lease = GuestReceiveLease(slot: UUID(), peerID: UUID(), negotiation: UUID(), generation: 1)
        try require(video.register(lease), "Owned video lease registration failed")
        let sink = NativeGuestMediaSink(registered: lease, video: video, audio: audio)
        let controlled = ControlledReturnSource()
        sink.bindProgramReturn(.init(authority: NativeGuestProgramReturnAuthority(),
            install: { token, _ in await controlled.install(token) },
            remove: { token in await controlled.remove(token) }))
        let original = UUID(), replacement = UUID()
        try require(sink.claimReturnVideo(original), "Original return claim failed")
        let installing = Task { await sink.installReturnVideo(token: original) { _ in } }
        try await wait("Original install did not enter") { await controlled.hasEntered(original) }
        sink.revokeReturnVideo(token: original)
        try require(sink.claimReturnVideo(replacement), "Replacement return claim failed")
        let replacing = Task { await sink.installReturnVideo(token: replacement) { _ in } }
        try await wait("Replacement install did not enter") { await controlled.hasEntered(replacement) }
        await controlled.acknowledge(replacement)
        try require(await replacing.value && sink.videoTokenIsCurrent(replacement), "Replacement installation did not remain current")
        await controlled.acknowledge(original)
        try require(!(await installing.value), "Late revoked install ACK was adopted")
        let premature = await controlled.count(original)
        print("Observed original source removals before explicit codec-owner cleanup: \(premature)")
        try require(premature == 0, "Late install ACK removed source before codec owner cleanup")
        let replacementRemovals = await controlled.count(replacement)
        try require(sink.videoTokenIsCurrent(replacement) && replacementRemovals == 0,
                    "Late revoked completion removed or replaced the current return")
        print("PASS: actual sink rejects revoked late ACK without premature source/encoder-reservation cleanup")

        // This marks ONLY the controlled codec-owner cleanup boundary. No
        // NativeGuestReturnVideoSender/encoder/receiver/RTC object is created.
        sink.removeReturnVideo(token: original)
        try await wait("Explicit original cleanup did not remove its source") { await controlled.count(original) == 1 }
        sink.removeReturnVideo(token: original)
        try require(await controlled.count(original) == 1 && sink.videoTokenIsCurrent(replacement),
                    "Repeated stale cleanup removed the replacement or repeated source removal")
        try require(await controlled.count(replacement) == 0, "Original cleanup retired the replacement source")
        print("PASS: explicit owner cleanup removes the old source exactly once; stale cleanup cannot retire replacement")
        sink.removeReturnVideo(token: replacement)
        try await wait("Replacement cleanup did not finish") { await controlled.count(replacement) == 1 }
        sink.close()

        let closedVideo = GuestVideoFrameStore()
        let closedLease = GuestReceiveLease(slot: UUID(), peerID: UUID(), negotiation: UUID(), generation: 2)
        try require(closedVideo.register(closedLease), "Owned close-case lease failed")
        let closedSink = NativeGuestMediaSink(registered: closedLease, video: closedVideo, audio: audio)
        let closedSource = ControlledReturnSource(), closedToken = UUID()
        closedSink.bindProgramReturn(.init(authority: NativeGuestProgramReturnAuthority(),
            install: { token, _ in await closedSource.install(token) },
            remove: { token in await closedSource.remove(token) }))
        try require(closedSink.claimReturnVideo(closedToken), "Close-case return claim failed")
        let closingInstall = Task { await closedSink.installReturnVideo(token: closedToken) { _ in } }
        try await wait("Close-case install did not enter") { await closedSource.hasEntered(closedToken) }
        closedSink.close()
        await closedSource.acknowledge(closedToken)
        let closedInstalled = await closingInstall.value, closedPremature = await closedSource.count(closedToken)
        try require(!closedInstalled && closedPremature == 0,
                    "Closed sink's late ACK bypassed codec-owner cleanup")
        closedSink.removeReturnVideo(token: closedToken)
        try await wait("Closed sink owner cleanup did not finish") { await closedSource.count(closedToken) == 1 }
        closedSink.removeReturnVideo(token: closedToken)
        try require(await closedSource.count(closedToken) == 1, "Closed source cleanup was not exactly once")
        print("PASS: actual closed sink also preserves source ownership until explicit owner cleanup")
        print("SCOPE: actual NativeGuestMediaSink cleanup fence only; sender fence source-reviewed, not executed. No mixer clock, PCM, DSP, codec, receiver, RTC, capture, device, window or network graph.")
    }
}
