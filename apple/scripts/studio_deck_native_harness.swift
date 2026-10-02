import Foundation
import StreamCore

@main @MainActor struct DeckNativeHarness {
    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw NSError(domain: "DeckNativeHarness", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("stream-deck-native-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        DesktopStorage.projectDirectory = directory
        let runtime = StudioRuntime()
        runtime.controllers.shutdown(); runtime.localControl.shutdown()
        runtime.dispatcher.bindChatCoordinator(runtime.chat)
        defer { runtime.controllers.shutdown(); runtime.localControl.shutdown(); runtime.chat.shutdown(); runtime.flush() }
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
        try require(!runtime.controller.outputSessionActive && !runtime.recorder.state.isActive, "Controller test started an output")
        print("PASS: actual dispatcher stable layer/group catalogue, preview/program policy, numeric gain/mute, comment staging/Take/hide feedback, queue boundary; no output started")
    }
}
