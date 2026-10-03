import AVFoundation
import CoreMedia
import Darwin
import Foundation
import StreamCore

private struct InterviewMediaConfiguration: Decodable {
    let serviceURL: URL, operatorToken: String, turnURL: String, turnUsername: String, turnCredential: String
    let mediaDirectory: URL
}
private struct OwnedLocalRelayService: NativeInterviewService {
    let client: NativeInterviewServiceClient
    let configuration: NativeInterviewConfiguration
    let ownedRelay: NativeInterviewRelayConfiguration
    func createRoom() async throws -> NativeInterviewCreatedRoom { try await client.createRoom() }
    func createInvite(room: UUID) async throws -> NativeInterviewInvite { try await client.createInvite(room: room) }
    func endRoom(_ room: UUID) async throws { try await client.endRoom(room) }
    func connect(room: UUID, host: NativeInterviewInvite) async throws -> any NativeInterviewSocketTransport {
        try await client.connect(room: room, host: host)
    }
    func shutdown() async { await client.shutdown() }
    func relay(room: UUID, host: NativeInterviewInvite) async throws -> NativeInterviewRelayConfiguration {
        // Explicit local TURN override; all service control remains the real
        // Worker. This cannot qualify the deployed Cloudflare TURN broker.
        guard host.expires > Date(), ownedRelay.expires > Date() else { throw NativeInterviewError.expired }
        return ownedRelay
    }
}
private final class InterviewCLIInput: @unchecked Sendable {
    let stream: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let lock = NSLock()
    private var pending = Data(), closed = false
    init() {
        let pair = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingOldest(32))
        stream = pair.stream; continuation = pair.continuation
    }
    func receive(_ bytes: Data) {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        guard !bytes.isEmpty, pending.count + bytes.count <= 16_384 else { closeLocked(); return }
        pending.append(bytes)
        while let newline = pending.firstIndex(of: 10) {
            let line = Data(pending.prefix(upTo: newline)); pending.removeSubrange(...newline)
            guard !line.isEmpty, line.count <= 4_096 else { closeLocked(); return }
            if case .dropped = continuation.yield(line) { closeLocked(); return }
        }
    }
    func close() { lock.lock(); closeLocked(); lock.unlock() }
    private func closeLocked() { closed = true; pending.removeAll(); continuation.finish() }
}
private final class InterviewCLIOutput: @unchecked Sendable {
    private let lock = NSLock(), queue = DispatchQueue(label: "stream.interview.fixture.output")
    private var pending: [Data] = [], bytes = 0, working = false, failed = false
    private let failure: @Sendable () -> Void
    init(failure: @escaping @Sendable () -> Void) { self.failure = failure }
    @discardableResult func emit(_ object: [String: Any]) -> Bool {
        guard var data = try? JSONSerialization.data(withJSONObject: object), data.count <= 16_384 else { return false }
        data.append(10); lock.lock()
        guard !failed, pending.count < 64, bytes + data.count <= 65_536 else {
            let notify = !failed; failed = true; lock.unlock(); if notify { failure() }; return false
        }
        pending.append(data); bytes += data.count
        let start = !working; working = true; lock.unlock()
        if start { queue.async { [weak self] in self?.drain() } }; return true
    }
    private func drain() {
        while true {
            lock.lock(); guard !pending.isEmpty, !failed else { working = false; lock.unlock(); return }
            let data = pending.removeFirst(); bytes -= data.count; lock.unlock()
            let success = data.withUnsafeBytes { buffer in
                var offset = 0
                let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
                while offset < buffer.count {
                    guard DispatchTime.now().uptimeNanoseconds < deadline else { return false }
                    let written = Darwin.write(STDOUT_FILENO, buffer.baseAddress! + offset, buffer.count - offset)
                    if written > 0 { offset += written; continue }
                    if written < 0 && errno == EINTR { continue }
                    guard written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) else { return false }
                    var descriptor = pollfd(fd: STDOUT_FILENO, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&descriptor, 1, 50)
                }
                return true
            }
            if !success { lock.lock(); failed = true; lock.unlock(); failure(); return }
        }
    }
    func flushed() async { await withCheckedContinuation { continuation in queue.async { continuation.resume() } } }
}

