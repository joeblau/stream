import AppKit
import SwiftUI
import StreamCore

struct NativeInterviewView: View {
    @ObservedObject var manager: NativeInterviewManager
    @EnvironmentObject private var dispatcher: StudioCommandDispatcher
    @EnvironmentObject private var sceneStore: SceneStore
    @EnvironmentObject private var previewProgram: PreviewProgramModel
    @State private var serviceURL = ""
    @State private var origin = ""
    @State private var operatorCredential = ""
    @State private var formMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Guests").font(.headline)
                Text("One guest connection with incoming camera, screen and audio. Public audio and optional Program, Secondary, or Clean video return availability appear below.")
                    .font(.caption).foregroundStyle(.secondary)
                GuestSlotsView(store: sceneStore)
                if [.idle, .ended, .expired, .failed, .closed].contains(manager.state.snapshot.phase) {
                    creationForm
                }
                if manager.state.snapshot.room != nil && [.connected, .connecting, .disconnected, .ending].contains(manager.state.snapshot.phase) {
                    roomControls
                }
                if let failure = manager.state.failure {
                    Text(NativeInterviewViewValues.message(failure)).foregroundStyle(.orange)
                        .accessibilityLabel("Guest connection issue: " + NativeInterviewViewValues.message(failure))
                }
                if let formMessage { Text(formMessage).font(.caption).foregroundStyle(.secondary) }
                ForEach(manager.state.snapshot.members) { member in guest(member) }
                if manager.state.snapshot.phase == .connected && manager.state.snapshot.members.isEmpty {
                    Text("Share an invite to bring a guest into the lobby. Admission is deliberate.")
                        .foregroundStyle(.secondary)
                }
            }.padding(12)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Guest interview controls")
        // Runtime ownership deliberately survives view/window detach. Every
        // callback captures this manager, never a mutable workspace runtime.
    }
    private var creationForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("HTTPS interview service URL", text: $serviceURL)
                .textFieldStyle(.roundedBorder).accessibilityIdentifier("interview.serviceURL")
            TextField("Allowed site origin (defaults to service URL)", text: $origin)
                .textFieldStyle(.roundedBorder)
            SecureField("Operator credential", text: $operatorCredential)
                .textFieldStyle(.roundedBorder).accessibilityIdentifier("interview.operatorCredential")
            Text("The credential is used privately for this room. Ending the room disables future credential reads; in-flight requests finish or cancel separately.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Create and Connect Room") { create() }
                .disabled(manager.state.busy || operatorCredential.isEmpty || serviceURL.isEmpty)
                .accessibilityIdentifier("interview.create")
        }
    }
    private var roomControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(NativeInterviewViewValues.phase(manager.state.snapshot.phase)).font(.subheadline)
                if manager.state.busy { ProgressView().controlSize(.small) }
            }
            let members = manager.state.snapshot.members
            Text("\(members.filter { $0.membership != .waiting }.count)/1 admitted · \(members.filter { $0.membership == .waiting }.count) waiting")
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("interview.capacity")
            Button("Copy Guest Invite Link") { share() }
                .disabled(manager.state.busy || ![.connected, .disconnected].contains(manager.state.snapshot.phase))
                .accessibilityIdentifier("interview.share")
            HStack {
                commandButton(manager.state.snapshot.locked ? "Unlock Room" : "Lock Room", .lock(!manager.state.snapshot.locked))
                if manager.state.snapshot.phase == .disconnected { commandButton("Rejoin Room", .rejoin) }
                else { commandButton("Disconnect", .disconnect) }
            }
            commandButton("End Room", .end)
                .accessibilityIdentifier("interview.end")
        }
    }
    private func guest(_ member: NativeInterviewMember) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text(manager.displayName(for: member.id)).font(.headline)
            Text("\(member.membership.rawValue.capitalized) · \(NativeInterviewViewValues.media(member.media))")
                .font(.caption).foregroundStyle(.secondary)
            if member.membership == .waiting {
                Picker("Saved Guest Slot", selection: Binding<UUID?>(
                    get: { manager.assignedSlot(for: member.id) },
                    set: { slot in if let slot { _ = manager.assignSlot(slot, to: member.id) } })) {
                    Text("Automatic unused slot").tag(Optional<UUID>.none)
                    ForEach(sceneStore.guestSlots) { slot in Text(slot.name).tag(Optional(slot.id)) }
                }
                commandButton("Admit Backstage", .admit(member.id))
            } else {
                if let context = dispatcher.currentGuestCommandContext(for: member.id) {
                    NativeGuestLocalControls(dispatcher: dispatcher, context: context,
                        serviceName: member.name,
                        localName: sceneStore.guestSlots.first(where: { $0.id == context.receive.slot })?.localName ?? "")
                        .id(context)
                    NativeGuestPrivateMessages(manager: manager, dispatcher: dispatcher, context: context)
                        .id(context)
                    NativeGuestTalkbackView(manager: manager, dispatcher: dispatcher, context: context)
                        .id(context)
                    if member.publicChat != .unavailable {
                        let shared = member.publicChat == .sharing
                        commandButton(shared ? "Stop Sharing Public Chat" : "Share Future Public Chat", .setPublicChatReturn(context, !shared))
                        Text("Shares new public messages from the studio's shared chat only. Long text may be clipped and bursts omitted. Private messages stay separate; reconnect stops sharing. No public overlay changes.")
                            .font(.caption).foregroundStyle(.secondary)
                        if member.publicChatDropped > 0 { Text("\(member.publicChatDropped) public messages omitted by format, rate or connection limits.").font(.caption).foregroundStyle(.secondary) }
                        if member.publicChat == .offUnconfirmed { Text("Stopped locally; guest display unconfirmed. Its feed expires without fresh host updates.").font(.caption).foregroundStyle(.orange) }
                    }
                }
                Text(member.returnAudio == .ready ? "Public show audio return is active; your own audio is excluded." :
                    member.returnAudio == .preparing ? "Preparing public show audio return. Start local preview to supply the mix." :
                    "Public show audio return is unavailable.")
                    .font(.caption).foregroundStyle(.secondary)
                if let context = manager.currentReadyLease, context.receive.peerID == member.id,
                   member.returnVideo != .unavailable {
                    let enabled = member.returnVideo == .preparing || member.returnVideo == .ready
                    HStack {
                        ForEach(NativeInterviewReturnVideoSource.allCases, id: \.self) { source in
                            commandButton(source.title, .selectReturnVideoSource(context, source))
                                .disabled(member.returnVideoSource == source)
                        }
                    }
                    commandButton(enabled ? "Stop Video Return" : "Start \(member.returnVideoSource.title) Video Return", .setProgramReturn(context, !enabled))
                    Text(member.returnVideo == .ready ? "Sending \(member.returnVideoSource.title) video, up to \(member.returnVideoProfile.width) × \(member.returnVideoProfile.height) at \(member.returnVideoProfile.framesPerSecond) fps / \(member.returnVideoProfile.maximumBitrate / 1000) kbps. Quality follows measured receiver feedback. Remote playback is not confirmed." :
                        member.returnVideo == .preparing ? "Preparing \(member.returnVideoSource.title) video return." :
                        member.returnVideo == .bandwidthLimited ? "Video return stopped because measured video capacity fell below64kbps. Audio continues. Check the connection, then explicitly start video again." :
                        member.returnVideo == .failed ? "Video return stopped or could not start. Check local preview and the studio encoder budget, then retry." :
                        "\(member.returnVideoSource.title) video return is off. It uses one encoder when enabled. Secondary requires a configured layout in Program. Clean omits project overlays and live annotations; scene layers remain. Additional compositions require qualified hardware.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    commandButton("On Air", .onair(member.id))
                    commandButton("Backstage", .backstage(member.id))
                }
                if manager.state.routes[member.id]?.programAllowed == true {
                    Label("Allowed in Program", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
                commandButton(manager.state.routes[member.id]?.monitorAllowed == true ? "Remove from Monitor" : "Allow in Monitor",
                              .monitor(member.id, manager.state.routes[member.id]?.monitorAllowed != true))
                commandButton(member.screenApproved ? "Revoke Screen Sharing" : "Approve Screen Sharing",
                              .approveScreen(member.id, !member.screenApproved))
                if member.screenSharing { Text("Screen sharing is active.").font(.caption) }
                HStack {
                    addLayerButton("Add Camera to Preview", member: member, role: .camera)
                    addLayerButton("Add Screen to Preview", member: member, role: .screen)
                }
                Text("Add the source to Preview, then Take to publish the layout. On Air separately permits its media in Program.")
                    .font(.caption).foregroundStyle(.secondary)
                commandButton("Reconnect Media", .restartMedia(member.id))
            }
            commandButton("Remove Guest", .remove(member.id))
        }
    }
    private func commandButton(_ title: String, _ command: NativeInterviewCommand) -> some View {
        Button(title) { dispatcher.execute(.interview(command)) }
            .disabled(!dispatcher.canExecute(.interview(command)))
            .help(dispatcher.availabilityError(for: .interview(command))?.description ?? title)
    }
    private func addLayerButton(_ title: String, member: NativeInterviewMember, role: GuestSourceRole) -> some View {
        let slot = manager.state.routes[member.id]?.slot
        let source = NativeInterviewViewValues.source(sceneStore.sources, slot: slot, role: role)
        return Button(title) {
            guard let source, var scene = previewProgram.stagedScene else { return }
            scene.layers.append(.init(name: source.name, sourceID: source.id, payload: source.payload, transform: .fullscreen))
            dispatcher.execute(.updateScene(scene))
        }.disabled(source == nil || member.media != .ready)
    }
    private func create() {
        do {
            guard let url = URL(string: serviceURL), let allowed = URL(string: origin.isEmpty ? serviceURL : origin) else {
                throw NativeInterviewError.configuration
            }
            let configuration = try NativeInterviewConfiguration(serviceURL: url, allowedOrigin: allowed)
            let secret = try NativeInterviewSecret(operatorCredential)
            operatorCredential = ""; formMessage = nil
            Task { [manager] in
                do { try await manager.create(configuration: configuration, credential: secret) }
                catch { formMessage = NativeInterviewViewValues.message((error as? NativeInterviewError) ?? .transport) }
            }
        } catch { formMessage = NativeInterviewViewValues.message((error as? NativeInterviewError) ?? .configuration) }
    }
    private func share() {
        formMessage = nil
        Task { [manager] in
            do {
                let url = try await manager.inviteForSharing()
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string)
                formMessage = "Private expiring guest invite copied. Share it only with the intended guest."
            } catch { formMessage = NativeInterviewViewValues.message((error as? NativeInterviewError) ?? .transport) }
        }
    }
}

