import AVFoundation
import CoreImage
import Foundation
import ImageIO
import StreamCore

private func emoteJSON(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }
private final class EmoteFixtureSocket: StudioChatSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Data] = []
    private var waiter: CheckedContinuation<Data, Error>?
    private var closed = false
    func push(_ value: Data) {
        let pending = lock.withLock { () -> CheckedContinuation<Data, Error>? in
            guard !closed else { return nil }
            if let waiter { self.waiter = nil; return waiter }; values.append(value); return nil
        }; pending?.resume(returning: value)
    }
    func receive() async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { pending in
                let value = lock.withLock { () -> Result<Data, Error>? in
                    if closed { return .failure(CancellationError()) }
                    if !values.isEmpty { return .success(values.removeFirst()) }; waiter = pending; return nil
                }; if let value { pending.resume(with: value) }
            }
        } onCancel: { self.cancel() }
    }
    func cancel() {
        let pending = lock.withLock { closed = true; let value = waiter; waiter = nil; return value }
        pending?.resume(throwing: CancellationError())
    }
}
private final class EmoteFixtureSockets: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [EmoteFixtureSocket]
    init(_ values: [EmoteFixtureSocket]) { self.values = values }
    func make(_ url: URL) -> any StudioChatSocket { lock.withLock { precondition(!values.isEmpty); return values.removeFirst() } }
}
private final class EmoteFixtureClock: @unchecked Sendable {
    private let lock = NSLock(); private var value = Date()
    func now() -> Date { lock.withLock { value } }
    func advance() { lock.withLock { value = value.addingTimeInterval(2) } }
}
private actor EmoteFixtureLoader {
    private var pending: [CheckedContinuation<CGImage, Error>] = []
    private(set) var urls: [URL] = []
    func load(_ url: URL) async throws -> CGImage {
        precondition(StudioStaticEmoteLoader.accepts(url)); urls.append(url)
        // Deliberately noncooperative so late images exercise shipping fences.
        return try await withCheckedThrowingContinuation { pending.append($0) }
    }
    var count: Int { pending.count }
    func finish(_ image: CGImage) { precondition(!pending.isEmpty); pending.removeFirst().resume(returning: image) }
}
@MainActor private final class EmoteFixtureHTTP {
    var subscriptions = 0, metadataReads = 0
    func send(_ provider: ManagedProvider, _ request: URLRequest) async throws -> Data {
        precondition(provider == .twitch)
        if request.url!.path == "/helix/eventsub/subscriptions" {
            subscriptions += 1
            var payload = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            payload["status"] = "enabled"; return emoteJSON(["data": [payload]])
        }
        precondition(request.url!.path == "/helix/chat/emotes/global" && request.httpMethod == "GET" && request.httpBody == nil)
        metadataReads += 1
        return emoteJSON(["template": "https://static-cdn.jtvnw.net/emoticons/v2/{{id}}/{{format}}/{{theme_mode}}/{{scale}}",
            "data": (["25"] + (1...8).map { "owned-\($0)" }).map {
                ["id": $0, "format": ["static"], "theme_mode": ["light"], "scale": ["3.0"]] as [String: Any]
            }])
    }
}
@MainActor private final class EmoteFixtureOwner { weak var chat: StudioChatCoordinator? }

