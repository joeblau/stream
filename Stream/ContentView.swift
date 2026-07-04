import SwiftUI
import StreamCore

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

    @State private var showingSettings = false

    /// Persists `settings` into the shared App Group suite. Called on every edit.
    private func persist() {
        SettingsStore().save(settings)
    }

    var body: some View {
        NavigationStack {
            ChatFeedView(chat: chat)
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
        .task { chat.autoConnect() }
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
                capture.stop()
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
        SettingsView(settings: $settings, chat: chat, onChange: persist)
    }
}

#Preview {
    ContentView()
}