@MainActor enum InterviewCaptureBoundary {
    static var refusedMicrophoneStarts = 0
}

final class InterviewDecodedProbe: @unchecked Sendable {
    static let value = InterviewDecodedProbe()
    private let lock = NSLock()
    private var lease: GuestReceiveLease?, flash: Double?, tone: Double?
    private var historyMisses = 0, firstMissing: [String: Double] = [:]
    func clear(_ lease: GuestReceiveLease) { lock.lock(); self.lease = lease; flash = nil; tone = nil; historyMisses = 0; firstMissing = [:]; lock.unlock() }
    func picture(_ frame: GuestVideoFrame) {
        guard frame.role == .camera else { return }
        CVPixelBufferLockBaseAddress(frame.pixels, .readOnly)
        let rgb = InterviewRecordingProbe.rgb(frame.pixels, x: 0.5, y: 0.5)
        CVPixelBufferUnlockBaseAddress(frame.pixels, .readOnly)
        lock.lock(); defer { lock.unlock() }
        if lease == frame.lease, flash == nil, rgb.allSatisfy({ $0 > 200 }) { flash = frame.pts.seconds }
    }
    func sound(_ frame: GuestAudioFrame) {
        guard let values = frame.pcm.floatChannelData else { return }
        let cue = (0..<Int(frame.pcm.frameLength)).first { abs(values[0][$0]) > 0.025 || abs(values[1][$0]) > 0.025 }
        lock.lock(); defer { lock.unlock() }
        if lease == frame.lease, tone == nil, let cue { tone = frame.pts.seconds + Double(cue) / 48_000 }
    }
    func snapshot() -> (Double?, Double?) { lock.lock(); defer { lock.unlock() }; return (flash, tone) }
    func missing(lease: GuestReceiveLease, at time: CMTime, history: (Double, Double)?) {
        lock.lock(); defer { lock.unlock() }
        guard lease == self.lease, let flash, time.seconds >= flash, time.seconds < flash + 0.35 else { return }
        historyMisses += 1
        if firstMissing.isEmpty, let history {
            firstMissing = ["query": time.seconds, "oldest": history.0, "newest": history.1,
                            "host": CMClockGetTime(CMClockGetHostTimeClock()).seconds]
        }
    }
    func historyTrace() -> [String: Double] {
        lock.lock(); defer { lock.unlock() }; var value = firstMissing; value["misses"] = Double(historyMisses); return value
    }
}

