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
    /// Apply/Revert route through the W05 command layer like every studio action.
    @EnvironmentObject private var dispatcher: StudioCommandDispatcher

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
                    capturePrivacySection.id(SettingsSession.Section.capturePrivacy)
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
            Button("Revert") { dispatcher.execute(.revertSettings) }
                .disabled(!session.isDirty)
                .help("Discard every unapplied edit")
            Button("Apply") { dispatcher.execute(.applySettings) }
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

    // MARK: - Capture privacy (C03, issue #78)

    /// The global privacy defaults every screen capture starts from. The
    /// per-source editor (Sources tab → Privacy…) can override cursor/audio
    /// and add exclusions; it can never REMOVE a default exclusion.
    @ViewBuilder
    private var capturePrivacySection: some View {
        Section {
            Toggle("Show Cursor in Captures", isOn: $session.draft.captureShowsCursor)
            Toggle("Include App Audio in Captures", isOn: $session.draft.captureIncludesAudio)

            ForEach(session.draft.captureExcludedBundleIDs, id: \.self) { bundleID in
                HStack {
                    Label {
                        Text(RunningAppList.name(for: bundleID))
                            .lineLimit(1)
                    } icon: {
                        Image(systemName: "eye.slash")
                    }
                    Spacer()
                    Button {
                        session.draft.captureExcludedBundleIDs.removeAll { $0 == bundleID }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Stop excluding this app by default")
                }
            }
            Menu("Always Exclude an App…") {
                let candidates = RunningAppList.candidates(
                    excluding: Set(session.draft.captureExcludedBundleIDs))
                if candidates.isEmpty {
                    Text("No other running apps")
                } else {
                    ForEach(candidates, id: \.bundleID) { candidate in
                        Button(candidate.name) {
                            session.draft.captureExcludedBundleIDs.append(candidate.bundleID)
                        }
                    }
                }
            }
        } header: {
            Text("Capture Privacy")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Label("Applies to captures started after Apply.", systemImage: "arrow.triangle.2.circlepath")
                Text("Defaults for every screen source; a source can override cursor/audio and add its own exclusions from the Sources tab. StreamMac's own windows are always excluded from pinned display captures, including sheets and windows opened later, so the studio never captures itself. Sources chosen through the system content picker are managed by macOS and can't carry app exclusions — pin the source from the Sources tab for full control.")
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
            Text("Broadcast-style EQ, compression and limiting on the mic. Voice Polish is the default chain for every mic channel without its own; per-channel effect chains (high-pass, gate, EQ, compressor, limiter) are edited live from each mixer strip's FX button.")
                .font(.caption)
                .foregroundStyle(.secondary)

            additionalInputsBlock

            monitoringBlock

            echoHandlingBlock

            avSyncAndDuckingBlock
        } header: {
            Text("Audio")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Label("Mic volume applies immediately, even while live.", systemImage: "bolt.fill")
                effectBadge(.nextSession)
                Text("Microphone choice is read when a session starts; Voice Polish and per-channel FX apply live. Additional inputs and their channel mappings apply immediately, each as its own mixer channel. Monitoring is heard while the studio pipeline is running (Preview, stream, or recording); its level is the mixer's Monitor fader, and soloing a channel auditions it on the monitor output only.")
            }
        }
    }

    // MARK: - A07 headphone monitoring (issue #119)

    /// The monitor output plays the mixer's MONITOR bus (same routing as
    /// program, independent level, monitor-only solo for per-channel
    /// audition) through a chosen output device. Edits are live session
    /// state (like the mixer): they persist and apply immediately through
    /// the W05 dispatcher. A pinned device that unplugs falls back to the
    /// system default honestly and re-pins when it returns; a monitor
    /// device that is also an enabled input is flagged as a feedback risk.
    @ViewBuilder
    private var monitoringBlock: some View {
        Text("Headphone Monitoring")
            .font(.callout.weight(.semibold))
        Toggle("Enable Monitoring", isOn: Binding(
            get: { session.activeSettings.monitoringEnabled },
            set: { dispatcher.execute(.setMonitoringEnabled($0)) }
        ))
        Picker("Monitor Output", selection: Binding(
            get: { session.activeSettings.monitorOutputDeviceUID ?? "" },
            set: { dispatcher.execute(.setMonitorOutputDevice(uid: $0.isEmpty ? nil : $0)) }
        )) {
            Text("System Default").tag("")
            ForEach(controller.monitorOutput.devices) { device in
                Text(device.name).tag(device.uid)
            }
        }
        .disabled(!session.activeSettings.monitoringEnabled)
        if controller.monitorOutput.isFallbackActive {
            Label("The selected output is disconnected — monitoring through the System Default until it returns.",
                  systemImage: "cable.connector.slash")
                .font(.caption)
                .foregroundStyle(.orange)
        }
        if let error = controller.monitorOutput.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        }
        if let riskUID = controller.monitorFeedbackRiskDeviceUID {
            let name = controller.audio.deviceNamesByUID[riskUID] ?? riskUID
            Label("Feedback risk: \"\(name)\" is both the monitor output and an enabled input — the monitor signal can loop into the program mix. Disable that input or pick another output.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    // MARK: - A09 echo handling & feedback diagnostics (issue #121)

    /// Echo handling is honest about the platform: macOS has no built-in AEC
    /// usable from Stream's capture architecture (VoiceProcessingIO is
    /// deprecated and incompatible — see `EchoHandlingEvaluation`), so the
    /// modes are Off and a Voice Isolation PREFERENCE (the OS mic mode is
    /// user-controlled; Stream reports its live state and guides). Feedback
    /// diagnostics surface below with one-click routing repairs. Edits are
    /// live session state (like monitoring) through the W05 dispatcher.
    @ViewBuilder
    private var echoHandlingBlock: some View {
        Text("Echo & Feedback")
            .font(.callout.weight(.semibold))
        Picker("Echo Handling", selection: Binding(
            get: { session.activeSettings.echoHandlingMode },
            set: { dispatcher.execute(.setEchoHandlingMode($0)) }
        )) {
            ForEach(EchoHandlingMode.allCases, id: \.self) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        // The channel/stereo limitations are displayed BEFORE the mode takes
        // effect (issue #121), and Stream never stacks a second suppressor
        // on top of the OS processing.
        Text(session.activeSettings.echoHandlingMode.limitationNote)
            .font(.caption)
            .foregroundStyle(.secondary)
        if session.activeSettings.echoHandlingMode == .voiceIsolation {
            switch controller.voiceIsolationActive {
            case .some(true):
                Label("Voice Isolation is active on the microphone. Stream applies no additional echo suppression on top.",
                      systemImage: "checkmark.shield.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            case .some(false):
                Label("Voice Isolation is not active — while the mic is in use, open Control Center → Mic Mode and choose Voice Isolation.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            case nil:
                Label("The Voice Isolation state is read once the mic is running.",
                      systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        ForEach(controller.feedbackDiagnostics.routeIssues) { issue in
            VStack(alignment: .leading, spacing: 4) {
                Label(issue.title, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                Text(issue.fix)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(repairTitle(for: issue.repair)) {
                    repairFeedbackRoute(issue.repair)
                }
                .controlSize(.small)
            }
        }
    }

    private func repairTitle(for repair: FeedbackRouteIssue.Repair) -> String {
        switch repair {
        case .disableInput: return "Disable That Input"
        case .muteDefaultMic: return "Mute the Mic"
        case .disableMonitoring: return "Disable Monitoring"
        case .lowerMonitor: return "Lower the Monitor Level"
        }
    }

    /// The concrete routing repair (issue #121): one dispatch of an existing
    /// studio command — never a silent automatic change.
    private func repairFeedbackRoute(_ repair: FeedbackRouteIssue.Repair) {
        switch repair {
        case .disableInput(let uid):
            dispatcher.execute(.setAudioInputEnabled(uid, false))
        case .muteDefaultMic:
            dispatcher.execute(.setChannelMuted(.microphone(deviceUID: nil), true))
        case .disableMonitoring:
            dispatcher.execute(.setMonitoringEnabled(false))
        case .lowerMonitor:
            let current = session.activeSettings.mixer.busGains[AudioBus.monitor.rawValue] ?? 1
            dispatcher.execute(.setBusGain(.monitor, max(0, current / 2)))
        }
    }

    // MARK: - A05 additional inputs (issue #84)

    /// Every connected input device (minus the one the default microphone
    /// already uses) can be enabled as its OWN mix channel, and every
    /// enabled-but-unplugged device stays listed honestly with a relink
    /// path. Enable/mapping edits are live session state (like the mixer):
    /// they persist and apply immediately through the W05 dispatcher.
    @ViewBuilder
    private var additionalInputsBlock: some View {
        let configured = session.activeSettings.audioInputs
        let connected = controller.audio.devices
        let preferredUID = session.draft.preferredAudioInputUID
        let listed = connected.filter { $0.uniqueID != preferredUID }
        let missing = configured.filter { selection in
            selection.isEnabled
                && selection.deviceUID != preferredUID
                && !connected.contains(where: { $0.uniqueID == selection.deviceUID })
        }
        if !listed.isEmpty || !missing.isEmpty {
            Text("Additional Inputs")
                .font(.callout.weight(.semibold))
            ForEach(listed, id: \.uniqueID) { device in
                additionalInputRow(
                    device: device,
                    selection: configured.first(where: { $0.deviceUID == device.uniqueID }))
            }
            ForEach(missing, id: \.deviceUID) { selection in
                missingInputRow(selection: selection)
            }
        }
    }

    @ViewBuilder
    private func additionalInputRow(device: AVCaptureDevice,
                                    selection: AudioInputSelection?) -> some View {
        let uid = device.uniqueID
        let enabled = selection?.isEnabled ?? false
        VStack(alignment: .leading, spacing: 4) {
            Toggle(device.localizedName, isOn: Binding(
                get: { enabled },
                set: { dispatcher.execute(.setAudioInputEnabled(uid, $0)) }
            ))
            if enabled {
                let channelCount = controller.audio.deviceChannelCounts[uid] ?? 1
                if channelCount > 1 {
                    // Audio-interface channel mapping: which hardware inputs
                    // feed this device's mix channel.
                    Picker("Channels", selection: Binding(
                        get: { selection?.mapping ?? .all },
                        set: { dispatcher.execute(.setAudioInputMapping(uid, $0)) }
                    )) {
                        Text("All \(channelCount) Inputs").tag(AudioInputMapping.all)
                        ForEach(0..<channelCount, id: \.self) { channel in
                            Text("Input \(channel + 1) (mono)")
                                .tag(AudioInputMapping.mono(channel))
                        }
                        ForEach(0..<max(0, channelCount - 1), id: \.self) { left in
                            Text("Inputs \(left + 1) + \(left + 2) (stereo)")
                                .tag(AudioInputMapping.stereo(left, left + 1))
                        }
                    }
                }
                if let error = controller.audio.additionalInputErrors[uid] {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    @ViewBuilder
    private func missingInputRow(selection: AudioInputSelection) -> some View {
        let uid = selection.deviceUID
        VStack(alignment: .leading, spacing: 4) {
            Toggle(controller.audio.deviceNamesByUID[uid] ?? "Missing input", isOn: Binding(
                get: { true },
                set: { dispatcher.execute(.setAudioInputEnabled(uid, $0)) }
            ))
            Label("Disconnected — reconnect it, or relink to another input.",
                  systemImage: "cable.connector.slash")
                .font(.caption)
                .foregroundStyle(.orange)
            inputRelinkMenu(for: uid)
        }
    }

    /// The explicit relink path (C10: a different device is never
    /// substituted silently) — replace the missing device's UID with a
    /// connected one, keeping the input's enable/mapping.
    @ViewBuilder
    private func inputRelinkMenu(for uid: String) -> some View {
        let candidates = controller.audio.devices.filter { device in
            device.uniqueID != uid && !session.activeSettings.audioInputs.contains {
                $0.deviceUID == device.uniqueID && $0.isEnabled
            }
        }
        Menu("Relink…") {
            if candidates.isEmpty {
                Text("No other inputs connected")
            } else {
                ForEach(candidates, id: \.uniqueID) { device in
                    Button(device.localizedName) {
                        dispatcher.execute(.relinkAudioInput(from: uid, to: device.uniqueID))
                    }
                }
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

            StudioInterfacePreferences()
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

    // MARK: - A10 A/V sync + speech ducking (issue #122)

    /// The engine's live ducked-channel set (labels), polled while the pane
    /// is open so each duck-target row can show its "ducking now" state.
    @State private var duckedChannelLabels: Set<String> = []

    /// Per-source capture-latency compensation (audio delay per mic channel,
    /// video delay per camera/screen source) and the speech-driven music
    /// ducker. All edits are live session state (the monitoring/additional-
    /// inputs precedent): they persist and apply immediately through the W05
    /// dispatcher — engine read-window shifts, frame-hold re-targeting, and
    /// ramped duck automation, never a capture restart or clock re-anchor.
    @ViewBuilder
    private var avSyncAndDuckingBlock: some View {
        Text("A/V Sync")
            .font(.callout.weight(.semibold))
        audioDelayRow(title: "Microphone Delay",
                      channel: .microphone(deviceUID: nil))
        ForEach(session.activeSettings.audioInputs.filter(\.isEnabled), id: \.deviceUID) { selection in
            audioDelayRow(title: "\(controller.audio.deviceNamesByUID[selection.deviceUID] ?? "Input") Delay",
                          channel: .microphone(deviceUID: selection.deviceUID))
        }
        ForEach(controller.sceneStore.sources.filter {
            if case .camera = $0.payload { return true }
            if case .screen = $0.payload { return true }
            return false
        }, id: \.id) { source in
            videoDelayRow(source: source)
        }
        Text("Delay compensates per-source hardware latency: a source that arrives EARLY gets delayed to match the others (a camera's video is usually the late one — delay its audio path's counterparts instead). Changes apply immediately; delays are bounded at \(Int(AVSyncDelay.maxAudioDelayMs)) ms.")
            .font(.caption)
            .foregroundStyle(.secondary)

        duckingBlock
    }

    private func audioDelayRow(title: String, channel: AudioChannelID) -> some View {
        let ms = dispatcher.state.audioDelaysMs[channel.label] ?? 0
        return delaySlider(title: title, value: ms, range: 0...AVSyncDelay.maxAudioDelayMs,
                           step: 5, unit: "ms") {
            dispatcher.execute(.setChannelAudioDelay(channel, ms: $0))
        }
    }

    private func videoDelayRow(source: SourceDefinition) -> some View {
        let key = StreamController.videoDelaySettingsKey(for: source.id)
        let ms = dispatcher.state.videoDelaysMs[key] ?? 0
        return delaySlider(title: "\(source.name) Video Delay", value: ms,
                           range: 0...AVSyncDelay.maxVideoDelayMs, step: 5, unit: "ms") {
            dispatcher.execute(.setSourceVideoDelay(source.id, ms: $0))
        }
    }

    private func delaySlider(title: String, value: Double, range: ClosedRange<Double>,
                             step: Double, unit: String,
                             onEdit: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading) {
            HStack {
                Text(title)
                Spacer()
                Text(value <= 0 ? "Off" : "\(Int(value.rounded())) \(unit)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: Binding(get: { value }, set: onEdit), in: range, step: step)
        }
    }

    // MARK: A10 ducking

    @ViewBuilder
    private var duckingBlock: some View {
        let ducking = dispatcher.state.ducking
        Group {
            Text("Music Ducking")
                .font(.callout.weight(.semibold))
            Toggle("Duck Music While Speaking", isOn: duckingBinding(\.isEnabled))
        if ducking.isEnabled {
            Text("Speech Channels")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            sidechainToggle(title: "Microphone", channel: .microphone(deviceUID: nil))
            ForEach(session.activeSettings.audioInputs.filter(\.isEnabled), id: \.deviceUID) { selection in
                sidechainToggle(title: controller.audio.deviceNamesByUID[selection.deviceUID] ?? "Input",
                                channel: .microphone(deviceUID: selection.deviceUID))
            }
            duckingSlider(title: "Threshold", keyPath: \.thresholdDb,
                          range: DuckingSettings.thresholdDbRange, step: 1,
                          format: { "\(Int($0.rounded())) dB" })
            duckingSlider(title: "Reduction", keyPath: \.reductionDb,
                          range: DuckingSettings.reductionDbRange, step: 1,
                          format: { "−\(Int($0.rounded())) dB" })
            duckingSlider(title: "Attack", keyPath: \.attackMs,
                          range: DuckingSettings.attackMsRange, step: 1,
                          format: { "\(Int($0.rounded())) ms" })
            duckingSlider(title: "Hold", keyPath: \.holdMs,
                          range: 0...2_000, step: 50,
                          format: { "\(Int($0.rounded())) ms" })
            duckingSlider(title: "Release", keyPath: \.releaseMs,
                          range: 10...3_000, step: 50,
                          format: { "\(Int($0.rounded())) ms" })
            Text("Duck Targets")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            let targets = duckTargetCandidates
            if targets.isEmpty {
                Text("No music, media, or app-audio sources yet — add a playlist or source to duck it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(targets, id: \.channel) { target in
                    HStack {
                        Toggle(target.name, isOn: duckTargetBinding(target.channel))
                        if duckedChannelLabels.contains(target.channel.label) {
                            Text("ducking")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
            Text("While any speech channel is above the threshold, the selected channels are attenuated by the reduction (engine-side gain automation on top of the faders — base gain × duck gain — so bypass restores your exact mix). Duck state survives scene changes.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        }
        .task { await pollDuckState() }
    }

    /// Every channel the ducker may target: music playlists (A03), app-audio
    /// captures (A06), and registry media sources (A02) — stable channels
    /// that outlive a release ramp (pads/stingers excluded, see
    /// `SoundboardController.duckTargets`).
    private var duckTargetCandidates: [(channel: AudioChannelID, name: String)] {
        var targets = dispatcher.soundboard.duckTargets
        for source in controller.sceneStore.sources {
            switch source.payload {
            case .appAudio(let payload):
                targets.append((channel: .application(bundleID: payload.channelBundleID),
                                name: source.name))
            case .media:
                targets.append((channel: .media(source.id), name: source.name))
            default:
                break
            }
        }
        return targets
    }

    private func duckingBinding<T>(_ keyPath: WritableKeyPath<DuckingSettings, T>) -> Binding<T> {
        Binding(
            get: { dispatcher.state.ducking[keyPath: keyPath] },
            set: { value in
                var ducking = dispatcher.state.ducking
                ducking[keyPath: keyPath] = value
                dispatcher.execute(.setDucking(ducking))
            })
    }

    private func duckTargetBinding(_ channel: AudioChannelID) -> Binding<Bool> {
        Binding(
            get: { dispatcher.state.ducking.targetLabels.contains(channel.label) },
            set: { isTarget in
                var ducking = dispatcher.state.ducking
                if isTarget {
                    ducking.targetLabels.insert(channel.label)
                } else {
                    ducking.targetLabels.remove(channel.label)
                }
                dispatcher.execute(.setDucking(ducking))
            })
    }

    private func sidechainToggle(title: String, channel: AudioChannelID) -> some View {
        Toggle(title, isOn: Binding(
            get: { dispatcher.state.ducking.sidechainLabels.contains(channel.label) },
            set: { isSidechain in
                var ducking = dispatcher.state.ducking
                if isSidechain {
                    ducking.sidechainLabels.insert(channel.label)
                } else {
                    ducking.sidechainLabels.remove(channel.label)
                }
                dispatcher.execute(.setDucking(ducking))
            }))
    }

    private func duckingSlider(title: String, keyPath: WritableKeyPath<DuckingSettings, Double>,
                               range: ClosedRange<Double>, step: Double,
                               format: @escaping (Double) -> String) -> some View {
        VStack(alignment: .leading) {
            HStack {
                Text(title)
                Spacer()
                Text(format(dispatcher.state.ducking[keyPath: keyPath]))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: duckingBinding(keyPath), in: range, step: step)
        }
    }

    /// Polls the engine's duck state while the pane is open (~7 Hz — the
    /// indicator's only consumer; the mixer strips poll their own meters).
    private func pollDuckState() async {
        while !Task.isCancelled {
            let levels = await controller.mixerLevels()
            duckedChannelLabels = Set(levels.duckedChannels.map(\.label))
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
    }
}
