import AVFoundation
import Combine
import CoreMedia
import CoreVideo
import Foundation
import StreamCore

private func check(_ condition: @autoclosure () throws -> Bool, _ reason: String) throws {
    if try !condition() { throw RecordingChatError.invalid(reason) }
}
private func chatLog(_ message: String) { FileHandle.standardOutput.write(Data((message + "\n").utf8)) }
private func event(_ id: String, text: String = "Hello 世界 👋", whisper: Bool = false, type: Int = 5) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["action": "event", "timestamp": 1_800_000_000,
        "token": "secret-token-sentinel", "payload": ["connectionIdentifier": "private-connection-sentinel",
            "eventTypeId": type, "eventPayload": ["liveChatMessageId": id, "text": text,
                "contentModifiers": ["whisper": whisper], "author": ["displayName": "Public Author",
                    "avatar": "https://private.invalid/avatar?token=secret-avatar-sentinel"]]]])
}

private final class ChatTestSummary: @unchecked Sendable {
    private let lock = NSLock()
    private var value: RecordingChatSummary?
    func receive(_ value: RecordingChatSummary) { lock.lock(); self.value = value; lock.unlock() }
    var warning: String? { lock.lock(); defer { lock.unlock() }; return value?.warning }
}

/// Holds one actual writer callback so the fixture can create a known backlog
/// without depending on the host renderer or encoder being slow.
private final class ChatPauseBacklog: @unchecked Sendable {
    let enabled: Bool
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var entered = false
    private var timedOut = false
    init(enabled: Bool) { self.enabled = enabled }
    func accepted(_ frame: RecordingChatFrame) {
        guard enabled, abs(frame.seconds - 1.4) < 0.000_001 else { return }
        lock.lock(); entered = true; lock.unlock()
        let timeout = release.wait(timeout: .now() + 3) == .timedOut
        lock.lock(); timedOut = timeout; lock.unlock()
    }
    var isEntered: Bool { lock.lock(); defer { lock.unlock() }; return entered }
    var didTimeOut: Bool { lock.lock(); defer { lock.unlock() }; return timedOut }
    func unblock() { release.signal() }
}

private final class ChatResumeAcknowledgement: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool?
    func receive(_ ready: Bool) { lock.lock(); value = ready; lock.unlock() }
    var ready: Bool? { lock.lock(); defer { lock.unlock() }; return value }
}