/// The rendered controls retain their exact connection, rather than looking
/// up a replacement while processing an old button or text-field callback.
private struct NativeGuestLocalControls: View {
    @ObservedObject var dispatcher: StudioCommandDispatcher
    let context: NativeInterviewPeerLease
    let serviceName: String
    @State private var name: String

    init(dispatcher: StudioCommandDispatcher, context: NativeInterviewPeerLease,
         serviceName: String, localName: String) {
        self.dispatcher = dispatcher; self.context = context; self.serviceName = serviceName
        _name = State(initialValue: localName)
    }
    private var channel: AudioChannelID { AudioMixEngine.guestChannelID(for: context.receive) }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                let muted = dispatcher.state.mixer.channelMutes[channel.label] == true
                let soloed = dispatcher.state.mixer.soloedChannels.contains(channel.label)
                button(muted ? "Unmute" : "Mute", .setMuted(context, !muted))
                button(soloed ? "Clear Monitor Solo" : "Solo in Monitor", .setSolo(context, !soloed))
            }
            Text("Mute uses the saved mixer channel. Solo affects private Monitor after the guest is allowed there; it grants no Monitor or Program permission.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Local display name", text: $name).textFieldStyle(.roundedBorder)
            HStack {
                button("Save Local Name", .rename(context, name))
                Button("Use Guest Name") {
                    if dispatcher.execute(.interview(.rename(context, ""))).error == nil { name = "" }
                }.disabled(!dispatcher.canExecute(.interview(.rename(context, ""))))
            }
            Text("Guest-reported name: \(serviceName). The local name labels this project and its overlays; it is not sent to the guest service.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func button(_ title: String, _ action: NativeInterviewCommand) -> some View {
        Button(title) { dispatcher.execute(.interview(action)) }
            .disabled(!dispatcher.canExecute(.interview(action)))
            .help(dispatcher.availabilityError(for: .interview(action))?.description ?? title)
    }
}

