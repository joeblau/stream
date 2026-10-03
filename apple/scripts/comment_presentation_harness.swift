import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ImageIO
import StreamCore
import UniformTypeIdentifiers

private func requireComment(_ value: @autoclosure () throws -> Bool, _ reason: String) throws {
    if try !value() { throw RecordingChatError.invalid(reason) }
}

@main @MainActor struct CommentPresentationHarness {
    static func main() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("stream-comments-\(UUID().uuidString)")
        let workspace = StudioWorkspace(root: folder.appendingPathComponent("Workspace"))
        let runtime = workspace.runtime
        runtime.previewProgram.setDirectLiveEditing(false)
        let body = String(repeating: "長いコメント 👩🏽‍🚀 العربية café e\u{301} {host} <3\n", count: 160)
        try requireComment(body.utf8.count <= 16_384, "Fixture exceeds provider message bound")
        let envelope = try JSONSerialization.data(withJSONObject: ["action": "event", "payload": [
            "connectionIdentifier": "public-fixture", "eventTypeId": 5,
            "eventPayload": ["liveChatMessageId": "long", "text": body, "author": ["displayName": "Viewer"]]]])
        runtime.chat.receive(envelope)
        let message = runtime.chat.queue.messages.last!
        runtime.chat.createSlot()
        let slot = runtime.chat.selectedSlot!
        let before = runtime.previewProgram.programScene
        try requireComment(!runtime.chat.dropMessage("untrusted external text"), "Drop accepted arbitrary external text")
        try requireComment(runtime.chat.dropMessage(message.id, into: slot), "Normalized local message drop failed")
        try requireComment(runtime.previewProgram.programScene == before, "Drop changed Program before Take")
        try requireComment(runtime.chat.queue.message(message.id)?.text == body, "Drop damaged original message")
        let layout = runtime.chat.selectedCommentPresentation!
        try requireComment(!layout.needsLargerBox && layout.pages.count > 1 && layout.fontSize >= 24,
            "Long comment should be paged at a readable reference size")
        for height in [220.0, 240, 260, 280, 300, 400] {
            let size = CommentTextLayout.make(text: "Viewer · YouTube\n" + body, headerLength: ("Viewer · YouTube\n" as NSString).length,
                requestedFontSize: 42, minimumFontSize: 24, fontName: nil, box: CGSize(width: 1572, height: height), alignment: .leading)
            try requireComment(!size.needsLargerBox && size.pages.count > 1, "Mixed-script footer fitting failed at height \(height)")
        }
        let value = body as NSString
        var joined = "", expectedStart = 0
        for page in layout.pages {
            try requireComment(page.bodyRange.location == expectedStart && page.bodyRange.length > 0, "Page ranges skip or duplicate text")
            joined += value.substring(with: page.bodyRange); expectedStart += page.bodyRange.length
        }
        try requireComment(joined == body, "Composed-character page ranges did not retain the full Unicode message")
        _ = runtime.dispatcher.execute(.take)
        runtime.chat.advanceCommentPage(1)
        guard case .text(let programFirst) = runtime.previewProgram.programScene!.layers.first(where: { $0.id == slot })!.payload,
              case .text(var stagedSecond) = runtime.previewProgram.stagedScene!.layers.first(where: { $0.id == slot })!.payload else { fatalError() }
        try requireComment(programFirst.commentPageIndex == 0 && stagedSecond.commentPageIndex == 1, "Next Page bypassed staged policy")
        runtime.chat.hide()
        try requireComment(runtime.chat.queue.message(message.id)?.text == body, "Hide deleted the provider message")