@main @MainActor struct RecordingChatHarness {
    static func main() async throws {
        let root: URL
        if let index = CommandLine.arguments.firstIndex(of: "--artifacts-dir") {
            try check(index + 1 < CommandLine.arguments.count, "Missing chat artifact directory")
            root = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
        } else {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("stream-chat-\(UUID().uuidString)")
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        chatLog("Native chat artifacts: \(root.path)")
        // Keep artifacts for media inspection outside the fixture.
        let workspace = StudioWorkspace(root: root.appendingPathComponent("Workspace"))
        let runtime = workspace.runtime
        runtime.previewProgram.setDirectLiveEditing(false)
        runtime.recorder.bindChat(runtime.chat)
        try check(!runtime.recorder.preferences.chatArchive.enabled, "Chat archive must default off")
        var scene = runtime.previewProgram.stagedScene!
        scene.layers = []; scene.background = .solid(colorHex: "#000000")
        runtime.previewProgram.applyStagedEdit(scene); _ = runtime.dispatcher.execute(.take)
        runtime.chat.createSlot()
        let slot = runtime.chat.selectedSlot!
        _ = runtime.dispatcher.execute(.setLayerTransform(slot, .fullscreen, in: scene.id))
        runtime.chat.includeAuthor = false; runtime.chat.includePlatform = false
        let feed = runtime.recorder.chatFeed
        let timeline = RecordingTimeline(), sessionID = UUID().uuidString
        let programURL = root.appendingPathComponent("Program.mp4")
        var prefs = RecordingChatPreferences(); prefs.enabled = true; prefs.includeAuthors = false
        let context = RecordingContext(projectID: workspace.selection.project.uuidString, profileID: workspace.selection.profile.uuidString)
        let archive = RecordingChatArchive(programURL: programURL, sessionID: sessionID, segmentIndex: 1,
            context: context, timeline: timeline, preferences: prefs)
        feed.install(archive)
        let backlog = ChatPauseBacklog(enabled: CommandLine.arguments.contains("--late-pause-burst"))
        defer { backlog.unblock() }
        var config = ProgramRecordingSession.Configuration()
        config.frameRate = 20; config.sessionID = sessionID; config.context = context
        config.chatArchiveFile = archive.url.lastPathComponent
        config.onVideoAccepted = { frame in feed.frame(frame, into: archive); backlog.accepted(frame) }
        config.onMarkerRecorded = { marker in archive.marker(marker) }
        let writer = ProgramRecordingSession(outputURL: programURL, configuration: config, timeline: timeline,
            spaceProbe: { _ in 8_000_000_000 })
        let renderer = SceneRenderer()
        let base = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        var deadline = ContinuousClock.now
        var firstID = "", secondID = ""
        var whiteFrames = 0, blackFrames = 0
        let slate = Scene(name: "Private", layers: [], background: .solid(colorHex: "#000000"))
        for tick in 0..<360 {
            let seconds = Double(tick) / 100
            // Receipt and generated samples must share the fixture's media
            // clock, independent of hosted renderer/encoder startup latency.
            feed.setValidationTime(CMTime(seconds: base + seconds, preferredTimescale: 48_000))
            if tick == 20 {
                runtime.chat.receive(try event("first")); firstID = runtime.chat.queue.messages.last!.id
                runtime.chat.receive(try event("first")) // Replayed delivery must stay deduplicated.
                runtime.chat.receive(try event("backstage", text: "secret-whisper-sentinel", whisper: true))
                runtime.chat.receive(try event("unknown", text: "secret-unknown-sentinel", type: 999))
            }
            if tick == 25 {
                runtime.chat.show(firstID)
                if case .text(var text) = runtime.previewProgram.stagedScene!.layers.first(where: { $0.id == slot })!.payload {
                    text.backgroundColorHex = "#FFFFFF"; text.colorHex = "#000000"
                    _ = runtime.dispatcher.execute(.setLayerText(slot, text, in: scene.id))
                }
            }
            if tick == 50 { _ = runtime.dispatcher.execute(.take) }
            if tick == 60 { runtime.chat.receive(try event("second")); secondID = runtime.chat.queue.messages.last!.id }
            if tick == 70 { runtime.chat.show(secondID) }
            if tick == 90 { _ = runtime.dispatcher.execute(.take) }
            if tick == 160 {
                if backlog.enabled {
                    let blocked = timeline.snapshot()
                    try check(backlog.isEntered && blocked.videoPTS.isNumeric
                        && abs((blocked.videoPTS - blocked.origin).seconds - 1.4) < 0.000_001,
                        "Controlled writer backlog did not hold the actual 1.40-second frame")
                    chatLog("Controlled pre-pause backlog: accepted video 1.40 s, three later frames queued")
                    backlog.unblock()
                }
                // Pause deliberately discards queued video. This fixture's
                // exact 1.6-second boundary must already be accepted, even
                // when an absolute wall deadline caused a catch-up burst.
                try await waitForBoundary(timeline, videoSeconds: 1.55, endSeconds: 1.6)
                writer.pause()
                try await waitForBoundary(timeline, paused: true)
                try check(!backlog.didTimeOut, "Controlled writer callback exceeded its bounded hold")
            }
            if tick == 175 {
                runtime.chat.receive(try event("paused", text: "During pause 🧑🏽‍🚀"))
                runtime.chat.hide(); _ = runtime.dispatcher.execute(.take)
            }
            if tick == 200 {
                let acknowledgment = ChatResumeAcknowledgement()
                writer.resume { acknowledgment.receive($0) }
                let until = ContinuousClock.now + .seconds(3)
                while acknowledgment.ready == nil && ContinuousClock.now < until {
                    try await Task.sleep(for: .milliseconds(5))
                }
                try check(acknowledgment.ready == true, "Native writer did not acknowledge resume before resumed media")
            }
            if tick == 225 { runtime.chat.receive(try event("long", text: String(repeating: "界👩🏽‍🚀", count: 400))) }
            if tick == 220 { writer.addMarker(title: "Chapter 世界") }
            if tick % 5 == 0 {
                let selected = (120..<150).contains(tick) ? slate : runtime.previewProgram.programScene!
                let until = ContinuousClock.now + .seconds(3)
                var rendered: CompositedFrame?
                repeat {
                    rendered = renderer.render(scene: selected, overlayContext: .empty,
                        canvasSize: CGSize(width: 320, height: 180), frames: .init(camera: { _ in nil }, screen: { _ in nil }),
                        sourcePayloads: [:], scenes: [:], presentationTime: CMTime(seconds: base + seconds, preferredTimescale: 48_000),
                        frameDuration: CMTime(value: 1, timescale: 20), sequence: Int64(tick))
                    if rendered == nil {
                        try check(ContinuousClock.now < until, "Native renderer did not release capacity for the requested source frame")
                        try await Task.sleep(for: .milliseconds(5))
                    }
                } while rendered == nil
                if let frame = rendered {
                    let paints = RecordingChatPaint.read(frame.sampleBuffer)
                    if tick < 50 { try check(paints.isEmpty, "Staged Show leaked to Program") }
                    if (70..<90).contains(tick) { try check(paints.first?.messageID == firstID, "Identical staged text relabeled Program before Take") }
                    if (120..<150).contains(tick) { try check(paints.isEmpty, "Private slate leaked a feature") }
                    if !paints.isEmpty { whiteFrames += 1 } else { blackFrames += 1 }
                    writer.appendVideo(frame.sampleBuffer)
                }
            }
            writer.appendAudio(try ProgramRecordingFixtures.audio(at: seconds, timestampBase: base))
            if backlog.enabled && tick == 140 {
                let until = ContinuousClock.now + .seconds(3)
                while !backlog.isEntered && ContinuousClock.now < until {
                    try await Task.sleep(for: .milliseconds(5))
                }
                try check(backlog.isEntered, "Native writer did not enter the controlled callback hold")
            }
            if tick == 0 {
                for _ in 0..<150 {
                    if timeline.snapshot().origin.isNumeric { break }
                    try await Task.sleep(for: .milliseconds(20))
                }
                try check(timeline.snapshot().origin.isNumeric, "Native writer must establish its media timeline before chat receipts")
                deadline = ContinuousClock.now
            }
            if !backlog.enabled || !(140..<160).contains(tick) {
                try await ContinuousClock().sleep(until: deadline + .milliseconds((tick + 1) * 10))
            }
        }
        let result = await withCheckedContinuation { continuation in writer.finish { continuation.resume(returning: $0) } }
        feed.install(nil)
        await withCheckedContinuation { continuation in archive.finish(completed: result.completed) { continuation.resume() } }
        chatLog("Native chat writer: duration \(result.progress.durationSeconds), accepted video \(result.progress.videoSamples), dropped video \(result.progress.droppedVideo), dropped audio \(result.progress.droppedAudio)")
        try check(result.completed && whiteFrames > 10 && blackFrames > 20, "Native program recording/rendering failed")
        try await ProgramRecordingFixtures.inspect(programURL, expectedDuration: 3.2, checkSync: false)
        var records: [RecordingChatRecord] = []
        let inspection = try RecordingChatReader.scan(archive.url, record: { records.append($0) })
        try check(!inspection.recovered, "Completed archive was misclassified as interrupted")
        try check(records.filter { $0.type == "message" }.count == 4, "Public replay/private filtering failed: \(records.filter { $0.type == "message" }.map { ($0.message?.id ?? "missing", $0.seconds) })")
        let shows = records.filter { $0.type == "show" }
        try check(shows.count == 3, "Expected Take(first), Take(second), private-slate restore only: \(shows)")
        try check(shows[0].messageID == firstID && abs(shows[0].seconds - 0.5) < 0.001, "First feature did not align with accepted Take frame")
        try check(shows[1].messageID == secondID && abs(shows[1].seconds - 0.9) < 0.001, "Identical caption lost actual message identity")
        try check(shows[2].messageID == secondID && abs(shows[2].seconds - 1.5) < 0.001, "Private slate restore timing mismatch")
        let paused = records.first { $0.whilePaused == true }
        try check(paused != nil && abs(paused!.seconds - 1.6) < 0.002, "Paused receipt must freeze on media timeline")
        try check(records.contains { $0.type == "hide" && abs($0.seconds - 1.6) < 0.002 }, "Hide while paused must wait for resumed accepted video")
        try check(records.contains { $0.type == "marker" && $0.title == "Chapter 世界" && $0.seconds < 2 }, "Marker did not use media clock after pause")
        let raw = String(decoding: try Data(contentsOf: archive.url), as: UTF8.self)
        try check(!raw.contains("sentinel") && !raw.contains("Public Author") && !raw.contains("avatar") && !raw.contains("connectionIdentifier"), "Archive leaked excluded provider/author fields")
        for format in RecordingChatFormat.allCases {
            let output = root.appendingPathComponent("Chat.\(format.rawValue)")
            try RecordingChatReader.export(archive.url, format: format, to: output)
            try check((try Data(contentsOf: output)).count > 30, "Export is empty")
        }
        try check(String(decoding: try Data(contentsOf: root.appendingPathComponent("Chat.vtt")), as: UTF8.self).contains("00:00:00.500 --> 00:00:00.900"), "Subtitle cue times do not match accepted video")
        try await decodedVisibility(programURL, records: records)
        try alphaContributions(renderer: renderer, messageID: firstID)
        try await splitting(root: root, feed: feed, binding: runtime.chat.recentRecordingBindings[0], context: context)
        try recoveryAndRetention(root: root, archive: archive.url, context: context)
        let model = RecordingLibraryModel()
        await model.refresh(access: .init(url: root, scoped: false), activeURLs: [])
        try check(model.entries.first { $0.url.lastPathComponent == programURL.lastPathComponent }?.chatURL?.lastPathComponent == archive.url.lastPathComponent, "Library did not associate the program archive")
        print("PASS: public-only opt-in chat; actual staged Show/Take/Hide identity; decoded feature pixels; privacy/alpha/opaque/stinger/transition suppression; native accepted-frame timing, pause, markers and two segment origins; bounded overload; interrupted-prefix recovery; JSON/CSV/VTT/SRT; author opt-out; profile retention; library association. Artifacts: \(root.path)")
    }

    static func waitForBoundary(_ timeline: RecordingTimeline, videoSeconds: Double? = nil,
                                endSeconds: Double? = nil, paused: Bool? = nil) async throws {
        let until = ContinuousClock.now + .seconds(3)
        while true {
            let snapshot = timeline.snapshot()
            let videoReady = videoSeconds.map { snapshot.origin.isNumeric && snapshot.videoPTS.isNumeric
                && (snapshot.videoPTS - snapshot.origin).seconds >= $0 - 0.000_001 } ?? true
            let endReady = endSeconds.map { snapshot.origin.isNumeric && snapshot.end.isNumeric
                && (snapshot.end - snapshot.origin).seconds >= $0 - 0.000_001 } ?? true
            if videoReady && endReady && (paused == nil || snapshot.paused == paused) { return }
            try check(ContinuousClock.now < until, "Native writer did not acknowledge the requested accepted media boundary")
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    static func alphaContributions(renderer: SceneRenderer, messageID: String) throws {
        var payload = TextSourcePayload(text: "Mask control")
        payload.recordingChatMessageID = messageID; payload.backgroundColorHex = "#FFFFFF"
        let layer = LayerNode(name: "Slot", payload: .text(payload), transform: .fullscreen)
        let visible = Scene(name: "Visible", layers: [layer], background: .solid(colorHex: "#000000"))
        let hidden = Scene(name: "Hidden", layers: [], background: .solid(colorHex: "#000000"))
        func render(_ scene: Scene, alpha: Double = 1, stinger: CVPixelBuffer? = nil) -> [RecordingChatPaint] {
            let frame = renderer.render(scene: scene, overlayContext: .empty, canvasSize: CGSize(width: 320, height: 180),
                frames: .init(camera: { _ in nil }, screen: { _ in nil }), sourcePayloads: [:], scenes: [:],
                presentationTime: .zero, frameDuration: CMTime(value: 1, timescale: 30), sequence: 1,
                layerOpacity: [layer.id: alpha], stinger: stinger)!
            return RecordingChatPaint.read(frame.sampleBuffer)
        }
        try check(render(visible).count == 1 && render(visible, alpha: 0).isEmpty, "Visibility fade alpha is wrong")
        var covered = visible
        covered.layers.append(.init(name: "Opaque cover", payload: .shape(.init()), transform: .fullscreen))
        try check(render(covered).isEmpty, "Covered comment must not be archived as visible")
        let child = visible
        let nested = Scene(name: "Parent", layers: [LayerNode(name: "Child", payload: .scene(.init(sceneID: child.id)), transform: .fullscreen)])
        for sequence in 1...2 {
            let frame = renderer.render(scene: nested, overlayContext: .empty, canvasSize: CGSize(width: 320, height: 180),
                frames: .init(camera: { _ in nil }, screen: { _ in nil }), sourcePayloads: [:], scenes: [child.id: child],
                presentationTime: .zero, frameDuration: CMTime(value: 1, timescale: 30), sequence: Int64(sequence))!
            try check(RecordingChatPaint.read(frame.sampleBuffer).count == 1, "Nested comment metadata disappeared through static caching")
        }
        let stinger = CMSampleBufferGetImageBuffer(try ProgramRecordingFixtures.video(at: 0, noisy: true))!
        try check(render(visible, stinger: stinger).isEmpty, "Opaque stinger must suppress comment metadata")
        for style in [SceneTransitionStyle.dissolve, .wipe, .slide, .dipToColor, .cut, .layerMotion] {
            for progress in [0.0, 0.5, 1.0] {
                let frame = renderer.renderTransition(from: visible, to: hidden,
                    blend: .init(style: style, progress: progress, direction: .right, dipColorHex: "#000000"),
                    overlayContext: .empty, canvasSize: CGSize(width: 320, height: 180),
                    frames: .init(camera: { _ in nil }, screen: { _ in nil }), sourcePayloads: [:], scenes: [:],
                    presentationTime: .zero, frameDuration: CMTime(value: 1, timescale: 30), sequence: 1)!
                let paints = RecordingChatPaint.read(frame.sampleBuffer)
                let absent = progress == 1 || style == .cut || (style == .dipToColor && progress == 0.5)
                try check(absent ? paints.isEmpty : paints.count == 1, "Transition \(style) \(progress) feature contribution mismatch")
            }
        }
    }

    static func decodedVisibility(_ url: URL, records: [RecordingChatRecord]) async throws {
        let asset = AVURLAsset(url: url)
        let reader = try AVAssetReader(asset: asset)
        let track = try await asset.loadTracks(withMediaType: .video)[0]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output); try check(reader.startReading(), "Cannot decode native recording")
        var samples = 0
        while let sample = output.copyNextSampleBuffer() {
            let time = sample.presentationTimeStamp.seconds
            let last = records.last { ($0.type == "show" || $0.type == "hide") && $0.seconds <= time + 0.001 }
            let expected = last?.type == "show"
            let pixel = CMSampleBufferGetImageBuffer(sample)!
            CVPixelBufferLockBaseAddress(pixel, .readOnly)
            let bytes = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to: UInt8.self)
            let bright = bytes[8 * 4] > 100
            CVPixelBufferUnlockBaseAddress(pixel, .readOnly)
            try check(bright == expected, "Decoded visibility differs from archive at \(time)")
            samples += 1
        }
        try check(samples > 40 && reader.status == .completed, "Decoded media did not complete")
    }

    static func splitting(root: URL, feed: RecordingChatFeed, binding: RecordingChatBinding, context: RecordingContext) async throws {
        feed.bind(binding)
        let sessionID = UUID().uuidString
        for segment in 1...2 {
            let timeline = RecordingTimeline(), base = 20_000.0 + Double(segment) * 2
            let url = root.appendingPathComponent("Split\(segment).mp4")
            var prefs = RecordingChatPreferences(); prefs.enabled = true
            let archive = RecordingChatArchive(programURL: url, sessionID: sessionID, segmentIndex: segment,
                context: context, timeline: timeline, preferences: prefs)
            var config = ProgramRecordingSession.Configuration(); config.frameRate = 60; config.requiresAudio = false
            config.onVideoAccepted = { frame in feed.frame(frame, into: archive) }
            let writer = ProgramRecordingSession(outputURL: url, configuration: config, timeline: timeline, spaceProbe: { _ in 8_000_000_000 })
            for i in 0..<20 {
                let sample = try ProgramRecordingFixtures.video(at: Double(i) / 60, timestampBase: base)
                RecordingChatPaint.attach([binding.paint], to: sample); writer.appendVideo(sample)
                try await Task.sleep(for: .milliseconds(17))
            }
            let result = await withCheckedContinuation { c in writer.finish { c.resume(returning: $0) } }
            await withCheckedContinuation { c in archive.finish(completed: result.completed) { c.resume() } }
            var records: [RecordingChatRecord] = []
            let info = try RecordingChatReader.scan(archive.url, record: { records.append($0) })
            try check(result.completed && info.header.sessionID == sessionID && info.header.segmentIndex == segment,
                "Split archive did not retain session/segment identity")
            try check(records.first?.type == "show" && records.first?.seconds == 0 && records.last?.type == "hide", "Already visible comment did not restart on segment media zero")
        }
        let collisionURL = root.appendingPathComponent("ArchiveFailure.mp4")
        let sentinel = Data("original archive sentinel".utf8)
        try sentinel.write(to: collisionURL.appendingPathExtension("chat.jsonl"))
        let failureTimeline = RecordingTimeline()
        let collisionSummary = ChatTestSummary()
        let failedArchive = RecordingChatArchive(programURL: collisionURL, sessionID: sessionID, segmentIndex: 4,
            context: context, timeline: failureTimeline, preferences: .init(), update: collisionSummary.receive)
        var collisionConfig = ProgramRecordingSession.Configuration(); collisionConfig.frameRate = 60; collisionConfig.requiresAudio = false
        collisionConfig.onVideoAccepted = { frame in feed.frame(frame, into: failedArchive) }
        let independent = ProgramRecordingSession(outputURL: collisionURL, configuration: collisionConfig, timeline: failureTimeline, spaceProbe: { _ in 8_000_000_000 })
        for i in 0..<20 {
            independent.appendVideo(try ProgramRecordingFixtures.video(at: Double(i) / 60))
            try await Task.sleep(for: .milliseconds(17))
        }
        let result = await withCheckedContinuation { c in independent.finish { c.resume(returning: $0) } }
        await withCheckedContinuation { c in failedArchive.finish(completed: result.completed) { c.resume() } }
        try check(result.completed && result.progress.videoSamples > 10, "Archive failure stopped independent media writer")
        try check(try Data(contentsOf: failedArchive.url) == sentinel, "Archive create failure overwrote the existing file")
        try check(collisionSummary.warning != nil, "Archive write failure was not surfaced")
        let overloadTimeline = RecordingTimeline(); overloadTimeline.begin(at: CMTime(seconds: 1, preferredTimescale: 100))
        let overload = RecordingChatArchive(programURL: root.appendingPathComponent("Overload.mp4"), sessionID: sessionID, segmentIndex: 3,
            context: context, timeline: overloadTimeline, preferences: .init())
        for i in 0..<10000 {
            let message = RecordingChatMessage(id: String(i), platform: "YouTube", author: nil, text: String(repeating: "界", count: 4000),
                providerTimestamp: Date(), timestampIsReceiptTime: true, kind: "Text")
            overload.receive(message, at: CMTime(seconds: 1.1, preferredTimescale: 100))
        }
        overload.frame(.init(seconds: 0, endSeconds: 0.5, painted: []), bindings: [])
        await withCheckedContinuation { c in overload.finish(completed: true) { c.resume() } }
        try check((RecordingChatReader.summary(overload.url)?.droppedEvents ?? 0) > 0, "Archive overload was not bounded/counted")
    }

    static func recoveryAndRetention(root: URL, archive: URL, context: RecordingContext) throws {
        let partial = root.appendingPathComponent("Partial.chat.jsonl")
        var bytes = try Data(contentsOf: archive); bytes.append(Data("{\"type\":\"message\",\"secret-private-sentinel\":\"".utf8))
        try bytes.write(to: partial)
        let inspection = try RecordingChatReader.scan(partial)
        try check(inspection.recovered && inspection.records > 5, "Interrupted tail did not recover valid prefix")
        let exported = root.appendingPathComponent("Partial.json")
        try RecordingChatReader.export(partial, format: .json, to: exported)
        try check(!String(decoding: try Data(contentsOf: exported), as: UTF8.self).contains("sentinel"), "Invalid tail leaked to export")
        do { try RecordingChatReader.export(partial, format: .json, to: exported); throw RecordingChatError.invalid("Export overwrote existing output") }
        catch RecordingChatError.invalid(let text) { try check(text.contains("unused"), "Unexpected export error") }
        let future = root.appendingPathComponent("Future.chat.jsonl")
        try Data("{\"type\":\"header\",\"version\":2}\n".utf8).write(to: future)
        var rejected = false
        do { _ = try RecordingChatReader.scan(future) } catch { rejected = true }
        try check(rejected, "Future archive should be rejected")
        var summary = RecordingChatReader.summary(archive)!
        summary.completedAt = Date().addingTimeInterval(-40 * 86_400)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(summary).write(to: archive.appendingPathExtension("summary.json"))
        try RecordingChatReader.applyRetention(directory: root, context: .init(projectID: UUID().uuidString, profileID: UUID().uuidString), days: 30)
        try check(FileManager.default.fileExists(atPath: archive.path), "Retention crossed project/profile scope")
        let aged = root.appendingPathComponent("Aged.chat.jsonl")
        try FileManager.default.copyItem(at: archive, to: aged)
        try encoder.encode(summary).write(to: aged.appendingPathExtension("summary.json"))
        try RecordingChatReader.applyRetention(directory: root, context: context, days: 30)
        try check(!FileManager.default.fileExists(atPath: aged.path), "Configured retention did not remove old completed archive")
        // Retention also removes the original old archive; restore its fixture for library review.
        let preserved = try Data(contentsOf: partial).split(separator: 10).dropLast().map { Data($0) + Data([10]) }.reduce(Data(), +)
        try preserved.write(to: archive)
        // Restore the recent date so the library association remains inspectable.
        summary.completedAt = Date(); try encoder.encode(summary).write(to: archive.appendingPathExtension("summary.json"))
        try RecordingChatReader.applyRetention(directory: root, context: context, days: 30)
        try check(FileManager.default.fileExists(atPath: partial.path) && FileManager.default.fileExists(atPath: future.path), "Retention removed interrupted/unknown archives")
    }
}
