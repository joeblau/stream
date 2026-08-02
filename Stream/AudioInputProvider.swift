import Foundation
import AVFAudio
import Observation
import StreamCore
import SwiftUI
import os

/// Observable helper that configures `AVAudioSession` so Bluetooth/DJI mic
/// inputs surface, enumerates `availableInputs`, exposes name/uid pairs, and
/// writes the chosen uid into `StreamSettings.preferredAudioInputUID`.
///
/// MUST compile and behave gracefully on the Simulator, where there are no
/// Bluetooth routes (the inputs list will simply be sparse/empty).
@MainActor
@Observable
final class AudioInputProvider {

    /// A selectable audio input surfaced from the audio session.
    struct Input: Identifiable, Hashable {
        let uid: String
        let displayName: String
        let isBluetooth: Bool
        var id: String { uid }
    }

    /// Microphone permission state, mirrored for the UI.
    enum Permission {
        case undetermined
        case granted
        case denied
    }

    /// The list of available inputs, Bluetooth/DJI ones flagged.
    private(set) var inputs: [Input] = []

    /// Current microphone permission state.
    private(set) var permission: Permission = .undetermined

    /// Fired after a live route change re-enumerates `inputs`, so the owning view
    /// can re-apply the persisted preferred input and restart the level meter on
    /// the new route. Not fired for a manual `refresh()` (the caller already knows).
    var onInputsChanged: (() -> Void)?

    /// Fired when a Bluetooth audio input appears that wasn't present on the
    /// previous enumeration — i.e. a device paired/connected mid-session. Carries
    /// the new device's display name so the UI can surface a "<name> connected"
    /// banner. Deliberately NOT fired for devices already connected when monitoring
    /// starts (the first `refresh()` only seeds the baseline), only for arrivals.
    var onBluetoothConnected: ((String) -> Void)?

    /// UIDs of the Bluetooth inputs seen on the most recent enumeration. A later
    /// route change diffs against this to tell which device is *newly* connected
    /// (fire the banner) versus one that was already present (stay quiet).
    private var knownBluetoothUIDs: Set<String> = []

    /// Observer token for `AVAudioSession.routeChangeNotification`. Marked
    /// `nonisolated(unsafe)` so `deinit` (which is nonisolated on a `@MainActor`
    /// type) can remove it; an `NSObjectProtocol` token is safe to touch there.
    @ObservationIgnored private nonisolated(unsafe) var routeChangeObserver: NSObjectProtocol?

    deinit {
        if let routeChangeObserver {
            NotificationCenter.default.removeObserver(routeChangeObserver)
        }
    }