        let imageContext = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 64 * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        imageContext.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); imageContext.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let imageData = NSMutableData()
        let destination = CGImageDestinationCreateWithData(imageData, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, imageContext.makeImage()!, nil); try requireComment(CGImageDestinationFinalize(destination), "PNG fixture failed")
        let avatar = try CommentAvatarLoader.decode(imageData as Data)
        let avatarKey = CommentAvatarStore.shared.publish(avatar)
        try requireComment(CommentAvatarLoader.accepts(URL(string: "https://yt3.ggpht.com/public")!), "Authorized image host rejected")
        for input in ["https://localhost/avatar", "http://yt3.ggpht.com/a", "https://user:pass@yt3.ggpht.com/a", "https://yt3.ggpht.com.private.invalid/a", "https://yt3.ggpht.com:8443/a"] {
            try requireComment(!CommentAvatarLoader.accepts(URL(string: input)!), "Untrusted avatar URL accepted")
        }
        var rejected = false
        do { _ = try CommentAvatarLoader.decode(Data(repeating: 0, count: 1_048_577)) } catch { rejected = true }
        try requireComment(rejected, "Oversized avatar decode was accepted")

        // Native rendering at an exact reference scale, retaining all pages.
        stagedSecond.commentPageIndex = 0; stagedSecond.commentAvatarKey = avatarKey
        var layer = runtime.previewProgram.stagedScene!.layers.first(where: { $0.id == slot })!
        layer.isVisible = true; layer.payload = .text(stagedSecond)
        let program = folder.appendingPathComponent("Paged.mp4")
        let timeline = RecordingTimeline(), feed = RecordingChatFeed(), sessionID = UUID().uuidString
        for binding in runtime.chat.recentRecordingBindings { feed.bind(binding) }
        var prefs = RecordingChatPreferences(); prefs.enabled = true
        let archive = RecordingChatArchive(programURL: program, sessionID: sessionID, segmentIndex: 1, context: .init(), timeline: timeline, preferences: prefs)
        var config = ProgramRecordingSession.Configuration(); config.frameRate = 10; config.requiresAudio = false
        config.onVideoAccepted = { frame in feed.frame(frame, into: archive) }
        let writer = ProgramRecordingSession(outputURL: program, configuration: config, timeline: timeline, spaceProbe: { _ in 8_000_000_000 })
        let renderer = SceneRenderer(tokenProvider: { ["host": "PRIVATE HOST MUST NOT EXPAND"] })
        let box = CGSize(width: layer.transform.size.width * 1920 - stagedSecond.padding * 2 - 64 - stagedSecond.padding,
                         height: layer.transform.size.height * 1080 - stagedSecond.padding * 2)
        let avatarLayout = CommentTextLayout.make(text: stagedSecond.text, headerLength: stagedSecond.commentHeaderUTF16Length!,
            requestedFontSize: CGFloat(stagedSecond.fontSize), minimumFontSize: 24, fontName: nil, box: box, alignment: stagedSecond.alignment)
        try requireComment(!avatarLayout.needsLargerBox && avatarLayout.pages.count > 1, "Avatar consumed the whole comment area")
        var rendered = 0
        for index in avatarLayout.pages.indices {
            var text = stagedSecond; text.commentPageIndex = index; layer.payload = .text(text)
            let scene = Scene(name: "Paged comment", layers: [layer], background: .solid(colorHex: "#000000"))
            let frame = renderer.render(scene: scene, overlayContext: .empty, canvasSize: CGSize(width: 1920, height: 1080),
                frames: .init(camera: { _ in nil }, screen: { _ in nil }), sourcePayloads: [:], scenes: [:],
                presentationTime: CMTime(seconds: 20_000 + Double(index) / 10, preferredTimescale: 48_000),
                frameDuration: CMTime(value: 1, timescale: 10), sequence: Int64(index))!
            let paints = RecordingChatPaint.read(frame.sampleBuffer)
            try requireComment(paints.count == 1 && paints[0].pageIndex == index && paints[0].bodyUTF16Start == avatarLayout.pages[index].bodyRange.location,
                "Actual rendered page metadata did not identify its Unicode text range")
            try requireComment(paints[0].fingerprint == RecordingChatPaint.fingerprint(text.text), "Public brace text expanded into private title tokens")
            writer.appendVideo(frame.sampleBuffer); rendered += 1
            try await Task.sleep(for: .milliseconds(100))
        }
        let result = await withCheckedContinuation { c in writer.finish { c.resume(returning: $0) } }
        await withCheckedContinuation { c in archive.finish(completed: result.completed) { c.resume() } }
        try requireComment(result.completed && result.progress.videoSamples == rendered, "Native page media writer lost the fixture")
        var records: [RecordingChatRecord] = []
        try RecordingChatReader.scan(archive.url, record: { records.append($0) })
        let shows = records.filter { $0.type == "show" }
        try requireComment(shows.count == avatarLayout.pages.count && shows.allSatisfy { $0.message?.text == body }, "Archive did not retain full provider message plus actual page transitions")
        try requireComment(shows.map { $0.paintedBody ?? "" }.joined() == body, "Archived painted pages skip or duplicate Unicode text")
        let subtitle = folder.appendingPathComponent("Paged.vtt")
        try RecordingChatReader.export(archive.url, format: .vtt, to: subtitle)
        let subtitles = String(decoding: try Data(contentsOf: subtitle), as: UTF8.self)
        try requireComment(!subtitles.contains(body) && !subtitles.contains("PRIVATE HOST"), "Subtitle claimed the complete long message was visible at once")
        let asset = AVURLAsset(url: program)
        let videos = try await asset.loadTracks(withMediaType: .video)
        try requireComment(videos.count == 1, "Native page video is missing")
        let reader = try AVAssetReader(asset: asset)
        let decoded = AVAssetReaderTrackOutput(track: videos[0], outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(decoded); try requireComment(reader.startReading(), "Could not decode native comment output")
        var decodedFrames = 0, redPixels = 0
        while let sample = decoded.copyNextSampleBuffer(), let pixel = CMSampleBufferGetImageBuffer(sample) {
            CVPixelBufferLockBaseAddress(pixel, .readOnly)
            let base = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to: UInt8.self)
            let row = CVPixelBufferGetBytesPerRow(pixel)
            for y in stride(from: 0, to: CVPixelBufferGetHeight(pixel), by: 8) {
                for x in stride(from: 0, to: CVPixelBufferGetWidth(pixel), by: 8) {
                    let offset = y * row + x * 4
                    if base[offset + 2] > 150 && base[offset + 1] < 60 && base[offset] < 60 { redPixels += 1 }
                }
            }
            CVPixelBufferUnlockBaseAddress(pixel, .readOnly); decodedFrames += 1
        }
        try requireComment(decodedFrames == rendered && redPixels > 20, "Decoded program did not contain the actual native avatar pixels")
        let serialized = String(decoding: try JSONEncoder().encode(layer), as: UTF8.self)
        try requireComment(!serialized.contains("https:") && !serialized.contains("imageData"), "Avatar URL/pixels persisted in scene data")
        let tiny = CommentTextLayout.make(text: stagedSecond.text, headerLength: stagedSecond.commentHeaderUTF16Length!, requestedFontSize: 42,
            minimumFontSize: 24, fontName: nil, box: CGSize(width: 2, height: 2), alignment: .leading)
        try requireComment(tiny.needsLargerBox, "Impossible size silently clipped comment")
        print("PASS: full bounded long Unicode messages retained across grapheme-safe readable pages; actual native page pixels/media and archive page ranges; staged click/drop/Next Page/Hide; literal public braces; optional bounded avatar pixels/host/decode policy; impossible slot size surfaced. \(avatarLayout.pages.count) native pages. Artifacts: \(folder.path)")
    }
}
