import Combine
import CryptoKit
import Foundation
import StreamCore

/// Configured slot actions deliberately follow the saved public assignment on
/// each NEW press. Live connection commands and provider writes instead carry
/// their exact authority; neither pending requests nor reconnects replay them.
enum StudioInteractionCommand: Equatable, Sendable {
    enum GuestAction: String, CaseIterable, Sendable { case admit, mute, unmute, solo, unsolo, remove, addToLayout }
    case guestSlot(UUID, GuestAction)
    case latestComment
    case sendPreset(UUID, DirectChatWriteTarget, String)
    case selectProfile(project: UUID, profile: UUID)
    var capturesAuthority: Bool { if case .sendPreset = self { return true }; return false }
    var label: String {
        switch self {
        case .guestSlot(_, let action): "Guest Slot \(action.rawValue)"
        case .latestComment: "Show Latest Comment"
        case .sendPreset: "Send Chat Preset"
        case .selectProfile: "Select Show Profile"
        }
    }
}

@MainActor final class StudioInteractionController {
    private weak var dispatcher: StudioCommandDispatcher?
    private weak var controller: StreamController?
    private weak var store: SceneStore?
    private weak var preview: PreviewProgramModel?
    private weak var chat: StudioChatCoordinator?
    private weak var interviews: NativeInterviewManager?
    private weak var workspace: StudioWorkspace?
    private var boundToWorkspace = false
    private weak var accounts: ProviderAccountSession?
    private let runtimeAuthority = UUID()
    private var observations: Set<AnyCancellable> = []
    private var presetObservation: AnyCancellable?
    private var directObservation: AnyCancellable?
    private var profileSelection: UUID?
    private var profileRequest: StudioWorkspace.Selection?
    private var presetReceipts: [String: UUID] = [:]
    var changed: (() -> Void)?