/// Private conversation contents never enter the shared command snapshot.
private struct NativeGuestPrivateMessages: View {
    @ObservedObject var manager: NativeInterviewManager
    @ObservedObject var dispatcher: StudioCommandDispatcher
    let context: NativeInterviewPeerLease
    @State private var draft = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Private messages").font(.headline)
            if !manager.privateMessages.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(manager.privateMessages) { message in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(message.fromGuest ? "Guest" : "You").font(.caption).foregroundStyle(.secondary)
                                Text(message.text).textSelection(.enabled)
                                if !message.fromGuest { Text(receipt(message.delivery)).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 150)
            }
            TextField("Message this guest privately", text: $draft, axis: .vertical)
                .lineLimit(1...3).textFieldStyle(.roundedBorder)
            Button("Send Private Message") {
                let command = StudioCommand.interview(.sendPrivateMessage(context, draft))
                if dispatcher.execute(command).error == nil { draft = "" }
            }.disabled(!dispatcher.canExecute(.interview(.sendPrivateMessage(context, draft))))
            Text("Text stays in this connection and is cleared on reconnect or room end. Received means the guest browser accepted it. Delivery without a receipt remains unknown; nothing is resent automatically.")
                .font(.caption).foregroundStyle(.secondary)
        }.onChange(of: manager.privateMessageConnectionOpen(context: context)) { _, open in
            if !open { draft = "" }
        }
    }
    private func receipt(_ state: NativeInterviewPrivateDelivery) -> String {
        switch state { case .pending: return "Waiting for guest receipt"; case .received: return "Guest received"; case .unknown: return "Delivery unknown" }
    }
}

