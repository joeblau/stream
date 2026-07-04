import SwiftUI
import Observation
import AVFAudio
import StreamCore
import os

/// SwiftUI form bound to `StreamSettings`. Every field edit mutates the bound
/// `settings` and then calls `onChange()` so the parent persists the snapshot
/// via `SettingsStore` BEFORE the user can tap the broadcast picker.
struct SettingsView: View {
    @Binding var settings: StreamSettings

    /// Restream unified-chat controller, shared with the main feed. Owned by the
    /// root view so the connection survives the settings sheet being dismissed.
    var chat: RestreamChat

    /// Called after any field mutation so the parent can persist immediately.
    var onChange: () -> Void

    /// Audio input enumeration helper (AVAudioSession-backed, Simulator-safe).
    @State private var audio = AudioInputProvider()

    /// Camera permission + device-capability helper for the facecam.
    @State private var camera = CameraSupport()

    /// Photos add-only permission helper for the Local Backup feature.
    @State private var photos = PhotosSupport()

    /// Smoothed live level published by the ReplayKit extension.
    @State private var micLevel = MicrophoneLevelMonitor()

    // MARK: - Chat credential fields

    @State private var clientIDField = ""
    @State private var clientSecretField = ""
    /// Forces the credential fields to show even when a Restream app is already
    /// stored, so the user can replace it.
    @State private var editingChatCredentials = false

    // MARK: - Quality presets

    /// Target SHORT edge (px). The long edge follows the live screen aspect, so
    /// the stream is portrait when the screen is portrait. 720 fits the broadcast
    /// extension's ~50 MB memory budget comfortably.
    private static let qualities: [Int] = [480, 720, 1080]

    private func qualityLabel(_ shortEdge: Int) -> String {
        switch shortEdge {
        case 480: return "480p (SD)"
        case 720: return "720p (HD)"
        case 1080: return "1080p (Full HD)"
        default: return "\(shortEdge)p"
        }
    }

    // MARK: - Bitrate / fps presets

    private static let videoBitrates: [Int] = [
        1_000_000, 2_000_000, 3_000_000, 4_500_000, 6_000_000, 8_000_000
    ]
    private static let audioBitrates: [Int] = [64_000, 96_000, 128_000, 192_000, 256_000]
    private static let frameRates: [Int] = [24, 30]

    private func bitrateLabel(_ bps: Int) -> String {
        String(format: "%.1f Mbps", Double(bps) / 1_000_000)
    }

    private func audioBitrateLabel(_ bps: Int) -> String {
        "\(bps / 1000) kbps"
    }

    var body: some View {
        Form {
            connectionSection
            videoSection
            backupSection
            audioSection
            pipSection
            chatSection
        }
        .onAppear {
            audio.refresh(requestPermission: false)
            camera.refresh()
            photos.refresh()
            micLevel.setGain(settings.micVolume)
            micLevel.setPreferredInput(settings.preferredAudioInputUID)
            micLevel.start()
        }
        .onDisappear { micLevel.stop() }
    }

    // MARK: - Connection

