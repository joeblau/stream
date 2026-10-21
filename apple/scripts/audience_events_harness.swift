import AVFoundation
import CoreImage
import CoreMedia
import Foundation
import StreamCore

private func requireAudience(_ value: @autoclosure () -> Bool, _ reason: String) {
    precondition(value(), reason)
}

@main @MainActor private enum AudienceEventsHarness {
    static func event(_ id: String, type: Int = 7, body: String = "Thank you 👩🏽‍🚀 世界 {host}") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["action": "event", "payload": [
            "connectionIdentifier": "owned-provider-fixture", "eventTypeId": type,
            "eventPayload": ["liveChatMessageId": id, "text": body,
                "author": ["displayName": "Fixture Viewer", "avatar": "https://unsupported.invalid/never-fetch"]]]])
    }
    static func render(_ scene: Scene, renderer: SceneRenderer) -> CompositedFrame {
        renderer.render(scene: scene, overlayContext: .empty, canvasSize: .init(width: 640, height: 360),
            frames: .init(camera: { _ in nil }, screen: { _ in nil }), sourcePayloads: [:], scenes: [:],
            presentationTime: CMTime(value: 960_000, timescale: 48_000),
            frameDuration: CMTime(value: 1, timescale: 24), sequence: 1)!
    }
    static func pixels(_ frame: CompositedFrame) -> Data {
        let buffer = CMSampleBufferGetImageBuffer(frame.sampleBuffer)!
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        return Data(bytes: CVPixelBufferGetBaseAddress(buffer)!, count: CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer))
    }
    static func text(_ scene: Scene, _ slot: LayerID) -> TextSourcePayload {
        guard let layer = scene.layers.first(where: { $0.id == slot }), case .text(let text) = layer.payload else { fatalError("Missing actual text slot") }
        return text
    }
    static func main() async throws {
        let folder: URL
        if let index = CommandLine.arguments.firstIndex(of: "--artifacts-dir"), index + 1 < CommandLine.arguments.count {
            folder = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
        } else { folder = FileManager.default.temporaryDirectory.appendingPathComponent("stream-audience-events-\(UUID().uuidString)") }
        let workspace = StudioWorkspace(root: folder.appendingPathComponent("Workspace"))
        let runtime = workspace.runtime, chat = runtime.chat, preview = runtime.previewProgram
        preview.setDirectLiveEditing(false)
        defer { chat.shutdown(); runtime.interviews.shutdown(); runtime.controller.retireGuestMedia() }
        var scene = preview.stagedScene!
        scene.layers = []; scene.background = .solid(colorHex: "#000000")
        preview.applyStagedEdit(scene); _ = runtime.dispatcher.execute(.take)
        RecordingChatPaintDemand.shared.acquire()
        defer { RecordingChatPaintDemand.shared.release() }
        let renderer = SceneRenderer(tokenProvider: { ["host": "PRIVATE TOKEN MUST NOT EXPAND"] })
        let original = preview.programScene!, blank = pixels(render(original, renderer: renderer))
        requireAudience(!chat.alertPromotionEnabled, "Alert promotion must default off")
        chat.receive(try event("super"))
        let message = chat.queue.messages.last!
        requireAudience(message.audienceEvent == .superChat, "Actual provider decoder lost supported type")
        requireAudience(preview.stagedScene == original && preview.programScene == original, "Event arrival edited a composition")
        requireAudience(!chat.stageAudienceAlert(message.id), "Alert promoted without explicit opt-in")
        chat.alertPromotionEnabled = true
        requireAudience(!chat.stageAudienceAlert(message.id), "Alert promoted without a separate explicit slot")
        chat.createSlot(); let comment = chat.selectedSlot!
        chat.createAlertSlot(); let alert = chat.selectedAlertSlot!
        requireAudience(comment != alert && chat.availableSlots.map(\.id) == [comment]
            && chat.availableAlertSlots.map(\.id) == [alert], "Comment and alert destinations are not separate")
        chat.setAudienceStyle(.teal, for: .superChat)
        chat.includeAvatar = true // Promotion must never use the avatar loader.
        requireAudience(chat.stageAudienceAlert(message.id), "Explicit supported event promotion failed")
        let staged = preview.stagedScene!, content = text(staged, alert)
        requireAudience(content.text == "Super Chat · Fixture Viewer · YouTube\n" + message.text,
            "Alert invented provider values or changed public Unicode text")
        requireAudience(content.colorHex == StudioAudienceEventStyle.teal.foreground
            && content.backgroundColorHex == StudioAudienceEventStyle.teal.background, "Selected event palette did not stage")
        requireAudience(content.commentAvatarKey == nil && content.timer == nil && content.ticker == nil && content.guestBinding == nil,
            "Alert retained unsupported dynamic/media content")
        requireAudience(chat.queue.featuredID == nil && !staged.layers.first(where: { $0.id == comment })!.isVisible,
            "Alert promotion replaced the curated comment")
        requireAudience(preview.programScene == original && pixels(render(preview.programScene!, renderer: renderer)) == blank,
            "Alert promotion changed actual Program pixels before Take")
        let beforePalette = preview.stagedScene
        chat.setAudienceStyle(.violet, for: .superChat)
        requireAudience(preview.stagedScene == beforePalette, "Changing a palette republished a staged event")
        _ = runtime.dispatcher.execute(.take)
        let visible = render(preview.programScene!, renderer: renderer), shown = pixels(visible)
        requireAudience(shown != blank, "Take did not publish actual native alert pixels")
        let paints = RecordingChatPaint.read(visible.sampleBuffer)
        requireAudience(paints.count == 1 && paints[0].messageID == message.id
            && paints[0].fingerprint == RecordingChatPaint.fingerprint(content.text), "Native alert paint expanded private tokens or lost recording identity")
        let output = folder.appendingPathComponent("TakenAlert.png")
        try CIContext().writePNGRepresentation(of: CIImage(cvPixelBuffer: CMSampleBufferGetImageBuffer(visible.sampleBuffer)!),
            to: output, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        preview.setDirectLiveEditing(true)
        let direct = preview.stagedScene
        requireAudience(!chat.stageAudienceAlert(message.id), "Direct Live Editing bypassed alert Take policy")
        chat.hideAudienceAlert()
        requireAudience(preview.stagedScene == direct && pixels(render(preview.programScene!, renderer: renderer)) == shown,
            "Direct-live refusal edited an alert")
        preview.setDirectLiveEditing(false)
        chat.alertPromotionEnabled = false
        requireAudience(preview.stagedScene == direct, "Disabling promotion unexpectedly changed output")
        chat.hideAudienceAlert()
        requireAudience(pixels(render(preview.programScene!, renderer: renderer)) == shown, "Hide changed Program before Take")
        _ = runtime.dispatcher.execute(.take)
        requireAudience(pixels(render(preview.programScene!, renderer: renderer)) == blank, "Hide/Take retained alert pixels")
        chat.alertPromotionEnabled = true
        let long = String(repeating: "長いイベント 👩🏽‍🚀 العربية café e\u{301} {host}\n", count: 120)
        requireAudience(long.utf8.count <= 16_384, "Oversized provider fixture")
        chat.receive(try event("long", type: 8, body: long))
        let longMessage = chat.queue.messages.last!
        requireAudience(chat.stageAudienceAlert(longMessage.id), "Long sticker display text could not stage")
        let layout = chat.selectedAlertPresentation!
        requireAudience(layout.pages.count > 1 && !layout.needsLargerBox && layout.fontSize >= 24, "Long alert silently shrank or clipped")
        let strings = long as NSString
        requireAudience(layout.pages.map { strings.substring(with: $0.bodyRange) }.joined() == long, "Alert pages lost composed Unicode text")
        let pageProgram = preview.programScene
        chat.advanceAudienceAlertPage(1)
        requireAudience(chat.selectedAlertPage == 1 && preview.programScene == pageProgram, "Alert page bypassed Take")
        chat.receive(.removed(ids: [longMessage.id]))
        requireAudience(!chat.stageAudienceAlert(longMessage.id) && preview.programScene == pageProgram,
            "A removed provider event was replayed or altered Program")
        chat.receive(try event("plain", type: 5))
        requireAudience(!chat.stageAudienceAlert(chat.queue.messages.last!.id), "Ordinary text acquired an inferred alert type")
        chat.receive(try event("unknown", type: 999))
        requireAudience(chat.queue.messages.last?.audienceEvent == .text, "Unknown event was accepted")
        let reloaded = StudioChatCoordinator(dispatcher: runtime.dispatcher, previewProgram: preview)
        requireAudience(!reloaded.alertPromotionEnabled && reloaded.audienceStyle(for: .superChat) == .violet,
            "Palette restart lost choices or rearmed manual promotion")
        requireAudience(reloaded.availableSlots.map(\.id) == [comment] && reloaded.availableAlertSlots.map(\.id) == [alert],
            "Separate alert slots did not survive bounded project metadata reload")
        let legacy = try JSONDecoder().decode(StudioChatCoordinator.SlotPreferences.self,
            from: Data("{\"version\":1,\"slots\":[]}".utf8))
        requireAudience(legacy.alertSlots == nil, "Legacy comment-only preferences did not retain their default")
        let capacityProgram = preview.programScene
        for _ in 0..<20 { reloaded.createAlertSlot() }
        requireAudience(reloaded.availableSlots.count + reloaded.availableAlertSlots.count == 16
            && reloaded.availableSlots.count == 1, "Comment and alert slots exceeded their shared sixteen-slot budget")
        requireAudience(reloaded.alertSlotCreationError != nil && reloaded.audienceStagingError == nil,
            "Capacity refusal hid its reason or disabled existing alert operations")
        requireAudience(preview.programScene == capacityProgram, "Capacity preparation bypassed Take")
        let preferences = DesktopStorage.projectDirectory.appendingPathComponent("audience-styles.json")
        let saved = try Data(contentsOf: preferences)
        try Data(repeating: 32, count: 4_097).write(to: preferences, options: .atomic)
        let oversized = StudioChatCoordinator(dispatcher: runtime.dispatcher, previewProgram: preview)
        requireAudience(oversized.audienceStyles.isEmpty && !oversized.alertPromotionEnabled, "Oversized local styles were accepted")
        requireAudience((try? Data(contentsOf: preferences).count) == 4_097, "Refused preferences were rewritten")
        try saved.write(to: preferences, options: .atomic)
        oversized.shutdown()
        reloaded.shutdown()
        let retired = preview.stagedScene, persisted = try Data(contentsOf: preferences)
        reloaded.alertPromotionEnabled = true
        reloaded.setAudienceStyle(.teal, for: .superChat)
        reloaded.createAlertSlot(); reloaded.hideAudienceAlert(); reloaded.advanceAudienceAlertPage(1)
        requireAudience(!reloaded.stageAudienceAlert(message.id) && preview.stagedScene == retired
            && (try? Data(contentsOf: preferences)) == persisted, "A retained old chat session mutated composition or style metadata")
        try await StaticEmoteAudienceFixture.run(folder: folder)
        print("PASS: actual public event decoder/coordinator/dispatcher/native renderer; off-by-default manual promotion, separate bounded slots and per-event palettes, arrival/setting/direct-live/removed-event refusal, exact Unicode/literal braces, native pixels only after Take, staged Hide/pages, style reload without rearming; no credentials/device/media fetch. Artifact: \(output.path)")
    }
}
