import SwiftUI
import Observation
import AVFAudio
import StreamCore
import UIKit
import os

/// The settings sections. Each is launched from the settings list into its own
/// Vaul-style sheet holding exactly that section's controls.
private enum SettingsSection: String, Identifiable, CaseIterable {
    case connection, video, backup, audio, pip, chat

    var id: String { rawValue }

    var title: String {
        switch self {
        case .connection: "Connection"
        case .video:      "Video"
        case .backup:     "Local Backup"
        case .audio:      "Audio"
        case .pip:        "Picture in Picture"
        case .chat:       "Chat"
        }
    }

    var icon: String {
        switch self {
        case .connection: "antenna.radiowaves.left.and.right"
        case .video:      "video.fill"
        case .backup:     "internaldrive.fill"
        case .audio:      "mic.fill"
        case .pip:        "person.crop.rectangle"
        case .chat:       "bubble.left.and.bubble.right.fill"
        }
    }

    var tint: Color {
        switch self {
        case .connection: .blue
        case .video:      .purple
        case .backup:     .gray
        case .audio:      .pink
        case .pip:        .orange
        case .chat:       .green
        }
    }
}

/// The settings launcher: a list of sections, each of which opens its controls in
/// the same content-hugging sheet. Every field edit
/// mutates the bound `settings` and calls `onChange()` so the parent persists the
/// snapshot via `SettingsStore` BEFORE the user can start a broadcast.
struct SettingsView: View {
    @Binding var settings: StreamSettings

    /// Restream unified-chat controller, shared with the main feed. Owned by the
    /// root view so the connection survives the settings sheet being dismissed.
    var chat: RestreamChat

    /// The live capture controller, so the launcher can show a live stats/uptime
    /// card while broadcasting. Read-only here; its `@Observable` telemetry drives
    /// the card's updates.
    var capture: ScreenCaptureController

    /// Called after any field mutation so the parent can persist immediately.
    var onChange: () -> Void

    /// Audio input enumeration helper (AVAudioSession-backed, Simulator-safe).
    /// Owned by the root view so route-change monitoring (and the Bluetooth-connect
    /// banner it drives) runs continuously, not only while this sheet is open.
    var audio: AudioInputProvider

    /// Camera permission + device-capability helper for the facecam.
    @State private var camera = CameraSupport()

    /// Photos add-only permission helper for the Local Backup feature.
    @State private var photos = PhotosSupport()

    /// Smoothed live level published by the ScreenCaptureKit sample router. Owned by
    /// the root view and shared with the toolbar's status meter — two instances would
    /// open competing record sessions when the meter falls back to local capture.
    var micLevel: MicrophoneLevelMonitor

    // MARK: - Chat credential fields

    @State private var clientIDField = ""
    @State private var clientSecretField = ""
    /// Forces the credential fields to show even when a Restream app is already
    /// stored, so the user can replace it.
    @State private var editingChatCredentials = false

    // MARK: - Quality presets

