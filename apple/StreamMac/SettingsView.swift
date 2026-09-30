import SwiftUI
import StreamCore

/// macOS settings panel. A plain grouped `Form` so Agent A can host it in a
/// toolbar sheet or a `Settings` scene unchanged. Persists through the same
/// `StreamSettings`/`SettingsStore` path as iOS (App Group container file +
/// per-protocol Keychain slots), so both apps share one settings snapshot.
///
/// Every field edit mutates the bound `settings` and calls `onChange()` so the
/// host can persist immediately — wire `onChange` to `SettingsStore().save(_:)`.
struct SettingsView: View {
    @Binding var settings: StreamSettings

    /// Called after any field mutation so the host can persist immediately.
    var onChange: () -> Void

    /// True while a stream or recording owns the encode geometry: canvas/fps
    /// edits are staged by the controller and apply on the next session (W07).
    var outputActive: Bool

    /// Restream chat controller. Pass the shared instance so credentials entered
    /// here light up the chat sidebar; a private one is created otherwise.
    @State private var chat: RestreamChat

    init(settings: Binding<StreamSettings>,
         chat: RestreamChat? = nil,
         outputActive: Bool = false,
         onChange: @escaping () -> Void = {}) {
        _settings = settings
        self.onChange = onChange
        self.outputActive = outputActive
        _chat = State(initialValue: chat ?? RestreamChat())
    }

    // MARK: - Chat credential fields

    @State private var clientIDField = ""
    @State private var clientSecretField = ""
    /// Forces the credential fields to show even when a Restream app is already
    /// stored, so the user can replace it.
    @State private var editingChatCredentials = false

    // MARK: - Output profile state

    /// This Mac's hardware + destination gating (StreamCore's single auditable
    /// capability place). Disabled options show its reason strings.
    private let capabilities = OutputCapabilities.current

    /// The canvas preset list covers fixed sizes only; "Custom…" is a selection
    /// in its own right (it has no size to apply), so it needs this override —
    /// otherwise picking it would snap straight back to the matching preset.
    @State private var presetOverride: CanvasPreset?

    private var selectedPreset: CanvasPreset {
        presetOverride ?? CanvasPreset(matching: settings.outputProfile)
    }

    var body: some View {
        Form {
            connectionSection
            videoSection
            audioSection
            chatSection
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 600)
    }

    // MARK: - Connection

