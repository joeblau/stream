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
@MainActor
final class BroadcastKeepAlive {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    /// Fixed engine format so the graph does not depend on the current hardware
    /// output route (which may change as the user moves between apps/devices).
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
    private var active = false

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    /// Begin holding the assertion. Call the instant the broadcast goes live,
    /// while the app is still foreground, so the session is active before any
    /// app-switch can suspend the host. Idempotent.
    func start() {
        guard !active else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            // `.playback` (not record — the extension owns the mic) with
            // `.mixWithOthers` so we never duck or interrupt the foreground app.
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            try engine.start()
        } catch {
            keepAliveLog.error("keepalive start failed: \(String(describing: error), privacy: .public)")
            try? session.setActive(false)
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
        player.play()
        active = true
        keepAliveLog.info("Background-audio keepalive active for the broadcast")
    }

    /// Release the assertion when the broadcast ends. Idempotent.
    func stop() {
        guard active else { return }
        active = false
        player.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        keepAliveLog.info("Background-audio keepalive released")
    }
}
