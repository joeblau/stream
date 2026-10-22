import AppKit
import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation
import Network
import PDFKit
import Security
import StreamCore

@MainActor final class MemoryCredentials: StudioControlCredentials {
    var tokens: [UUID: String] = [:]
    var deletionError: OSStatus = errSecSuccess
    func read(_ id: UUID) -> String? { tokens[id] }
    func write(_ token: String, for id: UUID) -> OSStatus { tokens[id] = token; return errSecSuccess }
    func delete(_ id: UUID) -> OSStatus {
        guard deletionError == errSecSuccess else { return deletionError }
        tokens.removeValue(forKey: id); return errSecSuccess
    }
}
private struct WireDeadlineFailure: Error {}

/// The Network callback and deadline may race after cancellation. Exactly one
/// owns the continuation; neither a late callback nor a canceled timer leaks it.
private final class WireOperation<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var timer: Task<Void, Never>?
    init(_ continuation: CheckedContinuation<Value, Error>) { self.continuation = continuation }
    func watch(_ timer: Task<Void, Never>) {
        let completed = lock.withLock {
            guard continuation != nil else { return true }
            self.timer = timer; return false
        }
        if completed { timer.cancel() }
    }
    func resolve(_ result: Result<Value, Error>) {
        let pending = lock.withLock { () -> (CheckedContinuation<Value, Error>, Task<Void, Never>?)? in
            guard let continuation else { return nil }
            let timer = self.timer
            self.continuation = nil; self.timer = nil
            return (continuation, timer)
        }
        guard let (continuation, timer) = pending else { return }
        timer?.cancel(); continuation.resume(with: result)
    }
}

@MainActor final class WireClient {
    let connection: NWConnection
    private var buffer = StudioControlFrameBuffer()
    private var frames: [StudioControlResponse] = []
    private(set) var receivedFrameCount = 0
    private var operationPhase = "idle"
    private let timeout: Duration
    init(port: UInt16, timeout: Duration = .seconds(5)) {
        self.timeout = timeout
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        connection.start(queue: .global())
    }
    private func arm<Value>(_ operation: WireOperation<Value>, deadline: ContinuousClock.Instant) {
        let connection = connection
        operation.watch(Task { @MainActor in
            do { try await ContinuousClock().sleep(until: deadline) } catch { return }
            operation.resolve(.failure(WireDeadlineFailure()))
            connection.cancel()
        })
    }
    func write(_ data: Data, deadline: ContinuousClock.Instant? = nil) async throws {
        operationPhase = "write"
        let deadline = deadline ?? .now.advanced(by: timeout)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let operation = WireOperation(continuation)
            arm(operation, deadline: deadline)
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { operation.resolve(.failure(error)) } else { operation.resolve(.success(())) }
            })
        }
        guard ContinuousClock.now < deadline else { connection.cancel(); throw WireDeadlineFailure() }
    }
    func request(_ request: StudioControlRequest) async throws -> StudioControlResponse {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var data = try JSONEncoder().encode(request); data.append(10)
        do {
            try await write(data, deadline: deadline)
            while true {
                let response = try await read(deadline: deadline)
                if response.id == request.id { return response }
            }
        } catch is WireDeadlineFailure {
            // Never log requests, tokens or response bodies. A bounded phase
            // report distinguishes connect/write/response failures on CI.
            let report = "Local wire deadline: type=\(request.type.rawValue) phase=\(operationPhase) receivedFrames=\(receivedFrameCount) queuedFrames=\(frames.count) connection=\(connection.state)\n"
            try? FileHandle.standardOutput.write(contentsOf: Data(report.utf8))
            throw WireDeadlineFailure()
        }
    }
    func read(deadline: ContinuousClock.Instant? = nil) async throws -> StudioControlResponse {
        operationPhase = "read"
        let deadline = deadline ?? .now.advanced(by: timeout)
        guard ContinuousClock.now < deadline else { connection.cancel(); throw WireDeadlineFailure() }
        while frames.isEmpty {
            let data: Data = try await withCheckedThrowingContinuation { continuation in
                let operation = WireOperation(continuation)
                arm(operation, deadline: deadline)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
                    if let error { operation.resolve(.failure(error)) }
                    else if let data, !data.isEmpty { operation.resolve(.success(data)) }
                    else { operation.resolve(.failure(StudioControlProtocolError(code: "closed", message: complete ? "Closed" : "Empty"))) }
                }
            }
            guard ContinuousClock.now < deadline else { connection.cancel(); throw WireDeadlineFailure() }
            let decoded = try buffer.append(data).map { try JSONDecoder().decode(StudioControlResponse.self, from: $0) }
            receivedFrameCount += decoded.count; frames += decoded
        }
        return frames.removeFirst()
    }
}


