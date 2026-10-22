import AppKit
import AVFoundation
import CoreMedia
import Foundation
import StreamCore

final class ISOTimeProbe: @unchecked Sendable {
    static let shared = ISOTimeProbe()
    private let lock = NSLock()
    private var events: [String: [Double]] = [:]
    private var previous: [String: Bool] = [:]
    func observe(_ key: String, time: Double, active: Bool) {
        lock.lock(); defer { lock.unlock() }
        if active && previous[key] != true { events[key, default: []].append(time) }
        previous[key] = active
    }
    func audio(_ key: String, sample: CMSampleBuffer) {
        guard let block = sample.dataBuffer else { return }
        let bytes = CMBlockBufferGetDataLength(block)
        var floats = [Float](repeating: 0, count: bytes/4)
        let status = floats.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes, destination: $0.baseAddress!) }
        guard status == noErr else { return }
        let onset = floats.firstIndex { abs($0) > 0.15 }
        observe(key, time: sample.presentationTimeStamp.seconds + Double((onset ?? 0)/2)/48000, active: onset != nil)
    }
    func video(_ key: String, sample: CMSampleBuffer) {
        guard let pixels = sample.imageBuffer else { return }
        CVPixelBufferLockBaseAddress(pixels,.readOnly)
        let light = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)[0] > 150
        CVPixelBufferUnlockBaseAddress(pixels,.readOnly)
        observe(key,time: sample.presentationTimeStamp.seconds,active: light)
    }
    func snapshot() -> [String: [Double]] { lock.lock(); defer { lock.unlock() }; return events }
}

private final class ISOInputClock: @unchecked Sendable {
    struct Value: Sendable { let origin: Double; let lease: GuestReceiveLease?; let mapping: UUID }
    private let lock = NSLock()
    private var value: Value
    init(origin: Double,lease: GuestReceiveLease?,mapping: UUID) { value = .init(origin:origin,lease:lease,mapping:mapping) }
    func update(origin: Double,lease: GuestReceiveLease?,mapping: UUID) { lock.lock(); value = .init(origin:origin,lease:lease,mapping:mapping); lock.unlock() }
    func snapshot() -> Value { lock.lock(); defer { lock.unlock() }; return value }
}