    @ViewBuilder
    private var connectionSection: some View {
        Section {
            Picker("Protocol", selection: Binding(
                get: { settings.selectedProtocol },
                set: { newProtocol in
                    // Save the current protocol's creds, switch, then load the
                    // target protocol's stored creds — each has its own Keychain
                    // slot. Persists the new selection itself.
                    var updated = settings
                    SettingsStore().switchProtocol(to: newProtocol, in: &updated)
                    // The new destination may carry less than the old one
                    // (e.g. 4K over SRT → RTMP): reduce the profile honestly.
                    updated.outputProfile = capabilities.clamped(updated.outputProfile,
                                                                 destination: newProtocol)
                    settings = updated
                    onChange()
                }
            )) {
                ForEach(StreamProtocol.allCases, id: \.self) { proto in
                    Text(proto.displayName).tag(proto)
                }
            }
            .pickerStyle(.segmented)

            TextField("Server URL", text: Binding(
                get: { settings.rtmpURL },
                set: { settings.rtmpURL = $0; onChange() }
            ), prompt: Text(settings.selectedProtocol.urlPlaceholder))
            .autocorrectionDisabled(true)

            // RTMP/RTMPS need a separate stream key; SRT/WHIP embed everything
            // (streamid, passphrase, token) in the URL query — so just one field.
            if settings.selectedProtocol.requiresKey {
                SecureField(settings.selectedProtocol.keyFieldLabel, text: Binding(
                    get: { settings.streamKey },
                    set: { settings.streamKey = $0; onChange() }
                ))
                .autocorrectionDisabled(true)
            }
        } header: {
            Text("Connection")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if settings.isPublishable {
                    Label(
                        settings.isSecure ? "Encrypted connection." : "Unencrypted connection.",
                        systemImage: settings.isSecure ? "lock.fill" : "lock.open"
                    )
                } else {
                    Text("Enter a valid \(settings.selectedProtocol.displayName) URL\(settings.selectedProtocol.requiresKey ? " and stream key" : ""). Get your key at restream.io.")
                }
                Label("Each protocol's URL + key are saved separately in your Keychain, shared with the iOS app.", systemImage: "key.fill")
            }
        }
    }

    // MARK: - Video

    /// Writes a new profile, keeping the legacy short-edge/fps fields the iOS
    /// app still reads in sync with the shared settings snapshot.
    private func setProfile(_ profile: OutputProfile) {
        settings.outputProfile = profile
        settings.videoQuality = min(profile.canvasWidth, profile.canvasHeight)
        settings.frameRate = profile.frameRate
        onChange()
    }

    @ViewBuilder
    private var videoSection: some View {
        Section {
            Picker("Canvas", selection: Binding(
                get: { selectedPreset },
                set: { preset in
                    presetOverride = preset
                    if let size = preset.size {
                        setProfile(settings.outputProfile.with(canvasWidth: size.width,
                                                               canvasHeight: size.height))
                    }
                }
            )) {
                ForEach(CanvasPreset.allCases, id: \.self) { preset in
                    if let size = preset.size {
                        let profile = OutputProfile(canvasWidth: size.width, canvasHeight: size.height,
                                                    frameRate: settings.outputProfile.frameRate)
                        Text(preset.displayName)
                            .tag(preset)
                            .disabled(capabilities.gateReason(for: profile,
                                                              destination: settings.selectedProtocol) != nil)
                    } else {
                        Text(preset.displayName).tag(preset)
                    }
                }
            }

            if selectedPreset == .custom {
                HStack {
                    TextField("Width", value: Binding(
                        get: { settings.outputProfile.canvasWidth },
                        set: { setProfile(settings.outputProfile.with(canvasWidth: $0)) }
                    ), format: .number)
                    .frame(maxWidth: 90)
                    Text("×")
                        .foregroundStyle(.secondary)
                    TextField("Height", value: Binding(
                        get: { settings.outputProfile.canvasHeight },
                        set: { setProfile(settings.outputProfile.with(canvasHeight: $0)) }
                    ), format: .number)
                    .frame(maxWidth: 90)
                    Text("px, even values only")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Picker("Frame Rate", selection: Binding(
                get: { min(settings.outputProfile.frameRate,
                           capabilities.maxFrameRate(for: settings.selectedProtocol)) },
                set: { setProfile(settings.outputProfile.with(frameRate: $0)) }
            )) {
                ForEach(OutputCapabilities.supportedFrameRates, id: \.self) { fps in
                    Text("\(fps) fps")
                        .tag(fps)
                        .disabled(fps > capabilities.maxFrameRate(for: settings.selectedProtocol))
                }
            }

            VStack(alignment: .leading) {
                HStack {
                    Text("Maximum Bitrate")
                    Spacer()
                    Text(String(format: "%.1f Mbps", Double(settings.videoBitrate) / 1_000_000))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(
                    value: Binding(
                        get: { Double(settings.videoBitrate) },
                        set: { settings.videoBitrate = Int($0); onChange() }
                    ),
                    in: 1_000_000...12_000_000,
                    step: 500_000
                )
            }

            Picker("Codec", selection: Binding(
                get: { settings.effectiveVideoCodec },
                set: { settings.videoCodec = $0; onChange() }
            )) {
                ForEach(settings.selectedProtocol.supportedVideoCodecs, id: \.self) { codec in
                    Text(codec.displayName).tag(codec)
                }
            }
        } header: {
            Text("Video")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if outputActive {
                    Label("Canvas and frame-rate changes are staged and apply on the next session — an output is live or recording.",
                          systemImage: "clock.badge.exclamationmark")
                }
                if let reason = capabilities.gateReason(for: settings.outputProfile,
                                                        destination: settings.selectedProtocol) {
                    Label("The current profile exceeds this \(settings.selectedProtocol.displayName) destination: \(reason). It will be reduced when the next session starts.",
                          systemImage: "exclamationmark.triangle")
                }
                Text("The canvas is fixed by this profile — a camera or screen source changing size never resizes the program; sources are fit into the canvas. Bitrate is a maximum and drops automatically when the uplink is congested. H.264 is recommended for Restream — traditional RTMP ingests do not accept HEVC.")
                if settings.effectiveVideoCodec == .hevc {
                    Label("HEVC saves roughly 40% bitrate, but needs a compatible ingest (SRT or enhanced-RTMP). Restream requires H.264.",
                          systemImage: "info.circle")
                }
            }
        }
    }

    // MARK: - Audio

    @ViewBuilder
    private var audioSection: some View {
        Section {
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
                        set: { settings.micVolume = $0; onChange() }
                    ),
                    in: 0.0...2.0,
                    step: 0.05
                )
            }

            Toggle("Voice Polish", isOn: Binding(
                get: { settings.voicePolishEnabled },
                set: { settings.voicePolishEnabled = $0; onChange() }
            ))
            Text("Broadcast-style EQ, compression and limiting on the mic. Applies from the next broadcast.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Audio")
        }
    }

    // MARK: - Restream chat

    @ViewBuilder
    private var chatSection: some View {
        Section {
            switch chat.status {
            case .connected:
                Label("Connected to Restream", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                Button("Disconnect", role: .destructive) { chat.signOut() }

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
                        .autocorrectionDisabled(true)
                    SecureField("Client Secret", text: $clientSecretField)
                        .autocorrectionDisabled(true)
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
            Text("Restream Chat")
        } footer: {
            Text("Register an app at dashboard.restream.io, set its redirect URI to \(RestreamAPI.redirectURI), then paste the Client ID + Secret here and sign in. Chat from every connected platform appears in the sidebar.")
        }
    }
}

#Preview {
    @Previewable @State var settings = StreamSettings.default
    return SettingsView(settings: $settings)
}
