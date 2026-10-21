import Foundation
import CoreMedia

final class NativeGuestProgramReturnAuthority: @unchecked Sendable {
    private let gate = NSLock()
    private var active = false, frontier = CMTime.invalid
    func change(active: Bool? = nil) {
        gate.lock(); if let active { self.active = active }
        frontier = CMClockGetTime(CMClockGetHostTimeClock()); gate.unlock()
    }
    func sendIfCurrent(_ pts: CMTime, _ send: () -> Bool) -> Bool {
        gate.lock(); defer { gate.unlock() }
        guard active, pts.isNumeric, !frontier.isNumeric || CMTimeCompare(pts, frontier) >= 0 else { return false }
        return send()
    }
}
struct NativeGuestProgramReturnSource: Sendable {
    typealias Consumer = @Sendable (CMSampleBuffer) -> Void
    let id = UUID()
    var maximumProfile: NativeGuestReturnVideoProfile = .low
    let authority: NativeGuestProgramReturnAuthority
    let install: @Sendable (UUID, @escaping Consumer) async -> Bool
    let remove: @Sendable (UUID) async -> Void
}
struct GuestReturnVideoFrame: @unchecked Sendable {
    let lease: GuestReceiveLease
    let token: UUID
    let sample: CMSampleBuffer
    var pts: CMTime { sample.presentationTimeStamp }
}

/// An inlet capability issued only after the controller has registered this
/// full lease. Media callbacks never register sources or create actor tasks.
final class NativeGuestMediaSink: @unchecked Sendable {
    let lease: GuestReceiveLease
    private let gate = NSLock()
    private let video: GuestVideoFrameStore
    private let audio: AudioMixEngine
    private var active = true
    private var returnTokens: Set<UUID> = []
    private var programReturns: [NativeInterviewReturnVideoSource: NativeGuestProgramReturnSource] = [:]
    private var returnVideoSources: [UUID: NativeGuestProgramReturnSource] = [:]
    private var selectedReturnVideoSource: NativeInterviewReturnVideoSource = .program
    private var returnVideoToken: UUID?
    private var videoRetirement: (@Sendable () -> Void)?
    private let acceptedVideo: (@Sendable (GuestVideoFrame) -> Void)?
    private let acceptedAudio: (@Sendable (GuestAudioFrame) -> Void)?

    /// Observers run synchronously inside this lease gate after acceptance.
    /// They must be bounded and must never reenter a sink, receiver or controller.
    init(registered lease: GuestReceiveLease, video: GuestVideoFrameStore, audio: AudioMixEngine,
         acceptedVideo: (@Sendable (GuestVideoFrame) -> Void)? = nil,
         acceptedAudio: (@Sendable (GuestAudioFrame) -> Void)? = nil) {
        self.lease = lease; self.video = video; self.audio = audio
        self.acceptedVideo = acceptedVideo; self.acceptedAudio = acceptedAudio
    }

    @discardableResult func receive(_ frame: GuestVideoFrame) -> Bool {
        gate.lock(); defer { gate.unlock() }
        guard active, frame.lease == lease else { return false }
        guard video.receive(frame) else { return false }
        acceptedVideo?(frame); return true
    }

    @discardableResult func receive(_ frame: GuestAudioFrame) -> Bool {
        gate.lock(); defer { gate.unlock() }
        guard active, frame.lease == lease, audio.validateGuestFrame(frame),
              video.acceptClock(lease: lease, mapping: frame.mappingGeneration) else { return false }
        guard audio.enqueueGuest(frame) else { return false }
        acceptedAudio?(frame); return true
    }

    func enableScreen(_ enabled: Bool) {
        gate.lock(); defer { gate.unlock() }
        guard active else { return }
        if enabled { video.enable(.screen, lease: lease) }
        else { video.disable(.screen, lease: lease) }
    }

