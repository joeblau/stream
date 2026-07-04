import AVFAudio
import os

private let keepAliveLog = Logger(subsystem: "com.joeblau.Stream",
                                  category: "broadcast-keepalive")

/// Keeps the HOST app out of `running-suspended` while a broadcast is live.
///
/// The screen broadcast runs in the `StreamBroadcast` upload extension, but the
/// live media session is attributed to this app (it launched the broadcast from
/// the in-app `RPSystemBroadcastPickerView`). When the user switches to another
/// app and iOS suspends this host process, CoreMedia's session manager stops the
/// tied broadcast session ("client is background suspended…"), which freezes the
/// out-of-process extension — its RTMP send/reconnect Tasks stop running and the
/// destination sees "Connection lost" until the app is foregrounded again.
///
/// The fix is a genuine background-execution assertion: with `UIBackgroundModes`
/// = `audio`, an AVAudioSession that is actively PLAYING keeps the host running
/// in the background. `setActive(true)` alone is not enough — audio must really
/// be flowing — so we loop a silent buffer through an `AVAudioEngine` for the
/// whole broadcast. `.mixWithOthers` keeps it inaudible and non-ducking against
/// whatever app the user is now using (e.g. Safari playing video).
///
/// Resilience: the assertion is worthless if it silently dies mid-broadcast, so
/// we recover from every way iOS can tear the audio graph down — interruptions
/// (a call, Siri, another app grabbing exclusive audio), engine configuration
/// changes (route changes), and a full media-services reset.
@MainActor
final class BroadcastKeepAlive {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    /// Fixed engine format so the graph does not depend on the current hardware
    /// output route (which may change as the user moves between apps/devices).
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
    /// The caller's intent: true between `start()` and `stop()`. Recovery paths
    /// only reassert while this holds, so a teardown during a real stop is left
    /// alone.
    private var wantsAssertion = false
    private var observers: [NSObjectProtocol] = []

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    /// Begin holding the assertion. Call the instant the broadcast goes live (or
    /// is initiated), while the app is still foreground, so the session is active
    /// before any app-switch can suspend the host. Idempotent.
    func start() {
        guard !wantsAssertion else { return }
        wantsAssertion = true
        installObservers()
        activateAndPlay()
    }

    /// Release the assertion when the broadcast ends. Idempotent.
    func stop() {
        guard wantsAssertion else { return }
        wantsAssertion = false
        removeObservers()
        player.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        keepAliveLog.info("Background-audio keepalive released")
    }

    // MARK: - Engine control

    /// (Re)activate the session and (re)start silent playback. Safe to call
    /// repeatedly — used on start and on every recovery path.
    private func activateAndPlay() {
        guard wantsAssertion else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            // `.playback` (not record — the extension owns the mic) with
            // `.mixWithOthers` so we never duck or interrupt the foreground app.
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            if !engine.isRunning { try engine.start() }
        } catch {
            keepAliveLog.error("keepalive (re)activate failed: \(String(describing: error), privacy: .public)")
            return
        }
        // Zero-filled buffer = pure silence; loop it for the broadcast's lifetime.
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(format.sampleRate)) else {
            keepAliveLog.error("keepalive buffer allocation failed")
            return
        }
        buffer.frameLength = buffer.frameCapacity
        player.scheduleBuffer(buffer, at: nil, options: [.loops], completionHandler: nil)
        if !player.isPlaying { player.play() }
        keepAliveLog.info("Background-audio keepalive active")
    }

    // MARK: - Resilience

    private func installObservers() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                            object: session, queue: .main) { [weak self] note in
            // Extract the Sendable primitive on the delivery queue; Notification
            // itself is not Sendable and must not cross into the actor closure.
            let typeRaw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            MainActor.assumeIsolated { self?.handleInterruption(typeRaw: typeRaw) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                            object: session, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleMediaServicesReset() }
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange,
                                            object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleConfigurationChange() }
        })
    }

    private func removeObservers() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    private func handleInterruption(typeRaw: UInt?) {
        guard wantsAssertion,
              let typeRaw,
              let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
        switch type {
        case .began:
            // The system paused our session; the engine has stopped. There is
            // nothing to reclaim until the interruption ends.
            keepAliveLog.info("keepalive interrupted; will recover when it ends")
        case .ended:
            // Reclaim the assertion regardless of the `.shouldResume` hint — a
            // live broadcast always wants its keepalive back.
            keepAliveLog.info("keepalive interruption ended; recovering")
            activateAndPlay()
        @unknown default:
            break
        }
    }

    private func handleMediaServicesReset() {
        guard wantsAssertion else { return }
        // The entire audio stack was torn down; rebuild the graph from scratch.
        keepAliveLog.warning("media services reset; rebuilding keepalive")
        engine.stop()
        engine.reset()
        engine.connect(player, to: engine.mainMixerNode, format: format)
        activateAndPlay()
    }

    private func handleConfigurationChange() {
        guard wantsAssertion else { return }
        // A route/format change can stop the engine; restore playback.
        keepAliveLog.info("engine configuration changed; restoring keepalive")
        activateAndPlay()
    }
}
