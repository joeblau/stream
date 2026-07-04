import SwiftUI

/// Main-page chat feed: Restream unified chat over OAuth2, aggregated across every
/// platform connected to the user's Restream account. Connection setup lives in the
/// Settings sheet (`SettingsView.chatSection`); this view only renders the feed.
struct ChatFeedView: View {
    var chat: RestreamChat

    var body: some View {
        Group {
            switch chat.status {
            case .connected:
                messageList
            case .connecting:
                ProgressView("Connecting to Restream…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .needsCredentials, .signedOut, .failed:
                waitingForChat
            }
        }
    }

    /// Shown until the chat socket is connected. Points the user at Settings, where
    /// the Restream connection now lives.
    private var waitingForChat: some View {
        ContentUnavailableView {
            Label("Waiting for chat…", systemImage: "bubble.left.and.bubble.right")
        } description: {
            Text(waitingDescription)
        }
    }

    private var waitingDescription: String {
        switch chat.status {
        case .failed(let message):
            return message
        case .signedOut:
            return "Tap the gear to connect with Restream and see chat from all your platforms here."
        default:
            return "Add your Restream app in Settings to see chat from all your connected platforms in one place."
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(chat.messages) { message in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(message.author).font(.caption.bold())
                                if let platform = message.platform {
                                    Text(platform).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            Text(message.text)
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id(message.id)
                    }
                }
                .padding()
            }
            .overlay {
                if chat.messages.isEmpty {
                    ContentUnavailableView("Waiting for chat…",
                                           systemImage: "bubble.left.and.bubble.right",
                                           description: Text("Messages from your connected platforms will appear here."))
                }
            }
            .onChange(of: chat.messages.count) {
                if let last = chat.messages.last {
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }
}
