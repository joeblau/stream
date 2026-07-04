import SwiftUI
import Observation
import AVFAudio
import StreamCore
import UIKit
import os

/// The settings sections. Each is launched from the settings list into its own
/// Vaul-style, content-sized sheet holding exactly that section's controls.
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

/// The settings launcher: a list of sections, each of which opens a dynamic,
/// content-sized sheet holding exactly that section's controls. Every field edit
/// mutates the bound `settings` and calls `onChange()` so the parent persists the
/// snapshot via `SettingsStore` BEFORE the user can start a broadcast.
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

    /// Smoothed live level published by the ScreenCaptureKit sample router.
    @State private var micLevel = MicrophoneLevelMonitor()

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
    /// push) lets ONE `withAnimation` drive the content morph and the detent resize
    /// together as a single motion.
    @State private var selected: SettingsSection?

    /// Owns the content-sized detent and animates every resize with ITS curve, and —
    /// crucially — guards a late re-measurement from restarting the spring mid-resize
    /// (the real cause of the height feeling "desynced"). The resize speed lives in
    /// this one initializer: 0.45s reads as settled where the old 0.3s outran the slide.
    @State private var detent = DynamicDetentSheetModel(
        initialHeight: 420,
        chrome: 100,                 // nav bar + grabber + home-indicator inset
        minimumContentHeight: 160,   // floor so a short section never collapses
        animation: .spring(duration: 0.45, bounce: 0.1)
    )

    var body: some View {
        // A NavigationStack purely for the system Liquid Glass chrome — the glass nav
        // bar, glass toolbar buttons, and inline title. It does NOT push via the nav
        // stack: the launcher and section are swapped with a directional slide
        // (section in from trailing / launcher out to leading = a forward push; the
        // reverse on back = a pop), driven by our own `withAnimation` so the slide
        // and the detent resize ride the same transaction.
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
            // Measure every section's height off-screen so the FIRST open resizes
            // in lockstep with the slide, not a beat after it.
            .background(sectionHeightPrewarm)
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
        .dynamicHeightDetents(detent)   // curve-controlled height + drag indicator
        .presentationCornerRadius(55)
        // Haptic when a section is opened (push) or closed (pop).
        .sensoryFeedback(.impact(weight: .light), trigger: selected)
        .onAppear {
            // Launcher is the active pane on present; in-place field growth then
            // animates automatically via each pane's measuredDetentHeight report.
            detent.activate(SettingsSection?.none)
            // Enumerate inputs/capabilities so the launcher summaries are accurate;
            // the live mic meter only runs while the Audio detail is open.
            audio.refresh(requestPermission: false)
            camera.refresh()
            photos.refresh()
        }
    }

    // MARK: - Drill-in navigation (custom, so the content morph + resize are one motion)

    /// Open a section: it slides in (push) and the drawer resizes to fit — both
    /// inside ONE `withAnimation`, so they move as a single motion.
    private func open(_ section: SettingsSection) {
        // No explicit tap here: `.sensoryFeedback(trigger: selected)` already fires
        // one light impact whenever `selected` changes. The slide (.transition) and the
        // detent resize ride ONE transaction (detent.animation), so they move together.
        detent.animatingResize {
            selected = section
            detent.activate(Optional(section))
        }
    }

    /// Return to the launcher (the nav-bar back button).
    private func back() {
        // Haptic comes from `.sensoryFeedback(trigger: selected)` (see `open`).
        detent.animatingResize {
            selected = nil
            detent.activate(SettingsSection?.none)
        }
    }

    // MARK: - Launcher pane

    private var launcherPane: some View {
        List {
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
        .measuredDetentHeight(SettingsSection?.none, into: detent)   // launcher's own identity
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

    /// One section's controls — the Form that fills the section pane below its
    /// header. The enclosing drawer resizes to fit whichever section is on screen
    /// (via `sectionHeights` → `currentTarget`), and re-sizes as fields appear/hide
    /// within it.
    /// A section's Form (controls only), reused by both the visible detail and the
    /// hidden height pre-warm — so measuring it off-screen triggers no side effects.
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
            .measuredDetentHeight(Optional(section), into: detent)   // this section's own identity
            .onAppear {
                guard section == .audio else { return }
                micLevel.setGain(settings.micVolume)
                micLevel.setPreferredInput(settings.preferredAudioInputUID)
                micLevel.start()
            }
            .onDisappear {
                if section == .audio { micLevel.stop() }
            }
    }

    /// Renders every section's Form once, hidden, so its content height is measured
    /// and cached BEFORE its first open — then `open` resizes in lockstep with the
    /// slide instead of a two-step (height jumping after the push). `report` only
    /// CACHES for non-active panes (never resizes the sheet), and a `.background`
    /// never affects the foreground's size.
    private var sectionHeightPrewarm: some View {
        ZStack {
            ForEach(SettingsSection.allCases) { section in
                sectionForm(section)
                    .measuredDetentHeight(Optional(section), into: detent)
            }
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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
            return "\(quality)p · \(bitrateLabel(settings.videoBitrate)) · \(fps) fps"
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
        } header: {
            Text("Video")
        } footer: {
            Text("Bitrate is a maximum and drops automatically when the uplink is congested. Resolution and frame rate are limited to what this device can sustain, and are reduced automatically when it runs warm or low on power.")
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
                    Haptics.tap()
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

        // Route the meter to the SAME input the user picked. Without activating a
        // Bluetooth-capable record session and setting the preferred input, the
        // recorder silently captures the built-in mic — so a selected DJI/BT mic
        // never registers on the meter. (Only reached when NOT broadcasting, so it
        // never competes with the extension's session.)
        let session = AVAudioSession.sharedInstance()
        guard await AudioInputProvider.activateBluetoothRecording(session) else { return }
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
            return
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
        // audio server and interrupting ScreenCaptureKit's live mic session.
        // Deactivate exactly once, on the real handover.
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        meterLevel.withLock { $0 = 0 }
        Task {
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: [.notifyOthersOnDeactivation]
            )
        }
    }
}

#Preview {
    @Previewable @State var settings = StreamSettings.default
    return NavigationStack {
        SettingsView(settings: $settings, chat: RestreamChat(), onChange: {})
    }
}
