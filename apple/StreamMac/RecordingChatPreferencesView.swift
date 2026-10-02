import SwiftUI

struct RecordingChatPreferencesView: View {
    @ObservedObject var recorder: RecordingController
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Toggle("Archive public chat with recordings", isOn: $recorder.preferences.chatArchive.enabled)
            if recorder.preferences.chatArchive.enabled {
                Toggle("Include author names", isOn: $recorder.preferences.chatArchive.includeAuthors)
                Picker("Keep completed chat archives", selection: $recorder.preferences.chatArchive.retentionDays) {
                    Text("Until removed").tag(0)
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                }
                Text("Saves public message text and actual Program comment timing. Private messages and connection credentials are excluded. Retention runs when the next archive starts; it preserves recordings and interrupted archives.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.disabled(recorder.state.isActive)
    }
}