    @ViewBuilder
    private var connectionSection: some View {
        Section {
            Picker("Protocol", selection: Binding(
                get: { settings.selectedProtocol },
                set: { newProtocol in
                    // Save the current protocol's creds, switch, then load the target
                    // protocol's stored creds — each has its own Keychain slot.
                    var updated = settings
                    SettingsStore().switchProtocol(to: newProtocol, in: &updated)
                    settings = updated
                }
            )) {
                ForEach(StreamProtocol.allCases, id: \.self) { proto in
                    Text(proto.displayName).tag(proto)
                }
            }
            .pickerStyle(.segmented)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        } header: {
            Text("Connection")
        }

        Section {
            HStack {
                TextField(settings.selectedProtocol.urlPlaceholder, text: Binding(
                    get: { settings.rtmpURL },
                    set: { settings.rtmpURL = $0; onChange() }
                ))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .keyboardType(.URL)

                clearButton(for: \.rtmpURL, label: "Clear URL")
            }

            // RTMP/RTMPS need a separate stream key; SRT/WHIP embed everything
            // (streamid, passphrase, token) in the URL query — so just one field.
            if settings.selectedProtocol.requiresKey {
                HStack {
                    SecureField(settings.selectedProtocol.keyFieldLabel, text: Binding(
                        get: { settings.streamKey },
                        set: { settings.streamKey = $0; onChange() }
                    ))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)

                    clearButton(for: \.streamKey, label: "Clear key")
                }
            }
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if !settings.selectedProtocol.isPublishingSupported {
                    Label("\(settings.selectedProtocol.displayName) publishing is coming soon — your settings are saved. RTMP/RTMPS stream today.",
                          systemImage: "hourglass")
                        .foregroundStyle(.orange)
                } else if settings.isPublishable {
                    Label(
                        settings.isSecure ? "Encrypted connection." : "Unencrypted connection.",
                        systemImage: settings.isSecure ? "lock.fill" : "lock.open"
                    )
                } else {
                    Text("Enter a valid \(settings.selectedProtocol.displayName) URL\(settings.selectedProtocol.requiresKey ? " and stream key" : "").")
                }
                Label("Each protocol's URL + key are saved separately in your Keychain.", systemImage: "key.fill")
            }
        }
    }

    @ViewBuilder
    private func clearButton(for value: WritableKeyPath<StreamSettings, String>,
                             label: String) -> some View {
        if !settings[keyPath: value].isEmpty {
            Button {
                settings[keyPath: value] = ""
                onChange()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
        }
    }

    // MARK: - Video

    @ViewBuilder
    private var videoSection: some View {
        Section {
            Picker("Quality", selection: Binding(
                get: { settings.videoQuality },
                set: { settings.videoQuality = $0; onChange() }
            )) {
                ForEach(Self.qualities, id: \.self) { q in
                    Text(qualityLabel(q)).tag(q)
                }
            }

            Picker("Maximum Bitrate", selection: Binding(
                get: { settings.videoBitrate },
                set: { settings.videoBitrate = $0; onChange() }
            )) {
                ForEach(Self.videoBitrates, id: \.self) { bps in
                    Text(bitrateLabel(bps)).tag(bps)
                }
            }

            Picker("Frame Rate", selection: Binding(
                get: { settings.frameRate },
                set: { settings.frameRate = $0; onChange() }
            )) {
                ForEach(Self.frameRates, id: \.self) { fps in
                    Text("\(fps) fps").tag(fps)
                }
            }
        } header: {
            Text("Video")
        } footer: {
            Text("Bitrate is a maximum and automatically drops when the uplink is congested. Capped at 30 fps — best for a stable screen-share within the broadcast extension's memory budget.")
        }
    }

    // MARK: - Local Backup

    private func backupQualityLabel(_ quality: BackupQuality) -> String {
        switch quality {
        case .matchStream: return "Match Stream"
        case .hd720:       return "720p"
        case .hd1080:      return "1080p"
        case .native:      return "Native (full screen)"
        }
    }

    @ViewBuilder
    private var backupSection: some View {
        Section {
            Toggle("Record Local Backup", isOn: .constant(false))
                .disabled(true)
        } header: {
            Text("Local Backup")
        } footer: {
            Text("Disabled for streaming stability. A second H.264 encoder can exceed the ReplayKit upload extension's memory limit and cause iOS to terminate the broadcast.")
        }
    }

    // MARK: - Audio

    @ViewBuilder
    private var audioSection: some View {
        Section {
            Picker("Audio Bitrate", selection: Binding(
                get: { settings.audioBitrate },
                set: { settings.audioBitrate = $0; onChange() }
            )) {
                ForEach(Self.audioBitrates, id: \.self) { bps in
                    Text(audioBitrateLabel(bps)).tag(bps)
                }
            }

            Toggle("Include App Audio", isOn: Binding(
                get: { settings.includeAppAudio },
                set: { settings.includeAppAudio = $0; onChange() }
            ))

            // Audio input picker. A nil tag means "Default (system)".
            Picker("Mic Input", selection: Binding<String?>(
                get: { selectedAudioInputUID },
                set: { newUID in
                    micLevel.setPreferredInput(newUID)
                    audio.select(uid: newUID, into: &settings)
                    onChange()
                }
            )) {
                Text("Default (system)").tag(String?.none)
                ForEach(audio.inputs, id: \.uid) { input in
                    HStack {
                        if input.isBluetooth {
                            Image(systemName: "wave.3.right.circle.fill")
                        }
                        Text(input.displayName)
                    }
                    .tag(Optional(input.uid))
                }
            }

            microphoneLevelMeter

            VStack(alignment: .leading) {
                HStack {
                    Text("Mic Volume")
                    Spacer()
                    Text(settings.micVolume <= 0.0001
                         ? "Muted"
                         : "\(Int((settings.micVolume * 100).rounded()))%")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(
                    value: Binding(
                        get: { settings.micVolume },
                        set: {
                            settings.micVolume = $0
                            micLevel.setGain($0)
                            onChange()
                        }
                    ),
                    in: 0.0...2.0,
                    step: 0.05,
                    onEditingChanged: { editing in
                        // Apply live to a running broadcast once the drag settles.
                        if !editing {
                            BroadcastControl.post(BroadcastControl.micVolumeSignal)
                        }
                    }
                )
            }

        } header: {
            HStack {
                Text("Audio")
                Spacer()
                Button {
                    micLevel.restartLocalCapture()
                    audio.refresh(requestPermission: true)
                } label: {
                    Label("Refresh Inputs", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .textCase(nil)
            }
        } footer: {
            audioFooter
        }
    }

    private var microphoneLevelMeter: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Mic Level")
                Spacer()
                Text(micLevel.isReceiving ? "Live" : "No signal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    // Gradient is FIXED across the full track (green at 0% → red at
                    // 100%); the fill just reveals it up to the current level, so a
                    // quiet signal shows only green, not a shrunk green→red bar.
                    LinearGradient(
                        colors: [.green, .yellow, .red],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geometry.size.width)
                    .mask(alignment: .leading) {
                        Capsule()
                            .frame(width: geometry.size.width * micLevel.level)
                    }
                }
            }
            .frame(height: 10)
            .animation(.linear(duration: 0.05), value: micLevel.level)
            .accessibilityLabel("Microphone level")
            .accessibilityValue(micLevel.isReceiving
                                ? "\(Int((micLevel.level * 100).rounded())) percent"
                                : "No signal")
        }
    }

    @ViewBuilder
    private var audioFooter: some View {
        switch audio.permission {
        case .denied:
            Text("Microphone access denied. Enable it in Settings to select an input.")
                .foregroundStyle(.red)
        case .granted where audio.inputs.isEmpty:
            Text("No selectable inputs found. Connect a Bluetooth or DJI mic, then Refresh.")
        case .granted:
            Text("Bluetooth/DJI mics are highlighted. Selection persists into the broadcast (telephony-quality over Bluetooth HFP).")
        case .undetermined:
            Text("Tap Refresh to grant microphone access and list inputs.")
        }
    }

    /// SwiftUI requires the picker selection to match one of its tags. Persisted
    /// audio route UIDs can become stale when a Bluetooth mic disconnects, so the
    /// picker falls back to the default tag until the input appears again.
    private var selectedAudioInputUID: String? {
        guard let uid = settings.preferredAudioInputUID,
              audio.inputs.contains(where: { $0.uid == uid }) else {
            return nil
        }
        return uid
    }

    // MARK: - Picture in Picture

    @ViewBuilder
    private var pipSection: some View {
        Section {
            Toggle("Facecam Overlay", isOn: Binding(
                get: { settings.pipEnabled },
                set: { newValue in
                    settings.pipEnabled = newValue
                    if newValue { camera.request() }
                    onChange()
                }
            ))

            if settings.pipEnabled {
                Picker("Corner", selection: Binding(
                    get: { settings.pipCorner },
                    set: { settings.pipCorner = $0; onChange() }
                )) {
                    ForEach(PIPCorner.allCases, id: \.self) { corner in
                        Text(cornerLabel(corner)).tag(corner)
                    }
                }

                Picker("Camera", selection: Binding(
                    get: { settings.cameraPosition },
                    set: { settings.cameraPosition = $0; onChange() }
                )) {
                    ForEach(CameraPosition.allCases, id: \.self) { pos in
                        Text(pos == .front ? "Front" : "Back").tag(pos)
                    }
                }

                VStack(alignment: .leading) {
                    HStack {
                        Text("Overlay Size")
                        Spacer()
                        Text("\(Int((settings.pipScale * 100).rounded()))%")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(
                        value: Binding(
                            get: { settings.pipScale },
                            set: { settings.pipScale = $0; onChange() }
                        ),
                        in: 0.10...0.40
                    )
                }
            }
        } header: {
            Text("Picture in Picture")
        } footer: {
            pipFooter
        }
    }

    @ViewBuilder
    private var pipFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Composites a corner facecam onto your screen frames inside the broadcast (not the system PiP window).")

            if settings.pipEnabled {
                if !camera.multitaskingSupported {
                    Label(
                        "This device can't run the camera during a system broadcast, so the facecam won't appear — the stream stays screen-only. Camera-while-broadcasting needs a device that supports multitasking camera access (e.g. iPad Pro / iPad Air).",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                } else {
                    switch camera.permission {
                    case .denied:
                        Label("Camera access denied. Enable it in Settings to use the facecam.",
                              systemImage: "video.slash.fill")
                            .foregroundStyle(.red)
                    case .undetermined:
                        Label("Grant camera access to use the facecam.",
                              systemImage: "video.fill")
                    case .granted:
                        Label("Facecam ready on this device.", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                    }
                }
            }
        }
    }

    private func cornerLabel(_ corner: PIPCorner) -> String {
        switch corner {
        case .topLeft: return "Top Left"
        case .topRight: return "Top Right"
        case .bottomLeft: return "Bottom Left"
        case .bottomRight: return "Bottom Right"
        }
    }

    // MARK: - Chat

    @ViewBuilder
    private var chatSection: some View {
        Section {
            switch chat.status {
            case .connected:
                Label("Connected to Restream", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                Button("Disconnect", systemImage: "rectangle.portrait.and.arrow.right",
                       role: .destructive) {
                    chat.signOut()
                }

            case .connecting:
                Label { Text("Connecting to Restream…") } icon: {
                    ProgressView().controlSize(.mini)
                }

            case .needsCredentials, .signedOut, .failed:
                if chat.hasCredentials && !editingChatCredentials {
                    Button("Connect with Restream") { chat.connect() }
                    Button("Change Restream App") { editingChatCredentials = true }
                } else {
                    TextField("Client ID", text: $clientIDField)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Client Secret", text: $clientSecretField)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Save & Connect") {
                        chat.saveCredentials(clientID: clientIDField, clientSecret: clientSecretField)
                        editingChatCredentials = false
                        chat.connect()
                    }
                    .disabled(clientIDField.isEmpty || clientSecretField.isEmpty)
                }

                if case .failed(let message) = chat.status {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
        } header: {
            Text("Chat")
        } footer: {
            Text("Register an app at dashboard.restream.io, set its redirect URI to \(RestreamAPI.redirectURI), then paste the Client ID + Secret here and sign in. Chat from every connected platform appears on the main screen.")
        }
    }
}

@MainActor
@Observable
private final class MicrophoneLevelMonitor {
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
    @ObservationIgnored private var lastBroadcastCheckAt: UInt64 = 0
    @ObservationIgnored private var broadcastIsLive = false

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 50_000_000)
                } catch {
                    return
                }
                guard let self else { return }
                refreshBroadcastStateIfNeeded()
                let target: Double
                if let extensionLevel = channel.read() {
                    stopLocalCapture()
                    isReceiving = true
                    target = Double(extensionLevel)
                } else if broadcastIsLive {
                    // Never compete with ReplayKit for the mic when its mic is
                    // paused/off and therefore not publishing meter samples.
                    stopLocalCapture()
                    isReceiving = false
                    target = 0
                } else if let localLevel = readLocalLevel() {
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

    func stop() {
        task?.cancel()
        task = nil
        stopLocalCapture()
        level = 0
        isReceiving = false
    }

    func setGain(_ gain: Double) {
        self.gain = max(0, min(gain, 2))
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
        stopLocalCapture()
        nextRecorderAttemptAt = 0
    }

    private func refreshBroadcastStateIfNeeded() {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now &- lastBroadcastCheckAt >= 500_000_000 else { return }
        lastBroadcastCheckAt = now
        broadcastIsLive = BroadcastStateStore.isLive()
    }

    private func readLocalLevel() -> Double? {
        if engine == nil { startLocalCaptureIfAvailable() }
        guard let engine, engine.isRunning else { return nil }
        // RMS captured on the audio render thread by the input tap.
        let rms = Double(meterLevel.withLock { $0 })
        let postGain = max(0.000_001, min(1, rms * gain))
        let decibels = 20 * log10(postGain)
        return max(0, min(1, (decibels + 60) / 60))
    }

    private func startLocalCaptureIfAvailable() {
        guard AVAudioApplication.shared.recordPermission == .granted else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        guard now >= nextRecorderAttemptAt else { return }
        nextRecorderAttemptAt = now + 1_000_000_000

        // Route the meter to the SAME input the user picked. Without activating a
        // Bluetooth-capable record session and setting the preferred input, the
        // recorder silently captures the built-in mic — so a selected DJI/BT mic
        // never registers on the meter. (Only reached when NOT broadcasting, so it
        // never competes with the extension's session.)
        let session = AVAudioSession.sharedInstance()
        guard AudioInputProvider.activateBluetoothRecording(session) else { return }
        if let uid = preferredInputUID,
           let port = session.availableInputs?.first(where: { $0.uid == uid }) {
            try? session.setPreferredInput(port)
        }

        // Meter from the engine's input node — it reflects the ACTIVE input route
        // (the DJI once it's the preferred input) and gives real PCM buffers, unlike
        // the /dev/null AVAudioRecorder metering trick which can read nothing.
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return }
        let level = meterLevel
        // @Sendable so the tap runs on the audio render thread — WITHOUT it the
        // closure inherits this @MainActor class's isolation and iOS crashes with
        // a libdispatch queue assertion when the render thread invokes it.
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable buffer, _ in
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
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            return
        }
        self.engine = engine

        let route = session.currentRoute.inputs
            .map { "\($0.portName)/\($0.portType.rawValue)" }
            .joined(separator: ",")
        Self.log.info("Mic meter started: route=[\(route, privacy: .public)] format=\(format.sampleRate, privacy: .public)Hz/\(format.channelCount, privacy: .public)ch pref=\(self.preferredInputUID ?? "nil", privacy: .public)")
    }

    private func stopLocalCapture() {
        // No-op when nothing was captured. Otherwise the 50ms meter loop fired a
        // blocking setActive(false) + deactivation-notification storm ~20x/s at the
        // audio server — stalling the app AND interrupting the broadcast extension's
        // live mic session. Deactivate exactly once, on the real handover.
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        meterLevel.withLock { $0 = 0 }
        try? AVAudioSession.sharedInstance()
            .setActive(false, options: .notifyOthersOnDeactivation)
    }
}

#Preview {
    @Previewable @State var settings = StreamSettings.default
    return NavigationStack {
        SettingsView(settings: $settings, chat: RestreamChat(), onChange: {})
    }
}