    /// Requests mic permission if needed, configures a record-capable session
    /// with Bluetooth options so BT inputs appear, then enumerates inputs.
    func refresh(requestPermission: Bool = true) {
        // Start listening for hardware route changes so a Bluetooth/DJI mic
        // connected while the app is already running is picked up immediately
        // rather than only on the next launch or a manual Refresh. Idempotent.
        startMonitoringRouteChanges()
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            permission = .granted
            configureAndEnumerate()
        case .denied:
            permission = .denied
            inputs = []
        case .undetermined:
            permission = .undetermined
            inputs = []
            guard requestPermission else { return }
            AVAudioApplication.requestRecordPermission { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    self.permission = granted ? .granted : .denied
                    if granted { self.configureAndEnumerate() }
                }
            }
        @unknown default:
            permission = .undetermined
            inputs = []
        }
    }

    /// Writes the chosen uid into the settings and, when granted, applies it as
    /// the preferred input on the session so the route is correct in-app.
    func select(uid: String?, into settings: inout StreamSettings) {
        settings.preferredAudioInputUID = uid
        guard permission == .granted, let uid else { return }
        AudioSessionCoordinator.shared.setPreferredInput(uid)
    }

    // MARK: - Live route changes

    /// Registers a single `AVAudioSession.routeChangeNotification` observer.
    /// Idempotent — safe to call from every `refresh()`.
    func startMonitoringRouteChanges() {
        guard routeChangeObserver == nil else { return }
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // Extract the reason off-actor (Notification isn't Sendable); the
            // reason enum is a plain Sendable value we can hop to the main actor.
            let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            let reason = raw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            Task { @MainActor in self?.handleRouteChange(reason) }
        }
    }

    private func handleRouteChange(_ reason: AVAudioSession.RouteChangeReason?) {
        // React only to hardware appearing/disappearing. We deliberately ignore
        // `.categoryChange` / `.override`, which we provoke ourselves by setting
        // the category and the preferred input — reacting to those would loop.
        switch reason {
        case .newDeviceAvailable, .oldDeviceUnavailable:
            guard permission == .granted else { return }
            configureAndEnumerate(announceNewBluetooth: true, notifyInputsChanged: true)
        default:
            break
        }
    }

    // MARK: - Private

    /// - Parameter announceNewBluetooth: when true, fire `onBluetoothConnected`
    ///   for each Bluetooth input not seen on the previous enumeration. False for
    ///   the initial `refresh()`, which only seeds the baseline set.
    private func configureAndEnumerate(announceNewBluetooth: Bool = false,
                                       notifyInputsChanged: Bool = false) {
        Task { [weak self] in
            // Category negotiation may consult media-server synchronously. Keep it
            // off the UI actor and ordered with meter/broadcast session handoffs.
            await AudioSessionCoordinator.shared.prepareForEnumeration()
            guard let self else { return }
            enumerate(from: AVAudioSession.sharedInstance(),
                      announceNewBluetooth: announceNewBluetooth)
            if notifyInputsChanged { onInputsChanged?() }
        }
    }

    private func enumerate(from session: AVAudioSession, announceNewBluetooth: Bool) {
        let available = session.availableInputs ?? []
        inputs = available.map { port in
            let isBT = port.portType == .bluetoothHFP || port.portType == .bluetoothLE
            return Input(
                uid: port.uid,
                displayName: port.portName,
                isBluetooth: isBT
            )
        }
        // Diff the Bluetooth set against the previous enumeration so a device that
        // paired mid-session surfaces once; already-connected devices stay quiet.
        let bluetooth = inputs.filter(\.isBluetooth)
        if announceNewBluetooth {
            for input in bluetooth where !knownBluetoothUIDs.contains(input.uid) {
                onBluetoothConnected?(input.displayName)
            }
        }
        knownBluetoothUIDs = Set(bluetooth.map(\.uid))
    }

    /// Activates a record-capable session that surfaces Bluetooth inputs.
    ///
    /// Critically uses mode `.default` — NOT `.videoRecording`, which makes iOS
    /// prefer the built-in mic and hides Bluetooth HFP inputs (the reason DJI/BT
    /// mics weren't selectable). Tries the richest Bluetooth option set first and
    /// degrades, so one unsupported option never blocks enumeration.
    /// Performs the potentially blocking audio-server category/activation handoff.
    /// This is deliberately nonisolated so the session coordinator can run it on
    /// its dedicated serial queue;
    /// `AVAudioSession.setActive` may take long enough to visibly stall a sheet push.
    @discardableResult
    nonisolated static func activateBluetoothRecording(preferredInputUID: String?) -> Bool {
        let session = AVAudioSession.sharedInstance()
        for options in bluetoothOptionLadder() {
            do {
                try session.setCategory(.playAndRecord, mode: .default, options: options)
                try session.setActive(true, options: [])
                if let preferredInputUID,
                   let port = session.availableInputs?.first(where: { $0.uid == preferredInputUID }) {
                    try? session.setPreferredInput(port)
                }
                return true
            } catch {
                continue
            }
        }
        return false
    }

    /// Bluetooth-capable record options, richest first. `.allowBluetoothHFP` is the
    /// iOS 26 replacement for the deprecated `.allowBluetooth`.
    nonisolated static func bluetoothOptionLadder() -> [AVAudioSession.CategoryOptions] {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            return [
                [.allowBluetoothHFP, .bluetoothHighQualityRecording, .mixWithOthers],
                [.allowBluetoothHFP, .mixWithOthers],
                [.allowBluetoothHFP],
                []
            ]
        }
        return [[.allowBluetoothHFP, .mixWithOthers], [.allowBluetoothHFP], []]
        #else
        return [[.allowBluetooth, .mixWithOthers], [.allowBluetooth], []]
        #endif
    }
}

