import AVFoundation
import AudioToolbox
import Combine
import CoreAudio
import CoreMedia
import os.lock

/// A07 (issue #119): playback-side counters for the monitor path — the A09
/// (feedback diagnostics) attach point. `scheduledChunks`/`playedChunks`
/// closing in on each other with `droppedChunks` flat means the monitor is
/// keeping up; a growing drop counter means the output device can't drain
/// the real-time chunk rate and the player is shedding to bound latency.
struct MonitorPlaybackStatistics: Equatable, Sendable {
    /// Chunks handed to the player node.
    var scheduledChunks: Int64 = 0
    /// Chunks the output device actually finished playing.
    var playedChunks: Int64 = 0
    /// Chunks shed because the playback queue hit its latency ceiling.
    var droppedChunks: Int64 = 0
    /// Chunks currently queued at the player node (target: ~2–4).
    var queuedDepth: Int = 0
}

/// A07 (issue #119): headphone monitoring — plays the audio engine's MONITOR
/// bus to a user-selected CoreAudio output device.
///
/// **Tap → playback path.** The `StreamController` registers one monitor-bus
/// tap for the app's lifetime; every ~10.7 ms the tap's serial queue delivers
/// a 512-frame canonical chunk (48 kHz stereo float) to the nonisolated
/// `play(_:)`, which schedules it on an `AVAudioPlayerNode` feeding the
/// engine's output. The monitor path is a TAP — a read-only fan-out of the
/// mix — never a channel: nothing on this path can re-enter the engine, so
/// monitoring can never feed back into the program mix by construction.
/// (The remaining real-world loop is ACOUSTIC — headphones bleeding into a
/// live mic; the feedback-risk warning below covers the electrical case
/// where the monitor device is also an enabled input.)
///
/// **Latency.** Engine chunk period 10.7 ms + ~2-chunk prebuffer (≈21 ms of
/// delivery-jitter absorption) + the output device's own buffer (typically
/// 5–15 ms) puts the monitor ≈35–50 ms behind the program mix. That is fine
/// for program confidence monitoring and PFL auditioning; it is NOT low
/// enough for a performer to monitor their own voice through headphones
/// (that needs hardware direct monitoring on the interface — documented,
/// not faked). The queue is capped at 6 chunks (≈64 ms): beyond that the
/// player sheds the incoming chunk (drop-new) so latency stays bounded
/// instead of growing — the same bounded-latency rule the engine's rings
/// and tap mailboxes follow.
///
/// **Device selection.** Nil selection = the system default output: the
/// output AudioUnit is aimed at the current default device and RE-aimed when
/// the HAL default changes. A specific selection pins
/// `kAudioOutputUnitProperty_CurrentDevice` on the output node (the only
/// macOS 14 API for this — there is no public `AVAudioEngine` setter, and
/// `AVAudioSession` routing is iOS-only). Anything beyond a single
/// destination — one mix to several devices at once — is OS-level routing
/// (an Aggregate/Multi-Output Device the user builds in Audio MIDI Setup);
/// those appear in the picker like any other output.
///
/// **Hot-plug (C10 rules).** The HAL device-list listener re-enumerates on
/// every change. If the pinned device disappears the monitor falls back to
/// the system default HONESTLY (`isFallbackActive` reads true in the UI)
/// and the selection is kept — when the same UID returns, the pin is
/// re-applied automatically. A different device is never substituted
/// silently.
@MainActor
final class MonitorOutput: ObservableObject {
    /// Output devices from the most recent HAL enumeration.
    @Published private(set) var devices: [MonitorOutputDevice] = []
    /// Whether monitoring is on (persisted in settings; applied live).
    @Published private(set) var isEnabled = false
    /// The selected output UID (nil = system default). Kept while the device
    /// is unplugged so its return re-applies the pin.
    @Published private(set) var selectedDeviceUID: String?
    /// True while the selected device is unplugged and the monitor is
    /// honestly playing through the system default instead.
    @Published private(set) var isFallbackActive = false
    /// The device UID the monitor is ACTUALLY playing through right now
    /// (the selection, or the system default's UID) — what the feedback-risk
    /// check compares against enabled input devices. Nil while disabled.
    @Published private(set) var effectiveDeviceUID: String?
    /// Human-readable description of the last configuration failure.
    @Published private(set) var errorMessage: String?
    /// A07/A09: playback counters (scheduled/played/dropped/queue depth).
    @Published private(set) var statistics = MonitorPlaybackStatistics()

