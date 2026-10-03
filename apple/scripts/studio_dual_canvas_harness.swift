import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import StreamCore

private final class CanvasFrames: @unchecked Sendable {
    struct Summary: Sendable {
        let sequence: Int64
        let presentationTime: CMTime
        let left: Int, right: Int, top: Int, bottom: Int
    }
    private let lock = NSLock()
    private var frames: [Summary] = []
    func receive(_ frame: CompositedFrame) {
        let summary = Summary(sequence: frame.sequence, presentationTime: frame.presentationTime,
            left: red(frame, x: 0.25, y: 0.5), right: red(frame, x: 0.75, y: 0.5),
            top: red(frame, x: 0.5, y: 0.25), bottom: red(frame, x: 0.5, y: 0.75))
        lock.lock(); frames.append(summary); if frames.count > 90 { frames.removeFirst() }; lock.unlock()
    }
    func snapshot() -> [Summary] { lock.lock(); defer { lock.unlock() }; return frames }
    private func red(_ frame: CompositedFrame, x: Double, y: Double) -> Int {
        guard let p = frame.pixelBuffer else { return -1 }
        CVPixelBufferLockBaseAddress(p, .readOnly); defer { CVPixelBufferUnlockBaseAddress(p, .readOnly) }
        let index = Int(y * Double(CVPixelBufferGetHeight(p))) * CVPixelBufferGetBytesPerRow(p) + Int(x * Double(CVPixelBufferGetWidth(p))) * 4 + 2
        return Int(CVPixelBufferGetBaseAddress(p)!.assumingMemoryBound(to: UInt8.self)[index])
    }
}

private final class CanvasAudioProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func receive() { lock.lock(); count += 1; lock.unlock() }
    func snapshot() -> Int { lock.lock(); defer { lock.unlock() }; return count }
}

/// Synthetic PCM follows each delivered canvas sample clock. This fixture
/// qualifies canvas/writer routing, not independent live capture-clock drift.
private final class CanvasRecordingFeed: @unchecked Sendable {
    private let lock = NSLock()
    private let frames: CanvasFrames
    private let writer: ProgramRecordingSession
    private var origin: Double?
    private var chunk = 0
    private var closed = false
    init(frames: CanvasFrames, writer: ProgramRecordingSession) { self.frames = frames; self.writer = writer }
    func receive(_ frame: CompositedFrame) {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        frames.receive(frame)
        writer.appendVideo(frame.sampleBuffer)
        let start = frame.presentationTime.seconds
        if origin == nil { origin = start }
        let duration = CMSampleBufferGetDuration(frame.sampleBuffer)
        let end = start + (duration.isNumeric && duration.seconds > 0 ? duration.seconds : 1.0 / 30)
        // The fixture is bounded to ten seconds; fail rather than manufacture an
        // unbounded catch-up allocation if the renderer stops making progress.
        precondition(end - origin! < 10, "Paired fixture render clock stalled")
        while origin! + Double(chunk) / 100 < end {
            let sample = try! ProgramRecordingFixtures.audio(at: Double(chunk) / 100,
                timestampBase: origin!, constantTone: true)
            writer.appendAudio(sample)
            chunk += 1
        }
    }
    func close() { lock.lock(); closed = true; lock.unlock() }
}

private final class CanvasOverride: @unchecked Sendable {
    private let lock = NSLock()
    private var scene: Scene?
    func publish(_ value: Scene?) { lock.lock(); scene = value; lock.unlock() }
    func snapshot() -> Scene? { lock.lock(); defer { lock.unlock() }; return scene }
}

