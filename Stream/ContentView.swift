import SwiftUI
import StreamCore

/// Root view. Hosts the settings form and a "Go Live" section that embeds the
/// system broadcast picker. Settings are owned here and threaded into
/// `SettingsView`; every edit is persisted via `SettingsStore` so the broadcast
/// extension can read the latest snapshot the instant the user taps the picker.
struct ContentView: View {
    /// The single source of truth for the editable settings, loaded from the
    /// shared App Group suite on launch.
    @State private var settings: StreamSettings = SettingsStore().load()

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
    }

    // MARK: - Go Live

    @ViewBuilder
    private var goLiveSection: some View {
        VStack(spacing: 12) {
            Divider()

            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Go Live")
                        .font(.headline)
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
        }
        .padding()
        .background(.bar)
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
