import SwiftUI
import StreamCore
import WebKit

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
    @Environment(\.scenePhase) private var scenePhase

    /// The single source of truth for the editable settings, loaded from the
    /// shared App Group suite on launch.
    @State private var settings: StreamSettings

    /// Owns ScreenCaptureKit selection/capture and the network publisher.
    @State private var capture = ScreenCaptureController()

    /// Restream unified-chat controller, shared by the main feed and the Settings
    /// sheet's chat section so both observe one connection.
    @State private var chat = RestreamChat()

    /// Audio input helper, owned here so its `AVAudioSession` route-change monitor
    /// runs for the whole app lifetime. Drives the Bluetooth-connect banner below
    /// and is threaded into the Settings sheet so both share one instance/observer.
    @State private var audio = AudioInputProvider()

    /// The single mic level monitor, driving both the toolbar's status meter and the
    /// Audio settings pane. Owned here so one instance serves both — a second would
    /// open a competing record session whenever the meter falls back to local capture.
    @State private var micLevel = MicrophoneLevelMonitor()

    /// The Bluetooth device that most recently paired mid-session, shown as a
    /// transient banner. Set from `audio.onBluetoothConnected`; auto-cleared after
    /// a few seconds by a `.task` keyed on its `id` (a fresh `id` restarts the
    /// timer, so a second device replaces the banner cleanly).
    @State private var bluetoothBanner: BluetoothConnection?

    @State private var showingSettings = false

    /// Coalesces rapid UI edits and performs Keychain/file writes away from the
    /// main actor. Text fields and sliders can update dozens of times per second;
    /// synchronously persisting each intermediate value made sheet navigation and
    /// control drags contend with Security.framework and atomic file I/O.
    @State private var settingsPersistence: SettingsPersistenceCoordinator

    /// Prevents a second go-live tap while the final settings snapshot is being
    /// flushed. Capture never starts before the latest scheduled save completes.
    @State private var isPreparingBroadcast = false

    /// Gates the "Stop Broadcast" confirmation. A live stream is easy to kill by a
    /// stray tap on the toolbar's stop button, so tapping it while live asks first
    /// instead of tearing the broadcast down immediately.
    @State private var showingStopConfirmation = false

    /// The mic gain to restore when the user un-mutes from the FAB. Captured the
    /// moment they mute so toggling back returns to their chosen level, not unity.
    @State private var preMuteVolume: Double = 1.0

    init() {
        let loaded = SettingsStore().load()
        _settings = State(initialValue: loaded)
        _settingsPersistence = State(
            initialValue: SettingsPersistenceCoordinator(initialSettings: loaded)
        )
    }

    /// Schedules a coalesced background save. `startBroadcast()` and sheet dismissal
    /// explicitly flush the latest snapshot, so debounce never weakens durability.
    private func persist() {
        settingsPersistence.schedule(settings)
    }

    private func flushSettings() {
        let snapshot = settings
        Task { await settingsPersistence.flush(snapshot) }
    }

    /// A gain at/below this reads as muted — matches the Settings "Muted" label.
    private var isMicMuted: Bool { settings.micVolume <= 0.0001 }

    /// Toggles the microphone between muted (gain 0) and the last chosen level.
    /// Persists and applies directly so a running broadcast responds immediately,
    /// exactly like the Settings mic-volume slider does.
    private func toggleMicMute() {
        Haptics.tap()
        if isMicMuted {
            settings.micVolume = preMuteVolume > 0.0001 ? preMuteVolume : 1.0
        } else {
            preMuteVolume = settings.micVolume
            settings.micVolume = 0
        }
        persist()
        capture.setMicVolume(settings.micVolume)
        // The idle meter applies gain itself, so the toolbar bars have to be told
        // about a mute that didn't come from the Settings slider.
        micLevel.setGain(settings.micVolume)
    }

    /// Keeps the toolbar meter live whenever the app is foregrounded, so the mic can
    /// be verified before going live and not only during a broadcast. While live the
    /// level arrives free over `MicrophoneLevelChannel`; when idle the monitor opens
    /// its own input tap, which is why this releases it the moment the app leaves the
    /// foreground rather than holding the mic (and the orange privacy indicator) open
    /// behind other apps.
    ///
    /// - Parameter phase: the incoming phase when called from `onChange`, whose
    ///   closure still sees the pre-change `scenePhase`.
    private func syncStatusMeter(phase: ScenePhase? = nil) {
        micLevel.setBroadcasting(capture.isLive)
        micLevel.setGain(settings.micVolume)
        micLevel.setPreferredInput(settings.preferredAudioInputUID)
        if (phase ?? scenePhase) == .active {
            micLevel.start(for: .statusBar)
        } else {
            micLevel.stop(for: .statusBar)
        }
    }

    var body: some View {
        TabView {
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
                    // Kept for VoiceOver/system context only — the principal toolbar
                    // item above replaces the visible title with the mic meter.
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
                        // Takes the title's slot: "Stream" is redundant on the app's own
                        // root screen, and the mic meter is the one thing worth a glance
                        // every time you look up here.
                        ToolbarItem(placement: .principal) {
                            MicrophoneStatusMeter(monitor: micLevel, isMuted: isMicMuted)
                        }
                        ToolbarItem(placement: .topBarTrailing) { broadcastButton }
                    }
                    .safeAreaInset(edge: .bottom) {
                        if !settings.isPublishable && !capture.isLive {
                            setupBanner
                        }
                    }
                    .sheet(isPresented: $showingSettings, onDismiss: flushSettings) {
                        settingsSheet
                    }
            }

            BloxwapWebView()
                // Page-style TabView gives each child its own safe-area proposal.
                // Opt the web page out as well as the pager below, otherwise a
                // narrow strip of the pager can remain visible at the top/bottom.
                .ignoresSafeArea(.container, edges: .all)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        // The pager itself must own the full window. Ignoring the safe area only
        // on the web-view page leaves UIPageViewController's page frame inset.
        .ignoresSafeArea(.container, edges: .all)
        // Unlike statusBarHidden, this also asks iOS to auto-hide the home
        // indicator so the web page can use the complete physical display.
        .persistentSystemOverlays(.hidden)
        .task {
            chat.autoConnect()
            // Surface a banner when a Bluetooth audio device pairs mid-session.
            audio.onBluetoothConnected = { name in
                bluetoothBanner = BluetoothConnection(name: name)
                Haptics.tap()
            }
            Haptics.warmUp()
            // Seed the baseline set + start the route-change observer. The ask has
            // to happen here now that the toolbar meter is always on screen —
            // without permission it can only ever read "no signal", with nothing on
            // the main screen to explain why. Already-connected devices only
            // populate the baseline; they don't trigger a banner — only arrivals do.
            audio.refresh(requestPermission: true)
            syncStatusMeter()
        }
        .onChange(of: capture.isLive) { _, _ in syncStatusMeter() }
        // Auto-dismiss the Bluetooth banner. Keyed on the connection id so a new
        // device restarts the timer; cancellation (id change) skips the stale clear.
        .task(id: bluetoothBanner?.id) {
            guard bluetoothBanner != nil else { return }
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            bluetoothBanner = nil
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { flushSettings() }
            syncStatusMeter(phase: phase)
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
                startBroadcast()
            }
        } label: {
            Image(systemName: capture.isLive ? "stop.circle" : "record.circle")
        }
        .tint(capture.isLive ? .red : .primary)
        .disabled(isPreparingBroadcast || capture.isStopping)
        .accessibilityLabel(capture.isLive ? "Stop broadcast" : "Start broadcast")
    }

    /// Flushes through the serial writer before handing the immutable snapshot to
    /// ScreenCaptureKit. This preserves the existing "saved before live" contract
    /// without doing Keychain or disk work in the toolbar button's main-actor turn.
    private func startBroadcast() {
        guard !isPreparingBroadcast, !capture.isStopping else { return }
        isPreparingBroadcast = true
        let snapshot = settings
        Task {
            await settingsPersistence.flush(snapshot)
            isPreparingBroadcast = false
            capture.presentPicker(settings: snapshot)
        }
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

    /// One Vaul-style drawer. `SettingsView` owns its two-level navigation and
    /// measures only the visible pane to drive its content-hugging detent.
    private var settingsSheet: some View {
        SettingsView(settings: $settings, chat: chat, capture: capture,
                     onChange: persist, audio: audio, micLevel: micLevel)
    }
}