@MainActor enum StaticEmoteAudienceFixture {
    private static func wait(_ predicate: @escaping @MainActor () async -> Bool) async {
        for _ in 0..<400 { if await predicate() { return }; try? await Task.sleep(for: .milliseconds(5)) }
        preconditionFailure("Static emote fixture deadline exceeded")
    }
    private static func message(_ id: String, emote: String = "25", removed: Bool = false) -> Data {
        let body = "👩🏽‍🚀 世界 Kappa {host}"
        return emoteJSON(["metadata": ["message_type": "notification"], "payload": [
            "subscription": ["type": removed ? "channel.chat.message_delete" : "channel.chat.message", "version": "1",
                "condition": ["broadcaster_user_id": "owner", "user_id": "owner"]],
            "event": ["broadcaster_user_id": "owner", "chatter_user_id": "viewer", "chatter_user_name": "Viewer",
                "message_id": id, "message": ["text": body, "fragments": [
                    ["type": "text", "text": "👩🏽‍🚀 世界 "],
                    ["type": "emote", "text": "Kappa", "emote": ["id": emote, "emote_set_id": "0", "format": ["static"]]],
                    ["type": "text", "text": " {host}"]]]]]])
    }
    private static func welcome() -> Data {
        emoteJSON(["metadata": ["message_type": "session_welcome"], "payload": ["session": ["id": "owned-session", "keepalive_timeout_seconds": 600]]])
    }
    private static func imageData(width: Int = 32, height: Int = 16, format: CFString = "public.png" as CFString) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Actual non-square alpha evidence: a half-opaque green corner and
        // an entirely transparent opposite corner, each with interior pixels.
        context.clear(CGRect(x: 0, y: 0, width: width / 4, height: height / 2))
        context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 0.5))
        context.fill(CGRect(x: 0, y: 0, width: width / 4, height: height / 2))
        context.clear(CGRect(x: width * 3 / 4, y: height / 2, width: width / 4, height: height / 2))
        let bytes = NSMutableData(), destination = CGImageDestinationCreateWithData(bytes, format, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil); precondition(CGImageDestinationFinalize(destination))
        return bytes as Data
    }
    private static func image() -> CGImage { try! StudioStaticEmoteLoader.decode(imageData()) }
    private static func render(_ scene: Scene, renderer: SceneRenderer, index: Int64 = 0) -> CompositedFrame {
        renderer.render(scene: scene, overlayContext: .empty, canvasSize: .init(width: 640, height: 360),
            frames: .init(camera: { _ in nil }, screen: { _ in nil }), sourcePayloads: [:], scenes: [:],
            presentationTime: CMTime(value: 960_000 + index * 2_000, timescale: 48_000), frameDuration: CMTime(value: 1, timescale: 24), sequence: index + 1)!
    }
    private static func pixels(_ frame: CompositedFrame) -> Data {
        let buffer = CMSampleBufferGetImageBuffer(frame.sampleBuffer)!
        CVPixelBufferLockBaseAddress(buffer, .readOnly); defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        return Data(bytes: CVPixelBufferGetBaseAddress(buffer)!, count: CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer))
    }
    static func run(folder: URL) async throws {
        let workspace = StudioWorkspace(root: folder.appendingPathComponent("StaticEmoteWorkspace")), owner = EmoteFixtureOwner()
        let runtime = workspace.runtime, preview = runtime.previewProgram
        let http = EmoteFixtureHTTP(), first = EmoteFixtureSocket(), second = EmoteFixtureSocket()
        let sockets = EmoteFixtureSockets([first, second]), clock = EmoteFixtureClock(), loader = EmoteFixtureLoader()
        let manager = StudioDirectChatManager(request: http.send, identity: { _ in .init(channelID: "owner", scopes: ["user:read:chat"]) },
            socketFactory: sockets.make, now: clock.now, emit: { owner.chat?.receive($0) })
        let chat = StudioChatCoordinator(dispatcher: runtime.dispatcher, previewProgram: preview,
            staticEmoteResolve: { [weak manager] in guard let manager else { throw CancellationError() }; return try await manager.staticEmoteURL(for: $0) },
            staticEmoteLoad: { try await loader.load($0) })
        owner.chat = chat
        defer { chat.shutdown(); manager.shutdown(); runtime.chat.shutdown(); runtime.interviews.shutdown(); runtime.controller.retireGuestMedia() }
        preview.setDirectLiveEditing(false)
        var scene = preview.stagedScene!; scene.layers = []; scene.background = .solid(colorHex: "#000000")
        preview.applyStagedEdit(scene); _ = runtime.dispatcher.execute(.take)
        chat.createSlot(); let comment = chat.selectedSlot!; chat.createAlertSlot(); let alert = chat.selectedAlertSlot!
        let renderer = SceneRenderer(tokenProvider: { ["host": "PRIVATE TOKEN MUST NOT EXPAND"] })
        let blank = pixels(render(preview.programScene!, renderer: renderer))
        manager.connect(.twitch); await wait { !manager.snapshot(.twitch).target.isEmpty }
        first.push(welcome()); await wait { manager.snapshot(.twitch).isConnected }
        first.push(message("first")); await wait { chat.queue.messages.count == 1 }
        let value = chat.queue.messages[0]
        precondition(value.staticEmote == .init(id: "25", setID: "0", label: "Kappa") && !chat.staticEmotesEnabled)
        precondition(!chat.stageStaticEmote(value.id, alert: false) && http.metadataReads == 0)
        chat.staticEmotesEnabled = true; chat.alertPromotionEnabled = true
        // A Hide on an already-hidden slot is still new operator intent. The
        // layer value may remain identical, so snapshot equality alone cannot
        // authorize an earlier artwork download to make that slot visible.
        for isAlert in [false, true] {
            precondition(chat.stageStaticEmote(value.id, alert: isAlert)); await wait { await loader.count == 1 }
            if isAlert { chat.hideAudienceAlert() } else { chat.hide() }
            let hidden = preview.stagedScene
            await loader.finish(image()); await wait { chat.staticEmoteLoads == 0 }
            precondition(preview.stagedScene == hidden, "Late artwork overrode an explicit Hide on an already-hidden slot")
            precondition(pixels(render(preview.programScene!, renderer: renderer)) == blank)
            clock.advance()
        }
        let beforeLoad = preview.stagedScene
        precondition(chat.stageStaticEmote(value.id, alert: false)); await wait { await loader.count == 1 }
        precondition(preview.stagedScene == beforeLoad && pixels(render(preview.programScene!, renderer: renderer)) == blank)
        let artwork = image(); await loader.finish(artwork); await wait { chat.staticEmoteLoads == 0 }
        let layer = preview.stagedScene!.layers.first { $0.id == comment }!
        guard case .text(let payload) = layer.payload else { preconditionFailure() }
        precondition(payload.commentAvatarKey?.hasPrefix("public-static-emote-") == true && payload.text.hasSuffix(value.text))
        precondition(pixels(render(preview.programScene!, renderer: renderer)) == blank)
        _ = runtime.dispatcher.execute(.take)
        let frame = render(preview.programScene!, renderer: renderer), shown = pixels(frame)
        precondition(shown != blank && http.metadataReads == 3 && http.subscriptions == 4)
        // Use accepted native movie frames and the production feed/archive,
        // so emote classification cannot silently discard the literal caption.
        let binding = chat.recentRecordingBindings.last(where: { $0.message.id == value.id })!
        let timeline = RecordingTimeline(), feed = RecordingChatFeed()
        var preferences = RecordingChatPreferences(); preferences.enabled = true
        let movie = folder.appendingPathComponent("TakenStaticEmote.mp4")
        let archive = RecordingChatArchive(programURL: movie, sessionID: UUID().uuidString, segmentIndex: 1,
            context: .init(), timeline: timeline, preferences: preferences)
        feed.bind(binding); feed.install(archive)
        var configuration = ProgramRecordingSession.Configuration()
        configuration.frameRate = 24; configuration.requiresAudio = false
        configuration.onVideoAccepted = { frame in feed.frame(frame, into: archive) }
        let writer = ProgramRecordingSession(outputURL: movie, configuration: configuration, timeline: timeline,
            spaceProbe: { _ in 8_000_000_000 })
        writer.appendVideo(frame.sampleBuffer)
        await wait { timeline.snapshot().origin.isNumeric }
        feed.receive(binding.message, at: CMTime(value: 960_000, timescale: 48_000))
        for index in 1...2 { writer.appendVideo(render(preview.programScene!, renderer: renderer, index: Int64(index)).sampleBuffer) }
        let result = await withCheckedContinuation { continuation in writer.finish { continuation.resume(returning: $0) } }
        feed.install(nil)
        await withCheckedContinuation { continuation in archive.finish(completed: result.completed) { continuation.resume() } }
        precondition(result.completed && result.progress.videoSamples > 0)
        var records: [RecordingChatRecord] = []
        let inspection = try RecordingChatReader.scan(archive.url, record: { records.append($0) })
        precondition(!inspection.recovered && records.contains { $0.type == "message" && $0.message?.text == value.text && $0.message?.kind == "Emotes" },
                     "Emote classification dropped the literal public message from the recording archive")
        precondition(records.contains { $0.type == "show" && $0.message?.text == value.text && $0.messageID == value.id },
                     "Taken emote pixels lost their literal recorded-chat binding")
        let archiveText = String(decoding: try Data(contentsOf: archive.url), as: UTF8.self)
        precondition(!archiveText.contains("static-cdn") && !archiveText.contains("staticEmote") && !archiveText.contains("PRIVATE TOKEN"))
        let buffer = CMSampleBufferGetImageBuffer(frame.sampleBuffer)!
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self), stride = CVPixelBufferGetBytesPerRow(buffer)
        var points: [(Int, Int)] = []
        for y in 0..<CVPixelBufferGetHeight(buffer) { for x in 0..<CVPixelBufferGetWidth(buffer) {
            let p = base.advanced(by: y * stride + x * 4)
            if p[2] > 200 && p[1] < 40 && p[0] < 40 { points.append((x, y)) }
        }}
        CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        precondition(points.count > 100)
        let w = points.map(\.0).max()! - points.map(\.0).min()! + 1, h = points.map(\.1).max()! - points.map(\.1).min()! + 1
        precondition(Double(w) / Double(h) > 1.7, "Static emote was stretched/cropped as an author portrait")
        // An all-clear image retains the exact artwork inset, text layout and
        // card background. Its rendered pixels give the actual alpha backdrop.
        let clearContext = CGContext(data: nil, width: artwork.width, height: artwork.height, bitsPerComponent: 8,
            bytesPerRow: artwork.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let clearKey = CommentAvatarStore.shared.publishStaticEmote(clearContext.makeImage()!, identity: "owned-alpha-backdrop")!
        var clearScene = preview.programScene!
        let commentIndex = clearScene.layers.firstIndex { $0.id == comment }!
        guard case .text(var clearText) = clearScene.layers[commentIndex].payload else { preconditionFailure() }
        clearText.commentAvatarKey = clearKey; clearScene.layers[commentIndex].payload = .text(clearText)
        let clearPixels = pixels(render(clearScene, renderer: renderer))
        let left = points.map(\.0).min()!, right = points.map(\.0).max()!
        let top = points.map(\.1).min()!, bottom = points.map(\.1).max()!
        var transparentPixels = 0, partialGreenPixels = 0
        shown.withUnsafeBytes { actualBytes in clearPixels.withUnsafeBytes { clearBytes in
            let actual = actualBytes.bindMemory(to: UInt8.self), reference = clearBytes.bindMemory(to: UInt8.self)
            for y in top...bottom { for x in left...right {
                let offset = y * stride + x * 4
                if (0..<4).allSatisfy({ actual[offset + $0] == reference[offset + $0] }) { transparentPixels += 1 }
                if Int(actual[offset + 1]) > Int(reference[offset + 1]) + 30 && actual[offset + 1] < 230,
                   Int(actual[offset]) <= Int(reference[offset]) + 2, Int(actual[offset + 2]) <= Int(reference[offset + 2]) + 2 {
                    partialGreenPixels += 1
                }
            }}
        }}
        precondition(transparentPixels >= 8 && partialGreenPixels >= 4,
                     "Static emote flattened transparent/partial-alpha pixels against the real card backdrop")
        print("Native static-emote alpha: \(transparentPixels) exact-backdrop pixels, \(partialGreenPixels) partially composited green pixels inside \(w)×\(h) non-square tile bounds")

        try CIContext().writePNGRepresentation(of: CIImage(cvPixelBuffer: buffer), to: folder.appendingPathComponent("TakenStaticEmote.png"), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        let encodedScene = String(decoding: try JSONEncoder().encode(preview.programScene!), as: UTF8.self)
        precondition(!encodedScene.contains("static-cdn") && !encodedScene.contains("emote_set_id"))
        let entry = StudioChatCoordinator.guestPublicEntry(value)!
        let publicWire = GuestPublicChatEnvelope.message(feed: UUID(), reset: 0, sequence: 1, dropped: 0, entry: entry).wire(negotiation: UUID())!
        precondition(!publicWire.contains("staticEmote") && !publicWire.contains("static-cdn") && entry.text == value.text)
        // Repeating a text-only Show also supersedes a scheduled cached tile,
        // even when the caption/visibility are already exactly as requested.
        chat.show(value.id); let plainComment = preview.stagedScene
        precondition(chat.stageStaticEmote(value.id, alert: false))
        chat.show(value.id)
        for _ in 0..<3 { await Task.yield() }
        precondition(chat.staticEmoteLoads == 0 && preview.stagedScene == plainComment)
        chat.hide(); precondition(chat.stageStaticEmote(value.id, alert: true)); await wait { chat.staticEmoteLoads == 0 }
        guard case .text(let alertText) = preview.stagedScene!.layers.first(where: { $0.id == alert })!.payload else { preconditionFailure() }
        precondition(alertText.commentAvatarKey == payload.commentAvatarKey && pixels(render(preview.programScene!, renderer: renderer)) == shown)
        precondition(chat.stageAudienceAlert(value.id)) // Text-only remains explicit and clears the optional tile.
        guard case .text(let plainAlert) = preview.stagedScene!.layers.first(where: { $0.id == alert })!.payload else { preconditionFailure() }
        precondition(plainAlert.commentAvatarKey == nil)
        let plainAlertScene = preview.stagedScene
        precondition(chat.stageStaticEmote(value.id, alert: true))
        precondition(chat.stageAudienceAlert(value.id))
        for _ in 0..<3 { await Task.yield() }
        precondition(chat.staticEmoteLoads == 0 && preview.stagedScene == plainAlertScene)
        for (index, reason) in [(1, "direct-live"), (2, "tombstone"), (3, "source-close")] {
            clock.advance(); first.push(message(reason, emote: "owned-\(index)")); await wait { chat.queue.messages.last?.staticEmote?.id == "owned-\(index)" }
            let item = chat.queue.messages.last!; precondition(chat.stageStaticEmote(item.id, alert: false)); await wait { await loader.count == 1 }
            if index == 1 { preview.setDirectLiveEditing(true) }
            else if index == 2 { first.push(message(reason, removed: true)); await wait { chat.queue.message(item.id) == nil } }
            else { manager.stop(.twitch) }
            let staged = preview.stagedScene, program = preview.programScene
            await loader.finish(artwork); await wait { chat.staticEmoteLoads == 0 }
            precondition(preview.stagedScene == staged && preview.programScene == program, "Late artwork crossed \(reason) authority")
            preview.setDirectLiveEditing(false)
        }
        manager.connect(.twitch); await wait { !manager.snapshot(.twitch).target.isEmpty }
        second.push(welcome()); await wait { manager.snapshot(.twitch).isConnected }
        precondition(chat.staticEmoteStagingError(for: value.id, alert: false) != nil, "Old provider message rearmed after reader rejoin")
        second.push(message("fresh")); await wait { chat.queue.messages.last?.id == StudioDirectChatDecoder.identity(.twitch, "owner", "fresh") }
        let fresh = chat.queue.messages.last!; precondition(chat.stageStaticEmote(fresh.id, alert: false)); await wait { chat.staticEmoteLoads == 0 }
        clock.advance(); second.push(message("retiring", emote: "owned-4")); await wait { chat.queue.messages.last?.staticEmote?.id == "owned-4" }
        let retiring = chat.queue.messages.last!
        precondition(chat.stageStaticEmote(retiring.id, alert: false)); await wait { await loader.count == 1 }
        let beforeClose = preview.programScene, stagedBeforeClose = preview.stagedScene
        chat.shutdown(); await loader.finish(artwork)
        try? await Task.sleep(for: .milliseconds(20))
        precondition(preview.stagedScene == stagedBeforeClose && chat.staticEmoteLoads == 0)
        chat.shutdown(); precondition(!chat.staticEmotesEnabled && preview.programScene == beforeClose)
        precondition(!chat.stageStaticEmote(fresh.id, alert: false))
        let localStore = CommentAvatarStore(); var firstKey: String?
        for index in 0..<32 { let key = localStore.publishStaticEmote(artwork, identity: "owned-\(index)"); precondition(key != nil); if index == 0 { firstKey = key } }
        precondition(!localStore.canPublishStaticEmote("over-capacity") && localStore.canPublishStaticEmote("owned-0"))
        precondition(localStore.publishStaticEmote(artwork, identity: "over-capacity") == nil && localStore.image(firstKey) != nil)
        precondition(localStore.publishStaticEmote(artwork, identity: "owned-0") == firstKey)
        for raw in ["https://localhost/emoticons/v2/25/static/light/3.0", "https://static-cdn.jtvnw.net/emoticons/v2/25/animated/light/3.0", "https://static-cdn.jtvnw.net/emoticons/v2/25/static/light/3.0?token=never", "https://static-cdn.jtvnw.net/emoticons/v2/%32%35/static/light/3.0"] {
            precondition(!StudioStaticEmoteLoader.accepts(URL(string: raw)!))
        }
        for invalid in [Data(repeating: 0, count: 262_145), imageData(width: 513, height: 1), imageData(format: "public.jpeg" as CFString), imageData(format: "com.compuserve.gif" as CFString)] {
            do { _ = try StudioStaticEmoteLoader.decode(invalid); preconditionFailure() } catch {}
        }
        if ProcessInfo.processInfo.environment["STREAM_STATIC_EMOTE_PUBLIC_CDN_PROBE"] == "1" {
            // The documentation's public sample is separate from authorized
            // live provider acceptance; no app/user grant is fabricated here.
            let publicImage = try await StudioStaticEmoteLoader.load(URL(string: "https://static-cdn.jtvnw.net/emoticons/v2/62836/static/light/3.0")!)
            precondition(publicImage.width <= 112 && publicImage.height <= 112)
            let destination = CGImageDestinationCreateWithURL(folder.appendingPathComponent("PublicCDNStaticEmote.png") as CFURL, "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, publicImage, nil); precondition(CGImageDestinationFinalize(destination))
            print("PASS: documented public Twitch CDN sample through shipping strict URL/no-redirect/ephemeral bounded PNG loader; not a live authorized chat-feed acceptance")
        }
        print("PASS: actual Twitch decoder/shared reader metadata request→manual bounded static PNG tile→shipping staged text/dispatcher/Program pixels+Take; complete Unicode/literal text+actual native movie/archive message/show readback, no-op Hide/repeated plain-text intent fences, aspect/alpha preserved, no private/public-feed media, defaultoff/DLE/tombstone/sourceclose/rejoin/retired fences and non-evicting32identity capacity")
    }
}