final class InterviewRecordingProbe: @unchecked Sendable {
    struct Picture { let pts: Double, rgb: [Int], screen: [Int] }
    struct PCM { let pts: CMTime, values: [Float], cue: CMTime?, peak: Float }
    private let lock = NSLock()
    private var pictures: [Picture] = [], program: [PCM] = [], isolated: [PCM] = []
    private var isoProgress: IsolatedVideoProgress?
    static func values(_ sample: CMSampleBuffer) -> [Float] {
        guard let format = sample.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format),
              let block = CMSampleBufferGetDataBuffer(sample) else { preconditionFailure("Actual canonical PCM required") }
        precondition(asbd.pointee.mSampleRate == 48_000 && asbd.pointee.mChannelsPerFrame == 2
                     && asbd.pointee.mBytesPerFrame == 8 && asbd.pointee.mBitsPerChannel == 32
                     && asbd.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0)
        let bytes = CMBlockBufferGetDataLength(block)
        precondition(bytes == CMSampleBufferGetNumSamples(sample) * 8)
        var values = [Float](repeating: 0, count: bytes / 4)
        values.withUnsafeMutableBytes {
            precondition(CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes, destination: $0.baseAddress!) == noErr)
        }
        return values
    }
    static func pcm(_ sample: CMSampleBuffer) -> PCM {
        let values = values(sample), peak = values.map { abs($0) }.max() ?? 0
        let cue = values.firstIndex { abs($0) > 0.025 }.map {
            sample.presentationTimeStamp + CMTime(value: Int64($0 / 2), timescale: 48_000)
        }
        return .init(pts: sample.presentationTimeStamp, values: values, cue: cue, peak: peak)
    }
    static func rgb(_ pixels: CVPixelBuffer, x: Double, y: Double) -> [Int] {
        let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
        let offset = CVPixelBufferGetBytesPerRow(pixels) * Int(Double(height) * y) + Int(Double(width) * x) * 4
        let bytes = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
        return [Int(bytes[offset + 2]), Int(bytes[offset + 1]), Int(bytes[offset])]
    }
    func picture(_ frame: CompositedFrame) {
        guard let pixels = frame.pixelBuffer else { return }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        let value = Picture(pts: frame.sampleBuffer.presentationTimeStamp.seconds,
                            rgb: Self.rgb(pixels, x: 0.5, y: 0.5), screen: Self.rgb(pixels, x: 0.85, y: 0.85))
        CVPixelBufferUnlockBaseAddress(pixels, .readOnly)
        lock.lock(); if pictures.count == 512 { pictures.removeFirst() }; pictures.append(value); lock.unlock()
    }
    func sound(_ sample: CMSampleBuffer, iso: Bool) {
        let value = Self.pcm(sample)
        lock.lock(); defer { lock.unlock() }
        if iso { if isolated.count == 1_024 { isolated.removeFirst() }; isolated.append(value) }
        else { if program.count == 1_024 { program.removeFirst() }; program.append(value) }
    }
    func status(_ value: IsolatedVideoProgress) { lock.lock(); isoProgress = value; lock.unlock() }
    var isoComplete: Bool { lock.lock(); defer { lock.unlock() }; return isoProgress?.status == "complete" }
    func clear() { lock.lock(); pictures.removeAll(); program.removeAll(); isolated.removeAll(); isoProgress = nil; lock.unlock() }
    func snapshot() -> (pictures: [Picture], program: [PCM], isolated: [PCM]) {
        lock.lock(); defer { lock.unlock() }; return (pictures, program, isolated)
    }
    func summary() -> [String: Any] {
        let value = snapshot()
        return ["pictures": value.pictures.count, "rgb": value.pictures.last?.rgb ?? [],
                "screenRGB": value.pictures.last?.screen ?? [], "picturePTS": value.pictures.last?.pts ?? 0,
                "programPackets": value.program.count, "isoPackets": value.isolated.count,
                "programPeak": Double(value.program.last?.peak ?? 0),
                "isoPeak": Double(value.isolated.last?.peak ?? 0),
                "whiteFrames": value.pictures.filter { $0.rgb.allSatisfy { $0 > 200 } }.count,
                "audiblePackets": value.program.filter { $0.peak > 0.025 }.count]
    }
}