/// The second page in the root pager. The web view is created once and retains its
/// navigation and scroll position while the user swipes back to the main screen.
private struct BloxwapWebView: UIViewRepresentable {
    private static let url = URL(string: "https://bloxwap.com")!

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = false
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.contentInset = .zero
        webView.scrollView.scrollIndicatorInsets = .zero
        webView.scrollView.automaticallyAdjustsScrollIndicatorInsets = false
        webView.load(URLRequest(url: Self.url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) { }
}

/// Serializes settings writes so an older debounced snapshot can never finish
/// after a newer flush and overwrite it. Actor isolation also keeps the synchronous
/// Keychain + atomic-file implementation off the main actor.
private actor SettingsWriter {
    private let store = SettingsStore()
    private var lastSaved: StreamSettings

    init(lastSaved: StreamSettings) {
        self.lastSaved = lastSaved
    }

    func save(_ settings: StreamSettings) {
        if settings.selectedProtocol != lastSaved.selectedProtocol
            || settings.rtmpURL != lastSaved.rtmpURL
            || settings.streamKey != lastSaved.streamKey {
            store.saveConnection(settings)
        }

        var redacted = settings
        redacted.rtmpURL = ""
        redacted.streamKey = ""
        var previousRedacted = lastSaved
        previousRedacted.rtmpURL = ""
        previousRedacted.streamKey = ""
        if redacted != previousRedacted {
            store.saveNonSecret(settings)
        }
        lastSaved = settings
    }
}

/// Main-actor scheduler owned by `ContentView`. Cancellation is cheap while the
/// task is sleeping; once a write reaches `SettingsWriter`, subsequent writes queue
/// behind it and therefore retain strict snapshot order.
@MainActor
private final class SettingsPersistenceCoordinator {
    private let writer: SettingsWriter
    private var pending: Task<Void, Never>?

    init(initialSettings: StreamSettings) {
        writer = SettingsWriter(lastSaved: initialSettings)
    }

    func schedule(_ settings: StreamSettings) {
        pending?.cancel()
        pending = Task { [writer] in
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await writer.save(settings)
        }
    }

    func flush(_ settings: StreamSettings) async {
        pending?.cancel()
        pending = nil
        await writer.save(settings)
    }
}

#Preview {
    ContentView()
}