/// Transport fixture; the production controller and mailboxes are unchanged.
private actor CanvasPublisherProbe: Publisher {
    nonisolated let events: AsyncStream<PublisherEvent>
    nonisolated let continuation: AsyncStream<PublisherEvent>.Continuation
    nonisolated let audio = CanvasAudioProbe()
    private(set) var videoPTS: [Double] = []
    init() { (events, continuation) = AsyncStream.makeStream(of: PublisherEvent.self) }
    func start(_ settings: StreamSettings) async throws { continuation.yield(.published) }
    func stop() async {}
    func pause() async {}
    func resume() async {}
    func setOutputSize(_ size: CGSize, nativeShortEdge: Int) async {}
    func appendVideo(_ sb: CMSampleBuffer) async { videoPTS.append(sb.presentationTimeStamp.seconds) }
    nonisolated func enqueueMic(_ sb: CMSampleBuffer) {}
    nonisolated func enqueueApp(_ sb: CMSampleBuffer) {}
    nonisolated func enqueueProgram(_ sb: CMSampleBuffer) { audio.receive() }
    func setMicVolume(_ volume: Double) async {}
    func setThermalCeiling(bitRateScale: Double, frameRateCap: Int) async {}
    func statsSnapshot() async -> LiveStats? { nil }
}

/// Actual production graph components, without provider-account Keychain reads.
@MainActor private final class CanvasStudio {
    let sceneStore: SceneStore
    let previewProgram: PreviewProgramModel
    let controller: StreamController
    let dispatcher: StudioCommandDispatcher
    init() {
        sceneStore = SceneStore(); previewProgram = PreviewProgramModel(selected: sceneStore.selected)
        controller = StreamController(sceneStore: sceneStore, previewProgram: previewProgram, permissions: PermissionsManager())
        dispatcher = StudioCommandDispatcher(controller: controller, sceneStore: sceneStore,
            session: SettingsSession(controller: controller), recorder: RecordingController(), previewProgram: previewProgram)
    }
}