    private let core = MonitorPlayerCore()
    private var hardwareListener: AudioHardwareListener?
    /// The HAL device the output node is currently aimed at (nil = default
    /// resolution), plus whether any configuration has been applied — the
    /// reconfigure short-circuit compares against this.
    private var appliedDeviceID: AudioDeviceID?
    private var configurationApplied = false
    private var statsTask: Task<Void, Never>?

    init() {
        refreshDevices()
        hardwareListener = AudioHardwareListener { [weak self] in
            Task { @MainActor [weak self] in
                self?.hardwareChanged()
            }
        }
    }

    /// The tap sink's entry point: called on the monitor tap's serial queue
    /// (~94 chunks/s), never on the main actor. Forwards to the lock-confined
    /// player core; a disabled monitor drops the chunk at negligible cost.
    nonisolated func play(_ sample: CMSampleBuffer) {
        core.play(sample)
    }

    /// Applies the persisted monitoring configuration live (enable/disable,
    /// device selection) — the controller calls this from settings applies
    /// and at launch. Safe to call with unchanged values (short-circuits).
    func applyConfiguration(enabled: Bool, deviceUID: String?) {
        isEnabled = enabled
        selectedDeviceUID = deviceUID
        if !enabled {
            configurationApplied = false
            appliedDeviceID = nil
            isFallbackActive = false
            effectiveDeviceUID = nil
            errorMessage = nil
            core.configure(deviceID: nil)
            stopStatsPolling()
            return
        }
        resolveAndApply()
    }

    // MARK: - Device resolution + hot-plug

    private func refreshDevices() {
        devices = MonitorOutputDevices.availableOutputs()
    }

    /// Hardware changed (device list or system default output). Re-enumerate,
    /// then re-apply the effective device — a returned selection re-pins
    /// itself, a vanished one falls back, a changed default re-aims the
    /// default-follow configuration.
    private func hardwareChanged() {
        refreshDevices()
        guard isEnabled else { return }
        resolveAndApply()
    }

    /// Resolves the selection to a HAL device (or the default) and applies it
    /// when the target actually changed. The reconfigure path restarts the
    /// output engine, so it only runs on real transitions.
    private func resolveAndApply() {
        let targetID: AudioDeviceID?
        if let uid = selectedDeviceUID {
            if let device = devices.first(where: { $0.uid == uid }) {
                targetID = device.deviceID
                isFallbackActive = false
            } else {
                // C10: honest fallback — keep the selection, play the
                // default, and SAY so until the device returns.
                targetID = nil
                isFallbackActive = true
            }
        } else {
            targetID = nil
            isFallbackActive = false
        }
        // The "default" resolution pins the CURRENT default device (the HAL
        // re-listener above re-resolves when it changes), so nil reads as
        // the live default output's id here.
        let resolvedID = targetID ?? MonitorOutputDevices.defaultOutputDeviceID()
        effectiveDeviceUID = resolvedID.flatMap { MonitorOutputDevices.deviceUID($0) }
        guard configurationApplied, resolvedID != nil, resolvedID == appliedDeviceID else {
            configurationApplied = true
            appliedDeviceID = resolvedID
            errorMessage = resolvedID == nil
                ? "No audio output device is available."
                : core.configure(deviceID: resolvedID)
            if errorMessage == nil { startStatsPolling() }
            return
        }
    }

    /// Polls the player core's counters into the published snapshot at a UI
    /// rate (~2 Hz) — cheap lock reads; A09 reads the same snapshot.
    private func startStatsPolling() {
        guard statsTask == nil else { return }
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self else { return }
                self.statistics = self.core.statistics()
            }
        }
    }

    private func stopStatsPolling() {
        statsTask?.cancel()
        statsTask = nil
        statistics = MonitorPlaybackStatistics()
    }
}

