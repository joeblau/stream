import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import StreamCore

/// Producer boundary only: three immutable owned screen images. The generated
/// CaptureSourcePool uses these in place of permission-bearing SCK producers.
@MainActor enum FailoverOwnedSources {
    static var holders: [CaptureSourceKey: LatestScreenFrame] = [:]
    static var enabled: Set<CaptureSourceKey> = []
    static var available: Set<CaptureSourceKey> = []
    static var primary: CaptureSourceKey!
    static var independent: CaptureSourceKey!
    static var standby: CaptureSourceKey!
    static var primaryBlue = false
    static func start(_ key: CaptureSourceKey) -> LatestScreenFrame? {
        guard let holder = holders[key] else { return nil }
        enabled.insert(key)
        return holder
    }
    static func stop(_ key: CaptureSourceKey) { enabled.remove(key) }
    static func fail(_ key: CaptureSourceKey) { available.remove(key); holders[key]?.clear() }
    static func restore(_ key: CaptureSourceKey) { available.insert(key) }
}

private struct RGB: Codable, Sendable {
    let red: Int, green: Int, blue: Int
    var isRed: Bool { red > 150 && green < 65 && blue < 65 }
    var isBlue: Bool { blue > 150 && red < 65 && green < 65 }
    var isHealthy: Bool { green > 150 && red < 65 }
    var isBlank: Bool { abs(red - 96) < 20 && green < 20 && abs(blue - 96) < 20 }
    var isDark: Bool { red < 45 && green < 45 && blue < 45 }
}
private enum PaintedMode: String, Codable, Sendable {
    case red, blue, blank, offline, sceneStandby, privateSlate
    func matches(_ frame: PaintedFrame) -> Bool {
        switch self {
        case .red: return frame.left.isRed && frame.right.isHealthy
        case .blue: return frame.left.isBlue && frame.right.isHealthy
        case .blank: return frame.left.isBlank && frame.right.isHealthy
        case .offline: return frame.left.isDark && frame.leftWhite > 100 && frame.right.isHealthy
        case .sceneStandby: return frame.left.isBlue && frame.right.isBlue
        case .privateSlate: return frame.left.isDark && frame.right.isDark && frame.allWhite > 100
        }
    }
}
private struct PaintedFrame: Codable, Sendable {
    let pts: Double
    let sequence: Int64
    let left: RGB, right: RGB
    let leftWhite: Int, allWhite: Int
    static func read(_ pixels: CVPixelBuffer, pts: Double, sequence: Int64) -> Self {
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        let p = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
        let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
        let row = CVPixelBufferGetBytesPerRow(pixels)
        func rgb(_ x: Int, _ y: Int) -> RGB {
            let offset = y * row + x * 4
            return .init(red: Int(p[offset + 2]), green: Int(p[offset + 1]), blue: Int(p[offset]))
        }
        var leftWhite = 0, allWhite = 0
        for y in stride(from: 0, to: height, by: 2) {
            for x in stride(from: 0, to: width, by: 2) {
                let value = rgb(x, y)
                if min(value.red, value.green, value.blue) > 140 {
                    allWhite += 1
                    if x < width / 2 { leftWhite += 1 }
                }
            }
        }
        return .init(pts: pts, sequence: sequence,
                     // Screen layers aspect-fit into each half-canvas: the source
                     // occupies the central 180px, not the outer letterbox.
                     left: rgb(width / 4, height * 7 / 20), right: rgb(width * 3 / 4, height * 7 / 20),
                     leftWhite: leftWhite, allWhite: allWhite)
    }
}
private final class FailoverFrameProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [PaintedFrame] = []
    private var validClock = true
    func receive(_ frame: CompositedFrame) {
        guard let pixels = frame.pixelBuffer else { return }
        let value = PaintedFrame.read(pixels, pts: frame.presentationTime.seconds, sequence: frame.sequence)
        lock.lock(); defer { lock.unlock() }
        validClock = validClock && frame.presentationTime == frame.sampleBuffer.presentationTimeStamp
            && frame.frameDuration == CMTime(value: 1, timescale: 30)
            && (frames.last.map { value.pts > $0.pts && value.sequence > $0.sequence } ?? true)
        if frames.count < 4096 { frames.append(value) } else { validClock = false }
    }
    func snapshot() -> [PaintedFrame] { lock.lock(); defer { lock.unlock() }; return frames }
    func clockIsValid() -> Bool { lock.lock(); defer { lock.unlock() }; return validClock }
}
private struct PaintedPhase: Codable {
    let name: String
    let mode: PaintedMode
    let startHostSeconds: Double
    let endHostSeconds: Double
    let expectsTone: Bool
}