@main @MainActor struct StudioDualCanvasHarness {
    static func check(_ value: Bool, _ message: String) throws {
        if !value { throw NSError(domain: "DualCanvasHarness", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func finish(_ session: ProgramRecordingSession) async -> ProgramRecordingSession.Result {
        await withCheckedContinuation { continuation in session.finish { continuation.resume(returning: $0) } }
    }
    static func red(_ frame: CompositedFrame, x: Double, y: Double) -> Int {
        guard let p = frame.pixelBuffer else { return -1 }
        CVPixelBufferLockBaseAddress(p, .readOnly); defer { CVPixelBufferUnlockBaseAddress(p, .readOnly) }
        let index = Int(y * Double(CVPixelBufferGetHeight(p))) * CVPixelBufferGetBytesPerRow(p) + Int(x * Double(CVPixelBufferGetWidth(p))) * 4 + 2
        return Int(CVPixelBufferGetBaseAddress(p)!.assumingMemoryBound(to: UInt8.self)[index])
    }
    static func routedClientDisconnect() async throws {
        let wide = CanvasPublisherProbe(), tall = CanvasPublisherProbe()
        var pending = [wide, tall]
        let outputs = DestinationOutputController(factory: { _ in pending.removeFirst() })
        let wideDestination = StreamDestination(name: "Wide"), tallDestination = StreamDestination(name: "Tall", canvas: .secondary)
        outputs.start(wideDestination, settings: .default); outputs.start(tallDestination, settings: .default)
        for _ in 0..<100 { if outputs.liveCount == 2 { break }; try await Task.sleep(for: .milliseconds(10)) }
        try check(outputs.liveCount == 2 && outputs.usesSecondaryCanvas, "Routed destinations failed to acknowledge")
        outputs.fanout.enqueueVideo(try ProgramRecordingFixtures.video(at: 0))
        outputs.fanout.enqueueVideo(try ProgramRecordingFixtures.video(at: 1), canvas: .secondary)
        outputs.fanout.enqueueAudio(try ProgramRecordingFixtures.audio(at: 0))
        for _ in 0..<100 {
            if await wide.videoPTS.count == 1, await tall.videoPTS.count == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let widePTS = await wide.videoPTS, tallPTS = await tall.videoPTS
        try check(widePTS == [10_000] && tallPTS == [10_001], "Publisher received the other canvas's video")
        try check(wide.audio.snapshot() == 1 && tall.audio.snapshot() == 1, "Canvases did not share the common program audio")
        tall.continuation.yield(.failed(message: "Disconnected fixture"))
        for _ in 0..<100 { if !outputs.usesSecondaryCanvas { break }; try await Task.sleep(for: .milliseconds(10)) }
        try check(outputs.states[wideDestination.id] == .live && !outputs.usesSecondaryCanvas, "Client disconnect stopped the healthy canvas")
        outputs.fanout.enqueueVideo(try ProgramRecordingFixtures.video(at: 2))
        outputs.fanout.enqueueVideo(try ProgramRecordingFixtures.video(at: 3), canvas: .secondary)
        outputs.fanout.enqueueAudio(try ProgramRecordingFixtures.audio(at: 1))
        for _ in 0..<100 { if await wide.videoPTS.count == 2 { break }; try await Task.sleep(for: .milliseconds(10)) }
        let surviving = await wide.videoPTS, disconnected = await tall.videoPTS
        try check(surviving == [10_000, 10_002] && disconnected == [10_001] && wide.audio.snapshot() == 2 && tall.audio.snapshot() == 1,
            "Disconnected route retained media demand or interrupted the survivor")
        outputs.stopAll()
    }
    static func main() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("stream-dual-canvas-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        DesktopStorage.projectDirectory = folder
        try JSONEncoder().encode([StreamDestination(name: "Budget Test", transport: .rtmp, canvas: .secondary)]).write(to: folder.appendingPathComponent("destinations.json"))
        let runtime = CanvasStudio()
        defer { runtime.sceneStore.flushPendingWrites() }
        let layer = LayerNode(name: "Red", payload: .shape(.init(fillColorHex: "#FF0000")),
            transform: .init(position: .init(x: 0, y: 0), size: .init(width: 0.5, height: 1), anchor: .topLeft))
        let secondary = SecondaryCanvasLayout(size: .init(width: 180, height: 320), placements: [layer.id:
            .init(transform: .init(position: .init(x: 0, y: 0.5), size: .init(width: 1, height: 0.5), anchor: .topLeft), isVisible: true)])
        let scene = Scene(name: "Wide + Portrait", layers: [layer], secondaryCanvas: secondary)
        try check(runtime.dispatcher.execute(.insertScene(scene)).error == nil, "Insert dual scene")
        _ = runtime.dispatcher.execute(.setDirectLiveEditing(false))
        try check(runtime.dispatcher.execute(.take).error == nil, "Take both layouts")
        let program = runtime.previewProgram.programScene
        var staged = secondary; staged.placements[layer.id]?.isVisible = false
        try check(runtime.dispatcher.execute(.setSecondaryCanvas(staged, in: scene.id)).error == nil, "Stage portrait-only visibility")
        try check(runtime.previewProgram.programScene == program && runtime.previewProgram.stagedScene?.secondaryCanvas != secondary,
            "Secondary edit leaked to Program before Take")
        try check(runtime.dispatcher.execute(.undo).error == nil && runtime.previewProgram.stagedScene?.secondaryCanvas == secondary, "Secondary geometry undo")
        try check(runtime.dispatcher.execute(.duplicateLayer(layer.id, in: scene.id)).error == nil, "Duplicate secondary layer")
        let duplicate = runtime.previewProgram.stagedScene!.layers.first { $0.id != layer.id }!
        try check(runtime.previewProgram.stagedScene?.secondaryCanvas?.placements[duplicate.id] == secondary.placements[layer.id], "Duplicated layer lost secondary geometry")
        try check(runtime.dispatcher.execute(.removeLayer(duplicate.id, in: scene.id)).error == nil &&
            runtime.previewProgram.stagedScene?.secondaryCanvas?.placements[duplicate.id] == nil, "Removed layer left stale secondary geometry")
        let copied = runtime.sceneStore.duplicateScene(scene.id)!
        try check(copied.layers[0].id != layer.id && copied.secondaryCanvas?.placements[copied.layers[0].id] == secondary.placements[layer.id], "Duplicate scene failed placement remapping")
        let data = try JSONEncoder().encode(scene)
        var map: [String:String] = [:]
        let imported = try JSONDecoder().decode(Scene.self, from: PortableShow.redact(data, remappingIDs: true, idMap: &map))
        try check(imported.layers[0].id != layer.id && imported.secondaryCanvas?.placements[imported.layers[0].id] == secondary.placements[layer.id], "Portable layout lost shared layer identity")
        var oldJSON = try JSONSerialization.jsonObject(with: data) as! [String:Any]; oldJSON["secondaryCanvas"] = nil
        try check(try JSONDecoder().decode(Scene.self, from: JSONSerialization.data(withJSONObject: oldJSON)).secondaryCanvas == nil, "Old scene schema does not decode")
        var budget = StudioEncoderReservations(); let main = UUID(), portrait = UUID(), rotation = UUID()
        try check(budget.reserve(main, encoders: 3, publishing: 0) == nil && budget.reserve(portrait, encoders: 1, publishing: 0) == nil, "Qualified total reservation rejected")
        try check(budget.reserve(rotation, encoders: 1, publishing: 0) != nil && budget.publishingError(current: 0, starting: 1) != nil && budget.recordingCount == 4,
            "Preflight exceeded four sessions or partially mutated reservations")
        budget.release(main); try check(budget.publishingError(current: 0, starting: 3) == nil, "Stopped output did not release encoder capacity")
        let layoutPlan = DestinationEncodingPlan(destinations: [.init(name: "Program"), .init(name: "Secondary", canvas: .secondary)], program: .default)
        try check(layoutPlan.compatibleGroups.count == 2 && layoutPlan.encoderSessions == 2,
            "Equal encoder settings incorrectly grouped different composed pixels")
        let reservation = UUID(); try check(runtime.controller.reserveRecordingEncoders(reservation, count: 4, canvas: .program) == nil, "Native controller reservation")
        runtime.controller.goLive(); try check(runtime.controller.activePublishingEncoderCount == 0, "Resource rejection started a partial publisher")
        let nextProfile = OutputProfile(canvasWidth: 640, canvasHeight: 360, frameRate: 30)
        runtime.controller.applyOutputProfile(nextProfile)
        try check(runtime.controller.stagedProfile != nil && runtime.controller.activeProfile != nextProfile,
            "Pending recording preflight failed to freeze output geometry")
        runtime.controller.releaseRecordingEncoders(reservation)
        try check(runtime.controller.stagedProfile == nil && runtime.controller.activeProfile == nextProfile,
            "Cancelled recording preflight failed to promote staged geometry")
        let hiddenCamera = LayerNode(name: "Secondary camera", payload: .camera(.init()), transform: .fullscreen, isVisible: false)
        let permissionScene = Scene(name: "Secondary permission", layers: [hiddenCamera], secondaryCanvas: .init(placements: [hiddenCamera.id: .init(transform: .fullscreen, isVisible: true)]))
        try check(runtime.dispatcher.execute(.insertScene(permissionScene)).error == nil, "Insert secondary-only camera scene")
        try check(runtime.dispatcher.automationCapturePermissions(for: .startStream).contains(.camera),
            "Foreground automation omitted a camera used only by the proposed secondary output")
        try await routedClientDisconnect()

        // One real PDF playback owns page state while caching each canvas's
        // fill crop. Alternating aspects must not thrash a single-aspect cache.
        let pdfURL = folder.appendingPathComponent("shared-pages.pdf")
        var pageBox = CGRect(x: 0, y: 0, width: 320, height: 180)
        let pdfContext = CGContext(pdfURL as CFURL, mediaBox: &pageBox, nil)!
        for color in [CGColor(red: 1, green: 0, blue: 0, alpha: 1), CGColor(red: 0, green: 1, blue: 0, alpha: 1)] {
            pdfContext.beginPDFPage(nil); pdfContext.setFillColor(color); pdfContext.fill(pageBox); pdfContext.endPDFPage()
        }
        pdfContext.closePDF()
        let pdfID = SourceDefinitionID(), state = PDFDeckStateStore()
        state.publish([pdfID.rawValue.uuidString: .init(page: 0, framing: .fill)])
        let playback = PDFSourcePlayback(sourceID: pdfID, payloadProvider: { .init(assetIdentifier: "fixture") },
            assetAccessProvider: { _ in ResolvedAssetAccess(url: pdfURL, needsSecurityScope: false) },
            deckStateProvider: { state.snapshot()[pdfID.rawValue.uuidString] })
        playback.load()
        var firstPage: CVPixelBuffer?
        for _ in 0..<100 {
            firstPage = playback.pullFrame(canvasSize: CGSize(width: 320, height: 180))
            if firstPage != nil { break }; try await Task.sleep(for: .milliseconds(10))
        }
        let portraitPage = playback.pullFrame(canvasSize: CGSize(width: 180, height: 320))
        try check(firstPage != nil && portraitPage != nil, "Actual PDF page was unavailable")
        try check(CVPixelBufferGetWidth(firstPage!) > CVPixelBufferGetHeight(firstPage!) && CVPixelBufferGetWidth(portraitPage!) < CVPixelBufferGetHeight(portraitPage!), "PDF fill crop ignored per-canvas aspect")
        try check(playback.pullFrame(canvasSize: CGSize(width: 320, height: 180)) === firstPage, "Alternating canvases evicted the other PDF raster")
        state.publish([pdfID.rawValue.uuidString: .init(page: 1, framing: .fill)])
        for size in [CGSize(width: 320, height: 180), CGSize(width: 180, height: 320)] {
            let page = playback.pullFrame(canvasSize: size)!
            CVPixelBufferLockBaseAddress(page, .readOnly)
            let green = CVPixelBufferGetBaseAddress(page)!.assumingMemoryBound(to: UInt8.self)[1]
            CVPixelBufferUnlockBaseAddress(page, .readOnly)
            try check(green > 240, "Shared page command did not reach both canvas rasters")
        }
        let source = SourceDefinition(id: pdfID, name: "Shared PDF", payload: .pdf(.init(assetIdentifier: "fixture")))
        let bound = LayerNode(name: "PDF", sourceID: pdfID, payload: source.payload, transform: .fullscreen)
        let pdfScene = Scene(name: "Shared", layers: [bound], secondaryCanvas: .init())
        let demand = CaptureSourceKey.demanded(layers: pdfScene.layers + pdfScene.composition(for: .secondary).layers, sources: [source])
        try check(demand == [.pdf(pdfID)], "Secondary layout created a second PDF source owner")

        let wideFrames = CanvasFrames(), tallFrames = CanvasFrames(), privacy = CanvasOverride()
        let engine = CompositionEngine(screenProvider: { nil }, cameraProvider: { nil }, sourcePayloadProvider: { [:] },
            overlayContextProvider: { .empty }, sceneRegistryProvider: { [:] }, transitionRequestProvider: { nil },
            canvasSize: CGSize(width: 320, height: 180), frameRate: 30, frameOverrideProvider: { privacy.snapshot() })
        await engine.setSecondaryOutput(canvasSize: CGSize(width: 180, height: 320))
        let wideURL = folder.appendingPathComponent("wide.mp4"), tallURL = folder.appendingPathComponent("portrait.mp4")
        var configuration = ProgramRecordingSession.Configuration(); configuration.frameRate = 30
        let wideWriter = ProgramRecordingSession(outputURL: wideURL, configuration: configuration)
        let tallWriter = ProgramRecordingSession(outputURL: tallURL, configuration: configuration)
        let wideToken = UUID(), tallToken = UUID()
        let cancelled = UUID()
        await engine.removeSink(cancelled)
        await engine.addSink(token: cancelled, canvas: .secondary) { _ in preconditionFailure("Cancelled secondary sink revived") }
        let cancelledCount = await engine.subscriberCount
        try check(cancelledCount == 0, "Secondary cancel-before-register leaked a mailbox")
        let wideFeed = CanvasRecordingFeed(frames: wideFrames, writer: wideWriter)
        let tallFeed = CanvasRecordingFeed(frames: tallFrames, writer: tallWriter)
        await engine.addSink(token: wideToken, capacity: 2) { wideFeed.receive($0) }
        await engine.addSink(token: tallToken, capacity: 2, canvas: .secondary) { tallFeed.receive($0) }
        await engine.run(scene: scene, canvasSize: CGSize(width: 320, height: 180), frameRate: 30)
        try await Task.sleep(for: .milliseconds(1100))
        for _ in 0..<30 {
            if wideFrames.snapshot().count >= 12 && tallFrames.snapshot().count >= 12 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        wideFeed.close()
        await engine.removeSink(wideToken)
        let wideResult = await finish(wideWriter)
        let remainingSinks = await engine.subscriberCount
        try check(remainingSinks == 1, "Stopping wide recording removed the other canvas's tap")
        let tallCountBefore = tallFrames.snapshot().count
        for _ in 0..<30 {
            if tallFrames.snapshot().count >= tallCountBefore + 5 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        try check(tallFrames.snapshot().count >= tallCountBefore + 5, "Stopping wide recording stopped portrait")
        await engine.stop()
        tallFeed.close()
        let tallResult = await finish(tallWriter)
        try check(wideResult.completed && tallResult.completed, "Paired recording writer failed: \(wideResult.error ?? "") / \(tallResult.error ?? "")")
        let wide = wideFrames.snapshot(), tall = tallFrames.snapshot()
        let index = Dictionary(uniqueKeysWithValues: tall.map { ($0.sequence, $0) })
        let paired = wide.compactMap { frame in index[frame.sequence].map { (frame, $0) } }
        try check(paired.count >= 10, "Too few paired native frames: \(paired.count) from wide=\(wide.count), portrait=\(tall.count)")
        try check(paired.allSatisfy { CMTimeCompare($0.0.presentationTime, $0.1.presentationTime) == 0 }, "Canvas frame clocks diverged")
        let first = paired.last!
        try check(first.0.left > 240 && first.0.right < 5, "Wide geometry pixels wrong")
        let a = first.1.top, b = first.1.bottom
        try check(max(a,b) > 240 && min(a,b) < 5, "Portrait used resized wide pixels instead of independent geometry")
        for (url, size) in [(wideURL, CGSize(width: 320, height: 180)), (tallURL, CGSize(width: 180, height: 320))] {
            try await ProgramRecordingFixtures.inspect(url, expectedDuration: nil, checkSync: false)
            let track = try await AVURLAsset(url: url).loadTracks(withMediaType: .video)[0]
            let actual = try await track.load(.naturalSize)
            try check(actual == size, "Generated recording dimensions incorrect")
        }
        try check(tallResult.progress.durationSeconds > wideResult.progress.durationSeconds + 0.1, "Recordings lacked independent duration")
        await engine.removeSink(tallToken)
        let privateWide = CanvasFrames(), privateTall = CanvasFrames(), privateWideToken = UUID(), privateTallToken = UUID()
        await engine.addSink(token: privateWideToken) { privateWide.receive($0) }
        await engine.addSink(token: privateTallToken, canvas: .secondary) { privateTall.receive($0) }
        privacy.publish(Scene(name: "Privacy sentinel", layers: [], background: .solid(colorHex: "#FFFFFF")))
        await engine.run(scene: scene, canvasSize: CGSize(width: 320, height: 180), frameRate: 30)
        for _ in 0..<100 {
            if !privateWide.snapshot().isEmpty && !privateTall.snapshot().isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        await engine.stop()
        for samples in [privateWide.snapshot(), privateTall.snapshot()] {
            let frame = samples.last
            try check(frame != nil && frame!.left > 240 && frame!.right > 240 && frame!.top > 240 && frame!.bottom > 240,
                "Secondary output ignored privacy override or emitted its original layout")
        }
        print("PASS: additive/portable/remapped dual layout, native dispatcher staging/undo, four-session atomic reservation rejection and cancelled preflight profile release, routed video/shared audio and independent client disconnect, shared PDF page ownership with cached per-canvas fill rasters, actual wide/portrait pixels with identical tick PTS, AAC/H264 decoded files and independent stop/duration, privacy override on both canvases; physical client and machine-class cadence gates remain separate")
    }
}