/// The off-actor playback plumbing: an `AVAudioEngine` with one
/// `AVAudioPlayerNode` fed from the monitor tap's serial queue. Every entry
/// point is lock-confined; `scheduleBuffer`/completion-handler accounting is
/// the only cross-thread state. `@unchecked Sendable` is sound for the same
/// reason as the codebase's other lock-confined boxes (PublisherBox et al.).
private final class MonitorPlayerCore: @unchecked Sendable {
    /// Playback queue ceiling: 6 chunks ≈ 64 ms. Past this the player sheds
    /// the INCOMING chunk (drop-new) — latency stays bounded; the listener
    /// hears a momentary gap rather than a growing delay.
    static let maxQueuedBuffers = 6
    /// Chunks queued before playback starts (~21 ms): absorbs tap-delivery
    /// jitter so the first audible chunk isn't a torn edge.
    static let prebufferBuffers = 2

    private var lock = os_unfair_lock_s()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                       sampleRate: 48_000,
                                       channels: 2,
                                       interleaved: true)!
    private var attached = false
    private var enabled = false
    private var isPlaying = false
    private var queuedDepth = 0
    private var scheduled: Int64 = 0
    private var played: Int64 = 0
    private var dropped: Int64 = 0

    /// Tap-queue entry point (~94 calls/s). Converts the canonical chunk to
    /// a player buffer and queues it, dropping new chunks past the latency
    /// ceiling. Never blocks, never touches the main actor.
    func play(_ sample: CMSampleBuffer) {
        os_unfair_lock_lock(&lock)
        let isEnabled = enabled
        let depth = queuedDepth
        os_unfair_lock_unlock(&lock)
        guard isEnabled, depth < Self.maxQueuedBuffers else {
            if isEnabled { noteDropped() }
            return
        }
        let frames = Int(CMSampleBufferGetNumSamples(sample))
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(frames))
        else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sample, at: 0, frameCount: Int32(frames),
            into: buffer.mutableAudioBufferList) == noErr
        else { return }

        os_unfair_lock_lock(&lock)
        queuedDepth += 1
        scheduled += 1
        let shouldStart = !isPlaying && queuedDepth >= Self.prebufferBuffers
        if shouldStart { isPlaying = true }
        os_unfair_lock_unlock(&lock)

        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [self] _ in
            os_unfair_lock_lock(&lock)
            played += 1
            queuedDepth = max(0, queuedDepth - 1)
            os_unfair_lock_unlock(&lock)
        }
        if shouldStart { player.play() }
    }

    /// (Re)configures the output path: `deviceID` nil = stop; otherwise aim
    /// the output node at the device and start the engine. Returns an error
    /// description on failure. Called on the main actor.
    func configure(deviceID: AudioDeviceID?) -> String? {
        os_unfair_lock_lock(&lock)
        enabled = deviceID != nil
        isPlaying = false
        queuedDepth = 0
        scheduled = 0
        played = 0
        dropped = 0
        os_unfair_lock_unlock(&lock)

        player.stop()
        engine.stop()
        guard let deviceID else { return nil }

        // The only macOS 14 device-selection API for AVAudioEngine: pin the
        // output AudioUnit's current device while the engine is stopped.
        guard let outputUnit = engine.outputNode.audioUnit else {
            return "The monitor output device is not available."
        }
        var target = deviceID
        let status = AudioUnitSetProperty(outputUnit,
                                          kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0,
                                          &target, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else {
            return "Could not select the monitor output device (error \(status))."
        }
        if !attached {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            attached = true
        }
        engine.prepare()
        do {
            try engine.start()
            return nil
        } catch {
            return "The monitor output could not start: \(error.localizedDescription)"
        }
    }

    func statistics() -> MonitorPlaybackStatistics {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return MonitorPlaybackStatistics(scheduledChunks: scheduled,
                                         playedChunks: played,
                                         droppedChunks: dropped,
                                         queuedDepth: queuedDepth)
    }

    private func noteDropped() {
        os_unfair_lock_lock(&lock)
        dropped += 1
        os_unfair_lock_unlock(&lock)
    }
}
