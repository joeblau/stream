import SwiftUI
import StreamCore

/// A Bluetooth audio device that paired mid-session, backing the transient
/// "connected" banner. The `id` is fresh per arrival so replacing the banner
/// restarts its dismiss timer even when the same device reconnects.
private struct BluetoothConnection: Equatable, Identifiable {
    let id = UUID()
    let name: String
}

/// Root view. The main page shows the live chat feed; the toolbar carries a "Live"
/// recording button (top right) that starts/stops capture and a gear button that
/// presents every setting — connection, video, backup, audio, and chat — in a
/// sheet. Settings are owned here and threaded into `SettingsView`; every edit is
/// persisted via `SettingsStore` before ScreenCaptureKit starts the stream.
struct ContentView: View {
    /// The single source of truth for the editable settings, loaded from the
    /// shared App Group suite on launch.
    @State private var settings: StreamSettings = SettingsStore().load()

    /// Owns ScreenCaptureKit selection/capture and the network publisher.
    @State private var capture = ScreenCaptureController()

    /// Restream unified-chat controller, shared by the main feed and the Settings
    /// sheet's chat section so both observe one connection.
    @State private var chat = RestreamChat()

    /// Audio input helper, owned here so its `AVAudioSession` route-change monitor
    /// runs for the whole app lifetime. Drives the Bluetooth-connect banner below
    /// and is threaded into the Settings sheet so both share one instance/observer.
    @State private var audio = AudioInputProvider()

    /// The Bluetooth device that most recently paired mid-session, shown as a
    /// transient banner. Set from `audio.onBluetoothConnected`; auto-cleared after
    /// a few seconds by a `.task` keyed on its `id` (a fresh `id` restarts the
    /// timer, so a second device replaces the banner cleanly).
    @State private var bluetoothBanner: BluetoothConnection?

    @State private var showingSettings = false

    /// Gates the "Stop Broadcast" confirmation. A live stream is easy to kill by a
    /// stray tap on the toolbar's stop button, so tapping it while live asks first
    /// instead of tearing the broadcast down immediately.
    @State private var showingStopConfirmation = false

    /// The mic gain to restore when the user un-mutes from the FAB. Captured the
    /// moment they mute so toggling back returns to their chosen level, not unity.
    @State private var preMuteVolume: Double = 1.0

    /// Persists `settings` into the shared App Group suite. Called on every edit.
    private func persist() {
        SettingsStore().save(settings)
    }

    /// A gain at/below this reads as muted — matches the Settings "Muted" label.
    private var isMicMuted: Bool { settings.micVolume <= 0.0001 }

    /// Toggles the microphone between muted (gain 0) and the last chosen level.
    /// Persists and posts the live-apply signal so a running broadcast responds
    /// immediately, exactly like the Settings mic-volume slider does.
    private func toggleMicMute() {
        Haptics.tap()
        if isMicMuted {
            settings.micVolume = preMuteVolume > 0.0001 ? preMuteVolume : 1.0
        } else {
            preMuteVolume = settings.micVolume
            settings.micVolume = 0
        }
        persist()
        BroadcastControl.post(BroadcastControl.micVolumeSignal)
    }

