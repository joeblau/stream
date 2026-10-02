import StreamCore
import SwiftUI

/// Account panel and sidebar observe the same reader, presets and outbox.
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
                Button("Post…") { compose = true }
            }.controlSize(.small)
            if let failure = manager.snapshot(provider).failure { Text(failure).font(.caption).foregroundStyle(.orange) }
            if let notice = manager.snapshot(provider).notice { Text(notice).font(.caption2).foregroundStyle(.secondary) }
            if let date = manager.snapshot(provider).retryUntil, date > Date() {
                Text("API cooldown until \(date.formatted(date: .omitted, time: .standard)). No action is replayed.").font(.caption2)
            }
            Text("Authorize in Provider Accounts first. Twitch reading, posting, deletion, and timeouts/bans use separate optional grants. Restream and other provider feeds are read-only here.")
                .font(.caption2).foregroundStyle(.secondary)
            DirectChatReceipts(manager: manager)
        }
        .sheet(isPresented: $compose) { DirectChatCompose(manager: manager, presets: manager.presets) }
    }
}
struct DirectChatMessageActions: View {
    @ObservedObject var manager: StudioDirectChatManager
    let message: StudioChatMessage
    @State private var reply = false
    @State private var review: ModerationReview?
    private struct ModerationReview { let kind: DirectChatWriteKind; let target: DirectChatWriteTarget }
    var body: some View {
        HStack {
            if manager.canReply(message.id) { Button("Reply…") { reply = true } }
            Menu("Moderate…") {
                moderationButton(.delete)
                moderationButton(.timeout)
                moderationButton(.ban)
                if manager.targetForMessage(message.id) == nil { Text("No current direct-provider route. This message is read-only.") }
                Text("Owner/moderator roles are protected. Unban and role changes use the provider's controls.")
            }
        }.controlSize(.small)
        .sheet(isPresented: $reply) { DirectChatCompose(manager: manager, presets: manager.presets, reply: message) }
        .confirmationDialog("\(review?.kind.label ?? "Moderate") — \(message.author)?", isPresented: Binding(
            get: { review != nil }, set: { if !$0 { review = nil } }), titleVisibility: .visible) {
            if let action = review {
                Button(action.kind.label, role: .destructive) {
                    manager.moderate(message.id, kind: action.kind, expectedTarget: action.target); review = nil
                }
            }
        } message: {
            Text("Target: \(review?.target.label ?? "Unavailable").\n\nDeletion affects the selected public message. Timeout/ban affects this author in the selected chat and removes their known local messages only after acknowledgement. Take publishes staged comment removal unless Direct Live Editing is enabled.")
        }
    }
    private func moderationButton(_ kind: DirectChatWriteKind) -> some View {
        let reason = manager.moderationAvailabilityError(message.id, kind: kind)
        return Button("\(kind.label)…", role: .destructive) {
            if let target = manager.targetForMessage(message.id) { review = .init(kind: kind, target: target) }
        }.disabled(reason != nil).help(reason ?? "Review the exact author and provider before requesting this action")
    }
}

