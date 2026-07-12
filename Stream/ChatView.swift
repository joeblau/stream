import SwiftUI

/// Main-page chat feed: Restream unified chat over OAuth2, aggregated across every
/// platform connected to the user's Restream account. Connection setup lives in the
/// Settings sheet (`SettingsView.chatSection`); this view only renders the feed.
struct ChatFeedView: View {
    var chat: RestreamChat

    /// Whether the feed is currently parked at the bottom. Gates the animated
    /// auto-follow so new messages only pull the view down when the user is already
    /// there — a viewer scrolled up reading history is never yanked. Seeded `true`
    /// so the first burst of messages sticks to the bottom.
    @State private var isAtBottom = true

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

    // The feed default-anchors to the BOTTOM, so the newest line sits at the bottom
    // of the screen on first paint and stays pinned there as chat streams in
    // (classic chat-app behavior).
    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(chat.messages) { message in
                        // Incoming-only feed: every bubble hugs the LEADING edge. The
                        // trailing Spacer caps width so a bubble never spans edge-to-edge.
                        HStack(spacing: 0) {
                            MessageBubble(message: message)
                            Spacer(minLength: 40)
                        }
                        .id(message.id)          // per-row id for scrollTo(_:)
                    }
                }
                .padding()
            }
            // Pin to the bottom on first layout and keep it pinned as rows append.
            .defaultScrollAnchor(.bottom)
            // Track "parked at the bottom" so the animated follow below only fires
            // there, never yanking a viewer scrolling up through history. 24pt slack
            // absorbs rounding and the bottom content inset.
            .onScrollGeometryChange(for: Bool.self) { geo in
                geo.contentOffset.y + geo.containerSize.height
                    >= geo.contentSize.height - geo.contentInsets.bottom - 24
            } action: { _, atBottom in
                isAtBottom = atBottom
            }
            .overlay {
                if chat.messages.isEmpty {
                    ContentUnavailableView("Waiting for chat…",
                                           systemImage: "bubble.left.and.bubble.right",
                                           description: Text("Messages from your connected platforms will appear here."))
                }
            }
            // Subtle animated follow — gated so it only fires when already at the bottom.
            .onChange(of: chat.messages.count) {
                guard isAtBottom, let last = chat.messages.last else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }
}

/// One incoming chat line, styled like an iMessage group bubble: a small secondary
/// caption (author + platform) sits ABOVE a content-hugging blue bubble. The body
/// wraps freely and never truncates; white-on-blue stays legible in light + dark,
/// and the whole line reads as a single VoiceOver element.
private struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // Sender caption above the bubble, like the name label over a group bubble.
            HStack(spacing: 4) {
                Text(message.author).fontWeight(.semibold)
                if let platform = message.platform, !platform.isEmpty {
                    Text(platform.capitalized)      // "youtube" -> "Youtube"
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)            // adapts to light/dark
            .lineLimit(1)                           // long names/handles truncate here
            .padding(.leading, 4)                   // nudge under the bubble's corner

            // The blue bubble: hugs short text, wraps long text, never truncates.
            Text(message.text)
                .font(.callout)                                // scales with Dynamic Type
                .foregroundStyle(.white)                       // legible on blue, both modes
                .fixedSize(horizontal: false, vertical: true)  // wrap to full height, no clip
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.blue, in: .rect(cornerRadius: 18, style: .continuous))
        }
        // Fold the whole line into ONE VoiceOver stop: "Ada on twitch: hello there".
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    // "Ada on twitch: hello there" — platform woven in only when present.
    private var accessibilityLabel: String {
        if let platform = message.platform, !platform.isEmpty {
            return "\(message.author) on \(platform): \(message.text)"
        }
        return "\(message.author): \(message.text)"
    }
}