/// Serializes every app-owned `AVAudioSession` activation/deactivation away from
/// the main actor. In particular, leaving the Audio settings pane enqueues its
/// deactivation before a subsequent broadcast activation, so a late meter teardown
/// can never turn off ScreenCaptureKit's microphone session.
final class AudioSessionCoordinator: @unchecked Sendable {
    static let shared = AudioSessionCoordinator()

    private let queue = DispatchQueue(
        label: "com.joeblau.Stream.audio-session",
        qos: .userInitiated
    )

    private init() {}

    /// Configures Bluetooth-capable recording without activating the session.
    /// Category setup is enough for `availableInputs` enumeration.
    func prepareForEnumeration() async {
        await withCheckedContinuation { continuation in
            queue.async {
                let session = AVAudioSession.sharedInstance()
                for options in AudioInputProvider.bluetoothOptionLadder() {
                    do {
                        try session.setCategory(.playAndRecord, mode: .default,
                                                options: options)
                        break
                    } catch {
                        continue
                    }
                }
                continuation.resume()
            }
        }
    }

    func setPreferredInput(_ uid: String) {
        queue.async {
            let session = AVAudioSession.sharedInstance()
            guard let port = session.availableInputs?.first(where: { $0.uid == uid }) else {
                return
            }
            try? session.setPreferredInput(port)
        }
    }

    func activate(preferredInputUID: String?) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: AudioInputProvider.activateBluetoothRecording(
                    preferredInputUID: preferredInputUID
                ))
            }
        }
    }

    /// Enqueues teardown immediately and returns without blocking the caller.
    /// A later `activate` is submitted behind it on the same serial queue.
    func deactivate() {
        queue.async {
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: [.notifyOthersOnDeactivation]
            )
        }
    }

    /// Used by capture teardown paths that must know the session is inactive before
    /// completing. It shares ordering with the fire-and-forget meter teardown.
    func deactivateAndWait() async {
        await withCheckedContinuation { continuation in
            queue.async {
                try? AVAudioSession.sharedInstance().setActive(
                    false,
                    options: [.notifyOthersOnDeactivation]
                )
                continuation.resume()
            }
        }
    }
}

// MARK: - Microphone level metering

/// The smoothed 0...1 microphone level, shared by the main toolbar's status meter
/// and the Audio settings pane. While a broadcast is live the level arrives free
/// over `MicrophoneLevelChannel` (published by the capture pipeline, already
/// post-gain); when idle the monitor opens its own `AVAudioEngine` tap on the
/// user's selected input.
///
/// Exactly one instance exists — owned by `ContentView` — because a second one
/// would open a competing record session. Callers therefore start/stop it with a
/// `Client` token and the meter runs until the last of them lets go.
@MainActor
@Observable
final class MicrophoneLevelMonitor {
    private(set) var level = 0.0
    private(set) var isReceiving = false

    private static let log = Logger(subsystem: "com.joeblau.Stream", category: "mic-meter")
    @ObservationIgnored private let channel = MicrophoneLevelChannel()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private let meterLevel = OSAllocatedUnfairLock<Float>(initialState: 0)
    @ObservationIgnored private var gain = 1.0
    @ObservationIgnored private var preferredInputUID: String?
    @ObservationIgnored private var nextRecorderAttemptAt: UInt64 = 0
    @ObservationIgnored private var broadcastIsLive = false
    @ObservationIgnored private var activationInFlight = false
    /// Invalidates an activation that is awaiting the serialized audio-session
    /// queue. Teardown enqueues deactivation immediately; a stale continuation must
    /// then return without submitting another operation behind a new broadcast.
    @ObservationIgnored private var localCaptureGeneration: UInt = 0

    /// Observer for `AVAudioEngineConfigurationChange`. The engine posts it when its
    /// I/O format changes underneath the running graph — most importantly when a
    /// Bluetooth HFP link finishes its asynchronous handoff after `setPreferredInput`.
    /// The tap was installed at the pre-switch format, so without rebuilding it on
    /// this notification the meter goes silent once the route lands on the BT mic.
    @ObservationIgnored private nonisolated(unsafe) var configChangeObserver: NSObjectProtocol?

    /// A surface currently displaying the meter. The toolbar meter and the Audio
    /// settings pane can be on screen at the same time, so the sampling loop is
    /// reference-counted across them — closing the settings sheet mid-broadcast
    /// must not silence the toolbar meter behind it.
    enum Client: Hashable {
        case statusBar
        case settings
    }

