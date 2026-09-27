import SwiftUI

/// macOS chat sidebar: Restream unified chat (OAuth2) aggregated across every
/// platform connected to the user's Restream account. A condensed port of the iOS
/// `ChatFeedView` — same feed concepts, plus a connection header since the macOS
/// layout keeps the panel always visible (no sheet detents).
struct ChatSidebarView: View {
    /// Owned here so the connection survives view re-creation. `RestreamChat` is
    /// `@Observable`, so plain `@State` (not `@StateObject`) keeps it alive.
    @State private var chat = RestreamChat()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 260, idealWidth: 300)
        .onAppear { chat.autoConnect() }
    }

    // MARK: - Connection header

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusTint)
                .frame(width: 8, height: 8)
            Text(statusTitle)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
            Spacer()
            switch chat.status {
            case .connected:
                Button("Sign Out") { chat.signOut() }
            case .connecting:
                ProgressView()
                    .controlSize(.small)
            case .needsCredentials, .signedOut, .failed:
                Button("Connect") { chat.connect() }
                    .disabled(!chat.hasCredentials)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var statusTitle: String {
        switch chat.status {
        case .connected:  return "Chat"
        case .connecting: return "Connecting…"
        case .needsCredentials, .signedOut: return "Chat Offline"
        case .failed:     return "Chat Error"
        }
    }

    private var statusTint: Color {
        switch chat.status {
        case .connected:  return .green
        case .connecting: return .yellow
        case .failed:     return .red
        case .needsCredentials, .signedOut: return .secondary
        }
    }

    // MARK: - Feed

    @ViewBuilder
    private var content: some View {
        switch chat.status {
        case .connected:
            messageList
        case .connecting:
            ProgressView("Connecting to Restream…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .needsCredentials, .signedOut, .failed:
            ContentUnavailableView {
                Label("Waiting for chat…", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text(waitingDescription)
            }
        }
    }

    private var waitingDescription: String {
        switch chat.status {
        case .failed(let message):
            return message
        case .signedOut:
            return "Connect with Restream to see chat from all your platforms here."
        default:
            return "Add your Restream app in Settings to see chat from all your connected platforms in one place."
        }
    }

    // The feed default-anchors to the BOTTOM, so the newest line sits at the bottom
    // on first paint and stays pinned there as chat streams in. (`onScrollGeometryChange`
    // is macOS 15+, so unlike iOS there is no "parked at bottom" gate — new messages
    // always follow, which matches desktop chat-client behavior.)
    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(chat.messages) { message in
                        ChatRow(message: message)
                            .id(message.id)
                    }
                }
                .padding()
            }
            .defaultScrollAnchor(.bottom)
            .overlay {
                if chat.messages.isEmpty {
                    ContentUnavailableView("Waiting for chat…",
                                           systemImage: "bubble.left.and.bubble.right",
                                           description: Text("Messages from your connected platforms will appear here."))
                }
            }
            .onChange(of: chat.messages.count) {
                guard let last = chat.messages.last else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }
}

/// One incoming chat line: a caption (author + platform badge) above a
/// content-hugging bubble. The body wraps freely and never truncates.
private struct ChatRow: View {
    let message: ChatMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(message.author)
                    .fontWeight(.semibold)
                if let platform = message.platform, !platform.isEmpty {
                    Text(platform.capitalized)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.leading, 4)

            Text(message.text)
                .font(.callout)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.blue, in: .rect(cornerRadius: 14, style: .continuous))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        if let platform = message.platform, !platform.isEmpty {
            return "\(message.author) on \(platform): \(message.text)"
        }
        return "\(message.author): \(message.text)"
    }
}

#Preview {
    ChatSidebarView()
}