private struct DirectChatCompose: View {
    @ObservedObject var manager: StudioDirectChatManager
    @ObservedObject var presets: StudioChatPresetStore
    var reply: StudioChatMessage?
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var selected: Set<ManagedProvider> = []
    @State private var presetID: UUID?
    @State private var presetName = ""
    @State private var review: SendReview?
    private struct SendReview { let text: String; let targets: [DirectChatWriteTarget] }
    private var targets: [DirectChatWriteTarget] {
        if let reply { return manager.targetForMessage(reply.id).map { [$0] } ?? [] }
        return [ManagedProvider.youtube, .twitch].compactMap { selected.contains($0) ? manager.writeTarget($0) : nil }
    }
    private var canReview: Bool {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.utf8.count > 4096 || targets.isEmpty { return false }
        if reply == nil && targets.count != selected.count { return false }
        if let reply, !manager.canReply(reply.id) { return false }
        for target in targets {
            if !manager.canSend(target.provider) || text.count > (target.provider == .youtube ? 200 : 500) { return false }
        }
        return true
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(reply.map { "Reply to \($0.author)" } ?? "Post a public message").font(.headline)
            if let reply { Text(reply.text).font(.caption).lineLimit(3) }
            else {
                Text("Choose each destination explicitly. Only the current owned direct chats are supported.").font(.caption)
                targetToggle(.youtube)
                targetToggle(.twitch)
            }
            TextEditor(text: $text).frame(height: 100)
            Text("\(text.count) characters · YouTube limit 200 · Twitch limit 500 · 4096 UTF-8 bytes maximum").font(.caption)
            presetControls
            Text("Twitch user-token messages may appear in all participating Shared Chat channels. YouTube posts public text without threaded replies. Every target receives one request; receipts report provider acknowledgements independently. Stream never inserts a local echo.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { dismiss() }; Spacer()
                Button("Review Send…") { review = .init(text: text, targets: targets) }.disabled(!canReview)
            }
        }.padding(20).frame(width: 480)
        .onChange(of: manager.writeTarget(.youtube)) { _, _ in selected.remove(.youtube) }
        .onChange(of: manager.writeTarget(.twitch)) { _, _ in selected.remove(.twitch) }
        .confirmationDialog("Send this public message?", isPresented: Binding(
            get: { review != nil }, set: { if !$0 { review = nil } }), titleVisibility: .visible) {
            if let draft = review {
                Button("Send to Reviewed Targets") {
                    if let reply, let target = draft.targets.first {
                        manager.send(draft.text, provider: target.provider, replyingTo: reply.id, expectedTarget: target)
                    } else { manager.send(draft.text, to: draft.targets) }
                    review = nil; dismiss()
                }
            }
        } message: {
            Text("\(review?.targets.map(\.label).joined(separator: "\n") ?? "No target")\n\n\(review?.text ?? "")\n\nA changed account or broadcast invalidates this review. Unconfirmed writes are never replayed.")
        }
    }
    private func targetToggle(_ provider: ManagedProvider) -> some View {
        let reason = manager.sendAvailabilityError(provider)
        return VStack(alignment: .leading, spacing: 2) {
            Toggle("\(provider.name) · \(manager.snapshot(provider).target.isEmpty ? "No verified target" : manager.snapshot(provider).target)", isOn: Binding(
                get: { selected.contains(provider) }, set: { if $0 { selected.insert(provider) } else { selected.remove(provider) } }))
                .disabled(reason != nil && !selected.contains(provider))
            if let reason { Text(reason).font(.caption2).foregroundStyle(.secondary) }
        }
    }
    private var presetControls: some View {
        DisclosureGroup("Reusable message presets") {
            VStack(alignment: .leading, spacing: 6) {
                Picker("Preset", selection: $presetID) {
                    Text("New preset").tag(Optional<UUID>.none)
                    ForEach(presets.document.presets) { Text($0.name).tag(Optional($0.id)) }
                }
                .onChange(of: presetID) { _, id in
                    if let preset = presets.document.presets.first(where: { $0.id == id }) { text = preset.text; presetName = preset.name }
                    else { presetName = "" }
                }
                TextField("Preset name", text: $presetName)
                HStack {
                    Button(presetID == nil ? "Save New Preset" : "Update Preset") { _ = presets.save(name: presetName, text: text, replacing: presetID) }
                        .disabled(!presets.writable || presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.isEmpty || text.count > 500 || text.utf8.count > 4096)
                    if let id = presetID { Button("Remove Preset") { presets.remove(id); presetID = nil } }
                }.controlSize(.small)
                if let error = presets.error { Text(error).font(.caption).foregroundStyle(.orange) }
                Text("Only your preset names/text are saved in this project. Targets, receipts and credentials are never saved, and loading a preset never sends it.").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

private struct DirectChatReceipts: View {
    @ObservedObject var manager: StudioDirectChatManager
    var body: some View {
        if !manager.receipts.isEmpty {
            DisclosureGroup("Recent chat actions · \(manager.receipts.count)/64") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(manager.receipts.reversed()) { receipt in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(receipt.provider.name) · \(receipt.target) · \(receipt.kind.label)").font(.caption.weight(.semibold))
                            Text(receipt.state.label).font(.caption2).foregroundStyle(receipt.state == .acknowledged ? Color.green : Color.secondary)
                            Text(receipt.summary).font(.caption2).lineLimit(2).textSelection(.enabled)
                            if receipt.state.isPending { Button("Stop Waiting") { manager.cancelWrite(receiptID: receipt.id) }.controlSize(.small) }
                        }.accessibilityElement(children: .contain)
                    }
                    Button("Clear Completed Receipts") { manager.clearReceipts() }.controlSize(.small)
                    Text("Stopping locally cannot undo a provider action. Inspect the provider before retrying an unknown outcome. Receipts remain in memory and are not restored or exported.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}