    @ObservationIgnored private var clients: Set<Client> = []

    func start(for client: Client) {
        clients.insert(client)
        startSampling()
    }

    func stop(for client: Client) {
        clients.remove(client)
        guard clients.isEmpty else { return }
        stopSampling()
    }

    private func startSampling() {
        guard task == nil else { return }
        task = Task { [weak self] in
            // Let the presenting transition (a settings push, or the go-live
            // handoff) finish before touching AVAudioEngine. If the user backs out
            // immediately, cancellation avoids starting audio at all.
            do {
                try await Task.sleep(for: .milliseconds(350))
            } catch {
                return
            }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 100_000_000)
                } catch {
                    return
                }
                guard let self else { return }
                let target: Double
                if let extensionLevel = channel.read() {
                    stopLocalCapture()
                    isReceiving = true
                    target = Double(extensionLevel)
                } else if broadcastIsLive {
                    // Never open a second mic capture while ScreenCaptureKit's
                    // microphone is paused/off and not publishing meter samples.
                    stopLocalCapture()
                    isReceiving = false
                    target = 0
                } else if let localLevel = await readLocalLevel() {
                    isReceiving = true
                    target = localLevel
                } else {
                    isReceiving = false
                    target = 0
                }
                var next = target >= level
                    ? level * 0.3 + target * 0.7
                    : max(target, level * 0.82)
                if next < 0.005 { next = 0 }
                // Only publish on change — @Observable fires on every set, so an
                // idle meter otherwise re-renders the view 20x/s for nothing.
                if next != level { level = next }
            }
        }
    }

    private func stopSampling() {
        task?.cancel()
        task = nil
        invalidateLocalCapture()
        level = 0
        isReceiving = false
    }

    func setGain(_ gain: Double) {
        self.gain = max(0, min(gain, 2))
    }

    func setBroadcasting(_ isLive: Bool) {
        guard broadcastIsLive != isLive else { return }
        broadcastIsLive = isLive
        if isLive {
            invalidateLocalCapture()
        } else {
            nextRecorderAttemptAt = 0
        }
    }

    /// Routes the local meter to the user's selected input (incl. Bluetooth/DJI).
    /// Without this the recorder captures the built-in mic, so a selected DJI/BT
    /// mic never registers on the meter.
    func setPreferredInput(_ uid: String?) {
        guard uid != preferredInputUID else { return }
        preferredInputUID = uid
        restartLocalCapture()
    }

    func restartLocalCapture() {
        invalidateLocalCapture()
        nextRecorderAttemptAt = 0
    }

    private func readLocalLevel() async -> Double? {
        if engine == nil { await startLocalCaptureIfAvailable() }
        guard let engine, engine.isRunning else { return nil }
        // RMS captured on the audio render thread by the input tap.
        let rms = Double(meterLevel.withLock { $0 })
        let postGain = max(0.000_001, min(1, rms * gain))
        let decibels = 20 * log10(postGain)
        return max(0, min(1, (decibels + 60) / 60))
    }

    private func startLocalCaptureIfAvailable() async {
        guard AVAudioApplication.shared.recordPermission == .granted else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        guard now >= nextRecorderAttemptAt else { return }
        nextRecorderAttemptAt = now + 1_000_000_000
        let generation = localCaptureGeneration

        // Route the meter to the SAME input the user picked. Without activating a
        // Bluetooth-capable record session and setting the preferred input, the
        // recorder silently captures the built-in mic — so a selected DJI/BT mic
        // never registers on the meter. (Only reached when NOT broadcasting, so it
        // never competes with the extension's session.)
        let uid = preferredInputUID
        activationInFlight = true
        let activated = await AudioSessionCoordinator.shared.activate(
            preferredInputUID: uid
        )
        activationInFlight = false
        guard activated else { return }
        // `stop()` can cancel this task while audio-server activation is in flight.
        // Do not resurrect an engine after the pane disappeared or a broadcast took
        // ownership; the queued deactivation remains ordered with future activation.
        guard !Task.isCancelled, !broadcastIsLive,
              generation == localCaptureGeneration else { return }
        var keepSessionActive = false
        defer {
            if !keepSessionActive { AudioSessionCoordinator.shared.deactivate() }
        }
        let session = AVAudioSession.sharedInstance()

        // Meter from the engine's input node — it reflects the ACTIVE input route
        // (the DJI once it's the preferred input) and gives real PCM buffers, unlike
        // the /dev/null AVAudioRecorder metering trick which can read nothing.
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { return }
        // A tap alone does NOT reliably pull a Bluetooth HFP input — the engine only
        // renders its input when the graph drives an output, so an unconnected
        // input node hands the tap silent buffers (the "DJI selected, meter flat"
        // bug). Route input → main mixer to force a full I/O cycle, and mute the
        // mixer output so nothing is monitored back to the speaker/HFP earpiece.
        do {
            try engine.connectNode(input, to: engine.mainMixerNode, format: inputFormat)
        } catch {
            return
        }
        engine.mainMixerNode.outputVolume = 0
        guard installMeterTap(on: engine) else { return }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            return
        }
        self.engine = engine
        keepSessionActive = true

        // A Bluetooth HFP link settles asynchronously AFTER setPreferredInput, so the
        // format above may still be the built-in mic's. Rebuild the tap on the new
        // format when the engine reconfigures, else the BT meter reads flat forever.
        observeConfigChanges(of: engine)

        let route = session.currentRoute.inputs
            .map { "\($0.portName)/\($0.portType.rawValue)" }
            .joined(separator: ",")
        let format = engine.inputNode.inputFormat(forBus: 0)
        Self.log.info("Mic meter started: route=[\(route, privacy: .public)] format=\(format.sampleRate, privacy: .public)Hz/\(format.channelCount, privacy: .public)ch pref=\(self.preferredInputUID ?? "nil", privacy: .public)")
    }

    /// Reads the input node's CURRENT format and installs the metering tap. Split out
    /// so it can be re-run on a configuration change (when the live route/format has
    /// changed). Returns false when the route has no usable input yet.
    private func installMeterTap(on engine: AVAudioEngine) -> Bool {
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return false }
        let level = meterLevel
        // @Sendable so the tap runs on the audio render thread — WITHOUT it the
        // closure inherits this @MainActor class's isolation and iOS crashes with
        // a libdispatch queue assertion when the render thread invokes it.
        do {
            try input.__installTap(onBus: 0, bufferSize: 1024, format: format, error: ()) {
                @Sendable buffer, _ in
                guard let channel = buffer.floatChannelData?[0] else { return }
                let count = Int(buffer.frameLength)
                guard count > 0 else { return }
                var sumOfSquares: Float = 0
                for i in 0..<count {
                    let sample = channel[i]
                    sumOfSquares += sample * sample
                }
                let rms = (sumOfSquares / Float(count)).squareRoot()
                level.withLock { $0 = rms }
            }
        } catch {
            return false
        }
        return true
    }

    /// Registers the configuration-change observer for `engine`, replacing any prior
    /// one. Fires on the main queue; hops back onto the actor to rebuild the tap.
    private func observeConfigChanges(of engine: AVAudioEngine) {
        if let configChangeObserver {
            NotificationCenter.default.removeObserver(configChangeObserver)
        }
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleEngineConfigChange() }
        }
    }

    /// The engine's I/O reconfigured (typically the BT route finishing its handoff).
    /// Reinstall the tap at the new input format and make sure the engine is running;
    /// a config change stops the engine, and the old tap's format no longer matches.
    private func handleEngineConfigChange() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        guard installMeterTap(on: engine) else { return }
        if !engine.isRunning {
            engine.prepare()
            try? engine.start()
        }
        let route = AVAudioSession.sharedInstance().currentRoute.inputs
            .map { "\($0.portName)/\($0.portType.rawValue)" }
            .joined(separator: ",")
        let format = engine.inputNode.inputFormat(forBus: 0)
        Self.log.info("Mic meter reconfigured: route=[\(route, privacy: .public)] format=\(format.sampleRate, privacy: .public)Hz/\(format.channelCount, privacy: .public)ch")
    }

    private func stopLocalCapture() {
        // No-op when nothing was captured. Otherwise the meter loop could fire a
        // blocking setActive(false) + deactivation-notification storm repeatedly at the
        // audio server and interrupting ScreenCaptureKit's live mic session.
        // Deactivate exactly once, on the real handover.
        guard let engine else { return }
        if let configChangeObserver {
            NotificationCenter.default.removeObserver(configChangeObserver)
            self.configChangeObserver = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        meterLevel.withLock { $0 = 0 }
        AudioSessionCoordinator.shared.deactivate()
    }

    /// Cancels both a running engine and an activation still waiting on the audio
    /// queue. Enqueuing deactivation now preserves ordering with a record-button tap
    /// that follows immediately after the settings sheet closes.
    private func invalidateLocalCapture() {
        localCaptureGeneration &+= 1
        if engine != nil {
            stopLocalCapture()
        } else if activationInFlight {
            AudioSessionCoordinator.shared.deactivate()
        }
    }
}

