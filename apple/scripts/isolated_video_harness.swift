import AVFoundation
import CoreMedia
import Foundation
import StreamCore

final class VideoHarnessProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var statuses: [String: IsolatedVideoProgress] = [:]
    private var network = 0
    func status(_ value: IsolatedVideoProgress) { lock.lock(); statuses[value.id] = value; lock.unlock() }
    func snapshot(_ id: String) -> IsolatedVideoProgress { lock.lock(); defer { lock.unlock() }; return statuses[id]! }
    func packet() { lock.lock(); network += 1; lock.unlock() }
    func packets() -> Int { lock.lock(); defer { lock.unlock() }; return network }
}
final class VideoHarnessSpace: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64 = 2_000_000_000
    func set(_ value: Int64) { lock.lock(); self.value = value; lock.unlock() }
    func read() -> Int64 { lock.lock(); defer { lock.unlock() }; return value }
}

@main struct IsolatedVideoHarness {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).standardizedFileURL
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let measured = try await Task.detached { try RecordingVideoStorageProbe.measure(folder) }.value
        var budget = IsolatedVideoBudget.current
        budget.selectedEncoders = 2; budget.publishingEncoders = 1
        budget.estimatedDiskMegabytesPerSecond = 12; budget.measuredDiskMegabytesPerSecond = measured
        print("Mac class: \(budget.machineClass), folder \(measured) MB/s; 4 native encoders at 1080p30")
        let settings = [IsolatedVideoSelection(targetID: "camera", name: "Camera", resolution: .fullHD1080),
                        IsolatedVideoSelection(targetID: "screen", name: "Screen", resolution: .fullHD1080)]
        if budget.qualified {
            precondition(budget.rejection(programWidth: 1920, programHeight: 1080, programFPS: 30, selections: settings) == nil)
            var excess = budget; excess.publishingEncoders = 2
            precondition(excess.rejection(programWidth: 1920, programHeight: 1080, programFPS: 30, selections: settings) != nil)
            precondition(budget.rejection(programWidth: 3840, programHeight: 2160, programFPS: 30, selections: settings) != nil)
            var slow = budget; slow.measuredDiskMegabytesPerSecond = 1
            precondition(slow.rejection(programWidth: 1920, programHeight: 1080, programFPS: 30, selections: settings) != nil)
        }
        // Unqualified classes still run this qualification tool to gather
        // evidence; the application gate remains closed until reviewed.
        try await scenario(folder: folder, budget: budget, codec: .h264, quality: .standard)
        try await scenario(folder: folder, budget: budget, codec: .hevc, quality: .high)
        try await lifecycle(folder: folder, budget: budget)
        try await audioLeadingRotation(folder: folder, budget: budget)
        print("PASS: strict holders, source processing, common timing/durations, camera disconnect/recovery, unavailable guest, associated audio and independent four-encoder workload")
    }
    @MainActor static func lifecycle(folder: URL, budget: IsolatedVideoBudget) async throws {
        let directory = folder.appendingPathComponent("lifecycle")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let providers = SourceFrameProviders(), holder = LatestScreenFrame()
        let payload = ScreenSourcePayload(targetIdentifier: "lifecycle-screen"), key = CaptureSourceKey.screen(payload)
        holder.store(try pixel(bright: false))
        providers.updateKeyed(screenHolders: [key: holder], cameraHolders: [:])
        let source = RecordingVideoSourceFactory.make(source: .init(name: "Static Screen", payload: .screen(payload)), key: key, frames: providers)
        let timeline = RecordingTimeline(), probe = VideoHarnessProbe(), space = VideoHarnessSpace()
        var config = ProgramRecordingSession.Configuration(); config.frameRate = 50; config.sessionID = "lifecycle-session"
        config.context = .init(projectID: "show", profileID: "studio")
        let programURL = directory.appendingPathComponent("program-1.mp4")
        let healthyURL = directory.appendingPathComponent("healthy-1.mp4"), partialURL = directory.appendingPathComponent("storage-1.mp4")
        config.isolatedFiles = [healthyURL.lastPathComponent, partialURL.lastPathComponent]
        let program = ProgramRecordingSession(outputURL: programURL, configuration: config, timeline: timeline)
        let selection = IsolatedVideoSelection(targetID: "healthy", name: "Camera", resolution: .hd720, frameRate: 15, audioTargetID: "bus.program")
        let healthy = IsolatedVideoRecorder(outputURL: healthyURL, selection: selection, source: source,
            sessionID: config.sessionID, segmentIndex: 1, programFile: programURL.lastPathComponent, context: config.context,
            budget: budget, timeline: timeline, event: probe.status)
        let partial = IsolatedVideoRecorder(outputURL: partialURL, selection: .init(targetID: "storage", name: "Storage Probe", frameRate: 15), source: source,
            sessionID: config.sessionID, segmentIndex: 1, programFile: programURL.lastPathComponent, context: config.context,
            budget: budget, timeline: timeline, spaceProbe: { _ in space.read() }, event: probe.status)
        try await feed(program, isolated: healthy, duration: 1.2, offset: 0, probe: probe)
        program.pause(); try await Task.sleep(for: .milliseconds(30))
        let before = probe.packets()
        try await feed(program, isolated: healthy, duration: 0.3, offset: 1.2, probe: probe)
        precondition(probe.packets() > before && timeline.snapshot().paused)
        program.resume()
        try await feed(program, isolated: healthy, duration: 1.4, offset: 1.5, probe: probe)
        space.set(0)
        try await feed(program, isolated: healthy, duration: 0.7, offset: 2.9, probe: probe)
        let result = await finish(program)
        await finish(healthy); await finish(partial)
        precondition(result.completed && probe.snapshot("healthy").status == "complete")
        precondition(probe.snapshot("storage").status == "failed" && probe.snapshot("storage").error!.contains("storage"))
        let partialAsset = AVURLAsset(url: partialURL)
        let partialDuration = try await partialAsset.load(.duration).seconds
        let partialVideos = try await partialAsset.loadTracks(withMediaType: .video)
        precondition(partialDuration > 1 && partialVideos.count == 1, "Failed ISO must preserve readable media")
        let healthyDuration = try await AVURLAsset(url: healthyURL).load(.duration).seconds
        precondition(abs(healthyDuration - result.progress.durationSeconds) < 0.04)
        precondition(abs(result.progress.durationSeconds - 3.3) < 0.04, "Pause must remove the same source interval")
        let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: healthyURL.appendingPathExtension("video-isolated.json"))) as! [String: Any]
        precondition(abs((metadata["pauseOffsetSeconds"] as! Double) - 0.3) < 0.04)

        // A new segment gets a new renderer/writer and keeps the session ID.
        let nextTimeline = RecordingTimeline(), nextURL = directory.appendingPathComponent("program-2.mp4")
        let nextISOURL = directory.appendingPathComponent("healthy-2.mp4")
        config.segmentIndex = 2; config.isolatedFiles = [nextISOURL.lastPathComponent]
        let next = ProgramRecordingSession(outputURL: nextURL, configuration: config, timeline: nextTimeline)
        var videoOnly = selection; videoOnly.audioTargetID = nil
        let nextISO = IsolatedVideoRecorder(outputURL: nextISOURL, selection: videoOnly, source: source,
            sessionID: config.sessionID, segmentIndex: 2, programFile: nextURL.lastPathComponent, context: config.context,
            budget: budget, timeline: nextTimeline, event: probe.status)
        try await feed(next, isolated: nextISO, duration: 0.7, offset: 3.6, probe: probe)
        let nextResult = await finish(next); await finish(nextISO)
        precondition(nextResult.completed && probe.snapshot("healthy").status == "complete")
        let library = RecordingLibraryModel()
        await library.refresh(access: RecordingDirectoryAccess(url: directory, scoped: false), activeURLs: [nextISOURL])
        precondition(!library.entries.first { $0.url == nextISOURL }!.canExport)
        await library.refresh(access: RecordingDirectoryAccess(url: directory, scoped: false), activeURLs: [])
        let healthyEntry = library.entries.first { $0.url == healthyURL }!, nextEntry = library.entries.first { $0.url == nextISOURL }!
        let partialEntry = library.entries.first { $0.url == partialURL }!, programEntry = library.entries.first { $0.url == programURL }!
        precondition(healthyEntry.sessionID == nextEntry.sessionID && nextEntry.segmentIndex == 2 && nextEntry.context.profileID == "studio")
        precondition(healthyEntry.manifestSummary.contains("No Source Effects") && healthyEntry.manifestSummary.contains("720p"))
        precondition(partialEntry.status == "recoverable" && partialEntry.canExport && partialEntry.error != nil)
        precondition(programEntry.manifestSummary.contains("Storage Probe: failed"))
        let clip = directory.appendingPathComponent("video-only-clip.mp4")
        await library.exportClip(nextEntry, from: 0.2, to: 0.6, output: clip)
        precondition(library.error == nil, library.error ?? "Video-only clip failed")
        let clipped = AVURLAsset(url: clip)
        let clippedVideos = try await clipped.loadTracks(withMediaType: .video), clippedAudios = try await clipped.loadTracks(withMediaType: .audio)
        let clipDuration = try await clipped.load(.duration).seconds
        precondition(clippedVideos.count == 1 && clippedAudios.isEmpty && abs(clipDuration - 0.4) < 0.04)
        let decoded = try await samplePixels(clip, at: [0.1])
        precondition(decoded[0].0 < 60 && decoded[0].2 > 70)
        print("PASS: common pause interval and segment identity, independent low-storage partial preservation, ISO library manifests/active guard and decoded video-only export")
    }
    @MainActor static func audioLeadingRotation(folder: URL, budget: IsolatedVideoBudget) async throws {
        let directory = folder.appendingPathComponent("audio-leading-rotation")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let providers = SourceFrameProviders(), holder = LatestScreenFrame()
        let payload = ScreenSourcePayload(targetIdentifier: "owned-leading-screen"), key = CaptureSourceKey.screen(payload)
        holder.store(try pixel(bright: false))
        providers.updateKeyed(screenHolders: [key: holder], cameraHolders: [:])
        let source = RecordingVideoSourceFactory.make(source: .init(name: "Owned Screen", payload: .screen(payload)), key: key, frames: providers)
        let oldURL = directory.appendingPathComponent("program-old.mp4"), nextURL = directory.appendingPathComponent("program-next.mp4")
        let oldTimeline = RecordingTimeline(), nextTimeline = RecordingTimeline()
        let programRouter = ProgramRecordingRouter(), audioRouter = IsolatedRecordingRouter(), videoRouter = IsolatedVideoRouter()
        var config = ProgramRecordingSession.Configuration(); config.frameRate = 60
        let old = ProgramRecordingSession(outputURL: oldURL, configuration: config, timeline: oldTimeline)
        let next = ProgramRecordingSession(outputURL: nextURL, configuration: config, timeline: nextTimeline)
        let audioSelections: [IsolatedRecordingSelection] = [
            .init(targetID: "bus.program", name: "PCM", format: .wav),
            .init(targetID: "bus.monitor", name: "AAC", format: .m4a)]
        let oldAudio = IsolatedRecordingGroup(programURL: oldURL, selections: audioSelections, sessionID: "leading", segmentIndex: 1, context: .init(), timeline: oldTimeline, event: { _ in })
        let nextAudio = IsolatedRecordingGroup(programURL: nextURL, selections: audioSelections, sessionID: "leading", segmentIndex: 2, context: .init(), timeline: nextTimeline, event: { _ in })
        let selection = IsolatedVideoSelection(targetID: "screen", name: "Screen", resolution: .hd720, frameRate: 15, audioTargetID: "bus.program")
        let probe = VideoHarnessProbe()
        let oldVideo = IsolatedVideoGroup(programURL: oldURL, selections: [selection], sources: ["screen": source], sessionID: "leading", segmentIndex: 1, context: .init(), budget: budget, timeline: oldTimeline, event: probe.status)
        let nextVideo = IsolatedVideoGroup(programURL: nextURL, selections: [selection], sources: ["screen": source], sessionID: "leading", segmentIndex: 2, context: .init(), budget: budget, timeline: nextTimeline, event: probe.status)
        programRouter.install(old); audioRouter.install(oldAudio); videoRouter.install(oldVideo)
        func audio(_ seconds: Double) throws {
            let sample = try ProgramRecordingFixtures.audio(at: seconds)
            programRouter.appendAudio(sample)
            for selected in audioSelections { audioRouter.append(sample, targetID: selected.targetID) }
            videoRouter.appendAudio(sample, videoTargetID: "screen")
        }
        let clock = ContinuousClock(), start = clock.now
        for index in 0..<100 {
            try await clock.sleep(until: start.advanced(by: .seconds(Double(index)/100)))
            try audio(Double(index)/100)
            if index % 5 == 0 {
                for frame in 0..<3 { programRouter.appendVideo(try ProgramRecordingFixtures.video(at: Double(index)/100 + Double(frame)/60)) }
            }
        }
        // Original PCM is delivered before a delayed next image stamped1.003.
        // Program accepts its lead; active ISO files must hold their commits.
        for index in 100..<106 { try audio(Double(index)/100) }
        let deadline = clock.now.advanced(by: .seconds(3))
        while (!oldTimeline.snapshot().end.isNumeric || (oldTimeline.snapshot().end-oldTimeline.snapshot().origin).seconds < 1.0599) && clock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        precondition((oldTimeline.snapshot().end-oldTimeline.snapshot().origin).seconds >= 1.0599,
                     "Fixture did not establish actual accepted audio-leading media")
        programRouter.rotate(to: next, finishing: old)
        audioRouter.retire(oldAudio, installing: nextAudio); videoRouter.retire(oldVideo, installing: nextVideo)
        let previous = Task { await withCheckedContinuation { continuation in
            old.finish(waitingForSourceBoundary: true) { continuation.resume(returning: $0) }
        } }
        let continuingPCM = Task {
            for index in 106..<212 {
                let seconds = Double(index)/100
                try await clock.sleep(until: start.advanced(by: .seconds(seconds)))
                try audio(seconds)
            }
        }
        for frame in 0..<60 {
            let seconds = 1.003 + Double(frame)/60
            try await clock.sleep(until: start.advanced(by: .seconds(seconds)))
            programRouter.appendVideo(try ProgramRecordingFixtures.video(at: seconds))
        }
        programRouter.stop(next); audioRouter.retire(nextAudio, installing: nil); videoRouter.retire(nextVideo, installing: nil)
        let finishingNext = Task { await finish(next) }
        try await continuingPCM.value
        let oldResult = await previous.value, nextResult = await finishingNext.value
        await withCheckedContinuation { continuation in oldAudio.finish { continuation.resume() } }
        await withCheckedContinuation { continuation in oldVideo.finish { continuation.resume() } }
        await withCheckedContinuation { continuation in nextAudio.finish { continuation.resume() } }
        await withCheckedContinuation { continuation in nextVideo.finish { continuation.resume() } }
        programRouter.finished(old); programRouter.finished(next)
        audioRouter.finished(oldAudio); audioRouter.finished(nextAudio); videoRouter.finished(oldVideo); videoRouter.finished(nextVideo)
        precondition(oldResult.completed && nextResult.completed, oldResult.error ?? nextResult.error ?? "Leading rotation failed")
        for (url, duration, audioGroup, videoGroup) in [(oldURL, 1.003, oldAudio, oldVideo), (nextURL, 1.0, nextAudio, nextVideo)] {
            try await ProgramRecordingFixtures.inspect(url, expectedDuration: duration, checkSync: false)
            for name in audioGroup.files {
                let file = url.deletingLastPathComponent().appendingPathComponent(name)
                let decoded = try AVAudioFile(forReading: file)
                precondition(abs(Double(decoded.length)/48_000-duration) < 1.0/48_000,
                             "Already-committed leading PCM exceeded its final shared cut: \(name), \(decoded.length) frames")
                let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: file.appendingPathExtension("isolated.json"))) as! [String: Any]
                precondition(!(metadata["gaps"] as! [[String: Any]]).contains { $0["reason"] as? String == "missing-tail" })
            }
            for name in videoGroup.files { try await ProgramRecordingFixtures.inspect(url.deletingLastPathComponent().appendingPathComponent(name), expectedDuration: duration, checkSync: false) }
        }
        print("PASS: accepted60ms audio lead plus delayed first-next image1.003s partitions real PCM history; WAV/M4A and associated ISO video honor the shared cut and decode without fabricated tails")
    }

    static func feed(_ program: ProgramRecordingSession, isolated: IsolatedVideoRecorder, duration: Double,
                     offset: Double, probe: VideoHarnessProbe) async throws {
        let clock = ContinuousClock(), start = clock.now
        for index in 0..<Int(duration * 100) {
            let time = Double(index) / 100
            try await clock.sleep(until: start.advanced(by: .seconds(time)))
            let audio = try ProgramRecordingFixtures.audio(at: offset + time)
            program.appendAudio(audio); isolated.appendAudio(audio)
            if index % 2 == 0 { program.appendVideo(try ProgramRecordingFixtures.video(at: offset + time)) }
            probe.packet()
        }
    }
    static func finish(_ writer: ProgramRecordingSession) async -> ProgramRecordingSession.Result {
        await withCheckedContinuation { continuation in writer.finish { continuation.resume(returning: $0) } }
    }
    static func finish(_ writer: IsolatedVideoRecorder) async {
        await withCheckedContinuation { continuation in writer.finish { continuation.resume() } }
    }
    static func pixel(bright: Bool, right: Bool = false) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, 1920, 1080, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &result) == kCVReturnSuccess, let result else { throw CocoaError(.fileReadUnknown) }
        CVPixelBufferLockBaseAddress(result, []); defer { CVPixelBufferUnlockBaseAddress(result, []) }
        let stride = CVPixelBufferGetBytesPerRow(result)
        let data = CVPixelBufferGetBaseAddress(result)!
        for y in 0..<1080 {
            let row = data.advanced(by: y * stride).assumingMemoryBound(to: UInt32.self)
            for x in 0..<1920 {
                let value: UInt32 = bright ? 0xFFFFFFFF : x < 960 ? 0xFF604020 : 0xFF203C60
                row[x] = right ? value ^ 0x00202020 : value
            }
        }
        return result
    }
    @MainActor static func scenario(folder: URL, budget: IsolatedVideoBudget, codec: RecordingCodec, quality: RecordingQuality) async throws {
        let directory = folder.appendingPathComponent(codec.rawValue)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let providers = SourceFrameProviders()
        let cameraPayload = CameraSourcePayload(deviceID: "qualified-camera")
        let screenPayload = ScreenSourcePayload(targetIdentifier: "qualified-screen")
        let cameraKey = CaptureSourceKey.camera(cameraPayload), screenKey = CaptureSourceKey.screen(screenPayload)
        let cameraHolder = LatestCameraFrame(), unrelatedDefault = LatestCameraFrame(), screenHolder = LatestScreenFrame()
        let normal = try pixel(bright: false), flash = try pixel(bright: true), screen = try pixel(bright: false, right: true)
        unrelatedDefault.store(flash, position: .front)
        cameraHolder.store(normal, position: .front); screenHolder.store(screen)
        providers.update(screenHolders: [screenHolder], cameraHolders: [unrelatedDefault, cameraHolder])
        providers.updateKeyed(screenHolders: [screenKey: screenHolder], cameraHolders: [cameraKey: cameraHolder, .defaultCamera: unrelatedDefault])
        let cameraSource = SourceDefinition(name: "Isolated Camera", payload: .camera(cameraPayload))
        var effects = SourceEffects(); effects.brightness = 0.2
        let screenSource = SourceDefinition(name: "Processed Screen", payload: .screen(screenPayload), effectDefaults: effects)
        SourceEffectsStore.shared.publish([cameraSource, screenSource])
        let scene = Scene(name: "Program", layers: [LayerNode(name: "Camera", sourceID: cameraSource.id,
            payload: cameraSource.payload, transform: .fullscreen)])
        let engine = CompositionEngine(screenProvider: { providers.screenFrame(for: screenKey) },
            cameraProvider: { providers.cameraFrame(for: cameraKey) },
            frameLookup: SourceFrameLookup(camera: { providers.cameraFrame(for: $0) }, screen: { providers.screenFrame(for: $0) }),
            sourcePayloadProvider: { [cameraSource.id: cameraSource.payload] }, overlayContextProvider: { .empty },
            transitionRequestProvider: { nil }, annotationProvider: { .empty }, canvasSize: CGSize(width: 1920, height: 1080), frameRate: 30)
        let timeline = RecordingTimeline(), probe = VideoHarnessProbe()
        var config = ProgramRecordingSession.Configuration(); config.frameRate = 30; config.codec = codec; config.quality = quality
        config.sessionID = "video-\(codec.rawValue)"; config.context = .init(projectID: "show", profileID: "studio")
        let programURL = directory.appendingPathComponent("program.mp4"), networkURL = directory.appendingPathComponent("network-consumer.mp4")
        let program = ProgramRecordingSession(outputURL: programURL, configuration: config, timeline: timeline)
        let network = ProgramRecordingSession(outputURL: networkURL, configuration: config)
        let rawURL = directory.appendingPathComponent("camera-raw.mp4"), processedURL = directory.appendingPathComponent("screen-processed.mp4")
        let rawSelection = IsolatedVideoSelection(targetID: "camera", name: "Raw Camera", processing: .raw, resolution: .fullHD1080,
            frameRate: 30, codec: codec, quality: quality, audioTargetID: "bus.program", audioName: "Program Bus")
        let postSelection = IsolatedVideoSelection(targetID: "screen", name: "Processed Screen", processing: .processed, resolution: .fullHD1080,
            frameRate: 30, codec: codec, quality: quality)
        let raw = IsolatedVideoRecorder(outputURL: rawURL, selection: rawSelection,
            source: RecordingVideoSourceFactory.make(source: cameraSource, key: cameraKey, frames: providers),
            sessionID: config.sessionID, segmentIndex: 1, programFile: programURL.lastPathComponent, context: config.context,
            budget: budget, timeline: timeline, event: probe.status)
        let processed = IsolatedVideoRecorder(outputURL: processedURL, selection: postSelection,
            source: RecordingVideoSourceFactory.make(source: screenSource, key: screenKey, frames: providers),
            sessionID: config.sessionID, segmentIndex: 1, programFile: programURL.lastPathComponent, context: config.context,
            budget: budget, timeline: timeline, event: probe.status)
        let guest = IsolatedVideoRecorder(outputURL: directory.appendingPathComponent("guest.mp4"),
            selection: .init(targetID: "guest", name: "Unavailable Guest"), source: nil,
            sessionID: config.sessionID, segmentIndex: 1, programFile: programURL.lastPathComponent, context: config.context,
            budget: budget, timeline: timeline,
            unavailableReason: "Guest video capture is not implemented; no other source was substituted.", event: probe.status)
        await engine.addSink(token: UUID(), capacity: 8) { program.appendVideo($0.sampleBuffer) }
        await engine.addSink(token: UUID(), capacity: 8) { network.appendVideo($0.sampleBuffer); probe.packet() }
        await engine.run(scene: scene, canvasSize: CGSize(width: 1920, height: 1080), frameRate: 30)
        let base = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        let clock = ContinuousClock(), start = clock.now
        for index in 0..<700 {
            let seconds = Double(index) / 100
            try await clock.sleep(until: start.advanced(by: .seconds(seconds)))
            if (2..<3).contains(seconds) { cameraHolder.clear() }
            else { cameraHolder.store((0.5..<0.6).contains(seconds) ? flash : normal, position: .front) }
            // The screen holder is deliberately static for all seven seconds.
            let audio = try ProgramRecordingFixtures.audio(at: seconds, timestampBase: base)
            program.appendAudio(audio); network.appendAudio(audio); raw.appendAudio(audio)
        }
        await engine.stop()
        let finishingProgram = Task { await finish(program) }, finishingNetwork = Task { await finish(network) }
        // The independent PCM source continues after video is sealed, as the
        // shipping recorder's retained audio tap does. Keep original PTS/data.
        for index in 700..<710 {
            let seconds = Double(index) / 100
            try await clock.sleep(until: start.advanced(by: .seconds(seconds)))
            let audio = try ProgramRecordingFixtures.audio(at: seconds, timestampBase: base)
            program.appendAudio(audio); network.appendAudio(audio); raw.appendAudio(audio)
        }
        let programResult = await finishingProgram.value, networkResult = await finishingNetwork.value
        await finish(raw); await finish(processed); await finish(guest)
        precondition(programResult.completed && networkResult.completed, "Program/other consumer failed")
        precondition(probe.snapshot("camera").status == "complete", probe.snapshot("camera").error ?? "Raw camera failed")
        precondition(probe.snapshot("screen").status == "complete", probe.snapshot("screen").error ?? "Processed screen failed")
        precondition(probe.snapshot("guest").status == "failed" && probe.snapshot("guest").error!.contains("Guest"))
        precondition(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("guest.mp4").path))
        precondition(probe.packets() >= 200, "Unrelated consumer must continue through disconnect")
        precondition(probe.snapshot("camera").missingVideoFrames >= 20 && probe.snapshot("screen").missingVideoFrames == 0)
        for (url, audioCount) in [(rawURL, 1), (processedURL, 0)] {
            let asset = AVURLAsset(url: url)
            let videos = try await asset.loadTracks(withMediaType: .video), audios = try await asset.loadTracks(withMediaType: .audio)
            let duration = try await asset.load(.duration).seconds
            precondition(videos.count == 1 && audios.count == audioCount)
            precondition(abs(duration - programResult.progress.durationSeconds) < 0.04, "ISO/program duration mismatch \(duration)")
            let formats = try await videos[0].load(.formatDescriptions)
            let dimensions = CMVideoFormatDescriptionGetDimensions(formats[0])
            precondition(dimensions.width == 1920 && dimensions.height == 1080)
            let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: url.appendingPathExtension("video-isolated.json"))) as! [String: Any]
            precondition(metadata["commonSourceStartSeconds"] as? Double == programResult.progress.sessionStartSourceSeconds)
            precondition((metadata["context"] as? [String: Any])?["profileID"] as? String == "studio")
        }
        let decodedRaw = try await samplePixels(rawURL, at: [0.2, 2.2, 3.3])
        precondition(decodedRaw[0].0 < 60 && decodedRaw[0].2 > 70, "Raw source must remain unmirrored/without source effects: \(decodedRaw)")
        precondition(decodedRaw[1].0 < 5 && decodedRaw[1].1 < 5 && decodedRaw[1].2 < 5, "Disconnected source must be black, never unrelated default pixels")
        precondition(decodedRaw[2].0 > 15 && decodedRaw[2].2 > 70, "Same source must recover")
        let decodedScreen = try await samplePixels(processedURL, at: [0.2, 2.2, 6.2])
        FileHandle.standardOutput.write(Data("Decoded BGRA: raw \(decodedRaw), processed \(decodedScreen)\n".utf8))
        // Screen fixture's left BGRA is (0, 96, 64). Brightness +0.2 adds
        // about 51 per channel; allow the native codec's color conversion.
        precondition(decodedScreen.allSatisfy { (40...65).contains($0.0) && $0.1 > 135 && $0.2 > 100 },
            "Source-default brightness must be applied: \(decodedScreen)")
        try await ProgramRecordingFixtures.inspect(rawURL, expectedDuration: nil, checkSync: true)
        print("PASS: \(codec.rawValue)/\(quality.rawValue), four native1080p30 encoders, common duration \(programResult.progress.durationSeconds)s, camera gaps \(probe.snapshot("camera").missingVideoFrames), source/encoder drops \(probe.snapshot("camera").renderDrops)/\(probe.snapshot("screen").renderDrops)")
    }
    static func samplePixels(_ url: URL, at times: [Double]) async throws -> [(UInt8, UInt8, UInt8)] {
        let asset = AVURLAsset(url: url)
        let video = try await asset.loadTracks(withMediaType: .video)[0]
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: video,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output); precondition(reader.startReading())
        var result: [(UInt8, UInt8, UInt8)] = []
        while let sample = output.copyNextSampleBuffer() {
            guard result.count < times.count, sample.presentationTimeStamp.seconds >= times[result.count] - 0.001,
                  let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
            CVPixelBufferLockBaseAddress(pixels, .readOnly)
            let offset = (CVPixelBufferGetHeight(pixels) / 2) * CVPixelBufferGetBytesPerRow(pixels) + 20 * 4
            let bytes = CVPixelBufferGetBaseAddress(pixels)!.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
            result.append((bytes[0], bytes[1], bytes[2]))
            CVPixelBufferUnlockBaseAddress(pixels, .readOnly)
        }
        precondition(result.count == times.count && reader.status == .completed)
        return result
    }
}