    func bindProgramReturn(_ source: NativeGuestProgramReturnSource) {
        gate.lock(); defer { gate.unlock() }
        guard active, programReturns[.program] == nil else { return }
        programReturns[.program] = source
    }
    var supportsProgramReturn: Bool {
        gate.lock(); defer { gate.unlock() }; return active && programReturns[.program] != nil
    }
    func bindSecondaryReturn(_ source: NativeGuestProgramReturnSource) {
        gate.lock(); defer { gate.unlock() }
        guard active, programReturns[.secondary] == nil else { return }
        programReturns[.secondary] = source
    }
    func bindCleanReturn(_ source: NativeGuestProgramReturnSource) {
        gate.lock(); defer { gate.unlock() }
        guard active, programReturns[.clean] == nil else { return }
        programReturns[.clean] = source
    }
    var returnVideoSource: NativeInterviewReturnVideoSource {
        gate.lock(); defer { gate.unlock() }; return selectedReturnVideoSource
    }
    func selectReturnVideoSource(_ source: NativeInterviewReturnVideoSource) -> Bool {
        gate.lock(); defer { gate.unlock() }
        guard active, returnVideoToken == nil, programReturns[source] != nil else { return false }
        selectedReturnVideoSource = source; return true
    }
    func bindVideoRetirement(_ retire: @escaping @Sendable () -> Void) {
        gate.lock(); videoRetirement = retire; let closed = !active; gate.unlock()
        if closed { retire() }
    }
    func stopProgramReturn() {
        gate.lock(); returnVideoToken = nil; let retire = videoRetirement; gate.unlock(); retire?()
    }
    func videoTokenIsCurrent(_ token: UUID) -> Bool {
        gate.lock(); defer { gate.unlock() }; return active && returnVideoToken == token
    }
    func claimReturnVideo(_ token: UUID) -> Bool {
        gate.lock(); defer { gate.unlock() }
        guard active, returnVideoToken == nil, let source = programReturns[selectedReturnVideoSource] else { return false }
        returnVideoToken = token; returnVideoSources[token] = source; return true
    }
    func maximumReturnVideoProfile(_ token: UUID) -> NativeGuestReturnVideoProfile {
        gate.lock(); defer { gate.unlock() }; return returnVideoSources[token]?.maximumProfile ?? .low
    }
    private func claimedReturnVideo(_ token: UUID) -> NativeGuestProgramReturnSource? {
        gate.lock(); defer { gate.unlock() }
        guard active, returnVideoToken == token else { return nil }
        return returnVideoSources[token]
    }
    func installReturnVideo(token: UUID, sink: @escaping @Sendable (GuestReturnVideoFrame) -> Void) async -> Bool {
        guard let source = claimedReturnVideo(token) else { return false }
        guard await source.install(token, { [weak self] sample in
            guard let self else { return }; sink(.init(lease: self.lease, token: token, sample: sample))
        }) else { clearVideoToken(token); return false }
        guard retainReturnVideoToken(token, source: source.id) else { await source.remove(token); return false }
        return true
    }
    private func clearVideoToken(_ token: UUID) {
        gate.lock(); if returnVideoToken == token { returnVideoToken = nil }; gate.unlock()
    }
    func revokeReturnVideo(token: UUID) { clearVideoToken(token) }
    private func retainReturnVideoToken(_ token: UUID, source: UUID) -> Bool {
        gate.lock(); defer { gate.unlock() }
        return active && returnVideoToken == token && returnVideoSources[token]?.id == source
    }
    func removeReturnVideo(token: UUID) {
        gate.lock(); if returnVideoToken == token { returnVideoToken = nil }; let source = returnVideoSources.removeValue(forKey: token); gate.unlock()
        if let source { Task { await source.remove(token) } }
    }
    func sendReturnVideoIfCurrent(_ frame: GuestReturnVideoFrame, _ send: () -> Bool) -> Bool {
        gate.lock(); defer { gate.unlock() }
        guard active, frame.lease == lease, returnVideoToken == frame.token, let source = returnVideoSources[frame.token] else { return false }
        return source.authority.sendIfCurrent(frame.pts, send)
    }

    func installReturnAudio(token: UUID, sink: @escaping @Sendable (GuestReturnAudioFrame) -> Void) async -> Bool {
        guard returnIsActive() else { return false }
        guard await audio.addGuestReturnTap(lease, token: token, capacity: 8, sink: sink) else { return false }
        guard retainReturnToken(token) else { await audio.removeTap(token); return false }
        return true
    }
    private func returnIsActive() -> Bool { gate.lock(); defer { gate.unlock() }; return active }
    private func retainReturnToken(_ token: UUID) -> Bool {
        gate.lock(); defer { gate.unlock() }; guard active, returnTokens.count < 4 else { return false }
        returnTokens.insert(token); return true
    }
    func removeReturnAudio(token: UUID) {
        gate.lock(); let removed = returnTokens.remove(token) != nil; gate.unlock()
        if removed {
            let audio = self.audio
            Task { await audio.removeTap(token) }
        }
    }
    @discardableResult func allowReturnAudio(_ enabled: Bool) -> Bool {
        gate.lock(); defer { gate.unlock() }
        guard active else { return false }
        return audio.setGuestReturnAllowed(lease, allowed: enabled)
    }
    /// Outbound authority stays locked through the bounded public SDK send.
    /// close/revoke waits for an already-entered send and fences later work.
    func sendReturnIfCurrent(_ frame: GuestReturnAudioFrame, _ send: () -> Bool) -> Bool {
        gate.lock(); defer { gate.unlock() }
        guard active, frame.lease == lease, audio.guestReturnFrameIsCurrent(frame) else { return false }
        return send()
    }

    /// Revocation waits for an entered receipt and clears retained output
    /// synchronously. Full-lease removal cannot touch a replacement peer.
    func close() {
        gate.lock()
        guard active else { gate.unlock(); return }
        active = false; video.remove(lease); _ = audio.removeGuest(lease)
        let tokens = returnTokens; returnTokens.removeAll()
        returnVideoToken = nil
        let retire = videoRetirement; videoRetirement = nil
        gate.unlock()
        // Encoder owner retires outside the sink lock, before releasing its
        // reservation. A late installation rechecks active/token/source identity.
        retire?()
        if !tokens.isEmpty {
            let audio = self.audio
            Task { for token in tokens { await audio.removeTap(token) } }
        }
    }
    deinit { close() }
}
