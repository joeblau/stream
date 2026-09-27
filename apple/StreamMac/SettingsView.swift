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

    /// Restream chat controller. Pass the shared instance so credentials entered
    /// here light up the chat sidebar; a private one is created otherwise.
    @State private var chat: RestreamChat

    init(settings: Binding<StreamSettings>,
         chat: RestreamChat? = nil,
         onChange: @escaping () -> Void = {}) {
        _settings = settings
        self.onChange = onChange
        _chat = State(initialValue: chat ?? RestreamChat())
    }

    // MARK: - Chat credential fields

    @State private var clientIDField = ""
    @State private var clientSecretField = ""
    /// Forces the credential fields to show even when a Restream app is already
    /// stored, so the user can replace it.
    @State private var editingChatCredentials = false

    // MARK: - Presets

    /// Target SHORT edge (px). Gated by the device ceiling, same as iOS.
    private static let qualities: [Int] = [720, 1080]
    private static let frameRates: [Int] = [30, 60]

    /// This Mac's resolution/fps ceiling (StreamCore, same derivation as iOS).
    private var capability: StreamCapability { .current }

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

    @ViewBuilder
    private var videoSection: some View {
        Section {
            Picker("Quality", selection: Binding(
                get: { min(settings.videoQuality, capability.maxShortEdge) },
                set: { settings.videoQuality = $0; onChange() }
            )) {
                ForEach(Self.qualities.filter { $0 <= capability.maxShortEdge }, id: \.self) { q in
                    Text(q == 720 ? "720p (HD)" : "1080p (Full HD)").tag(q)
                }
            }

            Picker("Frame Rate", selection: Binding(
                get: { min(settings.frameRate, capability.maxFrameRate) },
                set: { settings.frameRate = $0; onChange() }
            )) {
                ForEach(Self.frameRates.filter { $0 <= capability.maxFrameRate }, id: \.self) { fps in
                    Text("\(fps) fps").tag(fps)
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
                Text("Bitrate is a maximum and drops automatically when the uplink is congested. H.264 is recommended for Restream — traditional RTMP ingests do not accept HEVC.")
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
