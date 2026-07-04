import SwiftUI
import UIKit
import StreamCore

/// Root view. The main page shows the live chat feed; the toolbar carries a "Live"
/// recording button (top right) that starts/stops the broadcast and a gear button that
/// presents every setting — connection, video, backup, audio, and chat — in a
/// sheet. Settings are owned here and threaded into `SettingsView`; every edit is
/// persisted via `SettingsStore` so the broadcast extension can read the latest
/// snapshot the instant the user goes live.
struct ContentView: View {
    /// The single source of truth for the editable settings, loaded from the
    /// shared App Group suite on launch.
    @State private var settings: StreamSettings = SettingsStore().load()

    /// Reflects whether the broadcast extension is live, and carries the app's
    /// stop signal to it.
    @State private var broadcast = BroadcastMonitor()

    /// Holds the host app's background-audio assertion while a broadcast is live.
    @State private var keepAlive = BroadcastKeepAlive()

    /// Restream unified-chat controller, shared by the main feed and the Settings
    /// sheet's chat section so both observe one connection.
    @State private var chat = RestreamChat()

    @State private var showingSettings = false

    @Environment(\.scenePhase) private var scenePhase

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
                            showingSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel("Settings")
                    }
                    ToolbarItem(placement: .topBarTrailing) { broadcastButton }
                }
                .safeAreaInset(edge: .bottom) {
                    if !settings.isPublishable && !broadcast.isLive {
                        setupBanner
                    }
                }
                .sheet(isPresented: $showingSettings) { settingsSheet }
        }
        .task { chat.autoConnect() }
        .onAppear { broadcast.start() }
        .onDisappear { broadcast.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                broadcast.refresh()
                // If we're back in the app and NOT live, release any keepalive we
                // asserted proactively for a broadcast that never started (the
                // user cancelled the picker). A real live broadcast keeps it; if
                // this races ahead of isLive, the isLive handler restarts it.
                if !broadcast.isLive { keepAlive.stop() }
            }
        }
        // Hold a background-audio assertion for the whole broadcast so iOS does
        // not suspend this host app on app-switch (a suspended host makes
        // CoreMedia stop the tied broadcast session, freezing the extension).
        // Fires while foreground — the instant the extension reports live — so
        // the session is active before the user can switch away.
        .onChange(of: broadcast.isLive) { _, live in
            if live { keepAlive.start() } else { keepAlive.stop() }
        }
    }

    // MARK: - Broadcast control

    /// ReplayKit's native recording control. It presents the system start/stop
    /// sheet and targets this app's broadcast upload extension.
    private var broadcastButton: some View {
        // Assert the keepalive the instant the user taps Start (before the
        // extension reports live), so a very fast app-switch can't suspend the
        // host in the gap. A cancelled picker is cleaned up on the next
        // foreground (see scenePhase handler); a real start is confirmed by the
        // broadcast.isLive handler.
        BroadcastPickerView(onStartTap: { keepAlive.start() })
            .frame(width: 44, height: 44)
            .accessibilityLabel(broadcast.isLive ? "Stop broadcast" : "Start broadcast")
    }

    // MARK: - Setup banner

    /// Slim call-to-action shown when the connection isn't ready to publish. Tapping
    /// it opens the settings sheet at the connection fields.
    private var setupBanner: some View {
        Button {
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

    private var settingsSheet: some View {
        NavigationStack {
            SettingsView(settings: $settings, chat: chat, onChange: persist)
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { showingSettings = false }
                    }
                }
        }
    }
}

#Preview {
    ContentView()
}