    /// Target SHORT edge (px). The long edge follows the live screen aspect, so
    /// the stream is portrait when the screen is portrait. 720 is the stable
    /// default for simultaneous capture, encoding, and publishing.
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
        1_000_000, 2_000_000, 3_000_000, 4_500_000, 6_000_000, 8_000_000, 10_000_000, 12_000_000
    ]
    private static let audioBitrates: [Int] = [64_000, 96_000, 128_000, 192_000, 256_000]
    private static let frameRates: [Int] = [24, 30, 60]

    /// This device's resolution/fps ceiling. Gates the Quality and Frame Rate
    /// menus below so they never offer more than the hardware can actually stream
    /// (1080p60 on capable devices, 720p30 on older ones).
    private var capability: StreamCapability { .current }

    private func bitrateLabel(_ bps: Int) -> String {
        String(format: "%.1f Mbps", Double(bps) / 1_000_000)
    }

    private func audioBitrateLabel(_ bps: Int) -> String {
        "\(bps / 1000) kbps"
    }

    /// Dismisses the whole settings drawer (the "Done" affordance).
    @Environment(\.dismiss) private var dismiss

    /// The section currently shown, or `nil` for the launcher. Not a full stack —
    /// the drawer is exactly two levels deep (launcher → one section), so a single
    /// optional models it. Owning the level ourselves (instead of a NavigationStack
    /// push) lets one animation drive the content morph and sheet resize together.
    @State private var selected: SettingsSection?

    /// Vaul-style content-hugging detent. Only the pane currently on screen reports
    /// a height; previously visited panes are cached by the model. This preserves
    /// the dynamic drawer without rebuilding six hidden Forms behind every update.
    @State private var detent = DynamicDetentSheetModel(
        initialHeight: 420,
        chrome: 100,
        minimumContentHeight: 160,
        animation: .spring(duration: 0.45, bounce: 0.1)
    )

    var body: some View {
        // A NavigationStack purely for the system Liquid Glass chrome — the glass nav
        // bar, glass toolbar buttons, and inline title. It does NOT push via the nav
        // stack: the launcher and section are swapped with a directional slide
        // (section in from trailing / launcher out to leading = a forward push; the
        // reverse on back = a pop), driven by our own `withAnimation`.
        NavigationStack {
            ZStack(alignment: .top) {
                if let section = selected {
                    sectionDetail(section)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .transition(.move(edge: .trailing))
                } else {
                    launcherPane
                        .transition(.move(edge: .leading))
                }
            }
            .navigationTitle(selected?.title ?? "Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if selected != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { back() } label: { Image(systemName: "chevron.left") }
                            .accessibilityLabel("Back")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { Haptics.tap(); dismiss() }
                }
            }
        }
        .dynamicHeightDetents(detent)
        .presentationCornerRadius(55)
        // Haptic when a section is opened (push) or closed (pop).
        .sensoryFeedback(.impact(weight: .light), trigger: selected)
        .onAppear {
            detent.activate(SettingsSection?.none)
        }
        .onDisappear {
            micLevel.stop(for: .settings)
        }
    }

    // MARK: - Drill-in navigation

    /// Open a section and resize the drawer under the same spring transaction.
    private func open(_ section: SettingsSection) {
        // No explicit tap here: `.sensoryFeedback(trigger: selected)` already fires
        // one light impact whenever `selected` changes.
        navigate(to: section)
    }

    /// Return to the launcher (the nav-bar back button).
    private func back() {
        // Haptic comes from `.sensoryFeedback(trigger: selected)` (see `open`).
        navigate(to: nil)
    }

    /// Cached panes resize in exact lockstep with the directional transition. On a
    /// first visit there is intentionally no hidden prewarm tree; activate the key
    /// first, then let its visible geometry report start the height spring while the
    /// slide is already moving.
    private func navigate(to destination: SettingsSection?) {
        if detent.hasMeasurement(for: destination) {
            detent.animatingResize {
                selected = destination
                detent.activate(destination)
            }
        } else {
            detent.activate(destination)
            withAnimation(detent.animation) {
                selected = destination
            }
        }
    }

    // MARK: - Launcher pane

    private var launcherPane: some View {
        List {
            // Live stats/uptime card, shown atop the launcher only while broadcasting.
            // A fixed-height leaf subview so its ~1s telemetry ticks never re-measure
            // the launcher and spring the drawer height (see LiveStatsCard).
            if capture.isLive {
                Section {
                    LiveStatsCard(capture: capture)
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowBackground(Color.clear)
            }
            Section {
                ForEach(SettingsSection.allCases) { section in
                    Button { open(section) } label: {
                        sectionRow(section)
                    }
                    .buttonStyle(.plain)
                }
            } footer: {
                Text("Tap a section to adjust it. Changes save automatically.")
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .measuredDetentHeight(SettingsSection?.none, into: detent)
    }

    // MARK: - Launcher rows

    @ViewBuilder
    private func sectionRow(_ section: SettingsSection) -> some View {
        HStack(spacing: 12) {
            Image(systemName: section.icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 29, height: 29)
                .background(section.tint, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(section.title)
                    .foregroundStyle(.primary)
                Text(summary(for: section))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            // Disclosure affordance the old NavigationLink drew for us.
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Section detail body

    /// One section's controls — the Form that fills the section pane and scrolls
    /// when its content is taller than the current content-hugging detent.
    @ViewBuilder
    private func sectionForm(_ section: SettingsSection) -> some View {
        Form {
            switch section {
            case .connection: connectionSection
            case .video:      videoSection
            case .backup:     backupSection
            case .audio:      audioSection
            case .pip:        pipSection
            case .chat:       chatSection
            }
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    /// One section's controls, shown in the detail pane: reports its height under its
    /// own identity and runs the live mic meter only while the Audio detail is open.
    private func sectionDetail(_ section: SettingsSection) -> some View {
        sectionForm(section)
            .measuredDetentHeight(Optional(section), into: detent)
            .onAppear {
                switch section {
                case .audio:
                    micLevel.setGain(settings.micVolume)
                    micLevel.setPreferredInput(settings.preferredAudioInputUID)
                    micLevel.setBroadcasting(capture.isLive)
                    micLevel.start(for: .settings)
                case .pip:
                    camera.refresh()
                case .backup:
                    photos.refresh()
                default:
                    break
                }
            }
            .onChange(of: capture.isLive) { _, isLive in
                guard section == .audio else { return }
                micLevel.setBroadcasting(isLive)
            }
            .onDisappear {
                if section == .audio { micLevel.stop(for: .settings) }
            }
    }

    // MARK: - Launcher summaries

    private func summary(for section: SettingsSection) -> String {
        switch section {
        case .connection:
            return settings.isPublishable
                ? "\(settings.selectedProtocol.displayName) · \(settings.isSecure ? "Secure" : "Unencrypted")"
                : "\(settings.selectedProtocol.displayName) · Not configured"
        case .video:
            // Show the EFFECTIVE (device-capped) values, matching the Quality and
            // Frame Rate pickers — so the collapsed row never over-promises a
            // resolution/fps the device won't actually stream (e.g. a settings blob
            // restored from a more capable phone).
            let quality = min(settings.videoQuality, capability.maxShortEdge)
            let fps = min(settings.frameRate, capability.maxFrameRate)
            // Surface HEVC (the opt-in) in the collapsed row; H.264 stays implicit.
            let codec = settings.effectiveVideoCodec == .hevc ? " · HEVC" : ""
            return "\(quality)p · \(bitrateLabel(settings.videoBitrate)) · \(fps) fps\(codec)"
        case .backup:
            return "Off"
        case .audio:
            return audioSummary
        case .pip:
            return settings.pipEnabled ? "On · \(cornerLabel(settings.pipCorner))" : "Off"
        case .chat:
            return chatSummary
        }
    }

    private var audioSummary: String {
        let name: String
        if let uid = selectedAudioInputUID,
           let input = audio.inputs.first(where: { $0.uid == uid }) {
            name = input.displayName
        } else {
            name = "Default"
        }
        let volume = settings.micVolume <= 0.0001
            ? "Muted"
            : "\(Int((settings.micVolume * 100).rounded()))% mic"
        return "\(name) · \(volume)"
    }

    private var chatSummary: String {
        switch chat.status {
        case .connected:  return "Connected to Restream"
        case .connecting: return "Connecting…"
        case .needsCredentials, .signedOut, .failed:
            return chat.hasCredentials ? "Not connected" : "Not set up"
        }
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
                    // Cancels any pending snapshot for the previous protocol and
                    // queues this switched state behind the serial writer.
                    onChange()
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
                Haptics.tap()
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
                // Show the EFFECTIVE value: a stored pick above this device's
                // ceiling displays (and streams) as the capped value rather than
                // leaving the picker with no matching selection.
                get: { min(settings.videoQuality, capability.maxShortEdge) },
                set: { settings.videoQuality = $0; onChange() }
            )) {
                ForEach(Self.qualities.filter { $0 <= capability.maxShortEdge }, id: \.self) { q in
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
                get: { min(settings.frameRate, capability.maxFrameRate) },
                set: { settings.frameRate = $0; onChange() }
            )) {
                ForEach(Self.frameRates.filter { $0 <= capability.maxFrameRate }, id: \.self) { fps in
                    Text("\(fps) fps").tag(fps)
                }
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
            videoFooter
        }
    }

    @ViewBuilder
    private var videoFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Bitrate is a maximum and drops automatically when the uplink is congested. Resolution and frame rate are limited to what this device can sustain, and are reduced automatically when it runs warm or low on power.")
            if settings.effectiveVideoCodec == .hevc {
                Label("HEVC saves roughly 40% bitrate on screen content, but needs a compatible ingest — SRT or an enhanced-RTMP server. WHIP and traditional RTMP services (e.g. Restream) require H.264.",
                      systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }
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
            Text("Disabled for streaming stability. A second real-time H.264 encoder substantially increases memory, thermal, and power pressure.")
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
                        // Flag every external input, not just Bluetooth — a USB-C
                        // receiver is exactly the row the user is hunting for.
                        if input.isExternal {
                            Image(systemName: input.icon)
                        }
                        Text(input.displayName)
                    }
                    .tag(Optional(input.uid))
                }
            }

            MicrophoneLevelMeterView(monitor: micLevel)

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
                            capture.setMicVolume(settings.micVolume)
                        }
                    }
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
            HStack {
                Text("Audio")
                Spacer()
                Button {
                    Haptics.tap()
                    audio.refresh(requestPermission: true)
                    // Session enumeration and the meter restart share one serial
                    // audio queue, so repeated refreshes cannot overlap handoffs.
                    micLevel.restartLocalCapture()
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
                    capture.setPIPEnabled(newValue)
                    onChange()
                }
            ))

            if settings.pipEnabled {
                Picker("Corner", selection: Binding(
                    get: { settings.pipCorner },
                    set: {
                        settings.pipCorner = $0
                        capture.setPIPCorner($0)
                        onChange()
                    }
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
                            set: {
                                settings.pipScale = $0
                                capture.setPIPScale($0)
                                onChange()
                            }
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
                    Haptics.tap()
                    chat.signOut()
                }

            case .connecting:
                Label { Text("Connecting to Restream…") } icon: {
                    ProgressView().controlSize(.mini)
                }

            case .needsCredentials, .signedOut, .failed:
                if chat.hasCredentials && !editingChatCredentials {
                    Button("Connect with Restream") { Haptics.tap(); chat.connect() }
                    Button("Change Restream App") { Haptics.tap(); editingChatCredentials = true }
                } else {
                    TextField("Client ID", text: $clientIDField)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Client Secret", text: $clientSecretField)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Save & Connect") {
                        Haptics.tap()
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

/// The live stats/uptime card shown atop the settings launcher while broadcasting.
/// A leaf view so its ~1s telemetry ticks invalidate only this subtree (not the
/// whole launcher List), and every value is monospaced + single-line so the card's
/// height is invariant per tick, avoiding needless list relayout as values change.
private struct LiveStatsCard: View {
    var capture: ScreenCaptureController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            metricsRow
            if let notice = capture.thermalNotice {
                Label(notice, systemImage: "thermometer.medium")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            droppedNotice
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// Red LIVE marker + the elapsed timer. The clock ticks inside its own
    /// `TimelineView` off `broadcastStartedAt` (a Date), so it survives backgrounding
    /// and invalidates only this line.
    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(.red).frame(width: 8, height: 8)
            Text("LIVE")
                .font(.caption.weight(.bold))
                .foregroundStyle(.red)
            Spacer()
            if let start = capture.broadcastStartedAt {
                TimelineView(.periodic(from: start, by: 1)) { context in
                    Text(LiveStats.uptimeLabel(seconds: Int(context.date.timeIntervalSince(start))))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                }
            }
        }
    }

    /// Bitrate (ABR target) · achieved fps · uplink health. Bitrate is the encoder's
    /// applied target; FPS is the MEASURED achieved rate (M8), falling back to the
    /// target for the first second before a rate is available.
    private var metricsRow: some View {
        HStack(spacing: 0) {
            metric("Bitrate", value: capture.liveStats?.bitRateLabel ?? "—")
            divider
            metric("FPS", value: capture.liveStats.map { "\($0.displayFrameRate)" } ?? "—")
            divider
            metric("Uplink", value: capture.liveStats?.linkHealth.label ?? "—", tint: uplinkTint)
        }
    }

    /// A subtle count of the frames congestion has shed this session (backpressure +
    /// admission). Hidden until the first drop, so a healthy stream shows nothing;
    /// the coloured Uplink metric already carries the live severity signal.
    @ViewBuilder private var droppedNotice: some View {
        if let stats = capture.liveStats, stats.droppedFrames > 0 {
            Label("\(stats.droppedLabel) frames dropped", systemImage: "square.stack.3d.up.slash")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private var divider: some View { Divider().frame(height: 26) }

    private var uplinkTint: Color {
        switch capture.liveStats?.linkHealth {
        case .good:      return .green
        case .fair:      return .yellow
        case .congested: return .red
        case .none:      return .secondary
        }
    }

    private func metric(_ label: String, value: String, tint: Color = .primary) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        // One element per metric read as "Bitrate: 2.4 Mbps", not the raw
        // value-then-label order the VStack would otherwise expose.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }
}

#Preview {
    @Previewable @State var settings = StreamSettings.default
    return NavigationStack {
        SettingsView(settings: $settings, chat: RestreamChat(),
                     capture: ScreenCaptureController(), onChange: {},
                     audio: AudioInputProvider(), micLevel: MicrophoneLevelMonitor())
    }
}
