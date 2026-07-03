import SwiftUI
import UIKit
import StreamCore

/// Root view. Hosts the settings form and a "Go Live" section that embeds the
/// system broadcast picker. Settings are owned here and threaded into
/// `SettingsView`; every edit is persisted via `SettingsStore` so the broadcast
/// extension can read the latest snapshot the instant the user taps the picker.
struct ContentView: View {
    /// The single source of truth for the editable settings, loaded from the
    /// shared App Group suite on launch.
    @State private var settings: StreamSettings = SettingsStore().load()

    /// Imports finished local HD backups into Photos when the app is active.
    @State private var importer = RecordingsImporter()

    /// Reflects whether the broadcast extension is live, and carries the app's
    /// "End Stream" signal to it.
    @State private var broadcast = BroadcastMonitor()

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    /// Persists `settings` into the shared App Group suite. Called on every edit.
    private func persist() {
        SettingsStore().save(settings)
    }

    var body: some View {
        NavigationStack {
            SettingsView(settings: $settings, onChange: persist)
                .navigationTitle("Stream")
                .safeAreaInset(edge: .bottom) {
                    goLiveSection
                }
        }
        // Only refresh how many backups are waiting (a cheap directory scan, no
        // Photos access) so the "Save to Photos" button enables itself after a
        // broadcast. Saving — and the permission prompt — happens only when the
        // user taps the button.
        .task { importer.refreshPendingCount() }
        .onAppear { broadcast.start() }
        .onDisappear { broadcast.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                importer.refreshPendingCount()
                broadcast.refresh()
            }
        }
    }

    private func openAppSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            openURL(url)
        }
    }

    // MARK: - Go Live

    @ViewBuilder
    private var goLiveSection: some View {
        VStack(spacing: 12) {
            Divider()

            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("Go Live")
                            .font(.headline)
                        if broadcast.isLive {
                            Label("Live", systemImage: "dot.radiowaves.left.and.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.red)
                        }
                    }
                    Text(statusGuidance)
                        .font(.caption)
                        .foregroundStyle(settings.isPublishable ? Color.secondary : Color.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                // The actual broadcast trigger. Tapping it presents the system
                // sheet listing the StreamBroadcast upload extension.
                BroadcastPickerView()
                    .frame(width: 60, height: 60)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(.thinMaterial)
                    )
                    .opacity(settings.isPublishable ? 1.0 : 0.4)
                    .accessibilityLabel("Start or stop broadcast")
            }

            // Definitive in-app stop. Signals the extension to tear down with the
            // manual-stop flag set, so it ends immediately and does NOT reconnect.
            if broadcast.isLive {
                Button(role: .destructive) {
                    broadcast.endBroadcast()
                } label: {
                    Label("End Stream", systemImage: "stop.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
                .accessibilityLabel("End the current broadcast")
            }

            if settings.isPublishable {
                Label(
                    settings.isSecure
                        ? "Secure RTMPS (TLS) endpoint configured."
                        : "Plain RTMP endpoint (no TLS).",
                    systemImage: settings.isSecure ? "lock.fill" : "lock.open"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if settings.backupEnabled {
                backupStatusView
            }
        }
        .padding()
        .background(.bar)
    }

    /// Backup status + a user-initiated "Save to Photos" button. The button is
    /// disabled until a finished recording is waiting; tapping it is what triggers
    /// the Photos permission prompt and the save. Nothing leaves the app on its own.
    @ViewBuilder
    private var backupStatusView: some View {
        HStack(spacing: 8) {
            backupStatusLabel
            Spacer(minLength: 4)
            backupTrailingControl
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var backupStatusLabel: some View {
        switch importer.status {
        case .importing:
            Label { Text("Saving to Photos…") } icon: { ProgressView().controlSize(.mini) }
                .font(.caption2).foregroundStyle(.secondary)
        case let .saved(count):
            Label(count == 1 ? "Saved to Photos." : "\(count) saved to Photos.",
                  systemImage: "checkmark.seal.fill")
                .font(.caption2).foregroundStyle(.green)
        case .needsPhotosAccess:
            Label("Photos access is needed to save.", systemImage: "exclamationmark.triangle.fill")
                .font(.caption2).foregroundStyle(.orange)
        case .failed:
            Label("Couldn't save to Photos.", systemImage: "xmark.octagon.fill")
                .font(.caption2).foregroundStyle(.red)
        case .idle:
            Label(backupPendingText, systemImage: "film.stack")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var backupTrailingControl: some View {
        switch importer.status {
        case .importing:
            EmptyView()
        case .needsPhotosAccess:
            Button("Open Settings", action: openAppSettings).font(.caption2)
        default:
            // Save / Retry — enabled only when there's actually something to save.
            Button(importer.status == .failed ? "Retry" : "Save to Photos") {
                Task { await importer.importPending() }
            }
            .font(.caption2)
            .disabled(importer.pendingCount == 0)
        }
    }

    private var backupPendingText: String {
        switch importer.pendingCount {
        case 0: return "No backups waiting to save."
        case 1: return "1 HD backup ready to save."
        default: return "\(importer.pendingCount) HD backups ready to save."
        }
    }

    /// User-facing guidance text describing how to start/stop streaming and what
    /// is missing before a broadcast can begin.
    private var statusGuidance: String {
        if settings.isPublishable {
            return "Tap the broadcast button, choose \"Stream\", then Start Broadcast. Tap again to stop."
        }
        if settings.rtmpURL.isEmpty || URL(string: settings.rtmpURL)?.host == nil {
            return "Enter a valid rtmp:// or rtmps:// URL above to enable broadcasting."
        }
        if settings.streamKey.isEmpty {
            return "Enter your stream key above to enable broadcasting."
        }
        return "Complete the connection settings above to enable broadcasting."
    }
}

#Preview {
    ContentView()
}
