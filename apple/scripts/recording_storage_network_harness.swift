import AVFoundation
import CoreMedia
import Foundation
import StreamCore

/// Capture is the sole generated media boundary. Every sample keeps its
/// independent host-clock PTS through the shipping mixer and output routes.
private final class StorageNetworkCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var tone = false
    private var clockSourcesActive = true
    func setClockSourcesActive(_ value: Bool) { lock.lock(); clockSourcesActive = value; lock.unlock() }
    func hasClockSources() -> Bool { lock.lock(); defer { lock.unlock() }; return clockSourcesActive }
    private var flashes: [Double] = []
    private var sounds: [Double] = []
    private var previousLight = false
    private var previousSound = false
    private var videos = 0
    func setTone(_ value: Bool) { lock.lock(); tone = value; lock.unlock() }
    func hasTone() -> Bool { lock.lock(); defer { lock.unlock() }; return tone }
    func observeVideo(_ sample: CMSampleBuffer) {
        guard let pixels = sample.imageBuffer else { return }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        let bright = CVPixelBufferGetBaseAddress(pixels)?.assumingMemoryBound(to: UInt8.self)[0] ?? 0
        CVPixelBufferUnlockBaseAddress(pixels, .readOnly)
        lock.lock(); defer { lock.unlock() }
        videos += 1
        let light = bright > 150
        if light && !previousLight { flashes.append(sample.presentationTimeStamp.seconds) }
        previousLight = light
    }
    func observeAudio(_ sample: CMSampleBuffer) {
        guard let block = sample.dataBuffer else { return }
        let bytes = CMBlockBufferGetDataLength(block)
        var values = [Float](repeating: 0, count: bytes / MemoryLayout<Float>.size)
        let status = values.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes, destination: $0.baseAddress!) }
        guard status == noErr else { return }
        let onset = values.firstIndex { abs($0) > 0.15 }
        lock.lock(); defer { lock.unlock() }
        if let onset, !previousSound { sounds.append(sample.presentationTimeStamp.seconds + Double(onset / 2) / 48_000) }
        previousSound = onset != nil
    }
    func snapshot() -> (flashes: [Double], sounds: [Double], videos: Int) {
        lock.lock(); defer { lock.unlock() }; return (flashes, sounds, videos)
    }
}

private struct StorageNetworkMedia: Codable {
    var name: String
    var duration: Double
    var videoStart: Double
    var videoEnd: Double
    var audioStart: Double
    var audioEnd: Double
    var videoFrames: Int
    var audioFrames: Int
    var maximumVideoStep: Double
    var flashes: [Double]
    var tones: [Double]
}

