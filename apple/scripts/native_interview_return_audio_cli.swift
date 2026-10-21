import AppKit
import AVFoundation
import CoreMedia
import CryptoKit
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



private final class ReturnProgramProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var packets: [(CMTime, [Float])] = []
    func receive(_ sample: CMSampleBuffer) {
        guard let block = sample.dataBuffer, sample.numSamples == 512 else { return }
        var values = [Float](repeating: 0, count: 1_024)
        guard values.withUnsafeMutableBytes({ CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }) == noErr else { return }
        lock.lock(); if packets.count == 64 { packets.removeFirst() }; packets.append((sample.presentationTimeStamp, values)); lock.unlock()
    }
    func snapshot() -> [String: Any] {
        lock.lock(); let packets = packets; lock.unlock()
        var amplitudes: [Double] = []
        for (side, frequency) in [(0, 440.0), (1, 880.0), (0, 2_600.0), (1, 2_600.0)] {
            var re = 0.0, im = 0.0, count = 0
            for (pts, values) in packets {
                for index in 0..<512 {
                    let phase = (pts.seconds + Double(index) / 48_000) * 2 * .pi * frequency
                    let value = Double(values[index * 2 + side])
                    re += value * cos(phase); im += value * sin(phase); count += 1
                }
            }
            amplitudes.append(count > 0 ? 2 * hypot(re, im) / Double(count) : 0)
        }
        return ["chunks": packets.count, "pts": packets.last?.0.seconds ?? 0,
                "own440and880": Array(amplitudes.prefix(2)), "private2600": Array(amplitudes.suffix(2))]
    }
}
private final class ReturnPrivateTone: @unchecked Sendable {
    private let lock = NSLock()
    private var audible = false
    func set(_ value: Bool) { lock.lock(); audible = value; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return audible }
}
@MainActor private final class ReturnStudio {
    let mixer = AudioMixEngine(), scenes: SceneStore, preview: PreviewProgramModel
    let controller: StreamController, settings: SettingsSession, recorder: RecordingController, dispatcher: StudioCommandDispatcher
    let manager: NativeInterviewManager
    let chat: StudioChatCoordinator
    let program = ReturnProgramProbe(), programToken = UUID()
    let privacyProbes = (0..<4).map { _ in ReturnProgramProbe() }
    let privacyTokens = (0..<4).map { _ in UUID() }
    let recipientProbe = ReturnProgramProbe(), recipientProbeToken = UUID()
    let local = AudioChannelID.media(SourceDefinitionID())
    private var producer: Task<Void, Never>?
    private var privateMicProducer: Task<Void, Never>?
    private let privateMicTone = ReturnPrivateTone()
    init(configuration: NativeInterviewConfiguration, relay: NativeInterviewRelayConfiguration, directory: URL) throws {
        try DesktopStorage.prepare(directory.appendingPathComponent("project"))
        var saved = StreamSettings.default
        saved.outputProfile = .init(canvasWidth: 320, canvasHeight: 180, frameRate: 30)
        saved.monitoringEnabled = false; saved.audioInputs = []
        saved.micVolume = 0
        DesktopSettingsStore().saveNonSecret(saved)
        scenes = SceneStore(directory: DesktopStorage.projectDirectory)
        let blank = scenes.addScene(Scene(name: "Owned Guest Return", layers: [], background: .solid(colorHex: "#000000")))
        preview = .init(selected: blank)
        controller = .init(sceneStore: scenes, previewProgram: preview, permissions: PermissionsManager(), audioEngine: mixer)
        settings = .init(store: DesktopSettingsStore(), controller: controller)
        recorder = .init(defaultDirectory: directory.appendingPathComponent("unused-default-recordings"))
        dispatcher = .init(controller: controller, sceneStore: scenes, session: settings, recorder: recorder, previewProgram: preview)
        chat = .init(dispatcher: dispatcher, previewProgram: preview)
        manager = NativeInterviewManager(controller: controller, serviceFactory: { config, credential in
            let client = NativeInterviewServiceClient(configuration: config, credential: credential)
            return OwnedLocalRelayService(client: client, configuration: config, ownedRelay: relay)
        })
        dispatcher.bindInterviewManager(manager)
        manager.bindPublicChat(chat)
        controller.noteRecordingStarted()
        controller.guestTalkbackFixtureCapture = { $0 == .microphone(deviceUID: nil) }
    }
    func command(_ command: NativeInterviewCommand) throws {
        guard dispatcher.execute(.interview(command)).error == nil else { throw NativeInterviewError.changed }
    }
    func startTone() async {
        _ = await mixer.reserveCaptureHoldback(token: UUID(), milliseconds: 60)
        await mixer.addTap(bus: .monitor, token: privacyTokens[0], sink: privacyProbes[0].receive)
        await mixer.addTap(bus: .aux, token: privacyTokens[1], sink: privacyProbes[1].receive)
        await mixer.addIsolatedTap(channel: .microphone(deviceUID: nil), token: privacyTokens[2], processing: .beforeEffects, sink: privacyProbes[2].receive)
        await mixer.addIsolatedTap(channel: .microphone(deviceUID: nil), token: privacyTokens[3], processing: .afterEffects, sink: privacyProbes[3].receive)
        let micEngine = mixer, micTone = privateMicTone
        privateMicProducer = Task.detached {
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
            let origin = CMClockGetTime(CMClockGetHostTimeClock()) - CMTime(value: 512, timescale: 48_000)
            var index: Int64 = 0
            while !Task.isCancelled {
                let pts = origin + CMTime(value: index * 512, timescale: 48_000)
                let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!; pcm.frameLength = 512
                for frame in 0..<512 {
                    let phase = (pts.seconds + Double(frame) / 48_000) * 2 * .pi * 2_600
                    let value = micTone.get() ? Float(0.25 * sin(phase)) : 0
                    pcm.floatChannelData![0][frame] = value; pcm.floatChannelData![1][frame] = value
                }
                micEngine.enqueue(.microphone(deviceUID: nil), ReturnFixturePCM.sample(pcm, pts: pts))
                index += 1
                try? await Task.sleep(for: .seconds(max(0, (origin + CMTime(value: index * 512 + 512, timescale: 48_000) - CMClockGetTime(CMClockGetHostTimeClock())).seconds)))
            }
        }
        await mixer.setChannelGain(local, volume: 1, isMuted: false)
        await mixer.addTap(bus: .program, token: programToken, sink: program.receive)
        let engine = mixer, local = local
        producer = Task.detached {
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
            let origin = CMClockGetTime(CMClockGetHostTimeClock()) + CMTime(value: 3_840, timescale: 48_000)
            let clock = ContinuousClock(), start = ContinuousClock.now
            var index: Int64 = 0
            while !Task.isCancelled {
                let pts = origin + CMTime(value: index * 512, timescale: 48_000)
                let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
                pcm.frameLength = 512
                for frame in 0..<512 {
                    let phase = Double(index * 512 + Int64(frame)) / 48_000
                    pcm.floatChannelData![0][frame] = Float(0.4 * sin(phase * 2 * .pi * 1_000))
                    pcm.floatChannelData![1][frame] = Float(0.2 * sin(phase * 2 * .pi * 1_700))
                }
                engine.enqueue(local, ReturnFixturePCM.sample(pcm, pts: pts))
                index += 1
                try? await clock.sleep(until: start + .seconds(Double(index * 512) / 48_000))
            }
        }
    }
    func volume(_ value: Float, muted: Bool) async { await mixer.setChannelGain(local, volume: value, isMuted: muted) }
    func privateTone(_ enabled: Bool) { privateMicTone.set(enabled) }
    func publicMessage(_ id: String, text: String) throws {
        guard id.utf8.count <= 128, text.utf8.count <= 16_384 else { throw NativeInterviewError.malformed }
        let data = try JSONSerialization.data(withJSONObject: ["action": "event", "timestamp": 1_800_000_000,
            "payload": ["connectionIdentifier": "owned-public-return-fixture", "eventTypeId": 7,
                "eventPayload": ["liveChatMessageId": id, "text": text,
                    "author": ["displayName": "Owned Public Viewer", "isChatModerator": true]]]])
        chat.receive(data)
    }
    func close() async {
        privateMicProducer?.cancel(); privateMicProducer = nil
        producer?.cancel(); producer = nil
        manager.shutdown(); chat.shutdown(); controller.retireGuestMedia(); controller.noteRecordingStopped(); await mixer.removeTap(programToken)
        for token in privacyTokens { await mixer.removeTap(token) }
        await mixer.removeTap(recipientProbeToken)
        await mixer.stop()
        scenes.flushPendingWrites()
    }
}

