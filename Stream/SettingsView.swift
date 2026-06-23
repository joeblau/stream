import SwiftUI
import StreamCore

/// SwiftUI form bound to `StreamSettings`. Every field edit mutates the bound
/// `settings` and then calls `onChange()` so the parent persists the snapshot
/// via `SettingsStore` BEFORE the user can tap the broadcast picker.
struct SettingsView: View {
    @Binding var settings: StreamSettings

    /// Called after any field mutation so the parent can persist immediately.
    var onChange: () -> Void

    /// Audio input enumeration helper (AVAudioSession-backed, Simulator-safe).
    @State private var audio = AudioInputProvider()

    /// Camera permission + device-capability helper for the facecam.
    @State private var camera = CameraSupport()

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
    private static let frameRates: [Int] = [24, 30, 60]

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
            audioSection
            pipSection
        }
        .onAppear {
            audio.refresh()
            camera.refresh()
        }
    }

    // MARK: - Connection

    @ViewBuilder
    private var connectionSection: some View {
        Section {
            TextField("rtmps://live.restream.io/live", text: Binding(
                get: { settings.rtmpURL },
                set: { settings.rtmpURL = $0; onChange() }
            ))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            .keyboardType(.URL)

            SecureField("Stream key", text: Binding(
                get: { settings.streamKey },
                set: { settings.streamKey = $0; onChange() }
            ))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
        } header: {
            Text("Connection")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if settings.isPublishable {
                    Label(
                        settings.isSecure ? "TLS will be negotiated (rtmps)." : "Unencrypted (rtmp).",
                        systemImage: settings.isSecure ? "lock.fill" : "lock.open"
                    )
                } else {
                    Text("Enter a valid rtmp:// or rtmps:// URL and a stream key.")
                }
                Label("Saved securely to your Keychain — entered once.", systemImage: "key.fill")
            }
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

            Picker("Video Bitrate", selection: Binding(
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
            Text("Orientation and aspect ratio follow your screen at broadcast start — begin in portrait to stream portrait. Quality sets the short edge; the long edge matches your screen.")
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
            Picker("Microphone Input", selection: Binding<String?>(
                get: { settings.preferredAudioInputUID },
                set: { newUID in
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

            Button {
                audio.refresh()
            } label: {
                Label("Refresh Inputs", systemImage: "arrow.clockwise")
            }
        } header: {
            Text("Audio")
        } footer: {
            audioFooter
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
}

#Preview {
    @Previewable @State var settings = StreamSettings.default
    return NavigationStack {
        SettingsView(settings: $settings, onChange: {})
    }
}