    init(dispatcher: StudioCommandDispatcher, controller: StreamController, store: SceneStore, preview: PreviewProgramModel) {
        self.dispatcher = dispatcher; self.controller = controller; self.store = store; self.preview = preview
    }
    func bind(chat: StudioChatCoordinator) {
        self.chat = chat
        chat.$directChat.sink { [weak self] direct in
            self?.presetObservation = direct?.presets.objectWillChange.sink { [weak self] _ in self?.changed?() }
            self?.directObservation = direct?.objectWillChange.sink { [weak self] _ in self?.changed?() }
        }.store(in: &observations)
    }
    func bind(interviews: NativeInterviewManager) { self.interviews = interviews }
    func bind(workspace: StudioWorkspace) {
        self.workspace = workspace; boundToWorkspace = true; bind(accounts: workspace.runtime.providerAccounts)
        workspace.objectWillChange.sink { [weak self] _ in self?.changed?() }.store(in: &observations)
    }
    func bind(accounts: ProviderAccountSession) {
        self.accounts = accounts
        accounts.objectWillChange.sink { [weak self] _ in self?.changed?() }.store(in: &observations)
    }
    private var current: Bool {
        guard let dispatcher else { return false }
        return workspace.map { $0.runtime.dispatcher === dispatcher } ?? !boundToWorkspace
    }
    static func authority(_ parts: [String]) -> String {
        SHA256.hash(data: (try? JSONEncoder().encode(parts)) ?? Data()).map { String(format: "%02x", $0) }.joined()
    }
    static func authority(_ lease: NativeInterviewPeerLease) -> String {
        authority([lease.room.uuidString, lease.hostGeneration.uuidString, lease.guestGeneration.uuidString,
            lease.receive.slot.uuidString, lease.receive.peerID.uuidString, lease.receive.negotiation.uuidString, String(lease.receive.generation)])
    }
    func guestAuthority(_ guest: UUID) -> String? {
        if let lease = interviews?.controllerLease(for: guest) { return Self.authority(lease) }
        guard let lease = interviews?.controllerRosterLease(for: guest) else { return nil }
        return Self.authority([lease.room.uuidString, lease.hostGeneration.uuidString, lease.guest.uuidString, lease.guestGeneration.uuidString])
    }
    func authority(for command: StudioInteractionCommand) -> String? {
        switch command {
        case .guestSlot(let slot, let action):
            return action == .addToLayout ? nil : member(in: slot).flatMap { guestAuthority($0.id) }
        case .sendPreset(let id, let target, let text):
            return Self.authority([id.uuidString, target.provider.rawValue, target.channelID, target.chatID, target.broadcastID, target.generation.uuidString, text])
        case .selectProfile: return runtimeAuthority.uuidString
        default: return nil
        }
    }
    private func member(in slot: UUID) -> NativeInterviewMember? {
        guard let interviews else { return nil }
        let matches = interviews.state.snapshot.members.filter { interviews.assignedSlot(for: $0.id) == slot }
        return matches.count == 1 ? matches[0] : nil
    }
    private func guestCommand(_ slot: UUID, _ action: StudioInteractionCommand.GuestAction) -> StudioCommand? {
        guard let member = member(in: slot), let interviews else { return nil }
        if action == .admit { return .interview(.admit(member.id)) }
        if action == .remove { return .interview(.remove(member.id)) }
        guard let lease = interviews.currentReadyLease, lease.receive.slot == slot, lease.receive.peerID == member.id else { return nil }
        switch action {
        case .mute, .unmute: return .interview(.setMuted(lease, action == .mute))
        case .solo, .unsolo: return .interview(.setSolo(lease, action == .solo))
        default: return nil
        }
    }
    func availabilityError(for command: StudioInteractionCommand) -> StudioCommandError? {
        guard current, let dispatcher else { return .unavailable("This studio runtime has retired.") }
        switch command {
        case .guestSlot(let id, let action):
            guard store?.guestSlots.contains(where: { $0.id == id }) == true else { return .invalidTarget("The configured guest slot was deleted.") }
            if action == .addToLayout {
                guard let scene = preview?.stagedScene else { return .unavailable("Choose a Preview scene first.") }
                guard preview?.directLiveEditing == false else { return .unavailable("Disable Direct Live Editing before adding a guest layout. Take publishes it.") }
                return dispatcher.availabilityError(for: .updateScene(scene))
            }
            guard let target = guestCommand(id, action) else { return .unavailable("The configured slot has no matching ready guest for this action. Assign a waiting invite in Guests before admitting it.") }
            guard let guest = member(in: id), guestAuthority(guest.id) != nil else { return .unavailable("The interview service must expose the current guest generation before a controller can change admission.") }
            return dispatcher.availabilityError(for: target)
        case .latestComment:
            guard chat?.guestPublicAvailable == true, chat?.queue.messages.last != nil else { return .unavailable("No public comment is available.") }
            return dispatcher.availabilityError(for: .hideComment)
        case .sendPreset(let id, let target, let text):
            guard let direct = chat?.directChat, let preset = direct.presets.document.presets.first(where: { $0.id == id }), preset.text == text else { return .invalidTarget("This preset changed or was deleted. Review its current text.") }
            guard direct.writeTarget(target.provider) == target else { return .invalidTarget("The chat account, broadcast or reader changed. Refresh the binding before sending.") }
            guard direct.canSend(target.provider), text.count <= (target.provider == .youtube ? 200 : 500) else { return .unavailable(direct.sendAvailabilityError(target.provider) ?? "The preset exceeds this provider's supported message length.") }
            return nil
        case .selectProfile(let project, let profile):
            guard let workspace, workspace.catalog.projects.contains(where: { $0.id == project && !$0.isArchived && $0.profiles.contains(where: { $0.id == profile }) }) else { return .invalidTarget("The configured show profile is missing or archived.") }
            guard workspace.canSwitch, !workspace.packageBusy, !workspace.permissionChoicePending,
                  !dispatcher.macros.isRunning, profileSelection == nil else { return .unavailable("Stop active outputs and recordings, finish setup and let the current operation complete before changing show profiles.") }
            return nil
        }
    }
    func execute(_ command: StudioInteractionCommand) -> StudioCommandError? {
        if let error = availabilityError(for: command) { return error }
        guard let dispatcher else { return .unavailable("The studio retired.") }
        switch command {
        case .guestSlot(let id, .addToLayout):
            guard let slot = store?.guestSlots.first(where: { $0.id == id }), var scene = preview?.stagedScene,
                  let template = GuestSceneTemplate.solo.scene(slots: [slot], sources: store?.sources ?? [], hostCamera: nil) else { return .invalidTarget("The guest slot or Preview scene changed.") }
            for var layer in template.layers {
                layer.transform.position.x = 0.69 + layer.transform.position.x * 0.28
                layer.transform.position.y = 0.60 + layer.transform.position.y * 0.36
                layer.transform.size.width *= 0.28; layer.transform.size.height *= 0.36
                if case .text(var payload) = layer.payload {
                    payload.fontSize *= 0.36; payload.padding *= 0.36; payload.overflow = .scaleDown
                    layer.payload = .text(payload)
                }
                scene.layers.append(layer)
            }
            return dispatcher.execute(.updateScene(scene)).error
        case .guestSlot(let id, let action):
            guard let target = guestCommand(id, action) else { return .invalidTarget("The guest connection changed.") }
            return dispatcher.execute(target).error
        case .latestComment:
            guard let message = chat?.queue.messages.last else { return .invalidTarget("The latest comment was removed.") }
            chat?.show(message.id)
            return chat?.queue.featuredID == message.id ? nil : .unavailable(chat?.error ?? "The comment could not be staged.")
        case .sendPreset(let id, let target, let text):
            guard let direct = chat?.directChat else { return .unavailable("The chat reader retired.") }
            let receipt = direct.send(text, provider: target.provider, expectedTarget: target)
            if presetReceipts.count >= 64 && presetReceipts[Self.presetID(id, target.provider)] == nil { presetReceipts.removeAll() }
            presetReceipts[Self.presetID(id, target.provider)] = receipt
            if let result = direct.receipts.first(where: { $0.id == receipt }), case .notSent(let reason) = result.state { return .unavailable(reason) }
            return nil
        case .selectProfile(let project, let profile):
            guard let workspace else { return .unavailable("The show catalog retired.") }
            if workspace.selection == .init(project: project, profile: profile) { return nil }
            let operation = UUID(); profileSelection = operation; profileRequest = .init(project: project, profile: profile); changed?()
            Task { @MainActor [weak self, weak workspace] in
                guard let self, let workspace, self.current, self.profileSelection == operation else { return }
                self.profileSelection = nil
                guard self.availabilityError(for: command) == nil else { self.profileRequest = nil; self.changed?(); return }
                workspace.stage(project: project, profile: profile)
                await workspace.applyPending()
                self.profileRequest = nil
                self.changed?()
            }
            return nil
        }
    }
    private static func presetID(_ id: UUID, _ provider: ManagedProvider) -> String { "chat.preset.\(id.uuidString).\(provider.rawValue).send" }
    func actions() -> [StudioPaletteAction] {
        var result: [StudioPaletteAction] = []
        func add(_ id: String, _ title: String, _ category: String, _ command: StudioInteractionCommand, scope: String? = nil, intent: String? = nil) {
            result.append(.init(id: id, title: title, category: category, command: .interaction(command),
                unavailableReason: availabilityError(for: command)?.description, scope: scope, bindingIntent: intent))
        }
        for slot in store?.guestSlots ?? [] {
            for action in StudioInteractionCommand.GuestAction.allCases {
                let label: String = switch action { case .admit: "Admit"; case .mute: "Mute"; case .unmute: "Unmute"; case .solo: "Monitor Solo"; case .unsolo: "Clear Monitor Solo"; case .remove: "Remove Guest"; case .addToLayout: "Add to Preview Layout" }
                add("guest.slot.\(slot.id.uuidString).\(action.rawValue)", "\(label) — \(slot.resolvedName)", "Guests", .guestSlot(slot.id, action), intent: "configuredSlot")
            }
        }
        add("comments.latest", "Show Latest Public Comment in Preview", "Comments", .latestComment)
        if let direct = chat?.directChat {
            for preset in direct.presets.document.presets {
                for provider in [ManagedProvider.youtube, .twitch] {
                    if let target = direct.writeTarget(provider) {
                        add(Self.presetID(preset.id, provider), "Send \(preset.name) — \(provider.name) · \(target.broadcastID)", "Chat Presets", .sendPreset(preset.id, target, preset.text), intent: "currentConnection")
                    } else {
                        result.append(.init(id: Self.presetID(preset.id, provider), title: "Send \(preset.name) — \(provider.name)", category: "Chat Presets", command: nil, unavailableReason: "Connect the supported provider's authorized chat reader first.", bindingIntent: "currentConnection"))
                    }
                }
            }
        }
        for project in (workspace?.catalog.projects ?? []).filter({ $0.id == workspace?.selection.project && !$0.isArchived }) {
            for profile in project.profiles {
                add("show.\(project.id.uuidString).profile.\(profile.id.uuidString).select", "Select \(project.name) · \(profile.name)", "Show Profiles", .selectProfile(project: project.id, profile: profile.id), scope: "studio")
            }
        }
        for (id, title) in [("audience.viewers", "Viewers by Provider"), ("audience.liveTime", "Local Live Elapsed Time"), ("audience.health", "Publishing Connection State")] {
            result.append(.init(id: id, title: title, category: "Audience", command: nil, unavailableReason: nil, kind: "feedback"))
        }
        for destination in controller?.destinations.saved ?? [] where destination.providerBinding != nil {
            result.append(.init(id: "audience.\(destination.id.uuidString).viewers", title: "Viewers — \(destination.name)", category: "Audience", command: nil, unavailableReason: nil, kind: "feedback"))
        }
        return result
    }
    func guestSlotsSnapshot() -> [StudioControlGuestSlotState] {
        (store?.guestSlots ?? []).map { slot in
            let guest = member(in: slot.id), lease = interviews?.currentReadyLease
            let matching = lease?.receive.slot == slot.id ? lease : nil
            let label = matching.map { AudioMixEngine.guestChannelID(for: $0.receive).label }
            return .init(id: slot.id, name: GuestPublicChatEnvelope.prefix(slot.resolvedName, bytes: 256), peerID: guest?.id, membership: guest?.membership.rawValue,
                media: guest?.media.rawValue, muted: label.map { dispatcher?.state.mixer.channelMutes[$0] == true },
                solo: label.map { dispatcher?.state.mixer.soloedChannels.contains($0) == true })
        }
    }
    func showProfilesSnapshot() -> StudioControlShowProfileState? {
        guard let workspace else { return nil }
        return .init(projectID: workspace.selection.project, profileID: workspace.selection.profile,
            canSelect: current && workspace.canSwitch && !workspace.packageBusy && !workspace.permissionChoicePending && profileSelection == nil && dispatcher?.macros.isRunning != true,
            requestedProjectID: profileRequest?.project, requestedProfileID: profileRequest?.profile)
    }
    func audienceSnapshot(now: Date = Date()) -> StudioControlAudienceState {
        let readings = (controller?.destinations.saved ?? []).filter { $0.providerBinding != nil }.prefix(64).map { destination -> StudioControlAudienceState.Reading in
            let value = destination.providerBinding.flatMap { accounts?.viewerReading($0, now: now) }
            return .init(destinationID: destination.id, name: GuestPublicChatEnvelope.prefix(destination.name, bytes: 512), count: value?.count, readAt: value?.readAt?.timeIntervalSince1970,
                freshness: value?.freshness.rawValue ?? "unavailable")
        }
        let states = controller?.destinationOutputs.states ?? [:]
        let live = states.filter { $0.value == .live }.keys.compactMap { controller?.destinationOutputs.acknowledgedStarts[$0] }.filter { now.timeIntervalSince($0) >= 0 }
        let seconds = live.min().map { min(31_536_000, Int(now.timeIntervalSince($0))) }
        let health = states.values.contains(where: { if case .failed = $0 { return true }; if case .reconnecting = $0 { return true }; return false }) ? "degraded" : states.values.contains(.live) ? "live" : states.values.contains(.connecting) ? "connecting" : states.values.contains(.stopping) ? "stopping" : "idle"
        return .init(observedAt: now.timeIntervalSince1970, liveSeconds: seconds, health: health, readings: readings,
            presetDelivery: presetReceipts.reduce(into: [:]) { result, pair in
                if let receipt = chat?.directChat?.receipts.first(where: { $0.id == pair.value }) { result[pair.key] = switch receipt.state { case .sending: "sending"; case .acknowledged: "acknowledged"; case .notSent: "notSent"; case .rejected: "rejected"; case .unconfirmed: "unconfirmed"; case .stopped: "stopped" } }
            })
    }
}