/// Only device/decoded guest inputs are synthetic. Admission, capture-demand
/// ownership, guest leases, mix clocks, rendering, encoding and files ship.
@main @MainActor struct IsolatedSustainedHarness {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw NSError(domain: "IsolatedSustained", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func wait(_ message: String, seconds: Double = 15, _ condition: () -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(seconds))
        while ContinuousClock.now < end {
            if condition() { return }; try await Task.sleep(for: .milliseconds(20))
        }
        try check(false, message)
    }
    static func pixels(_ color: UInt32, width: Int = 1280, height: Int = 720) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        try check(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &result) == noErr, "Owned source pixels could not be allocated")
        let buffer = result!; CVPixelBufferLockBaseAddress(buffer, [])
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            let row = CVPixelBufferGetBaseAddress(buffer)!.advanced(by: y * stride).assumingMemoryBound(to: UInt32.self)
            for x in 0..<width { row[x] = color }
        }
        CVPixelBufferUnlockBaseAddress(buffer, []); return buffer
    }
    static func sample(_ pixels: CVPixelBuffer, pts: CMTime) throws -> CMSampleBuffer {
        var format: CMVideoFormatDescription?, sample: CMSampleBuffer?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixels, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        try check(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixels, formatDescription: format!, sampleTiming: &timing, sampleBufferOut: &sample) == noErr, "Owned screen sample failed")
        return sample!
    }
    nonisolated static func guestPCM(pts: Double, tone: Bool) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!; buffer.frameLength = 480
        for channel in 0..<2 { for index in 0..<480 {
            buffer.floatChannelData![channel][index] = tone ? Float(sin((pts + Double(index)/48_000) * 2 * .pi * 1000)) * 0.65 : 0
        } }
        return buffer
    }
    static func pcmRMS(_ url: URL, from: Double, to: Double) throws -> Double {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let start = AVAudioFramePosition(from * file.processingFormat.sampleRate)
        let end = min(file.length, AVAudioFramePosition(to * file.processingFormat.sampleRate))
        try check(end > start, "Decoded PCM window missing")
        file.framePosition = start
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)!
        var sum = 0.0, count = 0
        while file.framePosition < end {
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(4096, end-file.framePosition)))
            for index in 0..<Int(buffer.frameLength) { let value = Double(buffer.floatChannelData![0][index]); sum += value*value; count += 1 }
        }
        return sqrt(sum / Double(count))
    }
    static func manifest(_ url: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url.appendingPathExtension("video-isolated.json"))) as! [String: Any]
    }
    static func sourceClockRegression() throws {
        let blue = try pixels(0xFF204080), white = try pixels(0xFFFFFFFF), green = try pixels(0xFF20C020)
        let frames = SourceFrameProviders(), camera = LatestCameraFrame(), screen = LatestScreenFrame()
        let cameraKey = CaptureSourceKey.camera(.init(deviceID: "owned-clock-camera"))
        let screenKey = CaptureSourceKey.screen(.init(targetIdentifier: "owned-clock-screen"))
        frames.updateKeyed(screenHolders: [screenKey: screen], cameraHolders: [cameraKey: camera])
        let cameraSource = RecordingVideoSourceFactory.make(source: .init(name: "Clock camera", payload: .camera(.init(deviceID: "owned-clock-camera"))), key: cameraKey, frames: frames)
        let screenSource = RecordingVideoSourceFactory.make(source: .init(name: "Clock screen", payload: .screen(.init(targetIdentifier: "owned-clock-screen"))), key: screenKey, frames: frames)
        let cameraRender = cameraSource.makeRenderer(), screenRender = screenSource.makeRenderer()
        let duration = CMTime(value: 1, timescale: 30), size = CGSize(width: 320, height: 180)
        let origin = CMTime(seconds: 10000, preferredTimescale: 48000)
        func color(_ render: IsolatedVideoSource.Render, at time: CMTime, original: CMTime) throws -> (Bool, UInt8, UInt8, UInt8) {
            let frame = render(size,time,duration,1,.raw,sourceTime: original)
            guard let frame, let pixels = frame.sample?.imageBuffer else { throw CocoaError(.fileReadUnknown) }
            CVPixelBufferLockBaseAddress(pixels,.readOnly); defer { CVPixelBufferUnlockBaseAddress(pixels,.readOnly) }
            let bytes = CVPixelBufferGetBaseAddress(pixels)!.advanced(by: 90*CVPixelBufferGetBytesPerRow(pixels)+160*4).assumingMemoryBound(to: UInt8.self)
            return (frame.sourceAvailable,bytes[0],bytes[1],bytes[2])
        }
        camera.store(blue,position:.front,presentationTime:origin); screen.store(blue,presentationTime:origin)
        _ = try color(cameraRender,at:origin,original:origin); _ = try color(screenRender,at:origin,original:origin)
        let capture = origin + CMTime(value: 1,timescale: 10), delayed = origin + duration
        camera.store(white,position:.front,presentationTime:capture); screen.store(white,presentationTime:capture)
        // Another real capture arrives before the ISO worker wakes. Its
        // intermediate white receipt must survive independently of polling.
        camera.store(green,position:.front,presentationTime:origin+CMTime(value:1,timescale:5))
        let oldCamera = try color(cameraRender,at:delayed,original:delayed), oldScreen = try color(screenRender,at:delayed,original:delayed)
        try check(oldCamera.0 && oldCamera.1 > 100 && oldCamera.2 < 90 && oldScreen.1 > 100 && oldScreen.2 < 90,
            "ISO worker backdated future camera/screen pixels into a source window two frames earlier")
        let due = try color(cameraRender,at:capture,original:capture)
        try check(due.0 && due.1 > 240 && due.2 > 240, "Due original camera frame did not become available")
        let futureFrames = SourceFrameProviders(), futureCamera = LatestCameraFrame()
        futureCamera.store(white,position:.front,presentationTime:capture)
        futureFrames.updateKeyed(screenHolders:[:],cameraHolders:[cameraKey:futureCamera])
        let futureRenderer = RecordingVideoSourceFactory.make(source:.init(name:"Future-only camera",payload:.camera(.init(deviceID:"owned-clock-camera"))),key:cameraKey,frames:futureFrames).makeRenderer()
        let noHistory = try color(futureRenderer,at:delayed,original:delayed)
        try check(!noHistory.0 && noHistory.1 < 5 && noHistory.2 < 5 && noHistory.3 < 5, "Unavailable original history must become a marked black gap, never future content")
        let timelessFrames = SourceFrameProviders(), timeless = LatestScreenFrame()
        timeless.store(blue)
        timelessFrames.updateKeyed(screenHolders:[screenKey:timeless],cameraHolders:[:])
        let timelessRender = RecordingVideoSourceFactory.make(source:.init(name:"Timeless static screen",payload:.screen(.init(targetIdentifier:"owned-clock-screen"))),key:screenKey,frames:timelessFrames).makeRenderer()
        let unmapped = try color(timelessRender,at:origin,original:.invalid)
        try check(!unmapped.0 && unmapped.1 < 5 && unmapped.2 < 5 && unmapped.3 < 5, "An explicitly unmapped/pruned source interval reused a static screen")
        let staticScreen = try color(screenRender,at:origin+CMTime(seconds:10,preferredTimescale:48000),original:origin+CMTime(seconds:10,preferredTimescale:48000))
        try check(staticScreen.0 && staticScreen.1 > 240, "Static screen expired merely because no new frames were captured")
        let afterPause = origin+CMTime(seconds:2.2,preferredTimescale:48000), common = origin+CMTime(seconds:0.2,preferredTimescale:48000)
        camera.store(green,position:.front,presentationTime:afterPause)
        let resumed = try color(cameraRender,at:common,original:afterPause)
        try check(resumed.0 && resumed.2 > 150 && resumed.1 < 80, "Resumed camera lookup used pause-collapsed time instead of original host PTS")
        let guestFrames = GuestVideoFrameStore(), lease = GuestReceiveLease(slot:UUID(),peerID:UUID(),negotiation:UUID(),generation:1)
        _ = guestFrames.register(lease); guestFrames.allowProgram(true,lease:lease)
        _ = guestFrames.receive(.init(lease:lease,role:.camera,pixels:white,pts:afterPause,duration:duration,mappingGeneration:UUID(),clockQuality:.senderReportAligned),arrival:afterPause)
        let guest = RecordingVideoSourceFactory.makeGuest(source:.init(name:"Clock guest",payload:.guest(.init(slotID:lease.slot))),lease:lease,frames:guestFrames)!.makeRenderer()
        let resumedGuest = try color(guest,at:common,original:afterPause)
        try check(resumedGuest.0 && resumedGuest.1 > 240, "Resumed guest looked up the wrong original source clock")
        camera.clear()
        let disconnected = try color(cameraRender,at:afterPause,original:afterPause)
        try check(!disconnected.0 && disconnected.1 < 5, "Disconnect replayed retained source history")
        let lifetime = LatestCameraFrame()
        var firstLease: RecordingSourceHistoryLease? = lifetime.acquireRecordingHistory()
        var lastLease: RecordingSourceHistoryLease? = lifetime.acquireRecordingHistory()
        lifetime.store(blue,position:.front,presentationTime:origin)
        withExtendedLifetime(firstLease) {}; firstLease = nil
        try check(lifetime.recordingFrame(at:origin) != nil, "One ISO retired another consumer's history")
        withExtendedLifetime(lastLease) {}; lastLease = nil
        try check(lifetime.recordingFrame(at:origin) == nil && lifetime.freshest() != nil, "Last ISO lease retained history or stopped ordinary Program capture")
        camera.store(blue,position:.front,presentationTime:origin)
        let replacement = LatestCameraFrame(); replacement.store(green,position:.front,presentationTime:afterPause)
        frames.updateKeyed(screenHolders:[screenKey:screen],cameraHolders:[cameraKey:replacement])
        let swapped = try color(cameraRender,at:common,original:afterPause)
        try check(swapped.0 && swapped.2 > 150 && camera.recordingFrame(at:origin) == nil, "Same physical holder replacement leaked the old lease or lost the new frame")
        var timeline = RecordingTimeline.Snapshot()
        timeline.origin = origin; timeline.sourceStart = origin+CMTime(seconds:3,preferredTimescale:48000)
        timeline.offset = CMTime(seconds:2,preferredTimescale:48000); timeline.end = origin+CMTime(seconds:1.5,preferredTimescale:48000)
        timeline.completedIntervals = [.init(start:origin,end:origin+CMTime(seconds:1,preferredTimescale:48000),offset:.zero)]
        let pending = origin+CMTime(seconds:0.98,preferredTimescale:48000)
        try check(timeline.originalSourceTime(for:pending) == pending && timeline.originalSourceTime(for:origin+CMTime(seconds:1.2,preferredTimescale:48000)) == origin+CMTime(seconds:3.2,preferredTimescale:48000), "Pending pre-pause video inherited the resumed interval's offset")
        print("PASS: original source PTS selects historical camera/screen, rejects future-only history, retains static screen; pause mapping, shared lease cleanup and holder replacement preserve source clocks")
    }
    static func regressions(_ root: URL) async throws {
        if ProcessInfo.processInfo.environment["ISO_SUSTAINED_BASELINE"] != "1" { try sourceClockRegression() }
        let a = try pixels(0xFF204080), b = try pixels(0xFF20C020)
        OwnedCaptureBoundary.defaultID = "owned-camera-A"
        let pool = CaptureSourcePool(defaultCameraDeviceID: { OwnedCaptureBoundary.defaultID })
        pool.reconcile(demand: [.defaultCamera], settings: .default)
        let pinned = pool.recordingCaptureKey(for: .defaultCamera)
        OwnedCaptureBoundary.defaultID = "owned-camera-B"; pool.ownedRebuildCameras()
        let stamp = CMClockGetTime(CMClockGetHostTimeClock())
        pool.ownedDeliverCamera("owned-camera-A", pixels: a, pts: stamp)
        pool.ownedDeliverCamera("owned-camera-B", pixels: b, pts: stamp)
        var cameraPass = pinned == .camera(.init(deviceID: "owned-camera-A")) && pool.ownedCameraBindings == ["owned-camera-A"]
        pool.reconcile(demand: [.camera(.init(deviceID: "owned-camera-B"))], settings: .default)
        pool.reconcile(demand: [.camera(.init(deviceID: "owned-camera-B"))], settings: .default)
        pool.ownedDeliverCamera("owned-camera-B", pixels: b, pts: stamp)
        let cameraHolder = pool.frames.cameraFrame(for: .camera(.init(deviceID: "owned-camera-B")))
        cameraPass = cameraPass && cameraHolder != nil
        pool.stopAll()
        let guestFrames = GuestVideoFrameStore()
        let lease = GuestReceiveLease(slot: UUID(), peerID: UUID(), negotiation: UUID(), generation: 1)
        let mapping = UUID()
        _ = guestFrames.register(lease); guestFrames.allowProgram(true, lease: lease)
        GuestSlotRenderStore.shared.publish([GuestSlot(id: lease.slot, name: "Owned visible offline placeholder")])
        let source = RecordingVideoSourceFactory.makeGuest(source: .init(name: "Absent guest", payload: .guest(.init(slotID: lease.slot))), lease: lease, frames: guestFrames)!
        let timeline = RecordingTimeline(), status = VideoHarnessProbe()
        var config = ProgramRecordingSession.Configuration(); config.frameRate = 30
        let programURL = root.appendingPathComponent("absence-program.mp4"), isoURL = root.appendingPathComponent("absence-iso.mp4")
        let program = ProgramRecordingSession(outputURL: programURL, configuration: config, timeline: timeline)
        let iso = IsolatedVideoRecorder(outputURL: isoURL,
            selection: .init(targetID: "absent", name: "Absent associated audio", processing: .processed, resolution: .hd720, frameRate: 30, audioTargetID: "retired-guest"),
            source: source, sessionID: "owned-regression", segmentIndex: 1, programFile: programURL.lastPathComponent,
            context: .init(), budget: .current, timeline: timeline, event: status.status)
        let clock = ContinuousClock(), start = clock.now
        for index in 0..<1000 {
            let time = Double(index)/100
            try await clock.sleep(until: start.advanced(by: .seconds(time)))
            let audio = try ProgramRecordingFixtures.audio(at: time)
            program.appendAudio(audio)
            if index < 100 {
                iso.appendAudio(audio)
                let pts = CMTime(seconds: 10000+time, preferredTimescale: 48000)
                _ = guestFrames.receive(.init(lease: lease, role: .camera, pixels: a, pts: pts, duration: CMTime(value: 1, timescale: 30), mappingGeneration: mapping, clockQuality: .senderReportAligned), arrival: pts)
            } else if index == 100 { guestFrames.remove(lease) }
            if index % 3 == 0 { program.appendVideo(try ProgramRecordingFixtures.video(at: time)) }
        }
        // Independent real capture PCM is allowed to finish the last video
        // window after video admission seals, exactly as the controller does.
        let finishing = Task { await IsolatedVideoHarness.finish(program) }
        try await clock.sleep(until: start.advanced(by: .seconds(10.01)))
        program.appendAudio(try ProgramRecordingFixtures.audio(at: 10))
        let result = await finishing.value; await IsolatedVideoHarness.finish(iso)
        let progress = status.snapshot("absent")
        let receipt: [String: Any] = ["historicalBaseline": ProcessInfo.processInfo.environment["ISO_SUSTAINED_BASELINE"] == "1", "cameraIdentityPassed": cameraPass,
            "programCompleted": result.completed, "programDuration": result.progress.durationSeconds,
            "isolatedProgress": try JSONSerialization.jsonObject(with: JSONEncoder().encode(progress))]
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted,.sortedKeys]).write(to: root.appendingPathComponent("regression.json"))
        print("REGRESSION camera identity \(cameraPass), long absent associated PCM \(progress)")
        try check(cameraPass && result.completed && progress.status == "complete", "Camera physical identity or>5second associated audio absence regression")
        let file = try AVAudioFile(forReading: isoURL)
        let duration = Double(file.length)/file.processingFormat.sampleRate
        let silenceRMS = try pcmRMS(isoURL, from: 8, to: 9)
        try check(abs(duration-result.progress.durationSeconds) < 0.08 && silenceRMS < 0.00001, "Actual associated AAC long missing tail was truncated or not silent")
        let missingPixels = try await IsolatedVideoHarness.samplePixels(isoURL, at: [0.5, 8])
        try check(missingPixels[0].0 > 100 && missingPixels[1].0 < 5 && missingPixels[1].1 < 5 && missingPixels[1].2 < 5, "Processed guest ISO recorded a scene offline placeholder instead of a black source gap: \(missingPixels)")
        GuestSlotRenderStore.shared.publish([])
        print("PASS: actual camera binding plus decoded10second associated AAC, nine-second absent guest black/silence, common frontier; historical regression source retained")
        try await IsolatedVideoHarness.audioLeadingRotation(folder: root, budget: .current)
    }
    static func main() async throws {
        setbuf(stdout, nil); _ = NSApplication.shared
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let diagnostic = ProcessInfo.processInfo.environment["ISO_SUSTAINED_DIAGNOSTIC"] == "1"
        let timeProbe = ISOTimeProbe.shared
        if ProcessInfo.processInfo.environment["ISO_ENCODER_CADENCE_ONLY"] == "1" { try await SharedEncoderCadenceHarness.run(root: root); return }
        if ProcessInfo.processInfo.environment["ISO_RAW_CADENCE_ONLY"] == "1" { try await SharedEncoderCadenceHarness.raw(root: root); return }
        if ProcessInfo.processInfo.environment["ISO_SOURCE_CLOCK_ONLY"] == "1" { try sourceClockRegression(); return }
        print("Artifacts: \(root.path)")
        if ProcessInfo.processInfo.environment["ISO_SUSTAINED_REGRESSIONS_ONLY"] == "1" { try await regressions(root); return }
        let regressionRoot = root.appendingPathComponent("regressions")
        try FileManager.default.createDirectory(at: regressionRoot, withIntermediateDirectories: true)
        if !diagnostic { try await regressions(regressionRoot) }
        OwnedCaptureBoundary.defaultID = "owned-camera-A"
        print("Qualification: exact \(IsolatedVideoBudget.current.machineClass); generated physical capture and decoded guest boundaries; shipping controller/mixer/render/encoder/writers and actual RTMP. No physical camera/screen/device class claim.")
        try check(IsolatedVideoBudget.current.qualified, "This sustained test must run on the enabled Mac class")
        try check(ProgramRecordingFixtures.usesAudioFileDecoder, "This owned fixture explicitly qualifies offline AVAudioFile PCM; original AVAssetReader PCM remains separate")
        let project = root.appendingPathComponent("Project"); try DesktopStorage.prepare(project)
        let camera = SourceDefinition(name: "Owned default camera A", payload: .camera(.init()))
        var effect = SourceEffects(); effect.brightness = 0.2
        let screen = SourceDefinition(name: "Owned processed static screen", payload: .screen(.init(targetIdentifier: "owned-screen")), effectDefaults: effect)
        let scene = Scene(name: "Owned camera Program", layers: [.init(name: "Camera", sourceID: camera.id, payload: camera.payload, transform: .fullscreen)])
        try JSONEncoder().encode(SceneDocument(sources: [camera, screen], scenes: [scene], selectedID: scene.id)).write(to: project.appendingPathComponent("stream.scenes.v2.json"))
        try JSONEncoder().encode([StreamDestination]()).write(to: project.appendingPathComponent("destinations.json"))
        var settings = StreamSettings.default; settings.outputProfile = .init(canvasWidth: 1920, canvasHeight: 1080, frameRate: 30)
        settings.voicePolishEnabled = false; settings.micVolume = 1; settings.audioInputs = []
        DesktopSettingsStore().saveNonSecret(settings)
        let scenes = SceneStore(), preview = PreviewProgramModel(selected: scenes.selected), mixer = AudioMixEngine()
        let controller = StreamController(sceneStore: scenes, previewProgram: preview, permissions: PermissionsManager(), audioEngine: mixer)
        let recorder = RecordingController(defaults: GuestFixtureDefaults.value, defaultDirectory: root.appendingPathComponent("Recordings"))
        defer { controller.stopPreview(); controller.stopStream(); scenes.flushPendingWrites() }
        let health = StudioDiagnosticsMonitor(controller: controller, recorder: recorder)
        defer { health.shutdown() }
        let a = try pixels(0xFF204080), b = try pixels(0xFF20C020), white = try pixels(0xFFFFFFFF), screenPixels = try pixels(0xFF604060)
        let guestPixels = try pixels(0xFF603030)
        let lease = GuestReceiveLease(slot: UUID(), peerID: UUID(), negotiation: UUID(), generation: 1)
        // Slot identity is the lease authority, not its display text.
        let admitted = await controller.registerGuestMedia(lease, name: "Owned guest")
        try check(admitted, "Guest admission failed")
        try check(controller.setGuestMediaRouting(lease, programAllowed: true, monitorAllowed: false), "Guest routing admission failed")
        let guest = scenes.sources.first { if case .guest(let p) = $0.payload { return p.slotID == lease.slot && p.role == .camera }; return false }!
        let map = UUID()
        let receiver = Process(), log = root.appendingPathComponent("network-rtmp.log"), network = root.appendingPathComponent("network-rtmp.mp4")
        FileManager.default.createFile(atPath: log.path, contents: nil); let handle = try FileHandle(forWritingTo: log)
        defer { if receiver.isRunning { receiver.interrupt() }; try? handle.close() }
        let port = Int.random(in: 20_000...45_000)
        receiver.executableURL = try RecordingStorageNetworkHarness.receiverExecutable()
        receiver.arguments = ["-y", "-hide_banner", "-loglevel", "error", "-listen", "1", "-i", "rtmp://127.0.0.1:\(port)/live/iso", "-map", "0:v:0", "-map", "0:a:0", "-c", "copy", network.path]
        receiver.standardOutput = handle; receiver.standardError = handle; try receiver.run()
        try await wait("Owned RTMP receiver did not listen") { RecordingStorageNetworkHarness.receiverReady(receiver, transport: .rtmp, port: port) }
        let destination = StreamDestination(name: "Actual ISO qualification receiver", transport: .rtmp, videoBitrate: 6_000_000)
        controller.destinations.credentials[destination.id] = .init(endpoint: "rtmp://127.0.0.1:\(port)/live", streamKey: "iso")
        controller.destinations.draft = [destination]; try check(controller.destinations.apply(), "Destination apply failed")
        controller.capturePool.restoreScreenPermission() // Generated screen capture boundary is available.
        controller.startPreview(); controller.startDestination(destination.id)
        try await wait("Actual publisher did not acknowledge") { controller.destinationOutputs.liveCount == 1 }
        let probeTap = diagnostic ? controller.addRecordingAudioTap(targetID: "channel.mic.default", processing: .afterEffects) { timeProbe.audio("mic-output", sample: $0) } : nil
        let probeVideo = diagnostic ? controller.addFrameSink(capacity: 2) { timeProbe.video("program-video", sample: $0.sampleBuffer) } : nil
        defer {
            if let probeTap { controller.removeAudioTap(probeTap) }
            if let probeVideo { controller.removeFrameSink(probeVideo) }
        }
        var phase = 0, phaseStart = CMClockGetTime(CMClockGetHostTimeClock()).seconds, currentLease: GuestReceiveLease? = lease, currentMap = map
        let inputClock = ISOInputClock(origin:phaseStart,lease:lease,mapping:map)
        let audioInput = Task.detached(priority: .userInitiated) {
            let clock = ContinuousClock(), start = clock.now
            let origin = CMClockGetTime(CMClockGetHostTimeClock()).seconds + 0.02
            for index in 0..<30000 {
                try Task.checkCancellation()
                let pts = origin+Double(index)/100, value = inputClock.snapshot(), elapsed = pts-value.origin
                let tone = [2.0,12.0,45.0].contains { (0..<0.15).contains(elapsed-$0) }
                let sample = try ProgramRecordingFixtures.audio(at:pts,timestampBase:0,constantTone:tone,amplitude:0.6,eventSeconds:-1)
                timeProbe.audio("mic-input",sample:sample); mixer.enqueue(.microphone(deviceUID:nil),sample)
                if let current = value.lease {
                    controller.receiveGuestAudio(.init(lease:current,pcm:guestPCM(pts:pts,tone:current == lease ? tone : true),
                        pts:CMTime(seconds:pts,preferredTimescale:48000),duration:CMTime(value:480,timescale:48000),mappingGeneration:value.mapping,clockQuality:.senderReportAligned))
                }
                try await clock.sleep(until:start.advanced(by:.seconds(Double(index+1)/100)))
            }
        }
        defer { audioInput.cancel() }
        let input = Task { @MainActor in
            let clock = ContinuousClock(), start = clock.now
            let origin = CMClockGetTime(CMClockGetHostTimeClock()).seconds + 0.02
            var videoIndex = 0
            for index in 0..<30_000 {
                try Task.checkCancellation()
                let pts = origin + Double(index)/100, elapsed = pts-phaseStart
                let tone = [2.0, 12.0, 45.0].contains { (0..<0.15).contains(elapsed-$0) }
                let stamp = CMTime(seconds: pts, preferredTimescale: 48_000)
                // Real camera callbacks deliver already-captured pixels, never
                // future pixels. The PCM retains its independent20ms delivery
                // headroom; guest video selects by its original due PTS.
                let cameraPTS = CMClockGetTime(CMClockGetHostTimeClock())
                let cameraElapsed = cameraPTS.seconds-phaseStart
                let cameraFlash = [2.0, 12.0, 45.0].contains { (0..<0.15).contains(cameraElapsed-$0) }
                if index*30 >= videoIndex*100 {
                    videoIndex += 1
                    timeProbe.observe("camera-input", time: cameraPTS.seconds, active: cameraFlash)
                    let cameraDisconnected = phase == 0 && (8..<10).contains(cameraElapsed)
                    controller.capturePool.ownedDeliverCamera("owned-camera-A", pixels: cameraDisconnected ? nil : cameraFlash ? white : a, pts: cameraPTS)
                    controller.capturePool.ownedDeliverCamera("owned-camera-B", pixels: b, pts: cameraPTS)
                    let capture = controller.capturePool.screenCapture(for: .screen(.init(targetIdentifier: "owned-screen")))
                    capture.ownedDeliver(try sample(screenPixels, pts: cameraPTS))
                    if let currentLease {
                        controller.receiveGuestVideo(.init(lease: currentLease, role: .camera, pixels: tone ? white : currentLease == lease ? guestPixels : b, pts: stamp, duration: CMTime(value: 1, timescale: 30), mappingGeneration: currentMap, clockQuality: .senderReportAligned))
                    }
                }
                try await clock.sleep(until: start.advanced(by: .seconds(Double(index+1)/100)))
            }
        }
        defer { input.cancel() }
        try await wait("Generated camera never reached real pool") { controller.recordingVideoSources().contains { $0.id == "source.\(camera.id)" && $0.isAvailable } }
        var evidence: [[String: Any]] = [], identityValid = true
        for scenario in 0..<(diagnostic ? 1 : 2) {
            phase = scenario; phaseStart = CMClockGetTime(CMClockGetHostTimeClock()).seconds
            if scenario == 1 {
                if let replacement = currentLease { controller.removeGuestMedia(replacement) }; currentLease = nil
                OwnedCaptureBoundary.defaultID = "owned-camera-A"
                var original = camera; original.payload = .camera(.init(deviceID: "owned-camera-A")); scenes.updateSource(original)
            }
            inputClock.update(origin:phaseStart,lease:currentLease,mapping:currentMap)
            recorder.preferences.filenamePrefix = scenario == 0 ? "CameraGuest" : "CameraScreen"
            recorder.preferences.isolatedVideoTracks = [
                .init(targetID: "source.\(camera.id)", name: "Pinned Camera A", processing: scenario == 0 ? .raw : .processed, resolution: .fullHD1080, frameRate: 30, codec: scenario == 0 ? .h264 : .hevc, quality: .standard, audioTargetID: "channel.mic.default", audioName: "Selected microphone channel"),
                .init(targetID: "source.\(scenario == 0 ? guest.id : screen.id)", name: scenario == 0 ? "Lease-pinned Guest" : "Processed static screen", processing: .processed, resolution: .fullHD1080, frameRate: 30, codec: scenario == 0 ? .hevc : .h264, quality: .high, audioTargetID: scenario == 0 ? "source.\(guest.id)" : nil, audioName: scenario == 0 ? "Admitted guest" : nil)
            ]
            recorder.start(stream: controller, useCountdown: false)
            try await wait("Controller recorder did not start: \(recorder.lastError ?? "none")") { recorder.state == .recording && recorder.progress.durationSeconds > 0.5 }
            let program = recorder.currentOutputURL!
            try check(controller.reservedRecordingEncoderCount == 3 && controller.activePublishingEncoderCount == 1, "Actual four-encoder admission/reservation differed")
            // Fifth encoder is rejected through the shipping reservation path.
            let rejectedID = UUID()
            try check(controller.reserveRecordingEncoders(rejectedID, count: 1, canvas: .program) != nil && controller.reservedRecordingEncoderCount == 3, "Resource exhaustion changed healthy reservations")
            var changed = false, removed = false, rejoined = false
            while CMClockGetTime(CMClockGetHostTimeClock()).seconds-phaseStart < (diagnostic ? 15 : 60) {
                let elapsed = CMClockGetTime(CMClockGetHostTimeClock()).seconds-phaseStart
                if scenario == 0 && elapsed > 5 && !changed {
                    changed = true; OwnedCaptureBoundary.defaultID = "owned-camera-B"; controller.capturePool.ownedRebuildCameras()
                    identityValid = identityValid && controller.capturePool.ownedCameraBindings == ["owned-camera-A"]
                    var retargeted = camera; retargeted.payload = .camera(.init(deviceID: "owned-camera-B")); scenes.updateSource(retargeted)
                    print("TRACE bindings after rebuild: \(controller.capturePool.ownedCameraBindings)")
                    print("TRACE default changed to B and Program registry retargeted; ISO A must remain physically A")
                }
                if scenario == 0 && elapsed > 20 && !removed {
                    removed = true; currentLease = nil; controller.removeGuestMedia(lease)
                    inputClock.update(origin:phaseStart,lease:nil,mapping:currentMap)
                    print("TRACE old guest lease retired at20 seconds; associated ISO must retain marked black/silence for remaining40 seconds")
                }
                if scenario == 0 && elapsed > 25 && !rejoined {
                    rejoined = true
                    let replacement = GuestReceiveLease(slot: lease.slot, peerID: UUID(), negotiation: UUID(), generation: 2)
                    let admitted = await controller.registerGuestMedia(replacement, name: "Same slot new lease")
                    try check(admitted, "Guest rejoin failed")
                    try check(controller.setGuestMediaRouting(replacement, programAllowed: true, monitorAllowed: false), "Rejoined routing failed")
                    currentMap = UUID(); currentLease = replacement
                    inputClock.update(origin:phaseStart,lease:replacement,mapping:currentMap)
                }
                try check(recorder.state == .recording && controller.destinationOutputs.liveCount == 1, "Disconnect/exhaustion destabilized recorder or actual publisher: \(recorder.lastError ?? "none")")
                if Int(elapsed) % 10 == 0 {
                    await health.sample(controller: controller, recorder: recorder)
                    try health.snapshot.redactedExportData().write(to: root.appendingPathComponent("phase-\(scenario)-health-\(Int(elapsed)).json"), options: .atomic)
                    print("TRACE phase\(scenario) elapsed\(String(format: "%.1f", elapsed)) Program\(String(format: "%.2f", recorder.progress.durationSeconds)) ISO\(recorder.isolatedVideoProgress.map { "\($0.name):\($0.status):\($0.videoSamples)" })") }
                try await Task.sleep(for: .milliseconds(500))
            }
            await withCheckedContinuation { continuation in recorder.stop { continuation.resume() } }
            try check(recorder.lastError == nil && controller.reservedRecordingEncoderCount == 0 && controller.destinationOutputs.liveCount == 1, "Recording stop leaked resources or stopped actual network")
            let final = recorder.isolatedVideoProgress
            evidence.append(["scenario": scenario, "phaseStartSourceSeconds": phaseStart, "program": program.path, "programDuration": recorder.progress.durationSeconds,
                "isolated": try final.map { progress -> [String: Any] in
                    let url = program.deletingLastPathComponent().appendingPathComponent(progress.file)
                    return ["url": url.path, "progress": try JSONSerialization.jsonObject(with: JSONEncoder().encode(progress)), "manifest": try manifest(url)]
                }])
            try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("evidence.json"))
            print("TRACE finalized phase\(scenario): \(final)")
        }
        input.cancel(); audioInput.cancel(); controller.stopStream(); controller.stopPreview()
        try await wait("Actual publisher did not stop/drain") { controller.destinationOutputs.liveCount == 0 && controller.activePublishingEncoderCount == 0 }
        try await wait("Owned receiver did not finalize") { !receiver.isRunning }
        try check(receiver.terminationStatus == 0, "Owned receiver reported failure")
        try JSONEncoder().encode(timeProbe.snapshot()).write(to: root.appendingPathComponent("source-onsets.json"))
        if diagnostic {
            var decoded: [StorageNetworkMedia] = []
            for row in evidence {
                decoded.append(try await RecordingStorageNetworkHarness.inspect(URL(fileURLWithPath: row["program"] as! String)))
                for entry in row["isolated"] as! [[String: Any]] { decoded.append(try await RecordingStorageNetworkHarness.inspect(URL(fileURLWithPath: entry["url"] as! String))) }
            }
            try JSONEncoder().encode(decoded).write(to: root.appendingPathComponent("decoded-media.json"))
            print("DIAGNOSTIC ONLY: original source/post-FX/Program/decoded onset clocks saved; full sustained acceptance not run")
            return
        }
        try check(identityValid, "Baseline identity regression: rebuilding default capture switched selected ISO to another physical device")
        var decodedEvidence: [StorageNetworkMedia] = []
        for row in evidence {
            let expected = row["programDuration"] as! Double
            let program = URL(fileURLWithPath: row["program"] as! String)
            let programManifest = try JSONSerialization.jsonObject(with: Data(contentsOf: program.appendingPathExtension("recording.json"))) as! [String: Any]
            let media = try await RecordingStorageNetworkHarness.inspect(program); decodedEvidence.append(media)
            try check(abs(media.duration-expected) < 0.08 && media.maximumVideoStep < 0.2, "Program duration/cadence diverged")
            for entry in row["isolated"] as! [[String: Any]] {
                let url = URL(fileURLWithPath: entry["url"] as! String), m = entry["manifest"] as! [String: Any]
                let p = m["progress"] as! [String: Any], selection = m["selection"] as! [String: Any]
                try check(m["sessionID"] as? String == programManifest["sessionID"] as? String && abs((m["commonSourceStartSeconds"] as! Double)-(programManifest["sourceStartSeconds"] as! Double)) < 1.0/48000, "Manifest session/common origin diverged")
                try check(p["status"] as? String == "complete", "ISO must finish after long disconnect: \(p)")
                let asset = AVURLAsset(url: url), duration = try await asset.load(.duration).seconds
                let tracks = try await asset.loadTracks(withMediaType: .video)
                let size = try await tracks[0].load(.naturalSize)
                try check(size == CGSize(width: 1920, height: 1080) && abs(duration-expected) < 0.08, "ISO common duration/dimensions failed")
                if selection["audioTargetID"] != nil {
                    let decoded = try await RecordingStorageNetworkHarness.inspect(url); decodedEvidence.append(decoded)
                    try check(abs(decoded.audioEnd-decoded.videoEnd) < 0.08 && decoded.maximumVideoStep < 0.2, "Associated PCM/video frontier/cadence mismatch")
                    let expectedCues = selection["name"] as? String == "Lease-pinned Guest" ? 2 : 3
                    try check(decoded.flashes.count == expectedCues && decoded.tones.count == expectedCues,
                              "Every planned source cue must survive actual capture/encoding: expected\(expectedCues) \(decoded)")
                    for (flash,tone) in zip(decoded.flashes,decoded.tones) {
                        try check(abs(tone-flash) <= 0.08, "Decoded associated flash/tone sync exceeds80ms \(decoded)")
                    }
                } else { let audio = try await asset.loadTracks(withMediaType: .audio); try check(audio.isEmpty, "Video-only screen unexpectedly recorded Program audio") }
                if selection["name"] as? String == "Lease-pinned Guest" {
                    let color = try await IsolatedVideoHarness.samplePixels(url, at: [15, 30, 50])
                    try check(color[0].2 > 65 && color[1].0 < 5 && color[1].1 < 5 && color[1].2 < 5 && color[2].1 < 5, "Retired guest ISO must remain black, excluding replacement lease and scene offline graphic: \(color)")
                    let firstRMS = try pcmRMS(url, from: 30, to: 31), lastRMS = try pcmRMS(url, from: 50, to: 51)
                    try check(firstRMS < 0.00001 && lastRMS < 0.00001, "Retired guest audio was replaced or tail missing")
                    let gaps = m["gaps"] as! [[String: Any]]
                    try check(gaps.filter { $0["reason"] as? String == "associated-audio-timeline-gap" }.reduce(0.0) { $0 + ($1["durationSeconds"] as? Double ?? 0) } > 30, "Long associated audio absence was not marked")
                }
                if selection["name"] as? String == "Pinned Camera A", row["scenario"] as? Int == 0 {
                    let colors = try await IsolatedVideoHarness.samplePixels(url, at: [3, 7, 9, 15, 50])
                    try check(colors[0].0 > 100 && colors[0].1 < 90 && colors[1].0 > 100 && colors[1].1 < 90 && colors[2].0 < 5 && colors[3].0 > 100 && colors[4].1 < 90, "Pinned A ISO captured unrelated B, failed disconnect black, or failed same-A recovery: \(colors)")
                }
                if selection["name"] as? String == "Pinned Camera A", row["scenario"] as? Int == 1 {
                    let color = try await IsolatedVideoHarness.samplePixels(url, at: [3, 30, 55])[0]
                    try check(color.0 > 100 && color.1 < 90 && (p["missingVideoFrames"] as! Int) < 5, "Default/explicit physical holder handoff left camera ISO black")
                }
                if selection["name"] as? String == "Processed static screen" {
                    let color = try await IsolatedVideoHarness.samplePixels(url, at: [3, 30, 55])[0]
                    try check(color.0 > 110 && color.1 > 80 && color.2 > 60, "Source effects were absent from processed static screen")
                }
                print("DECODE PASS \(url.lastPathComponent): \(duration)s1920x1080 commonfrontier, exact identity/audio policy; drops\(p["renderDrops"] ?? "?")")
            }
        }
        let networkMedia = try await RecordingStorageNetworkHarness.inspect(network); decodedEvidence.append(networkMedia)
        try JSONEncoder().encode(decodedEvidence).write(to: root.appendingPathComponent("decoded-media.json"))
        try check(networkMedia.duration > 115 && networkMedia.maximumVideoStep < 0.2 && networkMedia.videoFrames > 3400, "Real network publication did not survive both independent recording stops/disconnects")
        try check(controller.capturePool.ownedRequestedCount == 0, "Capture demand survived all output stops")
        print("PASS: two60-second actual four-encoder1080p30 runs; camera/guest then camera/screen, mixed H264/HEVC/raw/processed, real RTMP, physical-default identity lock, source disconnect/recovery,40-second retired guest black/silence plus lease rejoin privacy, resource rejection and independent output stops. Offline AVAudioFile PCM + AVAssetReader video qualified; physical device IO and other Mac classes remain unmeasured.")
    }
}
