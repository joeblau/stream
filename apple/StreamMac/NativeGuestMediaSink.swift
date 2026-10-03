import Foundation

/// An inlet capability issued only after the controller has registered this
/// full lease. Media callbacks never register sources or create actor tasks.
final class NativeGuestMediaSink: @unchecked Sendable {
    let lease: GuestReceiveLease
    private let gate = NSLock()
    private let video: GuestVideoFrameStore
    private let audio: AudioMixEngine
    private var active = true
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

    /// Revocation waits for an entered receipt and clears retained output
    /// synchronously. Full-lease removal cannot touch a replacement peer.
    func close() {
        gate.lock(); defer { gate.unlock() }
        guard active else { return }
        active = false; video.remove(lease); _ = audio.removeGuest(lease)
    }
    deinit { close() }
}