@main @MainActor struct RecordingStorageNetworkHarness {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw NSError(domain: "RecordingStorageNetwork", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func wait(_ message: String, seconds: Double = 12, until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(domain: "RecordingStorageNetwork", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
    }
    static func receiverExecutable() throws -> URL {
        let override = ProcessInfo.processInfo.environment["STREAM_FFMPEG_BIN"]
        let candidates = override.map { [$0] } ?? ["/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg", "/usr/local/opt/ffmpeg-full/bin/ffmpeg", "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
        guard let path = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw NSError(domain: "RecordingStorageNetwork", code: 77, userInfo: [NSLocalizedDescriptionKey: "UNQUALIFIED: an actual FFmpeg RTMP/SRT receiver is required"])
        }
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path); process.arguments = ["-hide_banner", "-protocols"]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        let protocols = Set(String(decoding: output, as: UTF8.self).split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) })
        try check(process.terminationStatus == 0 && protocols.contains("rtmp") && protocols.contains("srt"), "UNQUALIFIED: selected receiver must support actual RTMP and SRT")
        return URL(fileURLWithPath: path)
    }
    static func receiverReady(_ process: Process, transport: StreamCore.StreamProtocol, port: Int) -> Bool {
        guard process.isRunning else { return false }
        let probe = Process(); probe.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        probe.arguments = ["-a", "-p", String(process.processIdentifier), "-nP", "-i\(transport == .srt ? "UDP" : "TCP"):\(port)"] + (transport == .srt ? [] : ["-sTCP:LISTEN"])
        probe.standardOutput = FileHandle.nullDevice; probe.standardError = FileHandle.nullDevice
        do { try probe.run(); probe.waitUntilExit(); return probe.terminationStatus == 0 } catch { return false }
    }
    private static func inspect(_ url: URL) async throws -> StorageNetworkMedia {
        let asset = AVURLAsset(url: url)
        let videos = try await asset.loadTracks(withMediaType: .video), audios = try await asset.loadTracks(withMediaType: .audio)
        try check(videos.count == 1 && audios.count == 1, "\(url.lastPathComponent) must contain actual video and audio")
        let size = try await videos[0].load(.naturalSize)
        try check(size.width == 320 && size.height == 180, "Preview resource policy changed actual encoded Program dimensions")
        let videoRange = try await videos[0].load(.timeRange), audioRange = try await audios[0].load(.timeRange)
        let reader = try AVAssetReader(asset: asset)
        let video = AVAssetReaderTrackOutput(track: videos[0], outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        let audio = AVAssetReaderTrackOutput(track: audios[0], outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false])
        reader.add(video); reader.add(audio)
        try check(reader.startReading(), "Actual file decoder did not start")
        var frames = 0, audioFrames = 0, flashes: [Double] = [], tones: [Double] = []
        var previousLight = false, previousSound = false, lastVideo: Double?, maximumStep = 0.0
        while let sample = video.copyNextSampleBuffer() {
            frames += 1
            let pts = sample.presentationTimeStamp.seconds
            if let lastVideo { try check(pts > lastVideo, "Decoded video moved backward"); maximumStep = max(maximumStep, pts - lastVideo) }
            lastVideo = pts
            if let pixels = sample.imageBuffer {
                CVPixelBufferLockBaseAddress(pixels, .readOnly)
                let light = (CVPixelBufferGetBaseAddress(pixels)?.assumingMemoryBound(to: UInt8.self)[0] ?? 0) > 150
                CVPixelBufferUnlockBaseAddress(pixels, .readOnly)
                if light && !previousLight { flashes.append(pts) }; previousLight = light
            }
        }
        while let sample = audio.copyNextSampleBuffer() {
            audioFrames += sample.numSamples
            guard let block = sample.dataBuffer else { continue }
            let bytes = CMBlockBufferGetDataLength(block)
            var values = [Float](repeating: 0, count: bytes / 4)
            let status = values.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes, destination: $0.baseAddress!) }
            try check(status == noErr, "Decoded PCM was unavailable")
            let onset = values.firstIndex { abs($0) > 0.15 }
            if let onset, !previousSound { tones.append(sample.presentationTimeStamp.seconds + Double(onset / 2) / 48_000) }
            previousSound = onset != nil
        }
        try check(reader.status == .completed && frames > 0 && audioFrames > 0, "Actual media decoding failed: \(String(describing: reader.error))")
        return StorageNetworkMedia(name: url.lastPathComponent, duration: try await asset.load(.duration).seconds,
            videoStart: videoRange.start.seconds, videoEnd: videoRange.end.seconds, audioStart: audioRange.start.seconds,
            audioEnd: audioRange.end.seconds, videoFrames: frames, audioFrames: audioFrames, maximumVideoStep: maximumStep, flashes: flashes, tones: tones)
    }
    static func main() async throws {
        setbuf(stdout, nil)
        let validateClocks = ProcessInfo.processInfo.environment["STORAGE_NETWORK_CLOCK_VALIDATION"] == "1"
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        print("Artifacts: \(root.path)")
        let ffmpeg = try receiverExecutable()
        let project = root.appendingPathComponent("Project")
        try DesktopStorage.prepare(project)
        let graphic = LayerNode(name: "Editable cue graphic", payload: .shape(.init(fillColorHex: "#000000")), transform: .fullscreen)
        let dark = Scene(name: "Taken black", layers: [graphic], background: .solid(colorHex: "#000000"))
        var light = dark; light.name = "Taken editable graphic"
        // Edit a retained graphic rather than inserting/removing it. The
        // supported show/hide fade is not an instantaneous AV sync cue.
        light.layers[0].payload = .shape(.init(fillColorHex: "#FFFFFF"))
        try JSONEncoder().encode(SceneDocument(sources: [], scenes: [dark], selectedID: dark.id)).write(to: project.appendingPathComponent("stream.scenes.v2.json"))
        try JSONEncoder().encode([StreamDestination]()).write(to: project.appendingPathComponent("destinations.json"))
        var settings = StreamSettings.default
        settings.outputProfile = .init(canvasWidth: 320, canvasHeight: 180, frameRate: 30)
        settings.voicePolishEnabled = false; settings.micVolume = 1; settings.audioInputs = []
        DesktopSettingsStore().saveNonSecret(settings)
        let scenes = SceneStore(), preview = PreviewProgramModel(selected: scenes.selected), mixer = AudioMixEngine()
        let controller = StreamController(sceneStore: scenes, previewProgram: preview, permissions: PermissionsManager(), audioEngine: mixer)
        let recorder = RecordingController(defaults: GuestFixtureDefaults.value, defaultDirectory: root.appendingPathComponent("Recordings"))
        recorder.preferences.isolatedTracks = [.init(targetID: "bus.program", name: "Program PCM", format: .wav)]
        let health = StudioDiagnosticsMonitor(controller: controller, recorder: recorder)
        defer { health.shutdown() }
        func sampledHealth() async -> StudioDiagnosticSnapshot {
            await health.sample(controller: controller, recorder: recorder)
            return health.snapshot
        }
        let capture = StorageNetworkCapture()
        let videoTap = controller.addFrameSink(capacity: 8) { capture.observeVideo($0.sampleBuffer) }
        let audioTap = controller.addProgramAudioTap { capture.observeAudio($0) }
        defer { controller.removeFrameSink(videoTap); controller.removeAudioTap(audioTap); controller.stopPreview(); controller.stopStream(); scenes.flushPendingWrites() }

        let transports: [StreamCore.StreamProtocol] = [.rtmp, .srt]
        var receivers: [Process] = [], handles: [FileHandle] = [], destinations: [StreamDestination] = []
        defer {
            for process in receivers where process.isRunning { process.interrupt() }
            for handle in handles { try? handle.close() }
        }
        for transport in transports {
            let port = Int.random(in: 20_000...45_000)
            let receiver = Process(); receiver.executableURL = ffmpeg
            let media = root.appendingPathComponent("network-\(transport.rawValue).mp4")
            let log = root.appendingPathComponent("network-\(transport.rawValue).log")
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let handle = try FileHandle(forWritingTo: log); handles.append(handle)
            let listen = transport == .srt ? ["-i", "srt://127.0.0.1:\(port)?mode=listener&latency=50000"] : ["-listen", "1", "-i", "rtmp://127.0.0.1:\(port)/live/storage"]
            receiver.arguments = ["-y", "-hide_banner", "-loglevel", "error"] + listen + ["-map", "0:v:0", "-map", "0:a:0", "-c", "copy", media.path]
            receiver.standardOutput = handle; receiver.standardError = handle
            try receiver.run(); receivers.append(receiver)
            try await wait("Owned \(transport.rawValue) receiver did not bind", until: { receiverReady(receiver, transport: transport, port: port) })
            let destination = StreamDestination(name: "Actual local \(transport.rawValue)", transport: transport, videoBitrate: 1_000_000)
            destinations.append(destination)
            controller.destinations.credentials[destination.id] = .init(endpoint: transport == .srt ? "srt://127.0.0.1:\(port)?mode=caller&latency=50" : "rtmp://127.0.0.1:\(port)/live", streamKey: transport == .rtmp ? "storage" : "")
        }
        if ProcessInfo.processInfo.environment["STORAGE_NETWORK_SHARED_ENCODING"] == "1" { controller.destinations.sharesFixedH264AAC = true }
        controller.destinations.draft = destinations
        try check(controller.destinations.apply(), controller.destinations.errorMessage ?? "Local destinations did not save")
        controller.startPreview()
        for destination in destinations { controller.startDestination(destination.id) }
        try await wait("Actual publishers did not acknowledge: \(controller.destinationOutputs.states)", until: { controller.destinationOutputs.liveCount == 2 })
        recorder.start(stream: controller)
        // These silent generated PCM sources enter the real shipping ingest,
        // conversion and ring path, with original timestamps untouched. They
        // are not alternative telemetry counters or publisher substitutes.
        let clockIDs = ["stable", "offset", "skew", "drops", "held"].map { AudioChannelID.application(bundleID: "fixture.clock." + $0) }
        let source = Task.detached(priority: .userInitiated) {
            let clock = ContinuousClock(), start = clock.now
            // Two capture chunks of delivery headroom preserve each original
            // PCM timestamp without intentionally adding a large AV cue skew.
            let origin = CMClockGetTime(CMClockGetHostTimeClock()).seconds + 0.02
            var index = 0
            while !Task.isCancelled {
                let pts = origin + Double(index) / 100
                let sample = try ProgramRecordingFixtures.audio(at: pts, timestampBase: 0, constantTone: capture.hasTone(), eventSeconds: -1)
                mixer.enqueue(.microphone(deviceUID: nil), sample)
                if validateClocks && capture.hasClockSources() {
                    for (kind, id) in clockIDs.enumerated() {
                        if kind == 3 && index % 7 == 0 { continue }
                        if kind == 4 && (300..<310).contains(index) { continue }
                        let elapsed = Double(kind == 4 && index == 310 ? 300 : index) / 100
                        let originalPTS = origin + elapsed * (kind == 2 ? 1.01 : 1) + (kind == 1 ? 0.12 : 0)
                        mixer.enqueue(id, try ProgramRecordingFixtures.audio(at: originalPTS, timestampBase: 0, eventSeconds: -1))
                    }
                }
                index += 1
                try await clock.sleep(until: start.advanced(by: .seconds(Double(index) / 100)))
            }
        }
        defer { source.cancel() }
        try await wait("Shipping recorder did not accept real compositor/mixer tracks", until: { recorder.state == .recording && recorder.progress.durationSeconds >= 0.5 })
        print("TRACE actual publishers acknowledged; recorder accepted both tracks; encoder owners \(controller.activePublishingEncoderCount)/\(controller.reservedRecordingEncoderCount)")
        var clockEvidence: [String: StudioDiagnosticSnapshot] = [:]
        func freshEncodedObservation(_ value: AVClockSnapshot?) -> Bool {
            guard let value, value.audioSamples >= 8, value.videoSamples >= 8, value.windowSeconds >= 2,
                  let audioAge = value.audioAgeMilliseconds, let videoAge = value.videoAgeMilliseconds,
                  audioAge <= 2_000, videoAge <= 2_000,
                  let audioResidual = value.audioResidualMilliseconds, let videoResidual = value.videoResidualMilliseconds else { return false }
            if max(audioResidual, videoResidual) >= 5 {
                return value.state == .unstable && value.relativeRateMillisecondsPerSecond == nil && value.audioMinusVideoMilliseconds == nil
            }
            return [.stable, .offset, .drifting].contains(value.state) && value.relativeRateMillisecondsPerSecond != nil && value.audioMinusVideoMilliseconds != nil
        }
        func outputObservation(_ output: DestinationDiagnosticSnapshot) -> Bool {
            if controller.destinations.sharesFixedH264AAC { return freshEncodedObservation(output.encoderInputClock) && freshEncodedObservation(output.sharedEncodedClock) }
            return output.encoderInputClock?.state == .stable && output.sharedEncodedClock == nil
        }
        if validateClocks {
            try await Task.sleep(for: .seconds(4.5))
            let measured = await sampledHealth()
            clockEvidence["controlled-source-clocks"] = measured
            try check(measured.recordingState == "recording" && measured.recordingElapsedSeconds >= 3 && measured.outputs.allSatisfy { $0.state == "live" && $0.startedAt != nil }, "Canonical runtime health omitted actual acknowledged live/recording elapsed state")
            try check(measured.resourceSampleAgeMilliseconds != nil && measured.resourceCPUCapacityPercent != nil && measured.physicalFootprintBytes != nil && measured.currentResidentBytes != nil, "Actual process resource observations did not reach canonical diagnostic export")
            try check(measured.metalAllocatedBytes != nil && measured.programKernel.samples > 0 && measured.programKernel.meanMilliseconds != nil, "Actual Metal allocation/kernel observations did not reach canonical diagnostic export")
            func clock(_ index: Int) throws -> AVClockSnapshot {
                guard let value = measured.sourceAudioClocks[clockIDs[index].label] else { throw CocoaError(.fileReadUnknown) }
                print("CLOCK original \(index): \(value)")
                return value
            }
            let stable = try clock(0), offset = try clock(1), skew = try clock(2), drops = try clock(3), held = try clock(4)
            try check(stable.state == .stable && abs(stable.relativeRateMillisecondsPerSecond ?? 100) < 2, "Actual stable PCM timestamp clock was not stable")
            try check(offset.state == .offset && abs(offset.relativeRateMillisecondsPerSecond ?? 100) < 2 && abs((offset.audioMinusVideoMilliseconds ?? 0) - (stable.audioMinusVideoMilliseconds ?? 0) - 120) < 10, "Actual fixed source timestamp offset was confused with rate skew")
            try check(skew.state == .drifting && abs((skew.relativeRateMillisecondsPerSecond ?? 0) - 10) < 2, "Actual 1% source timestamp skew was not measured as 10 ms/s")
            try check(drops.state == .stable, "Dropped actual PCM callbacks fabricated rate skew")
            try check(held.state == .unstable && held.relativeRateMillisecondsPerSecond == nil, "Held actual PCM callback fabricated confident clock drift")
            if controller.destinations.sharesFixedH264AAC {
                for output in measured.outputs { print("CLOCK actual shared encoded callbacks: \(String(describing: output.sharedEncodedClock))") }
                try check(measured.outputs.allSatisfy { freshEncodedObservation($0.sharedEncodedClock) }, "Actual shared encoder callback freshness/uncertainty semantics failed")
            } else {
                try check(measured.outputs.allSatisfy { $0.sharedEncodedClock == nil }, "Default backend invented post-encode observations")
            }
            for output in measured.outputs { print("CLOCK publisher ingress: \(String(describing: output.encoderInputClock))") }
            try check(measured.programClock.state == .stable && measured.outputs.allSatisfy(outputObservation), "Actual Program/raw clocks or encoded observation freshness/uncertainty failed; decoded media health checked independently")
            let camera = LatestCameraFrame(), frame = try ProgramRecordingFixtures.video(at: CMClockGetTime(CMClockGetHostTimeClock()).seconds, timestampBase: 0)
            camera.store(frame.imageBuffer!, position: .front, presentationTime: frame.presentationTimeStamp)
            try check(camera.captureClock.snapshot().state == .noAudio, "Video-only actual camera holder invented associated audio")
            camera.clear()
            for level in [DesktopResourceBudget.PreviewLevel.reduced, .minimum] {
                let frames = capture.snapshot().videos
                controller.applyResourcePreviewBudget(level)
                try await Task.sleep(for: .milliseconds(500))
                try check(controller.previewResourceLevel == level && capture.snapshot().videos > frames + 8 && controller.destinationOutputs.liveCount == 2,
                    "Preview resource budget disturbed actual Program/publishing demand")
            }
            capture.setClockSourcesActive(false)
            try await Task.sleep(for: .seconds(2.1))
            let stale = await sampledHealth(); clockEvidence["stopped-source-clocks"] = stale
            try check(clockIDs.allSatisfy { stale.sourceAudioClocks[$0.label]?.state == .staleAudio }, "Stopped actual PCM source retained a confident current reading")
            try check(stale.programClock.state == .stable && stale.outputs.allSatisfy(outputObservation), "Stopped PCM sources disturbed healthy real output clocks")
            capture.setClockSourcesActive(true)
            try await Task.sleep(for: .milliseconds(100))
            let rejoined = await sampledHealth(); clockEvidence["rejoined-source-clocks"] = rejoined
            try check(clockIDs.allSatisfy { rejoined.sourceAudioClocks[$0.label]?.state == .warming && (rejoined.sourceAudioClocks[$0.label]?.discontinuities ?? 0) > 0 }, "Rejoined actual source did not establish a fresh observation window")
        }
        preview.stage(light)
        try await Task.sleep(for: .milliseconds(350))
        try check(capture.snapshot().flashes.isEmpty, "Staging leaked unpublished flash into Program")
        preview.revert()
        try await Task.sleep(for: .milliseconds(150))
        try check(preview.stagedScene == preview.programScene, "Revert did not restore the taken Program")
        func pulse() async throws {
            capture.setTone(true); preview.stage(light); preview.take()
            try await Task.sleep(for: .milliseconds(350))
            capture.setTone(false); preview.stage(dark); preview.take()
            try await Task.sleep(for: .milliseconds(650))
        }
        try await pulse()
        try await wait("Recorder did not pass its fragment boundary", until: { recorder.progress.durationSeconds >= 2 })
        let original = recorder.currentOutputURL!
        let moved = root.appendingPathComponent("RemovedRecordingPath")
        let failureSourceTime = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        try FileManager.default.moveItem(at: original.deletingLastPathComponent(), to: moved)
        controller.stopPreview()
        try check(!controller.isPreviewing && controller.destinationOutputs.liveCount == 2 && recorder.state.isActive, "Stopping preview disturbed active outputs")
        print("TRACE recording directory relocated during two live actual network publishers; preview stopped")
        try await wait("Recording storage loss did not finalize/release owned writers", until: { !recorder.state.isActive && recorder.activeOutputURLs.isEmpty && controller.reservedRecordingEncoderCount == 0 })
        try check(recorder.lastError?.contains("storage") == true && recorder.lastPartialRecordingURL == original, "Storage failure was not retained visibly")
        print("TRACE actual recorder failure: \(recorder.lastError ?? "missing"); audio/video states \(recorder.progress.audioStatus)/\(recorder.progress.videoStatus); recording reservations \(controller.reservedRecordingEncoderCount); live network publishers \(controller.destinationOutputs.liveCount)")
        try check(controller.destinationOutputs.liveCount == 2 && controller.activePublishingEncoderCount == (controller.destinations.sharesFixedH264AAC ? 1 : 2), "Recording cleanup stopped/replaced a healthy actual network publisher")
        if validateClocks {
            let afterFailure = await sampledHealth(); clockEvidence["storage-failure-network-healthy"] = afterFailure
            try check(afterFailure.recordingState == "failed" && afterFailure.events.contains { $0.state == "recording.failed" }, "Actual recording failure missing from persistent runtime session events")
            let beforeFailureStarts = Dictionary(uniqueKeysWithValues: (clockEvidence["controlled-source-clocks"]?.outputs ?? []).compactMap { output in output.startedAt.map { (output.id, $0) } })
            try check(afterFailure.outputs.allSatisfy { $0.startedAt == beforeFailureStarts[$0.id] }, "Unrelated recording failure reset the acknowledged live elapsed timer")
            print("CLOCK Program after recording failure: \(afterFailure.programClock)")
            for output in afterFailure.outputs { print("CLOCK output \(output.id) after recording failure: \(String(describing: output.encoderInputClock))") }
            try check(afterFailure.programClock.state == .stable && afterFailure.outputs.allSatisfy(outputObservation), "Actual storage failure disturbed real output timestamp clocks")
        }
        let framesAtCleanup = capture.snapshot().videos
        try await pulse(); try await pulse()
        try check(capture.snapshot().videos > framesAtCleanup + 40 && controller.destinationOutputs.liveCount == 2 && !controller.isPreviewing,
            "Actual program/network demand did not advance independently after recorder cleanup")
        controller.stopDestination(destinations[0].id)
        try await wait("RTMP stop acknowledgment did not complete", until: { controller.destinationOutputs.states[destinations[0].id]?.isActive != true })
        try check(controller.destinationOutputs.liveCount == 1, "Stopping RTMP stopped the independent SRT publisher")
        try await Task.sleep(for: .milliseconds(400))
        controller.stopDestination(destinations[1].id)
        try await wait("Publisher cleanup did not complete", until: { controller.destinationOutputs.activeCount == 0 && controller.activePublishingEncoderCount == 0 })
        try await wait("Actual receivers did not finalize", until: { receivers.allSatisfy { !$0.isRunning } })
        // Retain the canonical health observations even if decoded media
        // subsequently fails its independent timing/cadence qualification.
        for (phase, snapshot) in clockEvidence { try snapshot.redactedExportData().write(to: root.appendingPathComponent("clock-" + phase + ".json"), options: .atomic) }
        let snapshot = capture.snapshot()
        try check(snapshot.flashes.count == 3 && snapshot.sounds.count == 3, "Original Program did not retain exactly three taken AV cues: \(snapshot.flashes)/\(snapshot.sounds)")
        for index in 0..<3 { try check(abs(snapshot.flashes[index] - snapshot.sounds[index]) < 0.06, "Actual pre-encoder Program source cue was not synchronized") }
        let local = try await inspect(moved.appendingPathComponent(original.lastPathComponent))
        print("Media \(local.name): \(local.duration)s, \(local.videoFrames) decoded frames, flashes \(local.flashes), tones \(local.tones)")
        try check(local.flashes.count == 1 && local.tones.count == 1 && local.duration >= 2, "Failed local file lost accepted pre-failure media or gained post-cleanup cues")
        try check(abs(local.flashes[0] - local.tones[0]) < 0.08, "Failed local media AV cue drift")
        var results = [local]
        for transport in transports {
            let media = try await inspect(root.appendingPathComponent("network-\(transport.rawValue).mp4"))
            print("Media \(media.name): \(media.duration)s, \(media.videoFrames) decoded frames, max step \(media.maximumVideoStep)s, track starts \(media.videoStart)/\(media.audioStart), ends \(media.videoEnd)/\(media.audioEnd), flashes \(media.flashes), tones \(media.tones)")
            try check(media.flashes.count == 3 && media.tones.count == 3, "Actual \(transport.rawValue) lost a pre/post-failure cue: \(media.flashes)/\(media.tones)")
            try check(abs(media.videoStart - media.audioStart) < 0.08 && abs(media.videoEnd - media.audioEnd) < 0.12, "Actual network track start/end alignment failed")
            try check(media.maximumVideoStep < 0.15, "Storage failure created a decoded network cadence gap: \(media.maximumVideoStep)")
            for index in 0..<3 { try check(abs(media.flashes[index] - media.tones[index]) < 0.08, "Actual \(transport.rawValue) AV cue drift after storage failure") }
            for index in 1..<3 {
                try check(abs((media.flashes[index] - media.flashes[0]) - (snapshot.flashes[index] - snapshot.flashes[0])) < 0.08, "Actual network source cue spacing changed across storage cleanup")
            }
            results.append(media)
        }
        let library = RecordingLibraryModel()
        await library.refresh(access: RecordingDirectoryAccess(url: moved, scoped: false), activeURLs: [])
        try check(library.entries.contains { $0.url.lastPathComponent == original.lastPathComponent && $0.status == "recoverable" && $0.canExport },
            "Readable interrupted local media was not conservatively classified as recoverable")
        if validateClocks {
            print("PASS: actual original PCM timestamps distinguish stable, 120ms fixed offset, 1% rate skew, dropped and held callbacks, source stop/rejoin and video-only camera; actual Program clock stays stable, raw publisher clocks stay stable or compressed callback jitter remains explicitly uncertain, and independent real RTMP/SRT media survives recorder storage failure")
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(results).write(to: root.appendingPathComponent("decoded-media.json"), options: .atomic)
        let sourceEvidence: [String: Any] = ["sourceFlashPTS": snapshot.flashes, "sourceTonePTS": snapshot.sounds,
            "storageFailureSourcePTS": failureSourceTime, "localFailure": recorder.lastError ?? "", "localVideoState": recorder.progress.videoStatus.rawValue,
            "localAudioState": recorder.progress.audioStatus.rawValue, "recordingEncoderReservationsAfterFailure": controller.reservedRecordingEncoderCount,
            "host": ProcessInfo.processInfo.operatingSystemVersionString, "cpus": ProcessInfo.processInfo.processorCount]
        try JSONSerialization.data(withJSONObject: sourceEvidence, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("source-evidence.json"), options: .atomic)
        print("PASS: shipping StreamController compositor/mixer → simultaneous actual RTMP/SRT publishers and RecordingController; staged/Revert isolation and three taken AV cues; real recording-path loss preserves readable recoverable media, independent writer cleanup, preview stop and continued decoded network cadence/timing; independent network stops")
        print("Configuration: \(ProcessInfo.processInfo.operatingSystemVersionString); \(ProcessInfo.processInfo.processorCount) CPUs; artifacts \(root.path)")
        print("Qualification: controlled recording-directory relocation, generated capture PCM and owned localhost receivers; physical drive unplug, hardware capture and public ingest are not claimed")
    }
}