private final class FailoverAudioProbe: @unchecked Sendable {
    private struct Energy { let pts: Double; let sum: Double; let count: Int }
    private let lock = NSLock()
    private var values: [Energy] = []
    func receive(_ sample: CMSampleBuffer) {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return }
        let count = CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size
        var pcm = [Float](repeating: 0, count: count)
        pcm.withUnsafeMutableBytes { bytes in
            _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * 4, destination: bytes.baseAddress!)
        }
        let entry = Energy(pts: sample.presentationTimeStamp.seconds,
                           sum: pcm.reduce(0) { $0 + Double($1) * Double($1) }, count: count)
        lock.lock(); defer { lock.unlock() }
        if values.count < 2048 { values.append(entry) }
    }
    func rms(from: Double, to: Double) -> (Double, Int) {
        lock.lock(); defer { lock.unlock() }
        let selected = values.filter { $0.pts >= from && $0.pts < to }
        let count = selected.reduce(0) { $0 + $1.count }
        return (sqrt(selected.reduce(0) { $0 + $1.sum } / Double(max(1, count))), count)
    }
}

@main @MainActor struct SourceFailoverNativeHarness {
    private static let probe = FailoverFrameProbe()
    private static var phases: [PaintedPhase] = []
    static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw NSError(domain: "SourceFailoverNativeHarness", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func wait(_ message: String, until ready: () -> Bool) async throws {
        for _ in 0..<1_200 {
            if ready() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        let last = probe.snapshot().last
        print("Last actual pixels: \(String(describing: last))")
        try check(false, message)
    }
    private static func phase(_ name: String, _ mode: PaintedMode, tone: Bool = true) async throws {
        let after = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        try await wait("Shipping pixels never reached \(name)") {
            let frames = probe.snapshot().suffix(3)
            return frames.count == 3 && frames.allSatisfy { $0.pts > after && mode.matches($0) }
        }
        let start = probe.snapshot().last!.pts + 1.0 / 30
        try await Task.sleep(for: .milliseconds(550))
        let end = probe.snapshot().last!.pts
        let observed = probe.snapshot().filter { $0.pts >= start && $0.pts <= end }
        try check(observed.count >= 3 && observed.allSatisfy(mode.matches), "Actual live composition changed unexpectedly during \(name)")
        if mode != .sceneStandby && mode != .privateSlate {
            try check(Set(observed.map { $0.right.blue > 100 }).count == 2,
                      "Independent healthy source did not advance during \(name)")
        }
        phases.append(.init(name: name, mode: mode, startHostSeconds: start, endHostSeconds: end, expectsTone: tone))
        print("Painted phase \(name): source window \(start)...\(end), \(observed.count) real frames")
    }
    static func pixels(_ red: UInt8, _ green: UInt8, _ blue: UInt8) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        try check(CVPixelBufferCreate(nil, 640, 360, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess, "Owned pixels allocation failed")
        let image = buffer!
        CVPixelBufferLockBaseAddress(image, [])
        defer { CVPixelBufferUnlockBaseAddress(image, []) }
        let p = CVPixelBufferGetBaseAddress(image)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<360 { for x in 0..<640 {
            let offset = y * CVPixelBufferGetBytesPerRow(image) + x * 4
            p[offset] = blue; p[offset + 1] = green; p[offset + 2] = red; p[offset + 3] = 255
        } }
        return image
    }
    private static func pendingSourceGains() async throws {
        let mixer = AudioMixEngine(), observed = FailoverAudioProbe()
        await mixer.addTap(bus: .program, token: UUID(), capacity: 8, sink: observed.receive)
        let capture = AudioChannelID.capture(.screen(ScreenSourcePayload(target: .application,
            targetIdentifier: "owned-gain-before-capture")))
        let media = AudioChannelID.media(SourceDefinitionID())
        func pulse(_ name: String, id: AudioChannelID, lower: Double, upper: Double) async throws {
            let begin = CMClockGetTime(CMClockGetHostTimeClock()).seconds
            for _ in 0..<70 {
                let host = CMClockGetTime(CMClockGetHostTimeClock()).seconds
                let sample = try ProgramRecordingFixtures.audio(at: 0, timestampBase: host + 0.02,
                    constantTone: true, amplitude: 0.3)
                mixer.enqueue(id, sample) // Actual nonisolated original-PTS capture ingestion.
                try await Task.sleep(for: .milliseconds(10))
            }
            let end = CMClockGetTime(CMClockGetHostTimeClock()).seconds
            let (rms, count) = observed.rms(from: begin + 0.12, to: end - 0.04)
            print("Gain-before-PCM \(name): \(count) actual scalars, Program RMS \(rms)")
            try check(count > 4_800 && rms >= lower && rms <= upper,
                      "Actual pending source gain lost during \(name): RMS=\(rms)")
        }
        await mixer.run()
        // Publish binding BEFORE the capture channel or its first PCM exists.
        await mixer.applyProgramCaptureGains([capture: (volume: 0.4, isMuted: false)])
        try await pulse("capture-first-arrival", id: capture, lower: 0.06, upper: 0.11)
        await mixer.stop(); await mixer.run()
        try await pulse("capture-ring-reset", id: capture, lower: 0.06, upper: 0.11)
        let latent = AudioChannelID.capture(.screen(ScreenSourcePayload(target: .application,
            targetIdentifier: "owned-declared-not-yet-delivered")))
        let replacement = AudioChannelID.capture(.screen(ScreenSourcePayload(target: .application,
            targetIdentifier: "owned-replacement-program-capture")))
        await mixer.applyProgramCaptureGains([latent: (volume: 0.4, isMuted: false)])
        await mixer.applyProgramCaptureGains([replacement: (volume: 0.4, isMuted: false)])
        try await pulse("scene-change-before-first-old-PCM-is-silent", id: latent, lower: 0, upper: 0.000001)
        await mixer.applyProgramCaptureGains([latent: (volume: 0.4, isMuted: false)])
        await mixer.stop(); await mixer.run()
        await mixer.applyProgramCaptureGains([replacement: (volume: 0.4, isMuted: false)])
        try await pulse("scene-change-after-ring-reset-old-PCM-is-silent", id: latent, lower: 0, upper: 0.000001)
        await mixer.applyProgramCaptureGains([latent: (volume: 0.4, isMuted: false)])
        await mixer.pruneChannels(keeping: [])
        await mixer.applyProgramCaptureGains([replacement: (volume: 0.4, isMuted: false)])
        try await pulse("scene-change-after-prune-old-PCM-is-silent", id: latent, lower: 0, upper: 0.000001)
        await mixer.setChannelGain(media, volume: 0.2, isMuted: true)
        try await pulse("media-first-arrival-muted", id: media, lower: 0, upper: 0.000001)
        await mixer.stop(); await mixer.run()
        try await pulse("media-ring-reset-stays-muted", id: media, lower: 0, upper: 0.000001)
        await mixer.setChannelGain(media, volume: 0.25, isMuted: false)
        await mixer.stop(); await mixer.run()
        try await pulse("media-ring-reset-nonunity", id: media, lower: 0.035, upper: 0.07)
        await mixer.stop(); await mixer.run()
        let unbound = AudioChannelID.capture(.screen(ScreenSourcePayload(target: .application,
            targetIdentifier: "owned-unbound-capture")))
        try await pulse("unknown-capture-remains-silent", id: unbound, lower: 0, upper: 0.000001)
        await mixer.stop()
        print("PASS: actual future source PCM honors gain/mute before first buffer and after real ring resets; removed Program bindings and unbound capture stay silent")
    }
    static func main() async throws {
        setbuf(stdout, nil)
        try await pendingSourceGains()
        let root = GuestFixtureStorage.artifactRoot
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let catalog = StudioProjectCatalog(project: StudioProject(name: "Owned resilience show",
            profiles: [StudioProfile(name: "Failure pixels"), StudioProfile(name: "Retirement target")]))
        let machine = GuestFixtureStorage.machineDirectory
        try FileManager.default.createDirectory(at: machine, withIntermediateDirectories: true)
        try JSONEncoder().encode(catalog).write(to: machine.appendingPathComponent("projects.v1.json"), options: .atomic)
        let directory = machine.appendingPathComponent(StudioProjectCatalog.relativeDirectory(
            project: catalog.selectedProjectID, profile: catalog.selectedProfileID), isDirectory: true)
        for profile in catalog.projects[0].profiles {
            let ownedDirectory = machine.appendingPathComponent(StudioProjectCatalog.relativeDirectory(
                project: catalog.selectedProjectID, profile: profile.id), isDirectory: true)
            try FileManager.default.createDirectory(at: ownedDirectory, withIntermediateDirectories: true)
        }
        try DesktopStorage.prepare(directory)
        func source(_ name: String) -> SourceDefinition {
            SourceDefinition(name: name, payload: .screen(ScreenSourcePayload(target: .application,
                targetIdentifier: "owned-fixture.\(UUID().uuidString)")))
        }
        let primary = source("Primary"), independent = source("Independent healthy"), standby = source("Owned standby")
        func key(_ source: SourceDefinition) -> CaptureSourceKey {
            guard case .screen(let payload) = source.payload else { fatalError("Owned source kind") }
            return .screen(payload)
        }
        FailoverOwnedSources.primary = key(primary); FailoverOwnedSources.independent = key(independent); FailoverOwnedSources.standby = key(standby)
        for source in [primary, independent, standby] { FailoverOwnedSources.holders[key(source)] = LatestScreenFrame(); FailoverOwnedSources.restore(key(source)) }
        let left = LayerNode(name: "Primary", sourceID: primary.id, payload: primary.payload,
            transform: .init(position: .init(x: 0, y: 0), size: .init(width: 0.5, height: 1), anchor: .topLeft))
        let right = LayerNode(name: "Independent", sourceID: independent.id, payload: independent.payload,
            transform: .init(position: .init(x: 0.5, y: 0), size: .init(width: 0.5, height: 1), anchor: .topLeft))
        let scene = Scene(name: "Source failure program", layers: [left, right], background: .solid(colorHex: "#600060"))
        let backup = Scene(name: "Actual configured standby scene", layers: [LayerNode(name: "Standby", sourceID: standby.id,
            payload: standby.payload, transform: .fullscreen)])
        let document = SceneDocument(sources: [primary, independent, standby], scenes: [scene, backup], selectedID: scene.id)
        try JSONEncoder().encode(document).write(to: directory.appendingPathComponent("stream.scenes.v2.json"), options: .atomic)
        try JSONEncoder().encode([StreamDestination]()).write(to: directory.appendingPathComponent("destinations.json"), options: .atomic)
        var settings = StreamSettings.default
        settings.outputProfile = .init(canvasWidth: 640, canvasHeight: 360, frameRate: 30)
        settings.micVolume = 0; settings.audioInputs = []
        DesktopSettingsStore().saveNonSecret(settings)
        var policy = DesktopResiliencePolicy()
        // A newly demanded standby has a genuine asynchronous first frame.
        // Exercise the configured startup grace instead of latching that
        // healthy producer before its initial delivery.
        policy.failureGraceSeconds = 0.2
        policy.sourceRules = [.init(sourceID: primary.id.rawValue, mode: .freeze)]
        try JSONEncoder().encode(policy).write(to: directory.appendingPathComponent("resilience.json"), options: .atomic)
        let workspace = StudioWorkspace(root: machine)
        let runtime = workspace.runtime, controller = runtime.controller, recorder = runtime.recorder
        let red = try pixels(210, 15, 15), blue = try pixels(15, 15, 210), green = try pixels(15, 210, 15), cyan = try pixels(15, 210, 210)
        let producer = Task { @MainActor in
            while !Task.isCancelled {
                let host = CMClockGetTime(CMClockGetHostTimeClock()).seconds
                for key in FailoverOwnedSources.enabled.intersection(FailoverOwnedSources.available) {
                    let image: CVPixelBuffer
                    if key == FailoverOwnedSources.primary { image = FailoverOwnedSources.primaryBlue ? blue : red }
                    else if key == FailoverOwnedSources.standby { image = blue }
                    else { image = Int(host * 5) % 2 == 0 ? green : cyan }
                    FailoverOwnedSources.holders[key]?.store(image)
                }
                if let sample = try? ProgramRecordingFixtures.audio(at: 0, timestampBase: host + 0.02,
                    constantTone: true, amplitude: 0.3) {
                    for key in FailoverOwnedSources.enabled.intersection(FailoverOwnedSources.available) {
                        controller.capturePool.onScreenAudioSample?(key, sample)
                    }
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        defer { producer.cancel(); runtime.flush() }
        let subscription = controller.addFrameSink(capacity: 2, sink: probe.receive)
        recorder.preferences.countdownSeconds = 0
        recorder.start(stream: controller, useCountdown: false)
        try await wait("Real recorder did not start") { recorder.state == .recording }
        guard let movie = recorder.currentOutputURL else { throw CocoaError(.fileNoSuchFile) }
        try await phase("healthy", .red)
        FailoverOwnedSources.fail(key(primary))
        try await wait("Actual frame absence never latched source failure") { !controller.sourceFailoverStatus.isEmpty }
        try await phase("freeze-last-frame", .red)
        FailoverOwnedSources.primaryBlue = true; FailoverOwnedSources.restore(key(primary))
        try await phase("recovered-provider-stays-frozen-until-manual-restore", .red)
        func mode(_ value: SourceFailureMode, standbyID: UUID? = nil) {
            controller.resilience.policy.sourceRules = [.init(sourceID: primary.id.rawValue, mode: value, standbySourceID: standbyID)]
            controller.resilience.save()
        }
        mode(.blank)
        try await phase("blank-shows-project-background", .blank)
        mode(.offline)
        try await phase("visible-source-offline-card", .offline)
        FailoverOwnedSources.primaryBlue = false
        mode(.standby, standbyID: standby.id.rawValue)
        try await phase("configured-healthy-standby-source", .blue)
        FailoverOwnedSources.fail(key(standby))
        try await phase("missing-standby-source-uses-offline-card", .offline)
        mode(.standby, standbyID: UUID())
        try await phase("unknown-standby-id-uses-offline-card", .offline)
        mode(.freeze)
        FailoverOwnedSources.primaryBlue = true
        controller.restoreResilienceProgram()
        try await phase("explicit-source-restore", .blue)
        try check(controller.sourceFailoverStatus.isEmpty && recorder.currentOutputURL == movie,
                  "Restore retained failure state or changed recording session")
        FailoverOwnedSources.restore(key(standby))
        controller.resilience.policy.standbySceneID = backup.id.rawValue
        FailoverOwnedSources.fail(key(primary))
        try await wait("Shipping controller did not switch to configured standby scene") { runtime.previewProgram.programScene?.id == backup.id }
        let healthyCount = controller.capturePool.frames.deliveryCount(for: key(independent)) ?? 0
        try await phase("actual-controller-standby-scene", .sceneStandby)
        try check((controller.capturePool.frames.deliveryCount(for: key(independent)) ?? 0) > healthyCount,
                  "Standby scene stopped an independently healthy demanded source")
        FailoverOwnedSources.primaryBlue = false; FailoverOwnedSources.restore(key(primary))
        try await Task.sleep(for: .milliseconds(100))
        try check(runtime.previewProgram.programScene?.id == backup.id, "Recovery surprised operator with automatic program restore")
        controller.restoreResilienceProgram()
        try await phase("manual-standby-scene-restore", .red)
        controller.resilience.policy.standbySceneID = nil
        controller.resilience.policy.lockAction = .continueWithOfflineSlate
        controller.resilience.handle(.locked)
        controller.goLive()
        try check(controller.destinationOutputs.states.isEmpty && controller.resilience.isLocked && recorder.state == .recording,
                  "Controlled lock created publishing or stopped continue-on-slate recording")
        try await phase("actual-runtime-private-lock-slate", .privateSlate, tone: false)
        controller.resilience.handle(.unlocked)
        try await phase("unlock-does-not-restore-private-program", .privateSlate, tone: false)
        controller.restoreResilienceProgram()
        try await phase("manual-private-program-restore", .red)
        try check(probe.clockIsValid(), "Source failure/scene/privacy switches reset or retimed the actual engine clock")
        try check(controller.failoverFixtureRetainedFrames <= 3, "Source cache exceeded owned active source count")
        controller.resilience.handle(.sleep)
        try await wait("Actual sleep callback did not finalize owned recorder and release pipeline") {
            !recorder.state.isActive && !controller.failoverFixturePipelineRunning && controller.reservedRecordingEncoderCount == 0
        }
        try check(recorder.lastRecordingURL == movie && recorder.lastError == nil && recorder.progress.videoStatus == .complete
            && recorder.progress.audioStatus == .complete, "Actual lifecycle finalization failed: \(recorder.lastError ?? "unknown")")
        try check(controller.failoverFixtureRetainedFrames == 0 && controller.capturePool.activeSources.isEmpty && FailoverOwnedSources.enabled.isEmpty,
                  "Lifecycle stop retained failed frames/source producer ownership")
        let frameCount = probe.snapshot().count
        try await Task.sleep(for: .milliseconds(250))
        try check(probe.snapshot().count == frameCount, "Stopped pipeline continued rendering")
        controller.resilience.handle(.wake)
        try check(!controller.failoverFixturePipelineRunning && !recorder.state.isActive && controller.destinationOutputs.states.isEmpty,
                  "Wake unexpectedly restarted output or preview without opt-in")
        controller.removeFrameSink(subscription)
        try await decode(movie)
        try await ProgramRecordingFixtures.inspect(movie, expectedDuration: nil, checkSync: false)
        controller.resilience.policy.previewAfterWake = true
        controller.resilience.handle(.wake)
        try await wait("Opt-in wake preview did not start the actual pipeline") { controller.failoverFixturePipelineRunning && !controller.capturePool.activeSources.isEmpty }
        try check(!recorder.state.isActive && controller.destinationOutputs.states.isEmpty && controller.reservedRecordingEncoderCount == 0,
                  "Preview opt-in restarted public output or recording")
        controller.stopPreview()
        try await wait("Stopped wake preview retained pipeline") { !controller.failoverFixturePipelineRunning }
        workspace.stage(project: catalog.selectedProjectID, profile: catalog.projects[0].profiles[1].id)
        await workspace.applyPending()
        try check(workspace.runtime !== runtime && workspace.pending == nil && !workspace.isSwitching,
                  "Actual owned runtime retirement did not complete")
        try check(controller.failoverFixtureRetainedFrames == 0 && FailoverOwnedSources.enabled.isEmpty
            && controller.capturePool.activeSources.isEmpty && !controller.failoverFixturePipelineRunning,
                  "Retired runtime retained source cache, captures or render demand")
        try JSONEncoder().encode(phases).write(to: root.appendingPathComponent("painted-source-windows.json"), options: .atomic)
        try JSONEncoder().encode(probe.snapshot()).write(to: root.appendingPathComponent("original-live-frame-receipts.json"), options: .atomic)
        print("PASS: shipping source health/configuration→freeze/blank/offline/healthy+missing standby→GPU compositor→real H264/AAC decoded Program pixels; independent healthy source keeps advancing")
        print("PASS: actual configured standby scene and runtime lifecycle callbacks preserve source clock/manual restore; silent private slate, real sleep writer finalization, opt-in preview only, bounded cache/producer retirement")
        print("LIMIT: owned producer and lifecycle event injection; no physical capture/device removal, TCC revocation, screen lock, sleep/wake or provider/network qualification")
        print("Owned artifacts: \(root.path)")
    }
    static func decode(_ movie: URL) async throws {
        let journal = try JSONSerialization.jsonObject(with: Data(contentsOf: movie.appendingPathExtension("recording.json"))) as! [String: Any]
        guard let origin = journal["sourceStartSeconds"] as? Double else { throw CocoaError(.fileReadCorruptFile) }
        let asset = AVURLAsset(url: movie)
        let videos = try await asset.loadTracks(withMediaType: .video), audios = try await asset.loadTracks(withMediaType: .audio)
        try check(videos.count == 1 && audios.count == 1, "Final program lost a real video/audio track")
        let reader = try AVAssetReader(asset: asset)
        let video = AVAssetReaderTrackOutput(track: videos[0], outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        let audio = AVAssetReaderTrackOutput(track: audios[0], outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false])
        reader.add(video); reader.add(audio)
        try check(reader.startReading(), "Actual final media did not open")
        var decoded: [PaintedFrame] = []
        while let sample = video.copyNextSampleBuffer() {
            guard let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
            try check(decoded.count < 4096, "Decoded evidence exceeded its bounded frame inventory")
            decoded.append(.read(pixels, pts: origin + sample.presentationTimeStamp.seconds, sequence: Int64(decoded.count + 1)))
        }
        var energies = [Double](repeating: 0, count: phases.count), samples = [Int](repeating: 0, count: phases.count)
        while let sample = audio.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let count = CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size
            var values = [Float](repeating: 0, count: count)
            values.withUnsafeMutableBytes { p in _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * 4, destination: p.baseAddress!) }
            let start = origin + sample.presentationTimeStamp.seconds
            for (index, phase) in phases.enumerated() {
                for frame in 0..<(values.count / 2) {
                    let host = start + Double(frame) / 48_000
                    if host >= phase.startHostSeconds + 0.08 && host <= phase.endHostSeconds - 0.04 {
                        energies[index] += Double(values[frame * 2]) * Double(values[frame * 2]); samples[index] += 1
                    }
                }
            }
        }
        try check(reader.status == .completed, "Actual final video/audio decode failed: \(reader.error?.localizedDescription ?? "unknown")")
        for (index, phase) in phases.enumerated() {
            let actual = decoded.filter { $0.pts >= phase.startHostSeconds && $0.pts <= phase.endHostSeconds }
            try check(actual.count >= 3 && actual.allSatisfy(phase.mode.matches), "Encoded program lost actual \(phase.name) pixels")
            if phase.mode != .sceneStandby && phase.mode != .privateSlate {
                try check(Set(actual.map { $0.right.blue > 100 }).count == 2, "Encoded healthy independent source froze during \(phase.name)")
            }
            let rms = sqrt(energies[index] / Double(max(1, samples[index])))
            try check(samples[index] > 2_400 && (phase.expectsTone ? rms > 0.03 : rms < 0.002),
                      "Decoded Program audio routing mismatch during \(phase.name): samples=\(samples[index]), RMS=\(rms)")
            print("Decoded phase \(phase.name): \(actual.count) frames; original window \(phase.startHostSeconds - origin)...\(phase.endHostSeconds - origin); PCM RMS \(rms)")
        }
        try JSONEncoder().encode(decoded).write(to: GuestFixtureStorage.artifactRoot.appendingPathComponent("decoded-frame-receipts.json"), options: .atomic)
    }
}
