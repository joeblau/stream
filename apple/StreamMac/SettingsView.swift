import AppKit
import AVFoundation
import CoreGraphics
import SwiftUI
import StreamCore

/// The embedded settings area (W04, issue #67). Lives in the studio shell as
/// a collapsible pane (⌘,) and edits the shared `SettingsSession` DRAFT —
/// nothing persists or reaches the pipeline until Apply, and Revert discards,
/// so displayed values, saved values, and the values `StreamController` is
/// actually using can never diverge silently.
///
/// Every group declares its live effect explicitly ("Applies immediately" /
/// "Applies on next session"): mic volume reaches a live publisher in place,
/// canvas/fps follow the W07 staged-profile rules, and connection/bitrate/
/// codec/input edits are read at the next session start — staged while
/// `session.isOutputActive`. Malformed values (bad URL scheme, out-of-range
/// port, whitespace-only key) show inline errors and block Apply.
struct SettingsView: View {
    @ObservedObject var session: SettingsSession
    @EnvironmentObject private var controller: StreamController
    @EnvironmentObject private var permissions: PermissionsManager

    /// Shared Restream chat controller (owned by the shell) so credentials
    /// entered here light up the chat sidebar.
    let chat: RestreamChat
    /// Closes the settings pane; unapplied edits stay in the draft.
    var onClose: () -> Void
    /// Application section: restores the default panel layout.
    var onResetLayout: () -> Void

    init(session: SettingsSession,
         chat: RestreamChat,
         onClose: @escaping () -> Void = {},
         onResetLayout: @escaping () -> Void = {}) {
        self.session = session
        self.chat = chat
        self.onClose = onClose
        self.onResetLayout = onResetLayout
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
        presetOverride ?? CanvasPreset(matching: session.draft.outputProfile)
    }

    // MARK: - Application permission state