/// Isolates the 10 Hz meter invalidations to this small leaf instead of rebuilding
/// the surrounding Form and Settings navigation tree on every level sample.
struct MicrophoneLevelMeterView: View {
    let monitor: MicrophoneLevelMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Mic Level")
                Spacer()
                Text(monitor.isReceiving ? "Live" : "No signal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    LinearGradient(
                        colors: [.green, .yellow, .red],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geometry.size.width)
                    .mask(alignment: .leading) {
                        Capsule()
                            .frame(width: geometry.size.width * monitor.level)
                    }
                }
            }
            .frame(height: 10)
            .animation(.linear(duration: 0.08), value: monitor.level)
            .accessibilityLabel("Microphone level")
            .accessibilityValue(monitor.isReceiving
                                ? "\(Int((monitor.level * 100).rounded())) percent"
                                : "No signal")
        }
    }
}

/// The toolbar's at-a-glance "is my mic working?" indicator: a mic glyph plus a
/// short ladder of segments that light with the live level. Shown only while
/// broadcasting, where the level costs nothing (the capture pipeline already
/// publishes it), and kept a leaf view so 10 Hz level changes never invalidate the
/// chat feed beneath it.
///
/// Three states the streamer needs to tell apart at a glance:
/// bars moving = audio is reaching the encoder; amber glyph with dark bars =
/// no meter samples at all (the mic isn't feeding the stream); red slash = muted.
struct MicrophoneStatusMeter: View {
    let monitor: MicrophoneLevelMonitor

