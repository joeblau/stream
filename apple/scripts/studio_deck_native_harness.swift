import AppKit
import Foundation
import StreamCore

@main @MainActor struct DeckNativeHarness {
    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw NSError(domain: "DeckNativeHarness", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func main() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("stream-deck-native-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        DesktopStorage.projectDirectory = directory
        let budgetDestination = StreamDestination(name: "Budget Fixture", transport: .rtmp)
        try JSONEncoder().encode([budgetDestination]).write(to: directory.appendingPathComponent("destinations.json"))
        let runtime = StudioRuntime()
        runtime.controllers.shutdown(); runtime.localControl.shutdown()
        runtime.dispatcher.bindChatCoordinator(runtime.chat)
        // The generated tool replaces Keychain with a no-op boundary. These
        // valid in-memory fixture credentials let the real budget gate run.
        runtime.controller.destinations.credentials[budgetDestination.id] = .init(endpoint: "rtmp://127.0.0.1/live", streamKey: "fixture-only")
        try require(runtime.controller.destinations.apply(), "Seed valid fixture destination")
        defer { runtime.controllers.shutdown(); runtime.localControl.shutdown(); runtime.chat.shutdown(); runtime.flush() }
        runtime.controller.maximumPublishingEncoders = { 0 }
        runtime.controller.goLive()
        try require(runtime.controller.errorMessage?.contains("budget reserved by isolated recording") == true, "Go Live did not honor recording reservation")
        runtime.controller.startDestination(budgetDestination.id)
        try require(runtime.controller.errorMessage?.contains("budget reserved by isolated recording") == true && runtime.controller.activePublishingEncoderCount == 0, "Destination start bypassed reservation")
        runtime.controller.maximumPublishingEncoders = { nil }
        let dispatcher = runtime.dispatcher
        let first = LayerNode(name: "First Caption", payload: .text(TextSourcePayload(text: "One")), transform: .fullscreen)
        let second = LayerNode(name: "Second Caption", payload: .text(TextSourcePayload(text: "Two")), transform: .fullscreen)
        let scene = Scene(name: "Controller Test", layers: [first, second])
        try require(dispatcher.execute(.insertScene(scene)).error == nil, "Insert test scene")
        try require(dispatcher.execute(.setDirectLiveEditing(false)).error == nil || !dispatcher.state.directLiveEditing, "Preview policy")
        try require(dispatcher.execute(.take).error == nil, "Initial program scene")
        let programBefore = runtime.previewProgram.programScene
        let hideID = "scene.\(scene.id.rawValue.uuidString).layer.\(first.id.rawValue.uuidString).hide"
        func run(_ id: String) throws {
            guard let command = dispatcher.catalogueActions().first(where: { $0.id == id })?.command else { throw NSError(domain: "DeckNativeHarness", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing \(id)"]) }
            try require(dispatcher.execute(command).error == nil, "Command rejected: \(id)")
        }
        try run(hideID)
        try require(dispatcher.state.layerVisibility[first.id] == false && runtime.previewProgram.programScene == programBefore, "Layer command bypassed Preview/Program policy")
        try require(dispatcher.execute(.renameLayer(first.id, to: "Renamed Caption", in: scene.id)).error == nil, "Rename layer")
        try require(dispatcher.catalogueActions().first(where: { $0.id == hideID })?.title.contains("Renamed Caption") == true, "Stable layer catalogue rename")
        try require(dispatcher.execute(.groupLayers([first.id, second.id], named: "Captions", in: scene.id)).error == nil, "Group test layers")
        guard let group = runtime.previewProgram.stagedScene?.groups.first else { throw NSError(domain: "DeckNativeHarness", code: 3) }
        try run("scene.\(scene.id.rawValue.uuidString).group.\(group.id.rawValue.uuidString).hide")
        try require(dispatcher.controllerGroupVisibility()[group.id.rawValue.uuidString] == false, "Authoritative group visibility")
        let previousOverlayIDs = Set(dispatcher.controllerOverlays().map(\.id))
        try require(dispatcher.execute(.addOverlay(.text(TextSourcePayload(text: "Global caption")))).error == nil, "Insert global overlay")
        guard let overlay = dispatcher.controllerOverlays().first(where: { !previousOverlayIDs.contains($0.id) }) else { throw NSError(domain: "DeckNativeHarness", code: 7) }
        let overlayPrefix = "overlay.\(overlay.id.rawValue.uuidString)"
        try run("\(overlayPrefix).hide")
        try require(dispatcher.controllerOverlays().first(where: { $0.id == overlay.id })?.isVisible == false, "Global overlay hide did not reach authoritative state")
        try require(dispatcher.execute(.renameOverlay(overlay.id, to: "Controller Global Caption")).error == nil, "Rename global overlay")
        try require(dispatcher.catalogueActions().first(where: { $0.id == "\(overlayPrefix).visibility" })?.title.contains("Controller Global Caption") == true, "Global overlay binding did not survive rename")
        try run("\(overlayPrefix).visibility")
        try require(dispatcher.controllerOverlays().first(where: { $0.id == overlay.id })?.isVisible == true, "Global overlay selector did not toggle authoritative state")
        try require(dispatcher.execute(.removeOverlay(overlay.id)).error == nil, "Remove global overlay")
        try require(!dispatcher.catalogueActions().contains(where: { $0.id == "\(overlayPrefix).visibility" }), "Deleted global overlay retained an executable binding")
        try require(dispatcher.controllerRecordingCountdown() == 0, "Idle recorder reported a countdown")
        guard let gain = dispatcher.controllerTargets().first(where: { $0.id == "audio.microphone.gain" }) else { throw NSError(domain: "DeckNativeHarness", code: 4) }
        try require(gain.execute(0.75) == nil && dispatcher.state.micVolume == 1.5, "Typed controller gain did not reach native settings")
        try require(gain.execute(2) != nil && dispatcher.state.micVolume == 1.5, "Out-of-range gain mutated native settings")
        try run("audio.microphone.mute.on")
        try require(dispatcher.controllerMuteSnapshot()["audio.microphone.gain"] == true, "Native mute feedback")
        try run("audio.microphone.mute.off")
        let event = try JSONSerialization.data(withJSONObject: ["action": "event", "timestamp": 1_800_000_000,
            "payload": ["connectionIdentifier": "fixture/channel", "eventTypeId": 5,
                "eventPayload": ["liveChatMessageId": "native-comment", "text": "Hello from a controller", "author": ["displayName": "Audience"]]]])
        runtime.chat.receive(event)
        guard let message = runtime.chat.queue.messages.first else { throw NSError(domain: "DeckNativeHarness", code: 5) }
        runtime.chat.enqueue(message.id); runtime.chat.createSlot()
        guard let slot = runtime.chat.selectedSlot else { throw NSError(domain: "DeckNativeHarness", code: 6) }
        let programBeforeComment = runtime.previewProgram.programScene
        try run("comments.show")
        try require(runtime.previewProgram.stagedScene?.layers.first(where: { $0.id == slot })?.isVisible == true, "Native comment was not staged")
        try require(runtime.previewProgram.programScene == programBeforeComment && dispatcher.controllerChatSnapshot()?.programVisible == false, "Comment feedback invented Program publication")
        try run("studio.take")
        try require(dispatcher.controllerChatSnapshot()?.programVisible == true, "Take did not update actual Program comment visibility")
        try run("comments.hide")
        try require(dispatcher.controllerChatSnapshot()?.stagedVisible == false && dispatcher.controllerChatSnapshot()?.programVisible == true, "Hide changed Program before Take")
        try require(dispatcher.availabilityError(for: .selectNextComment) != nil, "Queue boundary did not reject next")
        // A direct scene run uses the same Take hooks and can publish the
        // currently selected edited preview without restaging away its work.
        try run("scene.\(scene.id.rawValue.uuidString).run")
        try require(dispatcher.controllerChatSnapshot()?.programVisible == false, "Run scene discarded edited preview before Take")
        let alternate = Scene(name: "Second Transport Scene", layers: [])
        try require(dispatcher.execute(.insertScene(alternate)).error == nil, "Insert alternate run target")
        let runID = "scene.\(alternate.id.rawValue.uuidString).run"
        try run("scene.\(scene.id.rawValue.uuidString).run")
        try require(runtime.previewProgram.programScene?.id == scene.id, "Run scene failed to publish target")
        try require(dispatcher.execute(.renameScene(alternate.id, to: "Renamed Transport Scene")).error == nil, "Rename run target")
        try require(dispatcher.catalogueActions().first(where: { $0.id == runID })?.title.contains("Renamed Transport Scene") == true, "Run binding lost renamed scene")
        try run(runID)
        try require(runtime.previewProgram.programScene?.id == alternate.id, "Direct run did not update actual Program")
        try run("studio.scene.previous")
        try require(runtime.previewProgram.stagedScene?.id != alternate.id && runtime.previewProgram.programScene?.id == alternate.id,
            "Previous scene changed Program before Take")
        try run("studio.revert")
        try require(runtime.previewProgram.stagedScene == runtime.previewProgram.programScene, "Revert failed to restore authoritative Program")
        try run("studio.scene.previous"); try run("studio.scene.next")
        try require(runtime.previewProgram.stagedScene?.id == alternate.id, "Next scene did not select the adjacent scene")
        try run("studio.directLive.enable")
        try require(dispatcher.state.directLiveEditing, "Direct Live action did not set native editing policy")
        try run("studio.directLive.disable")
        try require(!dispatcher.state.directLiveEditing, "Preview-mode action did not set native editing policy")
        try run("scene.\(scene.id.rawValue.uuidString).run")
        try require(dispatcher.execute(.deleteScene(alternate.id)).error == nil && !dispatcher.catalogueActions().contains { $0.id == runID }, "Deleted run scene retained binding")

        let destinationSession = runtime.controller.destinations
        let destinationPrefix = "destination.\(budgetDestination.id.uuidString)"
        try require(dispatcher.catalogueActions().contains { $0.id == destinationPrefix + ".start" }, "Missing selected destination Start")
        let managed = StreamDestination(name: "Owned event fixture", transport: .rtmp,
            providerBinding: .init(provider: .youtube, channelID: "fixture-owner", eventID: "fixture-event"))
        destinationSession.draft.append(managed)
        destinationSession.credentials[managed.id] = .init(endpoint: "rtmp://127.0.0.1/live", streamKey: "fixture-only")
        try require(destinationSession.apply(), "Save event-bound test destination")
        let binding = managed.providerBinding!
        try require(StudioDestinationCommand.eventKey(binding) == StudioDestinationCommand.eventKey(binding), "Event key is unstable")
        try require(StudioDestinationCommand.eventKey(.init(provider: .youtube, channelID: "a", eventID: "bc")) != StudioDestinationCommand.eventKey(.init(provider: .youtube, channelID: "ab", eventID: "c")), "Ambiguous event identity collision")
        try require(StudioDestinationCommand.eventKey(.init(provider: .youtube, channelID: "a")) != StudioDestinationCommand.eventKey(.init(provider: .youtube, channelID: "a", eventID: "")), "Optional event identity collision")
        let eventPrefix = "destination.\(managed.id.uuidString).event.\(StudioDestinationCommand.eventKey(binding))"
        let capturedStart = StudioCommand.destination(.init(kind: .start, id: managed.id, binding: binding, eventBound: true))
        try require(dispatcher.catalogueActions().contains { $0.id == eventPrefix + ".start" }, "Missing exact event binding")
        if let index = destinationSession.draft.firstIndex(where: { $0.id == managed.id }) { destinationSession.draft[index].name = "Renamed owned event" }
        try require(destinationSession.apply(), "Rename selected event")
        try require(dispatcher.catalogueActions().first(where: { $0.id == eventPrefix + ".start" })?.title.contains("Renamed owned event") == true, "Event identity changed on rename")
        try run(eventPrefix + ".start")
        try require(runtime.controller.managedStart?.entries.contains { $0.id == managed.id } == true && !runtime.controller.outputSessionActive,
            "Event-bound Start bypassed native managed review")
        try run(eventPrefix + ".stop")
        try require(runtime.controller.managedStart?.entries.contains { $0.id == managed.id } == false,
            "Explicit Stop did not cancel pending native managed review")
        var remoteCalls = 0
        let endingTarget = StudioEndingTarget(id: managed.id, name: "Renamed owned event", session: nil, binding: binding)
        runtime.controller.ending.bind(.init(targets: { [endingTarget] }, stopLocal: { _ in .superseded },
            localReceipt: { _ in .superseded }, remote: { _, _ in remoteCalls += 1; return .init(.ended) }, canEndRemote: { _ in true }))
        let endID = eventPrefix + ".endRemote"
        try require(dispatcher.catalogueActions().first(where: { $0.id == endID })?.requiresConfirmation == true, "End Remote omitted confirmation descriptor")
        try run(endID)
        try require(remoteCalls == 0 && dispatcher.controllerTransportSnapshot().confirmationPending, "Remote end mutated provider before studio confirmation")
        guard let reviewID = dispatcher.controllerEndingReviewID() else { throw NSError(domain: "DeckNativeHarness", code: 9) }
        dispatcher.cancelControllerEndingReview(reviewID)
        try require(!dispatcher.controllerTransportSnapshot().confirmationPending && remoteCalls == 0, "Disconnect cancellation did not retire unconfirmed review")
        try run(endID)
        runtime.controller.ending.confirmControllerReview(dispatcher.controllerEndingReviewID()!)
        for _ in 0..<100 where runtime.controller.ending.isWorking { try await Task.sleep(for: .milliseconds(10)) }
        try require(remoteCalls == 1 && dispatcher.controllerTransportSnapshot().destinations.first(where: { $0.id == managed.id })?.remoteEnd == "ended", "Confirmed native end lacks authoritative receipt")
        if let index = destinationSession.draft.firstIndex(where: { $0.id == managed.id }) { destinationSession.draft[index].providerBinding?.eventID = "replacement-event" }
        try require(destinationSession.apply(), "Change saved event")
        try require(dispatcher.execute(capturedStart).error != nil, "Captured event start silently retargeted replacement")
        destinationSession.remove(managed.id); try require(destinationSession.apply(), "Delete event-bound destination")
        try require(!dispatcher.catalogueActions().contains { $0.id.hasPrefix("destination.\(managed.id.uuidString).") }, "Deleted destination retained command bindings")
        try require(!runtime.controller.outputSessionActive && !runtime.recorder.state.isActive, "Controller test started an output")
        if ProcessInfo.processInfo.environment["STREAM_DECK_VALIDATE_TRANSPORT"] == "1" { try await DeckTransportFixtures.run(directory: directory) }
        print("PASS: actual dispatcher stable layer/group/global-overlay catalogue, overlay rename/delete/toggle, preview/program policy, numeric gain/mute, idle recording countdown, comment staging/Take/hide feedback, queue boundary, direct scene-run/rename/delete, destination/event discovery/rename/delete, stale event rejection, reviewed remote-end receipt; no public output started")
    }
}