@main @MainActor private enum NativeInterviewReturnCLI {
    static func main() async {
        _ = Darwin.signal(SIGPIPE, SIG_IGN)
        _ = fcntl(STDOUT_FILENO, F_SETFL, fcntl(STDOUT_FILENO, F_GETFL) | O_NONBLOCK)
        let input = InterviewCLIInput(), output = InterviewCLIOutput { input.close() }
        var studio: ReturnStudio?
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
            let current = try ReturnStudio(configuration: configuration, relay: relay, directory: owned.mediaDirectory)
            studio = current; await current.startTone()
            var terminal = false
            let poll = Task {
                while !Task.isCancelled && !terminal {
                    let value = current.manager.state.snapshot
                    let admission = current.mixer.guestAdmissionSnapshot()
                    var state: [String: Any] = ["type": "state", "phase": value.phase.rawValue,
                        "failure": value.failure.map { $0.rawValue } ?? "", "members": value.members.map {
                            ["id": $0.id.uuidString.lowercased(), "membership": $0.membership.rawValue,
                             "media": $0.media.rawValue, "returnAudio": $0.returnAudio.rawValue,
                             "publicChat": $0.publicChat.rawValue, "publicChatDropped": $0.publicChatDropped,
                             "approved": $0.screenApproved, "sharing": $0.screenSharing] as [String: Any]
                        }, "audioAccepted": admission.acceptedPackets, "program": current.program.snapshot(),
                        "programAllowed": current.manager.state.routes.values.contains { $0.programAllowed },
                        "privateTalkback": current.manager.talkback != nil]
                    state["publicChatEnabled"] = current.manager.publicChatContext != nil
                    state["privacyBuses"] = current.privacyProbes.map { $0.snapshot() }
                    state["recipientPCM"] = current.recipientProbe.snapshot()
                    if let context = current.manager.currentReadyLease {
                        state["lease"] = ["generation": context.receive.generation, "slot": context.receive.slot.uuidString.lowercased(),
                                          "peer": context.receive.peerID.uuidString.lowercased(), "negotiation": context.receive.negotiation.uuidString.lowercased()]
                        if let pair = current.manager.fixtureSelectedICEPair {
                            state["transport"] = ["local": pair.local.label, "remote": pair.remote.label, "udp": pair.udp]
                        }
                    }
                    state["privateMessages"] = current.manager.privateMessages.map {
                        ["fromGuest": $0.fromGuest, "delivery": $0.delivery.rawValue,
                         "digest": SHA256.hash(data: Data($0.text.utf8)).map { String(format: "%02x", $0) }.joined()] as [String: Any]
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
            var retainedPrivateContext: NativeInterviewPeerLease?
            var retainedTalkback: (NativeInterviewPeerLease, UUID)?
            var retainedPublicContext: NativeInterviewPeerLease?
            commandLoop: for await line in input.stream {
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let command = object["type"] as? String else { throw NativeInterviewError.malformed }
                let guest = (object["id"] as? String).flatMap(UUID.init(uuidString:))
                switch command {
                case "public-chat-on":
                    guard let context = current.manager.currentReadyLease else { throw NativeInterviewError.changed }
                    if retainedPublicContext == nil { retainedPublicContext = context }
                    try current.command(.setPublicChatReturn(context, true)); _ = output.emit(["type": "ack", "command": command])
                case "public-chat-off":
                    guard let context = current.manager.currentReadyLease else { throw NativeInterviewError.changed }
                    try current.command(.setPublicChatReturn(context, false)); _ = output.emit(["type": "ack", "command": command])
                case "public-chat-message":
                    guard let id = object["messageID"] as? String, let text = object["text"] as? String else { throw NativeInterviewError.malformed }
                    try current.publicMessage(id, text: text); _ = output.emit(["type": "ack", "command": command])
                case "public-chat-burst":
                    for index in 0..<40 { try current.publicMessage("burst-\(index)", text: "Owned public burst \(index)") }
                    _ = output.emit(["type": "ack", "command": command])
                case "public-chat-remove":
                    guard let id = object["messageID"] as? String else { throw NativeInterviewError.malformed }
                    current.chat.receive(.removed(ids: [StudioChatMessageIdentity.make(provider: "YouTube", messageID: id)]))
                    _ = output.emit(["type": "ack", "command": command])
                case "public-chat-freeze":
                    // Owned MainActor stall proves the shipping guest clears
                    // a stale enabled feed even without receiving Off.
                    await MainActor.run { Thread.sleep(forTimeInterval: 7.2) }
                    _ = output.emit(["type": "ack", "command": command])
                case "public-chat-close":
                    current.chat.shutdown(); _ = output.emit(["type": "ack", "command": command])
                case "stale-public-chat":
                    guard let context = retainedPublicContext, current.manager.currentReadyLease != context,
                          current.dispatcher.execute(.interview(.setPublicChatReturn(context, true))).error != nil,
                          current.dispatcher.execute(.interview(.setPublicChatReturn(context, false))).error != nil else { throw NativeInterviewError.changed }
                    _ = output.emit(["type": "ack", "command": "stale-public-chat-rejected"])
                case "create":
                    try await current.manager.create(configuration: configuration, credential: try .init(owned.operatorToken))
                    let deadline = ContinuousClock.now + .seconds(6)
                    while current.manager.state.snapshot.phase != .connected && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
                    guard current.manager.state.snapshot.phase == .connected else { throw NativeInterviewError.timeout }
                    _ = output.emit(["type": "private-invite", "url": try await current.manager.inviteForSharing().absoluteString])
                case "admit": guard let guest else { throw NativeInterviewError.malformed }; try current.command(.admit(guest))
                case "message":
                    guard let context = current.manager.currentReadyLease, context.receive.peerID == guest,
                          let text = object["text"] as? String else { throw NativeInterviewError.changed }
                    if retainedPrivateContext == nil { retainedPrivateContext = context }
                    try current.command(.sendPrivateMessage(context, text))
                case "stale-message":
                    guard let context = retainedPrivateContext,
                          current.dispatcher.execute(.interview(.sendPrivateMessage(context, "Owned stale private command"))).error != nil else {
                        throw NativeInterviewError.changed
                    }
                    _ = output.emit(["type": "ack", "command": "stale-message-rejected"])
                case "talkback-start":
                    guard let context = current.manager.currentReadyLease else { throw NativeInterviewError.changed }
                    guard await current.mixer.addGuestReturnTap(context.receive, token: current.recipientProbeToken,
                        sink: { [probe = current.recipientProbe] in probe.receive($0.sample) }) else { throw NativeInterviewError.changed }
                    let press = UUID()
                    try current.command(.beginTalkback(context, .microphone(deviceUID: nil), press))
                    if retainedTalkback == nil { retainedTalkback = (context, press) }
                    current.privateTone(true)
                    _ = output.emit(["type": "ack", "command": "talkback-start"])
                case "talkback-stop":
                    current.privateTone(false)
                    guard let hold = current.manager.talkback else { throw NativeInterviewError.changed }
                    try current.command(.endTalkback(hold.context, hold.press))
                    _ = output.emit(["type": "ack", "command": "talkback-stop"])
                case "talkback-focus-loss":
                    current.privateTone(false)
                    NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
                    _ = output.emit(["type": "ack", "command": "talkback-focus-loss"])
                case "stale-talkback":
                    guard let (context, press) = retainedTalkback,
                          current.dispatcher.execute(.interview(.beginTalkback(context, .microphone(deviceUID: nil), press))).error != nil,
                          current.dispatcher.execute(.interview(.endTalkback(context, press))).error != nil else { throw NativeInterviewError.changed }
                    _ = output.emit(["type": "ack", "command": "stale-talkback-rejected"])
                case "onair": guard let guest else { throw NativeInterviewError.malformed }; try current.command(.onair(guest))
                case "backstage": guard let guest else { throw NativeInterviewError.malformed }; try current.command(.backstage(guest))
                case "mute": await current.volume(1, muted: true); _ = output.emit(["type": "ack", "command": "mute"])
                case "restore": await current.volume(0.4, muted: false); _ = output.emit(["type": "ack", "command": "restore"])
                case "rejoin": current.privateTone(false); try current.command(.disconnect); try current.command(.rejoin)
                case "remove": guard let guest else { throw NativeInterviewError.malformed }; try current.command(.remove(guest))
                case "end": try current.command(.end)
                case "stop": break commandLoop
                default: throw NativeInterviewError.malformed
                }
            }
            terminal = true; poll.cancel(); lifetime.cancel(); input.close(); FileHandle.standardInput.readabilityHandler = nil
            await current.close()
            precondition(InterviewCaptureBoundary.refusedMicrophoneStarts >= 1)
            _ = output.emit(["type": "stopped"]); await output.flushed()
        } catch {
            input.close(); FileHandle.standardInput.readabilityHandler = nil; await studio?.close()
            _ = output.emit(["type": "error", "reason": (error as? NativeInterviewError ?? .transport).rawValue])
            await output.flushed(); Darwin.exit(1)
        }
    }
}

private enum ReturnFixturePCM {
    static func sample(_ pcm: AVAudioPCMBuffer, pts: CMTime) -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8,
            mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var description: CMAudioFormatDescription?
        precondition(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0,
            layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description) == noErr)
        var block: CMBlockBuffer?
        precondition(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: 512 * 8, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: 512 * 8, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr)
        var values = [Float](repeating: 0, count: 1_024)
        for index in 0..<512 { for side in 0..<2 { values[index * 2 + side] = pcm.floatChannelData![side][index] } }
        values.withUnsafeBytes { precondition(CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: $0.count) == noErr) }
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000), presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        precondition(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: description,
            sampleCount: 512, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0,
            sampleSizeArray: nil, sampleBufferOut: &sample) == noErr)
        return sample!
    }
}