    /// Mic gain is at zero. The published level is already post-gain, so a muted
    /// mic and a silent room look identical on the meter — only the caller's
    /// settings can tell them apart.
    let isMuted: Bool

    /// Enough resolution to read speech peaks at toolbar size without turning into
    /// a smear of hairlines.
    private static let segmentCount = 5

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: isMuted ? "mic.slash.fill" : "mic.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(glyphTint)
                .contentTransition(.symbolEffect(.replace))

            HStack(spacing: 2.5) {
                ForEach(0..<Self.segmentCount, id: \.self) { index in
                    Capsule()
                        .fill(isLit(index) ? segmentTint(index) : Color.secondary.opacity(0.3))
                        .frame(width: 3.5, height: 14)
                }
            }
        }
        .animation(.linear(duration: 0.08), value: monitor.level)
        // The mute toggle mutates settings without its own transaction, so the
        // glyph swap needs an animation here for `.symbolEffect(.replace)` to run.
        .animation(.easeInOut(duration: 0.2), value: isMuted)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Microphone level")
        .accessibilityValue(accessibilityValue)
    }

    /// Muted reads red; live-but-receiving-nothing reads amber, since that's the
    /// failure the indicator exists to catch.
    private var glyphTint: Color {
        if isMuted { return .red }
        return monitor.isReceiving ? .primary : .orange
    }

    private func isLit(_ index: Int) -> Bool {
        guard !isMuted, monitor.isReceiving else { return false }
        return monitor.level > Double(index) / Double(Self.segmentCount)
    }

    /// Green through the healthy range, amber approaching the ceiling, red at it —
    /// same green→yellow→red reading as the full meter in Audio settings.
    private func segmentTint(_ index: Int) -> Color {
        switch index {
        case Self.segmentCount - 1: return .red
        case Self.segmentCount - 2: return .yellow
        default: return .green
        }
    }

    private var accessibilityValue: String {
        if isMuted { return "Muted" }
        guard monitor.isReceiving else { return "No signal" }
        return "\(Int((monitor.level * 100).rounded())) percent"
    }
}