private struct AudioWindow: Codable {
    var name: String
    var start: Double
    var end: Double
    var rms: Double
    var frequency: Double
    var frames: Int
}
private final class DeckPCM: @unchecked Sendable {
    struct Packet { let pts: Double; let values: [Float] }
    private let lock = NSLock()
    private var packets: [Packet] = []
    func receive(_ sample: CMSampleBuffer) {
        guard let block = sample.dataBuffer else { return }
        var values = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / 4)
        let result = values.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
        precondition(result == noErr)
        lock.withLock { precondition(packets.count < 10_000); packets.append(.init(pts: sample.presentationTimeStamp.seconds, values: values)) }
    }
    func window(_ name: String, since start: Double, end: Double) -> AudioWindow {
        let samples = lock.withLock { packets.filter { $0.pts >= start && $0.pts < end }.flatMap { packet in stride(from: 0, to: packet.values.count, by: 2).map { packet.values[$0] } } }
        let energy = samples.reduce(0.0) { $0 + Double($1 * $1) }
        let crossings = zip(samples, samples.dropFirst()).filter { $0 < 0 && $1 >= 0 }.count
        return .init(name: name, start: start, end: end, rms: sqrt(energy / Double(max(1, samples.count))),
                     frequency: Double(crossings) * 48_000 / Double(max(1, samples.count)), frames: samples.count)
    }
}

private final class DeckInputTiming: @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [String] = []
    private var durationsValid = true
    func receive(_ sample: CMSampleBuffer) {
        let pts = sample.presentationTimeStamp.seconds, now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        let rate = sample.formatDescription.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mSampleRate } ?? 0
        let value = "pts=\(pts) now=\(now) frames=\(sample.numSamples) rate=\(rate) duration=\(sample.duration.seconds)"
        lock.withLock {
            if rows.count < 20 { rows.append(value) }
            durationsValid = durationsValid && rate > 0 && abs(sample.duration.seconds - Double(sample.numSamples) / rate) < 0.00001
        }
    }
    func snapshot() -> [String] { lock.withLock { rows } }
    var timingValid: Bool { lock.withLock { durationsValid } }
}