    // Permission status/request/repair is centralized in the shared
    // PermissionsManager (W06) — the same object the onboarding flow and the
    // just-in-time explainers use, so this section can never disagree with
    // them.

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                Form {
                    connectionSection.id(SettingsSession.Section.connection)
                    videoSection.id(SettingsSession.Section.video)
                    audioSection.id(SettingsSession.Section.audio)
                    chatSection.id(SettingsSession.Section.chat)
                    applicationSection.id(SettingsSession.Section.application)
                }
                .formStyle(.grouped)
                .onChange(of: session.requestedSection) { _, section in
                    // W06 deep-link (e.g. the first-run flow's destination
                    // step): scroll to the requested section, then consume it.
                    guard let section else { return }
                    withAnimation { proxy.scrollTo(section, anchor: .top) }
                    session.requestedSection = nil
                }
            }
            Divider()
            actionBar
        }
        .onAppear {
            controller.audio.refreshDevices()
            permissions.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            // The user may have flipped a permission in System Settings.
            permissions.refresh()
        }
        .onExitCommand { onClose() }
    }

    private var header: some View {
        HStack {
            Text("Settings")
                .font(.callout.weight(.semibold))
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Close settings — edits are not applied until you choose Apply")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Persists + applies only when the draft is valid (W04: validate before
    /// applying; cancel/discard leaves the active state untouched).
    private var actionBar: some View {
        HStack(spacing: 12) {
            if session.isDirty {
                Label("Unsaved changes", systemImage: "circle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Label("All changes applied", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Revert") { session.revert() }
                .disabled(!session.isDirty)
                .help("Discard every unapplied edit")
            Button("Apply") { session.apply() }
                .disabled(!session.canApply)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .help(session.blockingErrors.isEmpty
                      ? "Validate, save and apply the edited settings"
                      : session.blockingErrors.joined(separator: "\n"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Live-effect indication

    /// How a settings group reaches the live pipeline (W04 acceptance: every
    /// group declares its live effect explicitly).
    private enum SettingEffect {
        /// Reaches the pipeline in place, even mid-stream (mic volume).
        case immediate
        /// Applies in place when idle; staged for the next session while an
        /// output owns the encode geometry (canvas/fps — the W07 model).
        case immediateOrStaged
        /// Read at session start; takes effect at the next Go Live / preview
        /// start (connection, bitrate, codec, input device, voice polish).
        case nextSession
    }

    private func effectBadge(_ effect: SettingEffect) -> some View {
        let (text, icon): (String, String)
        switch effect {
        case .immediate:
            (text, icon) = ("Applies immediately.", "bolt.fill")
        case .immediateOrStaged where session.isOutputActive:
            (text, icon) = ("Applies on next session — an output is active.",
                            "clock.badge.exclamationmark")
        case .immediateOrStaged:
            (text, icon) = ("Applies immediately.", "bolt.fill")
        case .nextSession where session.isOutputActive:
            (text, icon) = ("Applies on next session — an output is active.",
                            "clock.badge.exclamationmark")
        case .nextSession:
            (text, icon) = ("Applies at the next Go Live or preview start.",
                            "arrow.triangle.2.circlepath")
        }
        return Label(text, systemImage: icon)
    }

    // MARK: - Connection

    @ViewBuilder
    private var connectionSection: some View {
        Section {
            Picker("Protocol", selection: Binding(
                get: { session.draft.selectedProtocol },
                set: { session.selectProtocol($0) }
            )) {
                ForEach(StreamProtocol.allCases, id: \.self) { proto in
                    Text(proto.displayName).tag(proto)
                }
            }
            .pickerStyle(.segmented)

            TextField("Server URL", text: $session.draft.rtmpURL,
                      prompt: Text(session.draft.selectedProtocol.urlPlaceholder))
                .autocorrectionDisabled(true)
            if let error = SettingsValidator.serverURLError(
                session.draft.rtmpURL, for: session.draft.selectedProtocol) {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            // RTMP/RTMPS need a separate stream key; SRT/WHIP embed everything
            // (streamid, passphrase, token) in the URL query — so just one field.
            if session.draft.selectedProtocol.requiresKey {
                SecureField(session.draft.selectedProtocol.keyFieldLabel,
                            text: $session.draft.streamKey)
                    .autocorrectionDisabled(true)
                if let error = SettingsValidator.streamKeyError(
                    session.draft.streamKey, for: session.draft.selectedProtocol) {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        } header: {
            Text("Connection")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                effectBadge(.nextSession)
                if session.draft.isPublishable {
                    Label(
                        session.draft.isSecure ? "Encrypted connection." : "Unencrypted connection.",
                        systemImage: session.draft.isSecure ? "lock.fill" : "lock.open"
                    )
                } else {
                    Text("Enter a valid \(session.draft.selectedProtocol.displayName) URL\(session.draft.selectedProtocol.requiresKey ? " and stream key" : "") before going live. Get your key at restream.io.")
                }
                Label("Each protocol's URL + key are saved separately in your Keychain, shared with the iOS app.", systemImage: "key.fill")
            }
        }
    }

    // MARK: - Video

    /// Writes a new profile, keeping the legacy short-edge/fps fields the iOS
    /// app still reads in sync with the shared settings snapshot.
    private func setProfile(_ profile: OutputProfile) {
        session.draft.outputProfile = profile
        session.draft.videoQuality = min(profile.canvasWidth, profile.canvasHeight)
        session.draft.frameRate = profile.frameRate
    }

    @ViewBuilder
    private var videoSection: some View {
        Section {
            Picker("Canvas", selection: Binding(
                get: { selectedPreset },
                set: { preset in
                    presetOverride = preset
                    if let size = preset.size {
                        setProfile(session.draft.outputProfile.with(canvasWidth: size.width,
                                                                    canvasHeight: size.height))
                    }
                }
            )) {
                ForEach(CanvasPreset.allCases, id: \.self) { preset in
                    if let size = preset.size {
                        let profile = OutputProfile(canvasWidth: size.width, canvasHeight: size.height,
                                                    frameRate: session.draft.outputProfile.frameRate)
                        Text(preset.displayName)
                            .tag(preset)
                            .disabled(capabilities.gateReason(for: profile,
                                                              destination: session.draft.selectedProtocol) != nil)
                    } else {
                        Text(preset.displayName).tag(preset)
                    }
                }
            }

            if selectedPreset == .custom {
                HStack {
                    TextField("Width", value: Binding(
                        get: { session.draft.outputProfile.canvasWidth },
                        set: { setProfile(session.draft.outputProfile.with(canvasWidth: $0)) }
                    ), format: .number)
                    .frame(maxWidth: 90)
                    Text("×")
                        .foregroundStyle(.secondary)
                    TextField("Height", value: Binding(
                        get: { session.draft.outputProfile.canvasHeight },
                        set: { setProfile(session.draft.outputProfile.with(canvasHeight: $0)) }
                    ), format: .number)
                    .frame(maxWidth: 90)
                    Text("px, even values only")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Picker("Frame Rate", selection: Binding(
                get: { min(session.draft.outputProfile.frameRate,
                           capabilities.maxFrameRate(for: session.draft.selectedProtocol)) },
                set: { setProfile(session.draft.outputProfile.with(frameRate: $0)) }
            )) {
                ForEach(OutputCapabilities.supportedFrameRates, id: \.self) { fps in
                    Text("\(fps) fps")
                        .tag(fps)
                        .disabled(fps > capabilities.maxFrameRate(for: session.draft.selectedProtocol))
                }
            }

            VStack(alignment: .leading) {
                HStack {
                    Text("Maximum Bitrate")
                    Spacer()
                    Text(String(format: "%.1f Mbps", Double(session.draft.videoBitrate) / 1_000_000))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(
                    value: Binding(
                        get: { Double(session.draft.videoBitrate) },
                        set: { session.draft.videoBitrate = Int($0) }
                    ),
                    in: 1_000_000...12_000_000,
                    step: 500_000
                )
            }

            Picker("Codec", selection: Binding(
                get: { session.draft.effectiveVideoCodec },
                set: { session.draft.videoCodec = $0 }
            )) {
                ForEach(session.draft.selectedProtocol.supportedVideoCodecs, id: \.self) { codec in
                    Text(codec.displayName).tag(codec)
                }
            }
        } header: {
            Text("Video")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                effectBadge(.immediateOrStaged)
                if let reason = capabilities.gateReason(for: session.draft.outputProfile,
                                                        destination: session.draft.selectedProtocol) {
                    Label("The current profile exceeds this \(session.draft.selectedProtocol.displayName) destination: \(reason). It will be reduced when the next session starts.",
                          systemImage: "exclamationmark.triangle")
                }
                Text("The canvas is fixed by this profile — a camera or screen source changing size never resizes the program; sources are fit into the canvas. Bitrate is a maximum and drops automatically when the uplink is congested. H.264 is recommended for Restream — traditional RTMP ingests do not accept HEVC.")
                if session.draft.effectiveVideoCodec == .hevc {
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
            Picker("Microphone", selection: Binding(
                get: { session.draft.preferredAudioInputUID ?? "" },
                set: { session.draft.preferredAudioInputUID = $0.isEmpty ? nil : $0 }
            )) {
                Text("System Default").tag("")
                ForEach(controller.audio.devices, id: \.uniqueID) { device in
                    Text(device.localizedName).tag(device.uniqueID)
                }
            }

            VStack(alignment: .leading) {
                HStack {
                    Text("Mic Volume")
                    Spacer()
                    Text(session.draft.micVolume <= 0.0001
                         ? "Muted"
                         : "\(Int((session.draft.micVolume * 100).rounded()))%")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $session.draft.micVolume, in: 0.0...2.0, step: 0.05)
            }

            Toggle("Voice Polish", isOn: $session.draft.voicePolishEnabled)
            Text("Broadcast-style EQ, compression and limiting on the mic.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Audio")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Label("Mic volume applies immediately, even while live.", systemImage: "bolt.fill")
                effectBadge(.nextSession)
                Text("Microphone choice and Voice Polish are read when a session starts.")
            }
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
            VStack(alignment: .leading, spacing: 4) {
                effectBadge(.immediate)
                Text("Register an app at dashboard.restream.io, set its redirect URI to \(RestreamAPI.redirectURI), then paste the Client ID + Secret here and sign in. Chat from every connected platform appears in the sidebar.")
            }
        }
    }

    // MARK: - Application

    @ViewBuilder
    private func permissionRow(_ kind: PermissionsManager.Kind) -> some View {
        let status = permissions.status(for: kind)
        HStack {
            Label(kind.title,
                  systemImage: status == .granted ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                .foregroundStyle(status == .granted ? .green : .orange)
            if status == .denied {
                Text("Denied")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            }
            Spacer()
            if status == .needsRequest {
                Button("Request…") {
                    Task { await permissions.request(kind) }
                }
            }
            Button("System Settings…") {
                permissions.openSystemSettings(for: kind)
            }
        }
        .font(.callout)
        .help(permissions.repairAction(for: kind)?.message ?? kind.purpose)
    }

    @ViewBuilder
    private var applicationSection: some View {
        Section {
            permissionRow(.camera)
            permissionRow(.microphone)
            permissionRow(.screenCapture)

            Button("Restore Default Panel Layout", action: onResetLayout)
        } header: {
            Text("Application")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                effectBadge(.immediate)
                Text("Capture permissions are macOS-level; the app re-reads them when it becomes active. A denied source shows its repair action here and when the source is next used.")
            }
        }
    }
}
