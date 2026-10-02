import StreamCore
import SwiftUI

/// Reused by the account panel and sidebar; both observe the same reader.
struct DirectChatControls: View {
    @ObservedObject var manager: StudioDirectChatManager
    @State private var provider = ManagedProvider.youtube
    @State private var eventID = ""
    @State private var compose = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Direct public chat", selection: $provider) {
                Text("YouTube").tag(ManagedProvider.youtube); Text("Twitch").tag(ManagedProvider.twitch)
            }
            if provider == .youtube { TextField("Owned live broadcast ID", text: $eventID).autocorrectionDisabled() }
            Text("\(provider.name) · \(manager.snapshot(provider).state)").font(.caption.weight(.semibold))
            HStack {
                Button("Read Public Chat") { manager.connect(provider, eventID: eventID) }
                    .disabled(provider == .youtube && eventID.isEmpty)
                Button("Disconnect") { manager.stop(provider) }
                Button("Post…") { compose = true }.disabled(!manager.canSend(provider))
            }.controlSize(.small)
            if let failure = manager.snapshot(provider).failure { Text(failure).font(.caption).foregroundStyle(.orange) }
            if let notice = manager.snapshot(provider).notice { Text(notice).font(.caption2).foregroundStyle(.secondary) }
            Text("Authorize in Provider Accounts first. Twitch needs user:read:chat; posting/deleting need separate optional grants. Other direct providers, private messages and image emotes are unavailable.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .sheet(isPresented: $compose) { DirectChatCompose(manager: manager, provider: provider) }
    }
}
struct DirectChatMessageActions: View {
    @ObservedObject var manager: StudioDirectChatManager
    let message: StudioChatMessage
    @State private var reply = false
    @State private var deleting = false
    var body: some View {
        HStack {
            if manager.canReply(message.id) { Button("Reply…") { reply = true } }
            if manager.canDelete(message.id) { Button("Delete…", role: .destructive) { deleting = true } }
        }.controlSize(.small)
        .sheet(isPresented: $reply) { DirectChatCompose(manager: manager, provider: .twitch, reply: message) }
        .confirmationDialog("Delete this public message?", isPresented: $deleting, titleVisibility: .visible) {
            Button("Delete selected message", role: .destructive) { manager.delete(message.id) }
        } message: { Text("This requests a targeted provider deletion. An acknowledged deletion also removes the message from the local queue and staged comment slot. Use Take to update Program unless Direct Live Editing is enabled.") }
    }
}
private struct DirectChatCompose: View {
    @ObservedObject var manager: StudioDirectChatManager
    let provider: ManagedProvider
    var reply: StudioChatMessage?
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var confirm = false
    private var limit: Int { provider == .twitch ? 500 : 200 }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(reply == nil ? "Post a public \(provider.name) message" : "Reply to \(reply!.author)").font(.headline)
            if let reply { Text(reply.text).font(.caption).lineLimit(3) }
            TextEditor(text: $text).frame(height: 120)
            Text("\(text.count)/\(limit) characters").font(.caption)
            Text(provider == .twitch ? "Twitch user-token posts may appear in every channel participating in Shared Chat. The reader confirms delivery; Stream does not insert a local echo." : "YouTube posts a public message without a threaded reply. Stream limits this composer to 200 characters.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { dismiss() }; Spacer()
                Button("Review Send…") { confirm = true }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.count > limit || !manager.canSend(provider) || (reply != nil && !manager.canReply(reply!.id)))
            }
        }.padding(20).frame(width: 420)
        .confirmationDialog("Send this public message?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Send Public Message") { manager.send(text, provider: provider, replyingTo: reply?.id); dismiss() }
        } message: { Text("You are posting through your authorized \(provider.name) account.\n\n\(text)") }
    }
}