    var body: some View {
        NavigationStack {
            ChatFeedView(chat: chat)
                .overlay(alignment: .bottomTrailing) {
                    if capture.isLive { micFAB }
                }
                .overlay(alignment: .top) {
                    VStack(spacing: 8) {
                        if capture.isLive { livePill }
                        if let banner = bluetoothBanner {
                            bluetoothBannerView(name: banner.name)
                        }
                    }
                    .padding(.top, 8)
                }
                .animation(.spring(duration: 0.3, bounce: 0.2), value: capture.isLive)
                .animation(.spring(duration: 0.35, bounce: 0.25), value: bluetoothBanner)
                .navigationTitle("Stream")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            Haptics.tap()
                            showingSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel("Settings")
                    }
                    ToolbarItem(placement: .topBarTrailing) { broadcastButton }
                }
                .safeAreaInset(edge: .bottom) {
                    if !settings.isPublishable && !capture.isLive {
                        setupBanner
                    }
                }
                .sheet(isPresented: $showingSettings) { settingsSheet }
        }
        .task {
            chat.autoConnect()
            // Surface a banner when a Bluetooth audio device pairs mid-session.
            audio.onBluetoothConnected = { name in
                bluetoothBanner = BluetoothConnection(name: name)
                Haptics.tap()
            }
            // Seed the baseline set + start the route-change observer without
            // prompting for mic access here (Settings owns the permission ask).
            // Already-connected devices only populate the baseline; they don't
            // trigger a banner — only devices that arrive afterward do.
            audio.refresh(requestPermission: false)
        }
        // Auto-dismiss the Bluetooth banner. Keyed on the connection id so a new
        // device restarts the timer; cancellation (id change) skips the stale clear.
        .task(id: bluetoothBanner?.id) {
            guard bluetoothBanner != nil else { return }
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            bluetoothBanner = nil
        }
        .confirmationDialog(
            "Stop the broadcast?",
            isPresented: $showingStopConfirmation,
            titleVisibility: .visible
        ) {
            Button("Stop Broadcast", role: .destructive) {
                Haptics.tap()
                capture.stop()
            }
            Button("Keep Streaming", role: .cancel) { }
        } message: {
            Text("You're live. Stopping ends the stream for everyone watching.")
        }
        .alert("Screen Capture", isPresented: Binding(
            get: { capture.errorMessage != nil },
            set: { if !$0 { capture.clearError() } }
        )) {
            Button("OK") { Haptics.tap(); capture.clearError() }
        } message: {
            Text(capture.errorMessage ?? "Screen capture failed.")
        }
    }

    // MARK: - Broadcast control

    /// A normal toolbar button backed by ScreenCaptureKit's system content picker.
    private var broadcastButton: some View {
        Button {
            Haptics.tap()
            if capture.isLive {
                showingStopConfirmation = true
            } else {
                persist()
                capture.presentPicker(settings: settings)
            }
        } label: {
            Image(systemName: capture.isLive ? "stop.circle" : "record.circle")
        }
        .tint(capture.isLive ? .red : .primary)
        .accessibilityLabel(capture.isLive ? "Stop broadcast" : "Start broadcast")
    }

    // MARK: - Mute FAB

    /// Floating mic mute/unmute control, pinned to the bottom-trailing corner while
    /// a broadcast is live. Uses the platform glass so it reads as a control sitting
    /// above the chat feed; turns red-tinted and swaps to `mic.slash` when muted.
    private var micFAB: some View {
        Button(action: toggleMicMute) {
            Image(systemName: isMicMuted ? "mic.slash.fill" : "mic.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(isMicMuted ? Color.red : Color.primary)
                .frame(width: 60, height: 60)
                .contentTransition(.symbolEffect(.replace))
        }
        .glassEffect(.regular.interactive(), in: .circle)
        .padding(.trailing, 20)
        .padding(.bottom, 20)
        .accessibilityLabel(isMicMuted ? "Unmute microphone" : "Mute microphone")
        .transition(.scale.combined(with: .opacity))
    }

    // MARK: - Live pill

    /// Persistent LIVE indicator + elapsed timer, pinned to the top while a broadcast
    /// is live. A glass capsule matching the micFAB; the timer ticks in its own
    /// `TimelineView` off `broadcastStartedAt` (a Date) so it keeps counting across
    /// backgrounding and only the label — not the whole feed — refreshes each second.
    private var livePill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(.red)
                .frame(width: 8, height: 8)
            Text("LIVE")
                .font(.caption.weight(.bold))
                .foregroundStyle(.red)
            if let start = capture.broadcastStartedAt {
                TimelineView(.periodic(from: start, by: 1)) { context in
                    Text(LiveStats.uptimeLabel(seconds: Int(context.date.timeIntervalSince(start))))
                        .font(.caption.weight(.semibold).monospacedDigit())
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .glassEffect(.regular, in: .capsule)
        .transition(.scale.combined(with: .opacity))
        // Purely informational: never intercept taps/scroll on the chat beneath it.
        .allowsHitTesting(false)
        // Combine into one element but keep the elapsed time in the label (a static
        // override would drop it) — VoiceOver reads e.g. "LIVE, 12:34".
        .accessibilityElement(children: .combine)
    }

    // MARK: - Bluetooth-connected banner

    /// Transient glass capsule announcing a Bluetooth audio device that just
    /// paired. Sits below the LIVE pill (same top overlay stack) and auto-dismisses
    /// via the `.task(id:)` timer; purely informational, so it never eats taps.
    private func bluetoothBannerView(name: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "wave.3.right.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.blue)
            Text("\(name) connected")
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .glassEffect(.regular, in: .capsule)
        .transition(.move(edge: .top).combined(with: .opacity))
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name) connected")
    }

    // MARK: - Setup banner

    /// Slim call-to-action shown when the connection isn't ready to publish. Tapping
    /// it opens the settings sheet at the connection fields.
    private var setupBanner: some View {
        Button {
            Haptics.tap()
            showingSettings = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(setupGuidance)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
            }
            .font(.footnote)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.bar)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    /// Explains what's still missing before the Live switch will enable.
    private var setupGuidance: String {
        if !settings.selectedProtocol.isPublishingSupported {
            return "\(settings.selectedProtocol.displayName) publishing is coming soon — set up RTMP/RTMPS in Settings to go live."
        }
        if settings.rtmpURL.isEmpty || URL(string: settings.rtmpURL)?.host == nil {
            return "Add a valid \(settings.selectedProtocol.displayName) URL in Settings to go live."
        }
        if settings.selectedProtocol.requiresKey, settings.streamKey.isEmpty {
            return "Add your stream key in Settings to go live."
        }
        return "Complete the connection settings to go live."
    }

    // MARK: - Settings sheet

    /// One Vaul-style drawer. `SettingsView` owns the navigation stack and sizes
    /// the sheet to the exact height of whatever content is on screen (measured
    /// from the scroll view's real content size), resizing as sections are pushed.
    private var settingsSheet: some View {
        SettingsView(settings: $settings, chat: chat, capture: capture, onChange: persist, audio: audio)
    }
}

#Preview {
    ContentView()
}