@main @MainActor struct DeckAudioMediaHarness {
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw NSError(domain: "DeckAudioMedia", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func wait(_ message: String, seconds: Double = 8, until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while ContinuousClock.now < deadline { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        throw NSError(domain: "DeckAudioMedia", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
    }
    static func host() -> Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }
    static func timingRegression() throws {
        let frames = 8192, floats = (0..<(8192 * 2)).map { Float($0 % 101) / 101 }
        var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        try require(CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr, "Timing regression format failed")
        var block: CMBlockBuffer?
        try require(CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: floats.count * 4, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: floats.count * 4, flags: 0, blockBufferOut: &block) == noErr, "Timing regression data failed")
        let filled = floats.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: $0.count) }
        try require(filled == noErr, "Timing regression PCM fill failed")
        let engine = MediaSourcePlayback(sourceID: SourceDefinitionID()) { nil }
        let originalPTS = CMTime(value: 828_000, timescale: 48_000), targetPTS = CMTime(value: 480_000_000, timescale: 48_000)
        for validDTS in [false, true] {
            // A repeated timing entry requires invalid DTS. Exercise valid
            // DTS with one explicit timing entry per sample, as Core Media's
            // multi-sample buffer contract requires.
            var originalTimings = (0..<(validDTS ? frames : 1)).map { index in
                let pts = originalPTS + CMTime(value: Int64(index), timescale: 48_000)
                return CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000), presentationTimeStamp: pts,
                    decodeTimeStamp: validDTS ? pts - CMTime(value: 2400, timescale: 48_000) : .invalid)
            }
            var bytesPerFrame = 8, sample: CMSampleBuffer?
            let created = originalTimings.withUnsafeMutableBufferPointer {
                CMSampleBufferCreateReady(allocator: nil, dataBuffer: block!, formatDescription: format!, sampleCount: frames,
                    sampleTimingEntryCount: $0.count, sampleTimingArray: $0.baseAddress!, sampleSizeEntryCount: 1, sampleSizeArray: &bytesPerFrame, sampleBufferOut: &sample)
            }
            try require(created == noErr, "Timing regression sample creation failed")
            let output = try engine.deckFixtureRetime(sample!, to: targetPTS).unwrap("Timing regression retime failed")
            try require(output.numSamples == frames && output.presentationTimeStamp == targetPTS && abs(output.duration.seconds - Double(frames) / 48_000) < 0.000001, "8192-frame retime changed frame count, PTS or aggregate duration")
            var copiedTiming = CMSampleTimingInfo()
            try require(CMSampleBufferGetSampleTimingInfo(output, at: 0, timingInfoOut: &copiedTiming) == noErr && copiedTiming.duration == originalTimings[0].duration, "Retime changed original 48k sample grid")
            if validDTS { try require(copiedTiming.decodeTimeStamp == targetPTS - CMTime(value: 2400, timescale: 48_000), "Retime changed valid DTS offset") }
            else { try require(!copiedTiming.decodeTimeStamp.isValid, "Retime invented DTS for PCM") }
            var finalTiming = CMSampleTimingInfo()
            try require(CMSampleBufferGetSampleTimingInfo(output, at: frames - 1, timingInfoOut: &finalTiming) == noErr
                && finalTiming.presentationTimeStamp == targetPTS + CMTime(value: Int64(frames - 1), timescale: 48_000)
                && finalTiming.duration == originalTimings[0].duration, "Retime changed final sample's original PTS grid")
            var readback = [Float](repeating: 0, count: floats.count)
            let read = readback.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(output.dataBuffer!, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
            try require(read == noErr && readback == floats, "Timing-only retime modified actual PCM samples")
        }
        print("PASS: actual 8192-frame/48k retime keeps 0.170667s aggregate duration, original PCM/sample grid, target PTS and valid/invalid DTS semantics")
    }
    static func makeTone(_ url: URL, frequency: Double, cues: Bool = false) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
        let count = 144_000
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!; pcm.frameLength = AVAudioFrameCount(count)
        for side in 0..<2 { for frame in 0..<count {
            let hz = cues && frame >= 48_000 ? 1_000 : frequency
            pcm.floatChannelData![side][frame] = Float(sin(Double(frame) / 48_000 * 2 * .pi * hz)) * 0.3
        } }
        var settings = format.settings; settings[AVLinearPCMIsNonInterleaved] = false
        try AVAudioFile(forWriting: url, settings: settings).write(from: pcm)
    }
    static func makeVideo(_ url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180])
        writer.add(input); try require(writer.startWriting(), "Owned video writer did not start"); writer.startSession(atSourceTime: .zero)
        for frame in 0..<90 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
            let sample = try ProgramRecordingFixtures.video(at: Double(frame) / 30, timestampBase: 0, eventSeconds: 1)
            try require(input.append(sample), "Owned video append failed")
        }
        input.markAsFinished(); await writer.finishWriting(); try require(writer.status == .completed, "Owned video did not finalize")
    }
    static func makePDF(_ url: URL) throws {
        let document = PDFDocument()
        for index in 0..<3 {
            let image = NSImage(size: .init(width: 320, height: 180))
            image.lockFocus(); NSColor(calibratedRed: CGFloat(index) / 2, green: 0, blue: 0, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 320, height: 180).fill(); image.unlockFocus()
            document.insert(PDFPage(image: image)!, at: index)
        }
        try require(document.write(to: url), "Owned PDF did not write")
    }
    static func main() {
        setbuf(stdout, nil)
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await run(); exit(0) }
            catch { print("FAIL: \(error); owned artifacts \(GuestFixtureStorage.artifactRoot.path)"); exit(1) }
        }
        app.run()
    }
    static func run() async throws {
        let root = GuestFixtureStorage.artifactRoot
        try timingRegression()
        let project = root.appendingPathComponent("Project")
        try DesktopStorage.prepare(project)
        var settings = StreamSettings.default; settings.voicePolishEnabled = true; settings.micVolume = 0
        settings.audioInputs = []; settings.outputProfile = .init(canvasWidth: 320, canvasHeight: 180, frameRate: 30)
        DesktopSettingsStore().saveNonSecret(settings)
        let scene = Scene(name: "Owned controller media", layers: [], background: .solid(colorHex: "#000000"))
        try JSONEncoder().encode(SceneDocument(sources: [], scenes: [scene], selectedID: scene.id)).write(to: project.appendingPathComponent("stream.scenes.v2.json"))
        try JSONEncoder().encode([StreamDestination]()).write(to: project.appendingPathComponent("destinations.json"))
        for (name, hz) in [("tone-low.wav", 80.0), ("tone-high.wav", 2_000.0), ("cues.wav", 440.0)] {
            try makeTone(root.appendingPathComponent(name), frequency: hz, cues: name == "cues.wav")
        }
        try await makeVideo(root.appendingPathComponent("video.mov")); try makePDF(root.appendingPathComponent("pages.pdf"))
        func bookmark(_ name: String) throws -> Data {
            let url = root.appendingPathComponent(name)
            let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            try require(DeckFixtureOwnedMedia.resolve(data).resolvingSymlinksInPath().path == url.resolvingSymlinksInPath().path, "Internal ordinary-file boundary rejected owned media")
            return data
        }
        let scenes = SceneStore(), preview = PreviewProgramModel(selected: scenes.selected), mixer = AudioMixEngine()
        let controller = StreamController(sceneStore: scenes, previewProgram: preview, permissions: PermissionsManager(), audioEngine: mixer)
        try require(!controller.resilience.isLocked && !controller.resilience.requiresManualRestart,
                    "Owned audio/media fixture must construct its explicit simulated unlocked session")
        let session = SettingsSession(controller: controller), recorder = RecordingController(defaults: GuestFixtureDefaults.value, defaultDirectory: GuestFixtureStorage.recordingsDirectory)
        let dispatcher = StudioCommandDispatcher(controller: controller, sceneStore: scenes, session: session, recorder: recorder, previewProgram: preview)
        let probe = DeckPCM(), tap = controller.addProgramAudioTap(capacity: 16) { probe.receive($0) }
        let credentials = MemoryCredentials()
        let pairing = StudioControlPairingStore(url: root.appendingPathComponent("paired.json"), credentials: credentials)
        pairing.pair(name: "Owned native media fixture")
        let grant = pairing.pairing!
        let server = StudioLocalControlServer(defaults: GuestFixtureDefaults.value, pairingStore: pairing, port: 0)
        server.bind(to: dispatcher); server.setEnabled(true)
        try await wait("Native loopback server did not bind", until: { server.listeningPort != nil })
        var client = WireClient(port: server.listeningPort!), sessionID: UUID?
        func authenticate() async throws {
            let response = try await client.request(.init(type: .authenticate, id: UUID(), clientID: grant.id, token: grant.token))
            try require(response.error == nil && response.sessionID != nil, "Native authentication failed"); sessionID = response.sessionID
        }
        try await authenticate()
        defer { client.connection.cancel(); server.stop(); dispatcher.soundboard.shutdown(); controller.removeAudioTap(tap); controller.stopPreview(); scenes.flushPendingWrites() }
        func command(_ id: String, value: Double? = nil, page: Int? = nil, text: String? = nil, succeeds: Bool = true) async throws {
            let response = try await client.request(.init(type: .command, id: UUID(), sessionID: sessionID, commandID: id, value: value, page: page, text: text))
            try require(response.result?.succeeded == succeeds, "Native command \(id) unexpected result: \(String(describing: response.result?.error)) / \(String(describing: response.error))")
        }
        func snapshot() async throws -> StudioControlSnapshot {
            let result = try await client.request(.init(type: .snapshot, id: UUID(), sessionID: sessionID)); return result.snapshot!
        }
        var windows: [AudioWindow] = []
        func measure(_ label: String, settle: Int = 180, duration: Int = 260) async throws -> AudioWindow {
            try await Task.sleep(for: .milliseconds(settle)); let start = host()
            try await Task.sleep(for: .milliseconds(duration))
            let value = probe.window(label, since: start, end: host()); windows.append(value)
            print("PCM \(label): frames=\(value.frames) rms=\(value.rms) hz=\(value.frequency)")
            try require(value.frames >= duration * 30, "Program PCM clock stalled during \(label)"); return value
        }
        let pad = SoundPad(name: "Controller tone", loops: true, bookmarkData: try bookmark("tone-low.wav"), fileName: "tone-low.wav")
        try require(dispatcher.execute(.addSoundPad(pad)).error == nil, "Could not add sound pad")
        let base = "sound.\(pad.id.rawValue.uuidString)", channel = AudioChannelID.media(pad.id)
        try require(!dispatcher.state.fxChain(forLabel: channel.label).isActive, "Media FX UI inherited microphone voice-polish processing")
        controller.startPreview(); recorder.start(stream: controller)
        try await command(base + ".play")
        try await wait("Actual pad player did not play", until: { dispatcher.soundboard.padStatuses[pad.id]?.phase == .playing })
        let timing = DeckInputTiming()
        dispatcher.soundboard.deckFixtureObserve(pad.id) { timing.receive($0) }
        print("TRACE initial actual player \(String(describing: dispatcher.soundboard.deckFixturePlayerState(pad.id)))")
        _ = try await measure("pad.play.startup")
        print("TRACE after startup actual player \(String(describing: dispatcher.soundboard.deckFixturePlayerState(pad.id)))")
        try await wait("Actual player clock did not advance", until: { (dispatcher.soundboard.deckFixturePlayerState(pad.id)?.seconds ?? 0) > 0.25 })
        let unity = try await measure("pad.play.steady", settle: 100, duration: 350)
        for row in timing.snapshot() { print("INPUT \(row)") }
        print("TRACE sound mixer \(await controller.audioStatsSnapshot())")
        try require(timing.timingValid, "Retimed source duration does not match actual sample count/rate")
        try require(unity.rms > 0.15 && abs(unity.frequency - 80) < 8, "Sound did not reach the shipping Program mixer")
        let beforePause = dispatcher.soundboard.deckFixturePlayerState(pad.id)!.seconds
        try await command(base + ".pause")
        let silence = try await measure("pad.pause", settle: 400)
        let paused = dispatcher.soundboard.deckFixturePlayerState(pad.id)!
        try require(silence.rms < 0.00001 && paused.rate == 0 && abs(paused.seconds - beforePause) < 0.12, "Pause did not hold actual player and silence Program")
        let pausedSnapshot = try await snapshot()
        try require(pausedSnapshot.playback?[base] == "paused", "Paused feedback did not follow actual player")
        try await command(base + ".play"); _ = try await measure("pad.resume")
        try require(dispatcher.soundboard.deckFixturePlayerState(pad.id)!.seconds > paused.seconds + 0.2, "Play rewound instead of resuming")
        try await command(base + ".restart")
        try await Task.sleep(for: .milliseconds(180))
        try require(dispatcher.soundboard.deckFixturePlayerState(pad.id)!.seconds < 0.4, "Restart did not seek actual player to beginning")
        try await command(base + ".gain", value: 0.25)
        let half = try await measure("pad.gain.half")
        try require(half.rms / unity.rms > 0.43 && half.rms / unity.rms < 0.57, "Normalized controller gain did not change actual PCM")
        try await command(base + ".mute.on")
        var renamed = dispatcher.soundboardStore.pad(withID: pad.id)!; renamed.name = "Renamed controller tone"
        try require(dispatcher.execute(.updateSoundPad(renamed)).error == nil, "Rename failed")
        try await command(base + ".loop.off"); try await command(base + ".loop.on")
        let muted = try await measure("pad.mute.survives.rename.loop")
        try require(muted.rms < 0.00001 && session.activeSettings.mixer.channelMutes[channel.label] == true, "Metadata edit silently unmuted audio")
        try await command(base + ".mute.off"); try await command(base + ".gain", value: 0.5)
        try await command(base + ".restart")
        try await Task.sleep(for: .milliseconds(3_200))
        let looped = try await measure("pad.loop.crosses.end", settle: 0)
        try require(looped.rms > 0.15 && dispatcher.soundboard.deckFixturePlayerState(pad.id)!.rate > 0, "Loop flag did not produce PCM after actual file end")
        let loopState = try await snapshot()
        try require(loopState.loops?[base] == true, "Loop feedback missing")
        // The actual reader emits 8192-frame chunks (171 ms) with 150 ms
        // lookahead. Drain the bounded preprocessed queue before comparing
        // DSP edits; gain/mute still act on the mixer's current fader.
        var chain = ChannelFXChain.preset(.off); chain.highPass = .init(isEnabled: true, frequency: 400)
        try require(dispatcher.execute(.setChannelFXChain(channel, chain)).error == nil, "Could not configure native effect")
        let filtered = try await measure("native.highPass.active", settle: 400)
        try await command(base + ".effects.highPass.bypass.on")
        let bypass = try await measure("native.highPass.bypass", settle: 400)
        try require(filtered.rms < bypass.rms * 0.2 && bypass.rms > 0.15, "Advertised native bypass did not change actual PCM insert")
        let effectState = try await snapshot()
        try require(effectState.effectsBypassed?[base + ".effects.highPass.bypass"] == true, "Effect bypass feedback missing")
        let component = AudioUnitComponentID(componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_HighPassFilter, manufacturer: kAudioUnitManufacturer_Apple, displayName: "Apple: AUHipass")
        try require(component.isAvailable, "Apple installed AU effect unavailable")
        let unit = AVAudioUnitEffect(audioComponentDescription: component.componentDescription)
        unit.auAudioUnit.parameterTree?.allParameters.first(where: { $0.address == 0 })?.value = 400
        let slot = HostedAudioUnitSlot(component: component, state: HostedAudioUnitSlot.encodeState(unit.auAudioUnit.fullState))
        chain = .preset(.off); chain.audioUnits = [slot]
        try require(dispatcher.execute(.setChannelFXChain(channel, chain)).error == nil, "Could not configure hosted AU")
        let hosted = try await measure("hosted.AU.active", settle: 400)
        try require(dispatcher.hostedAudioUnitHandles(forLabel: channel.label)[slot.id] != nil, "Hosted AU did not instantiate in actual source insert")
        try await command(base + ".au.\(slot.id.uuidString).bypass.on")
        let hostedBypass = try await measure("hosted.AU.bypass", settle: 400)
        try require(hosted.rms < hostedBypass.rms * 0.3 && hostedBypass.rms > 0.15, "Hosted AU bypass did not change actual PCM")
        try await command(base + ".stop"); let stopped = try await measure("pad.stop", settle: 400)
        try require(stopped.rms < 0.00001 && dispatcher.soundboard.deckFixturePlayerState(pad.id)!.rate == 0, "Stop did not stop actual audio")
        print("TRACE actual sound transport, PCM gain/mute, loop, native/hosted AU bypass PASS")
        let loadingPad = SoundPad(name: "Pause during load", bookmarkData: try bookmark("tone-low.wav"), fileName: "tone-low.wav")
        try require(dispatcher.execute(.addSoundPad(loadingPad)).error == nil, "Could not add loading-race pad")
        // These supported synchronous dispatcher intents share one MainActor
        // turn, so pause necessarily precedes asynchronous AVAsset configure.
        try require(dispatcher.execute(.playSoundPad(loadingPad.id)).error == nil, "Cold Play failed")
        try require(dispatcher.execute(.pauseSoundPad(loadingPad.id)).error == nil, "Cold Pause failed")
        try await wait("Paused cold player did not finish loading", until: { dispatcher.soundboard.deckFixturePlayerState(loadingPad.id) != nil })
        let coldPaused = try await measure("pad.pause.before.load.completes")
        try require(coldPaused.rms < 0.00001 && dispatcher.soundboard.deckFixturePlayerState(loadingPad.id)?.rate == 0, "Late load completion ignored Pause and started audio")
        let loadingBase = "sound.\(loadingPad.id.rawValue.uuidString)"
        try await command(loadingBase + ".play")
        try await wait("Cold paused player did not advance after Play", until: { (dispatcher.soundboard.deckFixturePlayerState(loadingPad.id)?.seconds ?? 0) > 0.25 })
        let coldResumed = try await measure("pad.play.after.cold.pause")
        try require(coldResumed.rms > 0.15 && abs(coldResumed.frequency - 80) < 8, "Play did not release cold Pause")
        try await command(loadingBase + ".stop")
        try require(dispatcher.execute(.removeSoundPad(loadingPad.id)).error == nil, "Cold-pad removal failed")

        let cuePad = SoundPad(name: "Decoded restart cues", bookmarkData: try bookmark("cues.wav"), fileName: "cues.wav")
        try require(dispatcher.execute(.addSoundPad(cuePad)).error == nil, "Could not add restart cue pad")
        let cue = "sound.\(cuePad.id.rawValue.uuidString)"
        try await command(cue + ".play")
        try await wait("Actual cue player did not reach second tone", until: { (dispatcher.soundboard.deckFixturePlayerState(cuePad.id)?.seconds ?? 0) > 1.3 })
        let lateCue = try await measure("restart.before.1000Hz", settle: 100)
        try require(lateCue.rms > 0.15 && abs(lateCue.frequency - 1_000) < 15, "Cue source did not decode its later PCM segment")
        try await command(cue + ".restart")
        try await wait("Restarted actual cue clock did not advance from beginning", until: {
            guard let state = dispatcher.soundboard.deckFixturePlayerState(cuePad.id) else { return false }
            return state.seconds > 0.1 && state.seconds < 0.4
        })
        let earlyCue = try await measure("restart.after.440Hz", settle: 100, duration: 200)
        try require(earlyCue.rms > 0.15 && abs(earlyCue.frequency - 440) < 15, "Restart changed player clock without rewinding actual decoded PCM")
        try await command(cue + ".stop")
        try require(dispatcher.execute(.removeSoundPad(cuePad.id)).error == nil, "Restart-cue removal failed")

        let playlist = MusicPlaylist(name: "Controller playlist", tracks: [
            MusicTrack(name: "Low", bookmarkData: try bookmark("tone-low.wav"), fileName: "tone-low.wav"),
            MusicTrack(name: "High", bookmarkData: try bookmark("tone-high.wav"), fileName: "tone-high.wav")], repeatMode: .all)
        try require(dispatcher.execute(.addMusicPlaylist(playlist)).error == nil, "Could not add playlist")
        let music = "playlist.\(playlist.id.rawValue.uuidString)"
        try await command(music + ".play"); let musicLow = try await measure("playlist.play.low", settle: 350)
        try await command(music + ".next"); let musicHigh = try await measure("playlist.next.high", settle: 350)
        try await command(music + ".previous"); let musicPrevious = try await measure("playlist.previous.low", settle: 350)
        try require(abs(musicLow.frequency - 80) < 8 && abs(musicHigh.frequency - 2_000) < 15 && abs(musicPrevious.frequency - 80) < 8, "Playlist next/previous failed to change actual decoded track")
        try await command(music + ".pause"); let musicPaused = try await measure("playlist.pause", settle: 400)
        try require(musicPaused.rms < 0.00001, "Playlist pause leaked audio")
        try await command(music + ".play"); try await command(music + ".mute.on")
        let musicMuted = try await measure("playlist.mute")
        try require(musicMuted.rms < 0.00001, "Playlist mute leaked audio")
        try await command(music + ".stop")

        let sceneSound = scenes.addSource(SourceDefinition(name: "Owned scene audio", payload: .media(.init(bookmarkData: try bookmark("tone-low.wav"), fileName: "tone-low.wav", loops: true, autoplay: false))))
        let sceneSoundLayer = LayerNode(name: "Owned scene audio", sourceID: sceneSound.id, payload: sceneSound.payload, transform: .fullscreen)
        var audibleScene = preview.programScene!; audibleScene.layers = [sceneSoundLayer]
        let sceneAudio = "media.\(sceneSound.id.rawValue.uuidString)"
        preview.stage(audibleScene)
        try await command(sceneAudio + ".play"); try await command(sceneAudio + ".gain", value: 1)
        let stagedOnly = try await measure("scene.media.staged.gain.cannot.leak", settle: 300)
        try require(stagedOnly.rms < 0.00001, "Staged-only source fader bypassed Program isolation")
        try await command(sceneAudio + ".gain", value: 0.5)
        preview.take()
        let firstAdded = try await measure("scene.media.first.take")
        try require(firstAdded.rms > 0.15 && abs(firstAdded.frequency - 80) < 8, "New taken media insert overwrote its Program binding with silence")
        var emptyScene = audibleScene; emptyScene.layers = []
        preview.stage(emptyScene); preview.take()
        try await Task.sleep(for: .milliseconds(50))
        preview.stage(audibleScene); preview.take(); try await command(sceneAudio + ".play")
        let readded = try await measure("scene.media.fast.remove.readd")
        try require(readded.rms > 0.15, "Re-added media insert lost its current gain")
        try await command(sceneAudio + ".mute.on")
        let sceneMuted = try await measure("scene.media.mute")
        try require(sceneMuted.rms < 0.00001, "Source media mute failed to multiply Program binding")
        try await command(sceneAudio + ".stop")

        let video = scenes.addSource(SourceDefinition(name: "Owned video", payload: .media(.init(bookmarkData: try bookmark("video.mov"), fileName: "video.mov", loops: true, autoplay: false))))
        let videoLayer = LayerNode(name: "Owned video", sourceID: video.id, payload: video.payload, transform: .fullscreen)
        var visible = preview.programScene!; visible.layers = [videoLayer]; preview.stage(visible); preview.take()
        let movie = "media.\(video.id.rawValue.uuidString)"
        try await command(movie + ".play")
        try await wait("Actual native video did not load/play", until: { controller.capturePool.mediaStatus(for: video.id).phase == .playing })
        try await Task.sleep(for: .milliseconds(350))
        let videoPosition = controller.capturePool.deckFixturePlayerState(for: video.id)!.seconds
        try await command(movie + ".pause"); try await Task.sleep(for: .milliseconds(250))
        let heldVideo = controller.capturePool.deckFixturePlayerState(for: video.id)!
        try require(heldVideo.rate == 0 && abs(heldVideo.seconds - videoPosition) < 0.12, "Video pause did not hold actual AVPlayer")
        try await command(movie + ".play"); try await Task.sleep(for: .milliseconds(250))
        try require(controller.capturePool.deckFixturePlayerState(for: video.id)!.seconds > heldVideo.seconds + 0.15, "Video play did not resume actual AVPlayer")
        try await command(movie + ".stop"); try await Task.sleep(for: .milliseconds(100))
        let stoppedVideo = controller.capturePool.deckFixturePlayerState(for: video.id)!
        try require(stoppedVideo.rate == 0 && stoppedVideo.seconds < 0.05, "Video stop did not rewind actual AVPlayer")
        let asset = await dispatcher.assetLibrary.importFile(at: root.appendingPathComponent("pages.pdf"), mode: .copy)!
        let pdf = scenes.addSource(SourceDefinition(name: "Owned PDF", payload: .pdf(.init(assetIdentifier: asset.id.description))))
        visible.layers = [LayerNode(name: "Owned PDF", sourceID: pdf.id, payload: pdf.payload, transform: .fullscreen)]
        preview.stage(visible); preview.take()
        try await wait("Actual PDF source did not render", until: { controller.capturePool.pdfStates[pdf.id]?.pageCount == 3 })
        let pages = "pdf.\(pdf.id.rawValue.uuidString)"
        try await command(pages + ".next")
        try await wait("PDF next did not render page 2", until: { controller.capturePool.pdfStates[pdf.id]?.currentPage == 1 })
        try await command(pages + ".previous")
        try await wait("PDF previous did not render page 1", until: { controller.capturePool.pdfStates[pdf.id]?.currentPage == 0 })
        try await command(pages + ".goto", page: 2)
        try await wait("Typed PDF jump did not render page 3", until: { controller.capturePool.pdfStates[pdf.id]?.currentPage == 2 })
        let pdfState = try await snapshot()
        try require(pdfState.pdfPages?[pages] == .init(currentPage: 2, pageCount: 3), "Authoritative PDF page/count feedback missing")
        try await command("output.record.marker", text: "Native controller chapter")
        try await command("output.record.marker")
        print("TRACE actual playlist PCM, AVPlayer video transport, rendered PDF pages and typed markers PASS")

        // Each binding re-resolves the current stable command catalogue. Both
        // bindings survive rename; deletion rejects both without substitution.
        let first = dispatcher.controllerTargets().first { $0.id == base + ".play" }!
        let second = dispatcher.controllerTargets().first { $0.id == base + ".play" }!
        try require(first.execute(nil) == nil && second.execute(nil) == nil, "Two stable bindings did not execute")
        try await command(base + ".stop")
        client.connection.cancel(); client = WireClient(port: server.listeningPort!)
        try await authenticate()
        let reconnected = try await snapshot()
        try require(reconnected.playback?[base] == "ready" && reconnected.mutes?[base + ".gain"] == false, "Reconnect snapshot did not restore current native media state")
        try require(dispatcher.execute(.removeSoundPad(pad.id)).error == nil, "Pad deletion failed")
        try await Task.sleep(for: .milliseconds(120))
        try require(first.execute(nil) != nil && second.execute(nil) != nil, "Removed stable resource silently substituted another target")
        try await command(base + ".play", succeeds: false)
        dispatcher.soundboard.shutdown()
        try await Task.sleep(for: .milliseconds(300))
        try require(dispatcher.soundboard.deckFixtureResources.players == 0 && !dispatcher.soundboard.deckFixtureResources.pumping, "Shutdown retained a decoder or pump")
        try require(dispatcher.hostedAudioUnitHandles(forLabel: channel.label).isEmpty, "Deleted source retained hosted AU resources")
        let teardown = try await measure("all.soundboard.shutdown", settle: 0)
        try require(teardown.rms < 0.00001, "Retired sound resources continued writing Program")
        recorder.stop()
        try await wait("Actual recording did not finalize", until: { recorder.state == .idle })
        let outputs = try FileManager.default.contentsOfDirectory(at: GuestFixtureStorage.recordingsDirectory, includingPropertiesForKeys: nil)
        let recording = try outputs.first(where: { ["mp4", "mov"].contains($0.pathExtension) }).unwrap("Actual recording file missing")
        let recordedAsset = AVURLAsset(url: recording)
        let decoded = try AVAssetReader(asset: recordedAsset)
        let tracks = try await recordedAsset.loadTracks(withMediaType: .audio)
        let track = try tracks.first.unwrap("Recording audio track missing")
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false])
        decoded.add(readerOutput); try require(decoded.startReading(), "Actual recorded PCM decoder did not start")
        let decodedProbe = DeckPCM(); var decodedFrames = 0
        while let sample = readerOutput.copyNextSampleBuffer() { decodedProbe.receive(sample); decodedFrames += sample.numSamples }
        try require(decoded.status == .completed && decodedFrames > 48_000, "Actual media recording did not decode")
        let recordedDuration = try await recordedAsset.load(.duration).seconds
        let recorded = decodedProbe.window("decoded.recording", since: 0, end: recordedDuration)
        try require(recorded.rms > 0.03, "Actual sound playback did not reach recorded Program PCM")
        let children = FileManager.default.enumerator(at: GuestFixtureStorage.recordingsDirectory, includingPropertiesForKeys: nil)!
        var markers: [String] = []
        for url in children.allObjects.compactMap({ $0 as? URL }) where url.lastPathComponent.hasSuffix(".recording.json") {
            if let body = try? String(contentsOf: url, encoding: .utf8) { markers.append(body) }
        }
        try require(markers.contains(where: { $0.contains("Native controller chapter") && $0.contains("Chapter") }), "Actual writer journal did not retain custom and default markers")
        struct Report: Codable { var host: String; var system: String; var windows: [AudioWindow]; var recorded: AudioWindow; var decodedFrames: Int; var recording: String }
        let report = Report(host: Host.current().localizedName ?? "unknown", system: ProcessInfo.processInfo.operatingSystemVersionString, windows: windows, recorded: recorded, decodedFrames: decodedFrames, recording: recording.path)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: root.appendingPathComponent("deck-audio-media-report.json"))
        print("PASS: actual native loopback commands → shipping MediaSource/Soundboard/FX/mixer → Program and decoded recording; transport/loop/gain/mute/AU/PDF/markers/stable rename-delete/multiple-bindings/reconnect/decoder-pump lifecycle; \(root.path)")
    }
}
private extension Optional {
    func unwrap(_ message: String) throws -> Wrapped {
        guard let self else { throw NSError(domain: "DeckAudioMedia", code: 3, userInfo: [NSLocalizedDescriptionKey: message]) }; return self
    }
}