@MainActor private final class InterviewProgramStudio {
    let mixer = AudioMixEngine(), scenes: SceneStore, preview: PreviewProgramModel
    let controller: StreamController, settings: SettingsSession, recorder: RecordingController, dispatcher: StudioCommandDispatcher
    let manager: NativeInterviewManager, probe = InterviewRecordingProbe()
    let directory: URL
    private var program: ProgramRecordingSession?, isolated: IsolatedVideoRecorder?, timeline: RecordingTimeline?
    private var videoTap: StreamController.FrameSubscription?, audioTap: StreamController.AudioTapSubscription?
    private var isoAudioTap: StreamController.AudioTapSubscription?, isoVideoTap: StreamController.RecordingVideoSubscription?
    private var firstISO: IsolatedVideoSource.Render?, firstLease: GuestReceiveLease?
    private var urls: (URL, URL)?, segment = 0
    init(configuration: NativeInterviewConfiguration, relay: NativeInterviewRelayConfiguration, directory: URL) throws {
        self.directory = directory
        try DesktopStorage.prepare(directory.appendingPathComponent("project"))
        var saved = StreamSettings.default
        saved.outputProfile = .init(canvasWidth: 320, canvasHeight: 180, frameRate: 30)
        saved.monitoringEnabled = false; saved.audioInputs = []
        DesktopSettingsStore().saveNonSecret(saved)
        scenes = SceneStore(directory: DesktopStorage.projectDirectory)
        let blank = scenes.addScene(Scene(name: "Owned Guest Program", layers: [], background: .solid(colorHex: "#000000")))
        preview = .init(selected: blank)
        controller = .init(sceneStore: scenes, previewProgram: preview, permissions: PermissionsManager(), audioEngine: mixer)
        settings = .init(store: DesktopSettingsStore(), controller: controller)
        recorder = .init(defaultDirectory: directory.appendingPathComponent("unused-default-recordings"))
        dispatcher = .init(controller: controller, sceneStore: scenes, session: settings, recorder: recorder, previewProgram: preview)
        // Default production host factory and controller-issued sink. Only the
        // actual local Worker TURN endpoint is replaced by our owned relay.
        manager = NativeInterviewManager(controller: controller, serviceFactory: { config, credential in
            let client = NativeInterviewServiceClient(configuration: config, credential: credential)
            return OwnedLocalRelayService(client: client, configuration: config, ownedRelay: relay)
        })
        dispatcher.bindInterviewManager(manager)
        controller.noteRecordingStarted()
    }
    func command(_ command: NativeInterviewCommand) throws {
        guard dispatcher.execute(.interview(command)).error == nil else { throw NativeInterviewError.changed }
    }
    func startSegment() throws {
        guard program == nil, let context = manager.currentReadyLease else { throw NativeInterviewError.changed }
        let sources = scenes.sources.filter {
            guard case .guest(let payload) = $0.payload else { return false }; return payload.slotID == context.receive.slot
        }
        guard let camera = sources.first(where: { if case .guest(let p) = $0.payload { return p.role == .camera }; return false }),
              let screen = sources.first(where: { if case .guest(let p) = $0.payload { return p.role == .screen }; return false }) else {
            throw NativeInterviewError.changed
        }
        var scene = preview.stagedScene!
        scene.layers = [.init(name: "Actual Guest Camera", sourceID: camera.id, payload: camera.payload, transform: .fullscreen),
                        .init(name: "Actual Guest Screen", sourceID: screen.id, payload: screen.payload,
                              transform: .init(pipCorner: .bottomRight, scale: 0.3))]
        guard dispatcher.execute(.updateScene(scene)).error == nil, dispatcher.execute(.take).error == nil else { throw NativeInterviewError.changed }
        let target = "source.\(camera.id)"
        guard let (videoToken, source) = controller.addRecordingVideoSource(targetID: target) else { throw NativeInterviewError.changed }
        isoVideoTap = videoToken
        if firstISO == nil { firstISO = source.makeRenderer(); firstLease = context.receive }
        segment += 1; probe.clear()
        let programURL = directory.appendingPathComponent("segment-\(segment)-program.mp4")
        let isoURL = directory.appendingPathComponent("segment-\(segment)-guest-camera.mp4")
        var configuration = ProgramRecordingSession.Configuration()
        configuration.frameRate = 30; configuration.sessionID = "owned-native-interview-\(UUID())"
        configuration.context = .init(projectID: "synthetic-native-interview-show", profileID: "actual-manager-default-factory")
        configuration.isolatedFiles = [isoURL.lastPathComponent]
        let common = RecordingTimeline()
        let program = ProgramRecordingSession(outputURL: programURL, configuration: configuration, timeline: common)
        let selection = IsolatedVideoSelection(targetID: target, name: "Actual Manager Guest Camera", processing: .raw,
            resolution: .hd720, frameRate: 30, codec: .h264, quality: .standard,
            audioTargetID: target, audioName: "Admitted microphone")
        let isolated = IsolatedVideoRecorder(outputURL: isoURL, selection: selection, source: source,
            sessionID: configuration.sessionID, segmentIndex: segment, programFile: programURL.lastPathComponent,
            context: configuration.context, budget: .current, timeline: common, event: probe.status)
        self.program = program; self.isolated = isolated; timeline = common; urls = (programURL, isoURL)
        let probe = self.probe
        videoTap = controller.addFrameSink(capacity: 8) { frame in probe.picture(frame); program.appendVideo(frame.sampleBuffer) }
        audioTap = controller.addProgramAudioTap(capacity: 16) { sample in probe.sound(sample, iso: false); program.appendAudio(sample) }
        isoAudioTap = controller.addRecordingAudioTap(targetID: target, processing: .beforeEffects) { sample in
            probe.sound(sample, iso: true); isolated.appendAudio(sample)
        }
        precondition(isoAudioTap != nil && InterviewCaptureBoundary.refusedMicrophoneStarts == 1)
    }
    func assertQuiet(since: Double) {
        let live = probe.snapshot()
        let pictures = live.pictures.filter { $0.pts >= since + 0.05 }
        let audio = live.program.filter { $0.pts.seconds >= since + 0.05 }
        let iso = live.isolated.filter { $0.pts.seconds >= since + 0.05 }
        precondition(pictures.count >= 5 && audio.count >= 15 && iso.count >= 15, "Enough actual media must cover the quiet interval")
        precondition(pictures.allSatisfy { $0.rgb.allSatisfy { $0 < 5 } && $0.screen.allSatisfy { $0 < 5 } }, "Backstage must paint black pixels")
        precondition(audio.allSatisfy { $0.peak < 0.00001 } && iso.allSatisfy { $0.peak < 0.00001 }, "Backstage must withhold Program and isolated PCM")
    }
    func stalePinnedISORejected() -> Bool {
        guard let lease = manager.currentReadyLease?.receive, let firstLease, lease != firstLease,
              let frame = firstISO?(CGSize(width: 320, height: 180), CMClockGetTime(CMClockGetHostTimeClock()),
                                   CMTime(value: 1, timescale: 30), 1, .raw) else { return false }
        return !frame.sourceAvailable
    }
    func finishSegment() async throws -> [String: Any] {
        guard let program, let isolated, let urls, let timeline else { throw NativeInterviewError.changed }
        let live = probe.snapshot()
        guard let tone = live.program.compactMap(\.cue).first, let isoTone = live.isolated.compactMap(\.cue).first,
              let flash = live.pictures.first(where: { $0.rgb.allSatisfy { $0 > 200 } }) else { throw NativeInterviewError.changed }
        precondition(CMTimeCompare(tone, isoTone) == 0, "Real pre-writer Program/ISO cues must retain exact original CMTime")
        precondition(abs(flash.pts - tone.seconds) < 0.05, "Actual Chrome flash/tone must remain within50ms through the shipping compositor/mixer")
        let audible = live.program.filter { $0.peak > 0.025 }
        precondition(audible.count >= 30, "Enough real audible PCM must survive routing")
        for sample in audible {
            precondition(live.isolated.first { CMTimeCompare($0.pts, sample.pts) == 0 }?.values == sample.values,
                         "Actual Program and controller-resolved ISO must retain every original audible PCM window")
        }
        let result = await withCheckedContinuation { continuation in program.finish { continuation.resume(returning: $0) } }
        await withCheckedContinuation { continuation in isolated.finish { continuation.resume() } }
        if let videoTap { controller.removeFrameSink(videoTap) }; if let audioTap { controller.removeAudioTap(audioTap) }
        if let isoAudioTap { controller.removeAudioTap(isoAudioTap) }; if let isoVideoTap { controller.removeRecordingVideoSource(isoVideoTap) }
        self.program = nil; self.isolated = nil; self.timeline = nil; self.urls = nil
        videoTap = nil; audioTap = nil; isoAudioTap = nil; isoVideoTap = nil
        guard result.completed, probe.isoComplete else { throw NativeInterviewError.transport }
        var proof = try await InterviewRecordedAnalysis.inspect(urls.0, isoURL: urls.1)
        let meta = try JSONSerialization.jsonObject(with: Data(contentsOf: urls.1.appendingPathExtension("video-isolated.json"))) as! [String: Any]
        precondition(meta["programFile"] as? String == urls.0.lastPathComponent
                     && meta["commonSourceStartSeconds"] as? Double == result.progress.sessionStartSourceSeconds)
        proof["type"] = "proof"; proof["segment"] = segment; proof["liveAVDelta"] = flash.pts - tone.seconds
        let original = InterviewDecodedProbe.value.snapshot()
        guard let sourceFlash = original.0, let sourceTone = original.1 else { throw NativeInterviewError.changed }
        proof["sourceAVDelta"] = sourceFlash - sourceTone
        proof["videoPlayout"] = flash.pts - sourceFlash; proof["audioPlayout"] = tone.seconds - sourceTone
        proof["isoHistoryMisses"] = InterviewDecodedProbe.value.historyTrace()["misses"] ?? -1
        proof["preWriterWindows"] = audible.count; proof["leaseGeneration"] = manager.currentReadyLease?.receive.generation ?? 0
        precondition(timeline.snapshot().origin.isNumeric)
        return proof
    }
    func close() async {
        manager.shutdown(); controller.retireGuestMedia(); controller.noteRecordingStopped(); await mixer.stop()
        scenes.flushPendingWrites()
    }
}