private enum NativeInterviewViewValues {
    nonisolated static func source(_ sources: [SourceDefinition], slot: UUID?, role: GuestSourceRole) -> SourceDefinition? {
        guard let slot else { return nil }
        return sources.first { source in
            guard case .guest(let payload) = source.payload else { return false }
            return payload.slotID == slot && payload.role == role
        }
    }
    nonisolated static func phase(_ phase: NativeInterviewPhase) -> String {
        switch phase {
        case .connected: return "Room connected"
        case .connecting: return "Connecting room…"
        case .disconnected: return "Room disconnected; rejoin is explicit"
        case .ending: return "Ending room…"
        case .ended: return "Room ended"
        case .expired: return "Room expired"
        default: return phase.rawValue.capitalized
        }
    }
    nonisolated static func media(_ state: NativeInterviewMediaState) -> String {
        switch state {
        case .unavailable: return "Media unavailable"
        case .preparing: return "Preparing media"
        case .negotiating: return "Connecting media"
        case .ready: return "Media connected"
        case .failed: return "Media connection failed"
        }
    }
    nonisolated static func message(_ error: NativeInterviewError) -> String {
        switch error {
        case .configuration: return "Enter the HTTPS interview service URL and its allowed site origin."
        case .authorization: return "Interview authorization was refused. Check the credential and current room."
        case .expired: return "This room or media credential expired. Create a new room or deliberately reconnect media."
        case .unavailable: return "The media relay is unavailable or not configured. Guest media cannot connect."
        case .uncertainMutation: return "The request may have reached the service. It will not be replayed automatically."
        case .busy, .capacity: return "The single guest connection or previous preparation is still occupied. Wait and try again."
        case .rateLimited: return "The service rate limit was reached. Wait before trying again."
        case .timeout: return "The connection timed out. Reconnecting requires a new deliberate action."
        case .changed, .cancelled, .closed: return "The room or guest changed; the previous action was retired."
        case .malformed: return "The service or guest returned an invalid response."
        case .transport: return "The service connection failed. Rejoin or retry deliberately."
        }
    }
}
