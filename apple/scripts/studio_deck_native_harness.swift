import AppKit
import Foundation
import Network
import StreamCore

@main @MainActor struct DeckNativeHarness {
    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw NSError(domain: "DeckNativeHarness", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func visualActions(_ runtime: StudioRuntime, directory: URL) async throws {
        let dispatcher = runtime.dispatcher
        let a = runtime.sceneStore.addSource(.init(name: "Screen A", payload: .screen(.init(target: .window))))
        let b = runtime.sceneStore.addSource(.init(name: "Screen B", payload: .screen(.init(target: .application))))
        let offline = runtime.sceneStore.addSource(.init(name: "Offline Camera", payload: .camera(.init(deviceID: "missing-visual-fixture-camera"))))
        let screen = LayerNode(name: "Screen target", sourceID: a.id, payload: a.payload, transform: .fullscreen)
        let pip = LayerNode.cameraPIP(corner: .bottomRight, scale: 0.28, sourceID: offline.id)
        let ticker = TickerOverlayConfiguration()
        let caption = LayerNode(name: "Ticker", payload: .text(.init(text: "Shared clock", ticker: ticker)), transform: .fullscreen)
        let reusedScreen = LayerNode(name: "Reused screen", sourceID: a.id, payload: a.payload, transform: .fullscreen)
        let scene = Scene(name: "Visual bindings", layers: [screen, reusedScreen, pip, caption])
        try require(dispatcher.execute(.insertScene(scene)).error == nil && dispatcher.execute(.take).error == nil, "Install visual scene")
        let prefix = "scene.\(scene.id.rawValue.uuidString).layer.\(screen.id.rawValue.uuidString)"
        let pipPrefix = "scene.\(scene.id.rawValue.uuidString).layer.\(pip.id.rawValue.uuidString)"
        let selector = prefix + ".source.select"
        let actions = dispatcher.catalogueActions()
        try require(actions.filter { $0.id.hasPrefix("scene.\(scene.id.rawValue.uuidString).") && $0.id.hasSuffix(".source.select") }.count == 3, "Source selection generated a Cartesian catalog")
        try require(actions.first { $0.id == selector }?.sourceKind == "screen", "Source selector did not advertise its typed input")
        try require(dispatcher.execute(.bindLayerSource(screen.id, to: nil, in: scene.id)).error != nil, "Argument-free source selection silently chose a device")
        let unavailableScreens: [SourceDefinition] = [
            .init(name: "Invalid window", payload: .screen(.init(target: .window, targetIdentifier: "not-a-window-id"))),
            .init(name: "Closed window", payload: .screen(.init(target: .window, targetIdentifier: String(UInt32.max)))),
            .init(name: "Closed app", payload: .screen(.init(target: .application, targetIdentifier: "stream.fixture.missing.\(UUID())"))),
            .init(name: "Disconnected display", payload: .screen(.init(target: .display, targetIdentifier: String(UInt32.max))))]
        for source in unavailableScreens {
            try require(dispatcher.controllerSourceSelectionError(source) != nil, "Unavailable pinned screen target claimed connected: \(source.name)")
        }
        try require(dispatcher.controllerSourceSelectionError(a) == nil && dispatcher.controllerSourceSelectionError(b) == nil, "Unpicked screen target was confused with a disappeared pinned resource")
        let original = runtime.previewProgram.programScene
        let credentials = MemoryCredentials()
        let pairings = StudioControlPairingStore(url: directory.appendingPathComponent("visual-clients.json"), credentials: credentials)
        pairings.pair(name: "Visual SDK boundary")
        guard let pairing = pairings.pairing else { throw NSError(domain: "VisualDeck", code: 1) }
        let defaults = UserDefaults(suiteName: "stream.visual.\(UUID())")!
        let server = StudioLocalControlServer(defaults: defaults, pairingStore: pairings, port: 0)
        server.bind(to: dispatcher); server.setEnabled(true)
        defer { server.shutdown() }
        for _ in 0..<500 { if server.listeningPort != nil { break }; try await Task.sleep(for: .milliseconds(10)) }
        guard let port = server.listeningPort else { throw NSError(domain: "VisualDeck", code: 2) }
        let client = WireClient(port: port)
        defer { client.connection.cancel() }
        let auth = try await client.request(.init(type: .authenticate, id: UUID(), clientID: pairing.client.id, token: pairing.token))
        guard let session = auth.sessionID else { throw NSError(domain: "VisualDeck", code: 3) }
        let changed = try await client.request(.init(type: .command, id: UUID(), sessionID: session, commandID: selector, text: b.id.rawValue.uuidString))
        try require(changed.result?.succeeded == true && runtime.previewProgram.stagedScene?.layers.first?.sourceID == b.id, "Typed source UUID did not traverse actual local server/shared dispatcher")
        try require(runtime.previewProgram.programScene == original && runtime.previewProgram.stagedScene?.layers.first?.transform == screen.transform, "Source selection changed Program or geometry")
        try require(runtime.previewProgram.stagedScene?.layers.first { $0.id == reusedScreen.id }?.sourceID == a.id && runtime.sceneStore.source(withID: a.id)?.payload == a.payload, "Selecting one layer mutated a shared source or its other consumer")
        let snapshot = changed.snapshot?.visuals?[prefix]
        try require(snapshot?.sourceID == b.id.rawValue && snapshot?.programSourceID == a.id.rawValue, "Wire feedback conflated Preview and Program source")
        let wrongKind = try await client.request(.init(type: .command, id: UUID(), sessionID: session, commandID: selector, text: offline.id.rawValue.uuidString))
        try require(wrongKind.result?.succeeded == false && runtime.previewProgram.stagedScene?.layers.first?.sourceID == b.id, "Camera source could replace a screen target")
        try require(dispatcher.execute(.bindLayerSource(pip.id, to: offline.id, in: scene.id)).error != nil, "Disconnected camera selection was not unavailable")
        try require(dispatcher.catalogueActions().first { $0.id == "source.\(offline.id.rawValue.uuidString).effects.bypass" }?.sourceAvailable == false, "Disconnected camera descriptor claimed available media")
        guard let pipHide = dispatcher.catalogueActions().first(where: { $0.id == pipPrefix + ".pip.off" })?.command else { throw NSError(domain: "VisualDeck", code: 4) }
        try require(dispatcher.execute(pipHide).error == nil && runtime.previewProgram.stagedScene?.layers.first { $0.id == pip.id }?.isVisible == false, "PIP off did not hide only its explicit staged layer")
        try require(runtime.previewProgram.programScene?.layers.first { $0.id == pip.id }?.isVisible == true, "PIP off leaked before Take")
        let bypass = prefix + ".effects.bypass"
        try require(dispatcher.controllerTargets().first { $0.id == bypass }?.execute(nil) == nil, "Layer effect bypass did not execute")
        try require(dispatcher.controllerVisualSnapshot()[prefix]?.bypassed == true && dispatcher.controllerVisualSnapshot()[prefix]?.programBypassed == false, "Effect feedback ignored pending Take")
        let globalBypass = "source.\(a.id.rawValue.uuidString).effects.bypass"
        try require(dispatcher.controllerTargets().first { $0.id == globalBypass }?.execute(nil) == nil && runtime.sceneStore.source(withID: a.id)?.effectDefaults?.isBypassed == true, "Shared source effect command did not reach the registry")
        DynamicOverlayStore.shared.perform(.start, id: ticker.runtimeID, at: 1)
        let replay = "scene.\(scene.id.rawValue.uuidString).layer.\(caption.id.rawValue.uuidString).animation.restart"
        try require(dispatcher.controllerTargets().first { $0.id == replay }?.execute(nil) == nil && DynamicOverlayStore.shared.state(for: ticker.runtimeID).phase == .running && DynamicOverlayStore.shared.state(for: ticker.runtimeID).elapsed(at: DynamicOverlayStore.hostSeconds) < 1, "Replay reset to idle instead of restarting the shared animation")
        let globalTicker = TickerOverlayConfiguration()
        try require(dispatcher.execute(.addOverlay(.text(.init(text: "Global ticker", ticker: globalTicker)))).error == nil, "Insert global animation")
        guard let global = dispatcher.controllerOverlays().first(where: { if case .text(let t) = $0.payload { return t.ticker?.runtimeID == globalTicker.runtimeID }; return false }) else { throw NSError(domain: "VisualDeck", code: 5) }
        try require(dispatcher.execute(.setOverlayDynamicTransport(global.id, .replay)).error == nil && DynamicOverlayStore.shared.state(for: globalTicker.runtimeID).phase == .running, "Global animation replay did not run its explicit runtime")
        runtime.sceneStore.renameSource(b.id, to: "Renamed Screen B")
        try require(dispatcher.catalogueActions().first { $0.id == "source.\(b.id.rawValue.uuidString).effects.bypass" }?.title.contains("Renamed Screen B") == true, "Source identity failed rename")
        runtime.sceneStore.removeSource(b.id)
        let removed = try await client.request(.init(type: .command, id: UUID(), sessionID: session, commandID: selector, text: b.id.rawValue.uuidString))
        try require(removed.result?.succeeded == false, "Deleted source UUID remained executable")
        try require(dispatcher.execute(.setLayerLocked(screen.id, locked: true, in: scene.id)).error == nil, "Lock visual target")
        try require(dispatcher.availabilityError(for: .bindLayerSource(screen.id, to: nil, in: scene.id)) != nil, "Locked target source picker remained enabled")
        try require(!runtime.controller.outputSessionActive, "Visual actions started capture or publishing")
        print("PASS: actual native IPC source UUID binding with Preview/Program receipts, type/deletion/lock/disconnected-device fences, bounded catalog, PIP visibility, per-layer/shared effects and running scene/global animation replay; no capture or output started")
    }
    static func maximumVisualReceipts(_ runtime: StudioRuntime) throws {
        let dispatcher = runtime.dispatcher
        let source = runtime.sceneStore.addSource(.init(name: "Maximum receipt source", payload: .text(.init(text: "Maximum fixture"))))
        func scene(_ name: String) -> Scene {
            Scene(name: name, layers: (0..<256).map { index in
                LayerNode(name: "Layer \(index)", sourceID: source.id, payload: source.payload, transform: .fullscreen)
            })
        }
        let taken = scene("Maximum Program"), staged = scene("Maximum Preview")
        try require(dispatcher.execute(.insertScene(taken)).error == nil && dispatcher.execute(.take).error == nil, "Install 256-layer Program")
        try require(dispatcher.execute(.insertScene(staged)).error == nil, "Install distinct 256-layer Preview")
        let visuals = dispatcher.controllerVisualSnapshot()
        let programPrefix = "scene.\(taken.id.rawValue.uuidString).layer."
        let previewPrefix = "scene.\(staged.id.rawValue.uuidString).layer."
        try require(visuals.filter { $0.key.hasPrefix(programPrefix) && $0.value.programVisible == true && $0.value.previewVisible == nil }.count == 256, "Maximum Program receipts were dropped or confused with Preview")
        try require(visuals.filter { $0.key.hasPrefix(previewPrefix) && $0.value.previewVisible == true && $0.value.programVisible == nil }.count == 256, "Maximum Preview receipts were dropped or confused with Program")
        let state = dispatcher.state
        let snapshot = StudioControlSnapshot(projectID: "maximum-visual-fixture", revision: 101,
            stream: "idle", recording: "idle", preview: "idle", stagedSceneID: staged.id.rawValue, programSceneID: taken.id.rawValue,
            pendingStagedEdits: true,
            layerVisibility: Dictionary(uniqueKeysWithValues: state.layerVisibility.map { ($0.key.rawValue.uuidString, $0.value) }),
            macroProgress: .init(), programLayerVisibility: dispatcher.controllerProgramVisibility(), visuals: visuals)
        let response = StudioControlResponse(type: "event", sessionID: UUID(), snapshot: snapshot)
        let original = try JSONEncoder().encode(response)
        try require(original.count > StudioControlFrameBuffer.maximumFrameBytes, "Maximum fixture did not exercise chunked response path")
        let frames = try StudioControlResponseFramer.frames(response, chunking: true)
        try require(frames.count > 1 && frames.allSatisfy { $0.count <= StudioControlFrameBuffer.maximumFrameBytes }, "Maximum visual response exceeded frame size")
        var assembled = Data(), transfer: UUID?
        for (index, frame) in frames.enumerated() {
            let wrapper = try JSONDecoder().decode(StudioControlResponse.self, from: frame)
            guard let chunk = wrapper.responseChunk else { throw NSError(domain: "MaximumVisualReceipts", code: 1) }
            if index == 0 { transfer = chunk.transferID }
            try require(chunk.index == index && chunk.count == frames.count && chunk.transferID == transfer && chunk.snapshotRevision == 101 && chunk.totalBytes == original.count && wrapper.sessionID == response.sessionID, "Chunk changed receipt revision, session or transfer identity")
            assembled.append(chunk.body)
        }
        let complete = try JSONDecoder().decode(StudioControlResponse.self, from: assembled)
        try require(complete.snapshot == snapshot, "Maximum response reassembly lost or substituted visual receipts")
        do {
            _ = try StudioControlResponseFramer.frames(response, chunking: false)
            throw NSError(domain: "MaximumVisualReceipts", code: 2, userInfo: [NSLocalizedDescriptionKey: "Legacy controller silently received partial response"])
        } catch let error as StudioControlProtocolError {
            try require(error.code == "responseChunksRequired", "Legacy oversized response did not report explicit upgrade requirement")
        }
        print("PASS: actual distinct 256-layer Program + 256-layer Preview receipts survive \(original.count)-byte response in \(frames.count) bounded chunks (largest \(frames.map(\.count).max() ?? 0) bytes), exact full-state reassembly and explicit legacy-client rejection")
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
        try require(!runtime.controller.resilience.isLocked && !runtime.controller.resilience.requiresManualRestart,
                    "Owned native controller fixture must construct its explicit simulated unlocked session")
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
        try await visualActions(runtime, directory: directory)
        try maximumVisualReceipts(runtime)
        if ProcessInfo.processInfo.environment["STREAM_DECK_VALIDATE_TRANSPORT"] == "1" { try await DeckTransportFixtures.run(directory: directory) }
        print("PASS: actual dispatcher stable layer/group/global-overlay catalogue, overlay rename/delete/toggle, preview/program policy, numeric gain/mute, idle recording countdown, comment staging/Take/hide feedback, queue boundary, direct scene-run/rename/delete, destination/event discovery/rename/delete, stale event rejection, reviewed remote-end receipt; no public output started")
    }
}