@main @MainActor private enum NativeInterviewProgramISOCLI {
    static func main() async {
        _ = Darwin.signal(SIGPIPE, SIG_IGN)
        _ = fcntl(STDOUT_FILENO, F_SETFL, fcntl(STDOUT_FILENO, F_GETFL) | O_NONBLOCK)
        let input = InterviewCLIInput(), output = InterviewCLIOutput { input.close() }
        var studio: InterviewProgramStudio?
        do {
            guard CommandLine.arguments.count == 2 else { throw NativeInterviewError.configuration }
            let url = URL(fileURLWithPath: CommandLine.arguments[1])
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = (attributes[.size] as? NSNumber)?.intValue, size <= 16_384,
                  let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue, permissions & 0o077 == 0,
                  attributes[.type] as? FileAttributeType == .typeRegular else { throw NativeInterviewError.configuration }
            let owned = try JSONDecoder().decode(InterviewMediaConfiguration.self, from: Data(contentsOf: url))
            let configuration = try NativeInterviewConfiguration(serviceURL: owned.serviceURL,
                allowedOrigin: owned.serviceURL, allowLoopbackHTTPForValidation: true)
            let relay = NativeInterviewRelayConfiguration(servers: [.init(urls: [owned.turnURL], username: owned.turnUsername,
                credential: try .init(owned.turnCredential))], expires: Date().addingTimeInterval(120), refreshAt: Date().addingTimeInterval(100))
            try FileManager.default.createDirectory(at: owned.mediaDirectory, withIntermediateDirectories: true)
            let current = try InterviewProgramStudio(configuration: configuration, relay: relay, directory: owned.mediaDirectory)
            studio = current
            precondition(current.controller.guestVideoFrames.statistics().accepted == 0)
            var terminal = false, quietFrontier: Double?
            let poll = Task {
                while !Task.isCancelled && !terminal {
                    let value = current.manager.state.snapshot
                    let admission = current.mixer.guestAdmissionSnapshot()
                    var state: [String: Any] = ["type": "state", "phase": value.phase.rawValue,
                        "failure": value.failure.map { $0.rawValue } ?? "", "members": value.members.map {
                            ["id": $0.id.uuidString.lowercased(), "membership": $0.membership.rawValue,
                             "revision": $0.membershipRevision, "media": $0.media.rawValue,
                             "approved": $0.screenApproved, "sharing": $0.screenSharing] as [String: Any]
                        }, "programAllowed": current.manager.state.routes.values.contains { $0.programAllowed },
                        "live": current.probe.summary(), "acceptedVideo": current.controller.guestVideoFrames.statistics().accepted,
                        "audioAccepted": admission.acceptedPackets, "audioPTS": admission.lastPTS.isNumeric ? admission.lastPTS.seconds : 0,
                        "audioRejected": admission.rejectedPackets,
                        "mapping": admission.mappingGeneration?.uuidString.lowercased() ?? ""]
                    state["receiver"] = current.manager.fixtureReceiverDiagnostics
                    if let context = current.manager.currentReadyLease {
                        state["lease"] = ["generation": context.receive.generation, "slot": context.receive.slot.uuidString.lowercased(),
                                          "peer": context.receive.peerID.uuidString.lowercased(), "negotiation": context.receive.negotiation.uuidString.lowercased()]
                        if let pair = current.manager.fixtureSelectedICEPair {
                            state["transport"] = ["local": pair.local.label, "remote": pair.remote.label, "udp": pair.udp]
                        }
                    }
                    _ = output.emit(state)
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            let lifetime = Task { try? await Task.sleep(for: .seconds(90)); input.close() }
            defer { terminal = true; poll.cancel(); lifetime.cancel(); input.close(); FileHandle.standardInput.readabilityHandler = nil }
            FileHandle.standardInput.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil; input.close() } else { input.receive(data) }
            }
            commandLoop: for await line in input.stream {
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let command = object["type"] as? String else { throw NativeInterviewError.malformed }
                let guest = (object["id"] as? String).flatMap(UUID.init(uuidString:))
                switch command {
                case "create":
                    try await current.manager.create(configuration: configuration, credential: try .init(owned.operatorToken))
                    let connectionDeadline = ContinuousClock.now + .seconds(6)
                    while current.manager.state.snapshot.phase != .connected && ContinuousClock.now < connectionDeadline {
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    guard current.manager.state.snapshot.phase == .connected else { throw NativeInterviewError.timeout }
                    // Capability crosses PRIVATE owned IPC only, never public
                    // logs, a scene, defaults, clipboard or retained artifacts.
                    _ = output.emit(["type": "private-invite", "url": try await current.manager.inviteForSharing().absoluteString])
                case "admit": guard let guest else { throw NativeInterviewError.malformed }; try current.command(.admit(guest))
                case "begin": try current.startSegment(); quietFrontier = CMClockGetTime(CMClockGetHostTimeClock()).seconds
                case "quiet":
                    guard let quietFrontier else { throw NativeInterviewError.changed }
                    current.assertQuiet(since: quietFrontier); _ = output.emit(["type": "quiet", "passed": true])
                case "onair":
                    guard let guest else { throw NativeInterviewError.malformed }
                    guard let lease = current.manager.currentReadyLease?.receive else { throw NativeInterviewError.changed }
                    InterviewDecodedProbe.value.clear(lease)
                    try current.command(.onair(guest))
                case "backstage":
                    guard let guest else { throw NativeInterviewError.malformed }
                    try current.command(.backstage(guest)); quietFrontier = CMClockGetTime(CMClockGetHostTimeClock()).seconds
                case "approval":
                    guard let guest, let approved = object["approved"] as? Bool else { throw NativeInterviewError.malformed }
                    try current.command(.approveScreen(guest, approved))
                case "finish":
                    let input = InterviewDecodedProbe.value.snapshot(), capture = current.probe.snapshot()
                    let flash = capture.pictures.first { $0.rgb.allSatisfy { $0 > 200 } }?.pts
                    let tone = capture.program.compactMap(\.cue).first?.seconds
                    _ = output.emit(["type": "clock-trace", "decodedFlash": input.0 ?? 0, "decodedTone": input.1 ?? 0,
                                     "programFlash": flash ?? 0, "programTone": tone ?? 0,
                                     "history": InterviewDecodedProbe.value.historyTrace()])
                    _ = output.emit(try await current.finishSegment())
                case "rejoin": try current.command(.disconnect); try current.command(.rejoin)
                case "old-iso":
                    precondition(current.stalePinnedISORejected(), "First actual ISO renderer cannot adopt the rejoined peer")
                    _ = output.emit(["type": "old-iso", "rejected": true])
                case "end": try current.command(.end)
                case "stop": break commandLoop
                default: throw NativeInterviewError.malformed
                }
            }
            terminal = true; poll.cancel(); lifetime.cancel(); input.close(); FileHandle.standardInput.readabilityHandler = nil
            await current.close()
            _ = output.emit(["type": "stopped"]); await output.flushed()
        } catch {
            input.close(); FileHandle.standardInput.readabilityHandler = nil
            await studio?.close()
            _ = output.emit(["type": "error", "reason": (error as? NativeInterviewError ?? .transport).rawValue])
            await output.flushed(); Darwin.exit(1)
        }
    }
}
