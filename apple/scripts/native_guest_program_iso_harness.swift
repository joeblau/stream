import AVFoundation
import CoreMedia
import Foundation
import StreamCore

/// The source peer only sends owned synthetic compressed RTP. Every picture
/// and audio sample reaching the writers comes through the production decoder,
/// due-frame store, compositor, guest admission registry and bus/ISO taps.
private final class ProgramGuestBridge: @unchecked Sendable {
    private let lock = NSLock()
    weak var receiver: NativeGuestReceiver?
    var peer: OpaquePointer?
    private var failed = false
    func incoming(_ type: String, _ value: String, _ mid: String) {
        let accepted = type == "offer" ? receiver?.offer(value) : receiver?.candidate(value, mid: mid)
        if accepted != true { lock.lock(); failed = true; lock.unlock() }
    }
    func outgoing(_ type: String, _ value: String, _ mid: String) {
        lock.lock(); let current = peer; lock.unlock()
        if SGPeerFixtureSignal(current, type, value, mid) == 0 { lock.lock(); failed = true; lock.unlock() }
    }
    func hasFailed() -> Bool { lock.lock(); defer { lock.unlock() }; return failed }
}
private func programGuestSignal(_ context: UnsafeMutableRawPointer?, _ type: UnsafePointer<CChar>?,
                                _ value: UnsafePointer<CChar>?, _ mid: UnsafePointer<CChar>?) {
    guard let context, let type, let value, let mid else { return }
    Unmanaged<ProgramGuestBridge>.fromOpaque(context).takeUnretainedValue()
        .incoming(String(cString: type), String(cString: value), String(cString: mid))
}

private final class ProgramGuestProbe: @unchecked Sendable {
    struct Picture { let pts: Double; let red, green, blue: Int }
    struct Sound { let pts: Double; let peak: Float; let cue: Double?; let cueTime: CMTime? }
    struct PCM { let pts: CMTime; let bytes: Data }
    private let lock = NSLock()
    private var pictures: [Picture] = [], program: [Sound] = [], isolated: [Sound] = []
    private var videoCount = 0, audioCount = 0, rejectedVideo = 0, rejectedAudio = 0
    private var lastVideo: GuestVideoFrame?, lastAudio: GuestAudioFrame?
    private var decodedFlash: Double?, decodedTone: Double?
    private var programPCM: [PCM] = [], isolatedPCM: [PCM] = []
    private var initialProgramSamples: [CMSampleBuffer] = [], firstIsolatedSample: CMSampleBuffer?
    private var programSourceSamples: [CMSampleBuffer] = [], isolatedSourceSamples: [CMSampleBuffer] = []
    private var isoProgress: IsolatedVideoProgress?
    func receive(_ frame: GuestVideoFrame, accepted: Bool) {
        precondition(!frame.duration.isNumeric, "RTP video has no inferred source duration")
        CVPixelBufferLockBaseAddress(frame.pixels, .readOnly)
        let offset = CVPixelBufferGetBytesPerRow(frame.pixels) * 90 + 160 * 4
        let bytes = CVPixelBufferGetBaseAddress(frame.pixels)!.assumingMemoryBound(to: UInt8.self)
        let isFlash = bytes[offset] > 200 && bytes[offset + 1] > 200 && bytes[offset + 2] > 200
        CVPixelBufferUnlockBaseAddress(frame.pixels, .readOnly)
        lock.lock(); defer { lock.unlock() }
        videoCount += 1; if !accepted { rejectedVideo += 1 }; lastVideo = frame
        if accepted && isFlash && decodedFlash == nil { decodedFlash = frame.pts.seconds }
    }
    func receive(_ frame: GuestAudioFrame, accepted: Bool) {
        let cue = (0..<Int(frame.pcm.frameLength)).first { abs(frame.pcm.floatChannelData![0][$0]) > 0.025 }
            .map { frame.pts.seconds + Double($0) / 48_000 }
        lock.lock(); defer { lock.unlock() }
        audioCount += 1; if !accepted { rejectedAudio += 1 }; lastAudio = frame
        if accepted && decodedTone == nil { decodedTone = cue }
    }
    func picture(_ frame: CompositedFrame) {
        guard let pixels = frame.pixelBuffer else { return }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        let offset = CVPixelBufferGetBytesPerRow(pixels) * (CVPixelBufferGetHeight(pixels) / 2)
            + (CVPixelBufferGetWidth(pixels) / 2) * 4
        let bytes = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
        let value = Picture(pts: frame.sampleBuffer.presentationTimeStamp.seconds,
                            red: Int(bytes[offset + 2]), green: Int(bytes[offset + 1]), blue: Int(bytes[offset]))
        CVPixelBufferUnlockBaseAddress(pixels, .readOnly)
        lock.lock(); if pictures.count == 512 { pictures.removeFirst() }; pictures.append(value); lock.unlock()
    }
    static func pcmValues(_ sample: CMSampleBuffer) -> [Float] {
        guard let format = sample.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format) else {
            preconditionFailure("Decoded canonical LPCM format required")
        }
        precondition(asbd.pointee.mSampleRate == 48_000 && asbd.pointee.mChannelsPerFrame == 2
                     && asbd.pointee.mBytesPerFrame == 8 && asbd.pointee.mBitsPerChannel == 32
                     && asbd.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0)
        guard let block = CMSampleBufferGetDataBuffer(sample) else { preconditionFailure("Mixed LPCM block required") }
        let bytes = CMBlockBufferGetDataLength(block)
        precondition(bytes == CMSampleBufferGetNumSamples(sample) * 8)
        var values = [Float](repeating: 0, count: bytes / MemoryLayout<Float>.size)
        values.withUnsafeMutableBytes { pointer in
            precondition(CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes, destination: pointer.baseAddress!) == noErr)
        }
        return values
    }
    static func sound(_ sample: CMSampleBuffer) -> Sound {
        let values = pcmValues(sample)
        let cueTime = values.firstIndex(where: { abs($0) > 0.025 }).map {
            sample.presentationTimeStamp + CMTime(value: Int64($0 / 2), timescale: 48_000)
        }
        return .init(pts: sample.presentationTimeStamp.seconds, peak: values.map { abs($0) }.max() ?? 0,
                     cue: cueTime?.seconds, cueTime: cueTime)
    }
    func sound(_ sample: CMSampleBuffer, iso: Bool) {
        let value = Self.sound(sample)
        let pcm: PCM? = value.peak > 0.025 ? Self.pcmValues(sample).withUnsafeBytes {
            .init(pts: sample.presentationTimeStamp, bytes: Data($0))
        } : nil
        lock.lock(); defer { lock.unlock() }
        if iso {
            if firstIsolatedSample == nil { firstIsolatedSample = sample }
            if isolatedSourceSamples.count < 512 { isolatedSourceSamples.append(sample) }
            if isolated.count == 512 { isolated.removeFirst() }; isolated.append(value)
            if let pcm, isolatedPCM.count < 128 { isolatedPCM.append(pcm) }
        } else {
            if initialProgramSamples.count < 64 { initialProgramSamples.append(sample) }
            if programSourceSamples.count < 512 { programSourceSamples.append(sample) }
            if program.count == 512 { program.removeFirst() }; program.append(value)
            if let pcm, programPCM.count < 128 { programPCM.append(pcm) }
        }
    }
    func status(_ progress: IsolatedVideoProgress) { lock.lock(); isoProgress = progress; lock.unlock() }
    func firstSamples() -> ([CMSampleBuffer], CMSampleBuffer?) {
        lock.lock(); defer { lock.unlock() }; return (initialProgramSamples, firstIsolatedSample)
    }
    func sourceSamples() -> (program: [CMSampleBuffer], isolated: [CMSampleBuffer]) {
        lock.lock(); defer { lock.unlock() }; return (programSourceSamples, isolatedSourceSamples)
    }
    func snapshot() -> (pictures: [Picture], program: [Sound], isolated: [Sound], video: Int, audio: Int,
                        rejectedVideo: Int, rejectedAudio: Int, lastVideo: GuestVideoFrame?, lastAudio: GuestAudioFrame?, iso: IsolatedVideoProgress?,
                        decodedFlash: Double?, decodedTone: Double?, programPCM: [PCM], isolatedPCM: [PCM]) {
        lock.lock(); defer { lock.unlock() }
        return (pictures, program, isolated, videoCount, audioCount, rejectedVideo, rejectedAudio, lastVideo, lastAudio,
                isoProgress, decodedFlash, decodedTone, programPCM, isolatedPCM)
    }
}

@main private enum NativeGuestProgramISOHarness {
    static func log(_ text: String) { FileHandle.standardOutput.write(Data((text + "\n").utf8)) }
    static func be32(_ value: UInt32) -> [UInt8] {
        [UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
         UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
    }
    static func packet(role: Int32, sequence: UInt16, timestamp: UInt32, payload: [UInt8], marker: Bool) -> Data {
        // CSRC, a validated BEDE extension and padding exercise the qualified
        // normalizer before the pinned public depacketizer sees the payload.
        Data([0xb1, (role == 2 ? 111 : 96) | (marker ? 128 : 0), UInt8(sequence >> 8), UInt8(truncatingIfNeeded: sequence)]
             + be32(timestamp) + be32(1001 + UInt32(role))
             + [0, 0, 0, 7, 0xbe, 0xde, 0, 1, 0x10, 0xaa, 0, 0] + payload + [0, 0, 0, 4])
    }
    static func send(_ data: Data, role: Int32, peer: OpaquePointer) {
        precondition(data.withUnsafeBytes {
            SGPeerFixtureSend(peer, role, $0.bindMemory(to: UInt8.self).baseAddress!, $0.count)
        } != 0, "The actual local peer rejected an RTP/RTCP packet")
    }
    static func report(_ role: Int32, timestamp: UInt32, seconds: Double, peer: OpaquePointer) {
        send(Data([128, 200, 0, 6] + be32(1001 + UInt32(role)) + be32(UInt32(seconds))
                  + be32(UInt32((seconds - floor(seconds)) * 4_294_967_296)) + be32(timestamp) + be32(0) + be32(0)), role: role, peer: peer)
    }
    static func accessUnits(_ data: Data) -> [[[UInt8]]] {
        let bytes = [UInt8](data); var starts: [(Int, Int)] = [], cursor = 0
        while cursor + 3 <= bytes.count {
            if bytes[cursor] == 0, bytes[cursor + 1] == 0 {
                if bytes[cursor + 2] == 1 { starts.append((cursor, 3)); cursor += 3; continue }
                if cursor + 4 <= bytes.count, bytes[cursor + 2] == 0, bytes[cursor + 3] == 1 {
                    starts.append((cursor, 4)); cursor += 4; continue
                }
            }
            cursor += 1
        }
        var result: [[[UInt8]]] = [], current: [[UInt8]] = []
        for (index, start) in starts.enumerated() {
            let end = index + 1 < starts.count ? starts[index + 1].0 : bytes.count
            let nal = Array(bytes[(start.0 + start.1)..<end]); guard !nal.isEmpty else { continue }
            if nal[0] & 31 == 9, !current.isEmpty { result.append(current); current = [] }
            current.append(nal)
        }
        if !current.isEmpty { result.append(current) }; return result
    }
    static func video(_ unit: [[UInt8]], role: Int32, timestamp: UInt32, sequence: inout UInt16, peer: OpaquePointer) {
        for (index, nal) in unit.enumerated() {
            let last = index == unit.count - 1
            if nal.count <= 240 {
                send(packet(role: role, sequence: sequence, timestamp: timestamp, payload: nal, marker: last), role: role, peer: peer)
                sequence &+= 1
            } else {
                var cursor = 1
                while cursor < nal.count {
                    let end = min(nal.count, cursor + 240)
                    let fragment = [nal[0] & 0xe0 | 28, (nal[0] & 31) | (cursor == 1 ? 128 : 0) | (end == nal.count ? 64 : 0)]
                        + Array(nal[cursor..<end])
                    send(packet(role: role, sequence: sequence, timestamp: timestamp, payload: fragment,
                                marker: last && end == nal.count), role: role, peer: peer)
                    sequence &+= 1; cursor = end
                }
            }
        }
    }
    static func progress(_ receiver: NativeGuestReceiver, _ probe: ProgramGuestProbe) -> String {
        let snapshots = receiver.diagnosticSnapshot(), counts = receiver.counters, receipts = probe.snapshot()
        let roles = snapshots.map { snapshot in
            let transport = receiver.transportStats(snapshot.role)
            let statuses = snapshot.statuses.map { "\($0.stage):\($0.status):\($0.detail)" }.joined(separator: ",")
            return "role=\(snapshot.role.rawValue) received=\(snapshot.received) decoded=\(snapshot.decoded) expired=\(snapshot.expired) queued=\(snapshot.queued)/\(snapshot.bytes) working=\(snapshot.working) awaitingIDR=\(snapshot.awaitingIDR) lossEpoch=\(snapshot.lossEpoch) srAge=\(snapshot.senderReportAge.map { String(format: "%.3f", $0) } ?? "none") transportFrames=\(transport.frames) rejected=\(transport.rejected) codec=[\(statuses)]"
        }.joined(separator: " | ")
        return "video=\(receipts.video) audio=\(receipts.audio) rejected=\(receipts.rejectedVideo)/\(receipts.rejectedAudio) errors=\(counts.errors) drops=\(counts.dropped) unsynchronized=\(counts.unsynchronized) \(roles)"
    }
    @MainActor static func wait(_ label: String, _ predicate: () -> Bool, diagnostics: (() -> String)? = nil) async throws {
        let start = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        if let diagnostics { log("Guest Program/ISO phase start \(label): \(diagnostics())") }
        for _ in 0..<1_000 {
            if predicate() {
                if let diagnostics { log("Guest Program/ISO phase complete \(label) elapsed=\(CMClockGetTime(CMClockGetHostTimeClock()).seconds - start)s: \(diagnostics())") }
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        if let diagnostics { log("Guest Program/ISO phase deadline \(label) elapsed=\(CMClockGetTime(CMClockGetHostTimeClock()).seconds - start)s: \(diagnostics())") }
        preconditionFailure("Bounded deadline: \(label)")
    }
    @MainActor static func startupReports(_ reports: [(Int32, UInt32, Double)], peer: OpaquePointer,
                                         receiver: NativeGuestReceiver, probe: ProgramGuestProbe) async throws {
        // Connected can precede authenticated RTCP readiness. Retry these exact
        // initial reports only during bounded setup, before sending any media.
        let sender = Task {
            for attempt in 0..<50 {
                guard !Task.isCancelled else { return }
                log("Guest Program/ISO explicit startup SR transmission attempt=\(attempt + 1) roles=\(reports.count)")
                for (role, rtp, ntp) in reports { report(role, timestamp: rtp, seconds: ntp, peer: peer) }
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            }
        }
        defer { sender.cancel() }
        try await wait("startup-SR-readiness-before-unregistered-media", {
            let snapshots = receiver.diagnosticSnapshot()
            return reports.allSatisfy { role, _, _ in snapshots[Int(role)].senderReportAge.map { $0 <= 3 } ?? false }
        }, diagnostics: { progress(receiver, probe) })
    }
    static func finish(_ writer: ProgramRecordingSession) async -> ProgramRecordingSession.Result {
        await withCheckedContinuation { continuation in writer.finish { continuation.resume(returning: $0) } }
    }
    static func finish(_ writer: IsolatedVideoRecorder) async {
        await withCheckedContinuation { continuation in writer.finish { continuation.resume() } }
    }

    @MainActor static func main() async throws {
        precondition(CommandLine.arguments.count >= 3)
        let options = Array(CommandLine.arguments.dropFirst(3))
        precondition(options.allSatisfy { $0 == "--hold-startup-800ms" }, "Unsupported fixture option")
        let holdStartup = options.contains("--hold-startup-800ms")
        let fixtures = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let folder = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        log("Guest Program/ISO qualification: \(ProcessInfo.processInfo.operatingSystemVersionString); \(IsolatedVideoBudget.current.machineClass); synthetic loopback media only")
        let camera = accessUnits(try Data(contentsOf: fixtures.appendingPathComponent("camera.h264")))
        precondition(camera.count == 14)
        let opus = try (0..<70).map { try Data(contentsOf: fixtures.appendingPathComponent(String(format: "opus-%03d.bin", $0))) }
        let lease = GuestReceiveLease(slot: UUID(), peerID: UUID(), negotiation: UUID(), generation: 11)
        let store = GuestVideoFrameStore(), mixer = AudioMixEngine(), probe = ProgramGuestProbe(), bridge = ProgramGuestBridge()
        let guestID = AudioMixEngine.guestChannelID(for: lease)
        let payload = GuestSourcePayload(slotID: lease.slot, role: .camera)
        let source = SourceDefinition(name: "Actual decoded guest camera", payload: .guest(payload))
        let scene = Scene(name: "Guest Program", layers: [.init(name: source.name, sourceID: source.id, payload: source.payload, transform: .fullscreen)],
                          background: .solid(colorHex: "#000000"))
        let engine = CompositionEngine(screenProvider: { nil }, cameraProvider: { nil },
            frameLookup: .init(camera: { _ in nil }, screen: { _ in nil }, guest: { payload, time in
                guard let slot = payload.slotID else { return nil }
                return store.pixels(slot: slot, role: payload.role == .camera ? .camera : .screen, at: time, program: true)
            }), sourcePayloadProvider: { [source.id: source.payload] }, transitionRequestProvider: { nil },
            canvasSize: CGSize(width: 320, height: 180), frameRate: 30)
        let receiver = try NativeGuestReceiver(admitted: lease, cameraMID: "camera-mid", screenMID: "screen-mid", audioMID: "audio-mid",
            video: { frame in probe.receive(frame, accepted: store.receive(frame)) },
            audio: { frame in
                let accepted = mixer.validateGuestFrame(frame)
                    && store.acceptClock(lease: frame.lease, mapping: frame.mappingGeneration) && mixer.enqueueGuest(frame)
                probe.receive(frame, accepted: accepted)
            }, signal: { bridge.outgoing($0, $1, $2) })
        bridge.receiver = receiver
        let peer = SGPeerFixtureCreate(programGuestSignal, Unmanaged.passUnretained(bridge).toOpaque())!
        bridge.peer = peer
        defer { receiver.stop(); SGPeerFixtureDestroy(peer) }
        precondition(SGPeerFixtureStart(peer) != 0)
        try await wait("actual DTLS/SRTP", { SGPeerFixtureReady(peer) != 0 })
        precondition(!bridge.hasFailed())
        log("Guest Program/ISO: actual public SDK peers connected; explicit audio/video admission remains absent")

        let timeline = RecordingTimeline(), programURL = folder.appendingPathComponent("program.mp4"), isoURL = folder.appendingPathComponent("guest-camera.mp4")
        var config = ProgramRecordingSession.Configuration()
        config.frameRate = 30; config.sessionID = "guest-receive-\(UUID().uuidString)"
        config.context = .init(projectID: "synthetic-guest-show", profileID: "qualified-local-prototype")
        config.isolatedFiles = [isoURL.lastPathComponent]
        let program = ProgramRecordingSession(outputURL: programURL, configuration: config, timeline: timeline)
        // The source factory pins the admitted lease even before its first
        // frame. The worker cannot substitute a camera or adopt a later peer.
        let selection = IsolatedVideoSelection(targetID: "guest-camera", name: "Actual Guest Camera", processing: .raw,
            resolution: .hd720, frameRate: 30, codec: .h264, quality: .standard,
            audioTargetID: guestID.label, audioName: "Admitted guest microphone")
        let isolated = IsolatedVideoRecorder(outputURL: isoURL, selection: selection,
            source: RecordingVideoSourceFactory.makeGuest(source: source, lease: lease, frames: store),
            sessionID: config.sessionID, segmentIndex: 1, programFile: programURL.lastPathComponent,
            context: config.context, budget: .current, timeline: timeline, event: probe.status)
        let videoToken = UUID(), programToken = UUID(), isoToken = UUID()
        await engine.addSink(token: videoToken, capacity: 8) { frame in probe.picture(frame); program.appendVideo(frame.sampleBuffer) }
        await mixer.addTap(bus: .program, token: programToken, capacity: 16) { sample in probe.sound(sample, iso: false); program.appendAudio(sample) }
        await mixer.setChannelGain(guestID, volume: 1, isMuted: false)
        await mixer.run()
        await engine.run(scene: scene, canvasSize: CGSize(width: 320, height: 180), frameRate: 30)
        try await wait("actual writer origin", { timeline.snapshot().origin.isNumeric && timeline.snapshot().videoPTS.isNumeric })
        // Warm the actual encoder and ISO worker before the measured source
        // clock starts. This is ordinary black/silent output, not retimed input.
        try await Task.sleep(for: .milliseconds(300))

        let cameraBase: UInt32 = 0xffff_e000, audioBase: UInt32 = 0xffff_a000
        let ntp = 4_000_000_000.0
        // Every role starts at the SAME sender instant. Reports are sent
        // immediately so the120ms receiver playout lies ahead of host ticks.
        try await startupReports([(0, cameraBase, ntp), (2, audioBase, ntp), (1, 123_000_000, ntp)],
                                 peer: peer, receiver: receiver, probe: probe)
        var videoSequence: UInt16 = 65_534, audioSequence: UInt16 = 65_534
        let clock = ContinuousClock(), began = clock.now
        // Real decoded red pixels and audible tone before registration prove
        // receipts alone cannot create a global guest channel or source.
        video(camera[0], role: 0, timestamp: cameraBase, sequence: &videoSequence, peer: peer)
        send(packet(role: 2, sequence: audioSequence, timestamp: audioBase, payload: [UInt8](opus[25]), marker: true), role: 2, peer: peer)
        audioSequence &+= 1
        try await wait("unregistered decoded media", { probe.snapshot().video >= 1 && probe.snapshot().audio >= 1 }, diagnostics: { progress(receiver, probe) })
        if holdStartup {
            log("Guest Program/ISO controlled setup: hold800ms before admission; real source clock and media checks unchanged")
            try await Task.sleep(for: .milliseconds(800))
        }
        precondition(mixer.registeredGuestChannelID(slot: lease.slot) == nil)
        let unregistered = probe.snapshot()
        precondition(unregistered.rejectedVideo == 1 && unregistered.rejectedAudio == 1)
        precondition(!mixer.enqueueGuest(unregistered.lastAudio!),
                     "The typed mixer inlet must also reject a real unregistered decoded receipt")
        precondition((0..<Int(unregistered.lastAudio!.pcm.frameLength)).contains {
            abs(unregistered.lastAudio!.pcm.floatChannelData![0][$0]) > 0.15
        }, "The denied decoded packet must contain actual audible PCM")
        try await clock.sleep(until: began.advanced(by: .milliseconds(180)))
        precondition(probe.snapshot().pictures.allSatisfy { $0.red < 5 && $0.green < 5 && $0.blue < 5 })
        precondition(probe.snapshot().program.allSatisfy { $0.peak < 0.00001 }
                     && probe.snapshot().isolated.allSatisfy { $0.peak < 0.00001 })
        log("Guest Program/ISO: actual decoded audible PCM/red video cannot register or leak before explicit admission PASS")

        precondition(store.register(lease))
        let registered = await mixer.registerGuest(lease)
        precondition(registered)
        precondition(mixer.registeredGuestChannelID(slot: lease.slot) == guestID)
        // A real guest ISO tap captures the CURRENT admitted lease. Requests
        // made before registration intentionally cannot create such a tap.
        await mixer.addIsolatedTap(channel: guestID, token: isoToken, capacity: 16) { sample in
            probe.sound(sample, iso: true); isolated.appendAudio(sample)
        }
        store.allowProgram(true, lease: lease)
        precondition(mixer.setGuestRouting(lease, programAllowed: true, monitorAllowed: false))
        // The first real denied video receipt already carries the common
        // sender instant's original mapped host PTS. Subtract the receiver's
        // declared120ms playout to pace this synthetic sender against that
        // EXISTING anchor, even if initial authenticated SR setup retried.
        // No receiver mapping, receipt PTS or source sample is rewritten.
        let senderHostOrigin = unregistered.lastVideo!.pts.seconds - 0.12
        let schedulingHost = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        let sourceBegan = clock.now.advanced(by: .seconds(senderHostOrigin - schedulingHost))
        // Actual cold decode and privacy/admission setup can exceed300ms on
        // hosted CPUs. Choose a future20ms source-grid frontier after setup;
        // matching90k/48k offsets advance the same RTP/NTP relationship.
        let sourceTick = max(15, Int(ceil((schedulingHost - senderHostOrigin) * 50)) + 3)
        let sourceOffset = Double(sourceTick) / 50
        let videoOffset = UInt32(sourceTick * 1_800), audioOffset = UInt32(sourceTick * 960)
        log("Guest Program/ISO admission frontier elapsed=\(began.duration(to: clock.now)) sourceOffset=\(sourceOffset)s on20msgrid; original mapped anchor retained")
        try await clock.sleep(until: sourceBegan.advanced(by: .seconds(sourceOffset)))
        report(0, timestamp: cameraBase &+ videoOffset, seconds: ntp + sourceOffset, peer: peer)
        report(2, timestamp: audioBase &+ audioOffset, seconds: ntp + sourceOffset, peer: peer)
        for index in 0..<70 {
            try await clock.sleep(until: sourceBegan.advanced(by: .seconds(sourceOffset + Double(index) / 50)))
            send(packet(role: 2, sequence: audioSequence, timestamp: audioBase &+ audioOffset &+ UInt32(index * 960),
                        payload: [UInt8](opus[index]), marker: true), role: 2, peer: peer)
            audioSequence &+= 1
            if index % 5 == 0 {
                video(camera[index / 5], role: 0, timestamp: cameraBase &+ videoOffset &+ UInt32((index / 5) * 9_000),
                      sequence: &videoSequence, peer: peer)
            }
        }
        log("Guest Program/ISO source feed finished elapsed=\(sourceBegan.duration(to: clock.now)); source duration=1.4s: \(progress(receiver, probe))")
        try await wait("all actual decoded packets", { probe.snapshot().video == 15 && probe.snapshot().audio == 71 }, diagnostics: { progress(receiver, probe) })
        precondition(receiver.counters.errors == 0 && receiver.counters.dropped == 0 && receiver.counters.unsynchronized == 0)
        try await clock.sleep(until: sourceBegan.advanced(by: .seconds(sourceOffset + 1.55)))
        let live = probe.snapshot()
        let liveFlash = live.pictures.first { $0.red > 200 && $0.green > 200 && $0.blue > 200 }!
        let liveTone = live.program.compactMap(\.cue).first!
        let isoTone = live.isolated.compactMap(\.cue).first!
        log("Guest actual host playout: Program flash-tone delta=\(liveFlash.pts - liveTone)s; Program/ISO PCM cue difference=\(liveTone - isoTone)s; original decoded→mix cue difference=\(liveTone - live.decodedTone!)s")
        precondition(abs(liveFlash.pts - liveTone) < 0.05)
        precondition(CMTimeCompare(live.program.compactMap(\.cueTime).first!, live.isolated.compactMap(\.cueTime).first!) == 0,
                     "Actual Program and pre-fader ISO PCM cues must match exactly before independent encoders")
        precondition(live.programPCM.count >= 50 && live.programPCM.count == live.isolatedPCM.count)
        for packet in live.programPCM {
            let matching = live.isolatedPCM.first { CMTimeCompare(packet.pts, $0.pts) == 0 }
            precondition(matching?.bytes == packet.bytes,
                         "Every audible source window must retain identical PCM bits and original PTS before independent writers")
        }
        log("Guest actual pre-writer PCM: \(live.programPCM.count) audible windows match exact CMTime and Float32 sample bytes")
        precondition(abs(liveTone - live.decodedTone!) < 1.0 / 48_000,
                     "The mixer must retain the decoded original sender-clock sample position")
        precondition(liveFlash.pts >= live.decodedFlash! && liveFlash.pts - live.decodedFlash! < 0.05,
                     "Program must wait for a mapped frame to become due")

        // Keep the peer/decoder alive and keep feeding actual audible media.
        // Backstage revocation must silence both ISO and Program immediately,
        // rather than depending on a socket disconnect or a zero fader.
        let revokedAt = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        store.allowProgram(false, lease: lease)
        precondition(mixer.setGuestRouting(lease, programAllowed: false, monitorAllowed: false))
        for index in 0..<15 {
            let seconds = sourceOffset + 1.6 + Double(index) / 50
            try await clock.sleep(until: sourceBegan.advanced(by: .seconds(seconds)))
            send(packet(role: 2, sequence: audioSequence, timestamp: audioBase &+ UInt32((seconds * 48_000).rounded()),
                        payload: [UInt8](opus[25 + index]), marker: true), role: 2, peer: peer)
            audioSequence &+= 1
            if index % 5 == 0 {
                video(camera[0], role: 0, timestamp: cameraBase &+ UInt32((seconds * 90_000).rounded()),
                      sequence: &videoSequence, peer: peer)
            }
        }
        try await Task.sleep(for: .milliseconds(220))
        let backstage = probe.snapshot()
        precondition(backstage.video == 18 && backstage.audio == 86 && receiver.counters.errors == 0)
        let afterPictures = backstage.pictures.filter { $0.pts >= revokedAt + 0.05 }
        let afterProgram = backstage.program.filter { $0.pts >= revokedAt + 0.05 }
        let afterISO = backstage.isolated.filter { $0.pts >= revokedAt + 0.05 }
        precondition(afterPictures.count > 5 && afterPictures.allSatisfy { $0.red < 5 && $0.green < 5 && $0.blue < 5 })
        precondition(afterProgram.count > 15 && afterProgram.allSatisfy { $0.peak < 0.00001 })
        precondition(afterISO.count > 15 && afterISO.allSatisfy { $0.peak < 0.00001 })
        log("Guest Program/ISO: live decoder continues through explicit backstage revocation; Program+pre-fader ISO silence and black video PASS")

        await receiver.finishAudio()
        receiver.stop()
        await engine.stop()
        let finishing = Task { await finish(program) }
        // The actual retained bus taps continue emitting original host-clock
        // windows until the Program writer has its sealed video tail.
        try await Task.sleep(for: .milliseconds(100))
        let result = await finishing.value
        await finish(isolated)
        await mixer.removeTap(programToken); await mixer.removeTap(isoToken); await mixer.stop()
        await engine.removeSink(videoToken)
        precondition(result.completed, result.error ?? "Program writer failed")
        precondition(probe.snapshot().iso?.status == "complete", probe.snapshot().iso?.error ?? "Guest ISO writer failed")
        precondition(mixer.removeGuest(lease))
        store.remove(lease)
        precondition(!mixer.enqueueGuest(backstage.lastAudio!) && !store.receive(backstage.lastVideo!))
        precondition(mixer.registeredGuestChannelID(slot: lease.slot) == nil)
        store.retire(); mixer.retireGuestAdmissions()
        precondition(!store.register(lease))
        let retiredRegistration = await mixer.registerGuest(lease)
        precondition(!retiredRegistration)
        log("Guest Program/ISO: explicit removal/retirement reject captured decoded receipts and cannot register a retired guest PASS")
        let initial = probe.firstSamples(), origin = timeline.snapshot().origin
        let firstProgram = initial.0.compactMap { ProgramRecordingSession.audioRange($0, start: origin) }.first!
        let firstISO = initial.1!
        let programMetadata = try JSONSerialization.jsonObject(with: Data(contentsOf: programURL.appendingPathExtension("recording.json"))) as! [String: Any]
        let isolatedMetadata = try JSONSerialization.jsonObject(with: Data(contentsOf: isoURL.appendingPathExtension("recording.json"))) as! [String: Any]
        let programOffset = programMetadata["audioStartOffsetSeconds"] as! Double
        let isolatedOffset = isolatedMetadata["audioStartOffsetSeconds"] as! Double
        let hostTick = 1.0 / Double(origin.timescale)
        let metadataRounding = (programOffset.ulp + isolatedOffset.ulp) * 4
        precondition(abs(programOffset - isolatedOffset) <= hostTick + metadataRounding,
                     "Both writers must begin on the same real PCM grid within one declared host-clock tick")
        let gapMetadata = try JSONSerialization.jsonObject(with: Data(contentsOf: isoURL.appendingPathExtension("video-isolated.json"))) as! [String: Any]
        let leadingGap = (gapMetadata["gaps"] as! [[String: Any]]).first {
            $0["reason"] as? String == "associated-audio-timeline-gap"
        }
        let leadingStart = leadingGap?["startSeconds"] as? Double ?? -1
        precondition(leadingStart >= 0 && leadingStart < 1.0 / 48_000,
                     "Leading silence must preserve the real PCM grid's fractional movie-origin residue")
        precondition(abs(leadingStart - programOffset) <= hostTick + metadataRounding,
                     "The leading gap must preserve Program's first retained audio offset")
        let padded = ((leadingGap?["durationSeconds"] as? Double ?? 0) * 48_000).rounded()
        let gap = firstISO.presentationTimeStamp - origin
        log("Guest actual writer source grids: origin=\(origin.value)/\(origin.timescale) firstRetainedProgramPTS=\(firstProgram.presentationTimeStamp.value)/\(firstProgram.presentationTimeStamp.timescale) offsetSamples=\((firstProgram.presentationTimeStamp - origin).seconds * 48_000); firstISOInputPTS=\(firstISO.presentationTimeStamp.value)/\(firstISO.presentationTimeStamp.timescale) gapSamples=\(gap.seconds * 48_000) recordedLeadingStartSamples=\(leadingStart * 48_000) recordedLeadingSilenceSamples=\(padded)")
        // Exercise the shipping range helper with the actual retained mixer
        // buffers. Host-clock timestamps may round a rational PCM boundary;
        // adjacent chunks must not lose a whole source frame for that residue.
        let sourceWindows = probe.sourceSamples(), sourceSamples = sourceWindows.isolated
        var roundedBoundaries = 0, droppedAtBoundaries = 0
        for (previous, sample) in zip(sourceSamples, sourceSamples.dropFirst()) {
            let end = previous.presentationTimeStamp
                + CMTime(value: Int64(CMSampleBufferGetNumSamples(previous)), timescale: 48_000)
            let pts = sample.presentationTimeStamp, delta = end - pts
            guard abs(delta.seconds * 48_000) < 0.01 else { continue }
            let retained = ProgramRecordingSession.audioRange(sample, start: end)
            let lost = CMSampleBufferGetNumSamples(sample) - (retained.map(CMSampleBufferGetNumSamples) ?? 0)
            if delta != .zero {
                if roundedBoundaries < 3 {
                    log("Guest actual adjacent PCM boundary: previousPTS=\(previous.presentationTimeStamp.value)/\(previous.presentationTimeStamp.timescale) nextRequestedPTS=\(end.value)/\(end.timescale) sourcePTS=\(pts.value)/\(pts.timescale) delta=\(delta.value)/\(delta.timescale) roundedFlags=\(end.flags.contains(.hasBeenRounded))/\(pts.flags.contains(.hasBeenRounded))/\(delta.flags.contains(.hasBeenRounded)) shippingRangeDropped=\(lost)")
                }
                roundedBoundaries += 1
            }
            droppedAtBoundaries += lost
        }
        log("Guest actual PCM adjacency: \(sourceSamples.count) retained source windows, \(roundedBoundaries) sub-0.01-sample rounded boundaries, \(droppedAtBoundaries) whole source frames removed by shipping audioRange")
        precondition(droppedAtBoundaries == 0,
                     "Rounded host-clock adjacency must preserve every original PCM frame")
        let timing = timeline.snapshot(), cutoff = timing.end + timing.offset
        for (name, samples) in [("Program", sourceWindows.program), ("ISO", sourceWindows.isolated)] {
            let retained = samples.compactMap {
                ProgramRecordingSession.audioRange($0, start: timing.sourceStart, end: cutoff)
            }
            let last = retained.last!, end = last.presentationTimeStamp
                + CMTime(value: Int64(CMSampleBufferGetNumSamples(last)), timescale: 48_000)
            let count = retained.reduce(0) { $0 + CMSampleBufferGetNumSamples($1) }
            log("Guest actual \(name) retained source tail: cutoff=\(cutoff.value)/\(cutoff.timescale) frames=\(count) lastPTS=\(last.presentationTimeStamp.value)/\(last.presentationTimeStamp.timescale) lastFrames=\(CMSampleBufferGetNumSamples(last)) end=\(end.value)/\(end.timescale) cutoffResidueSamples=\((end - cutoff).seconds * 48_000) roundedFlags=\(cutoff.flags.contains(.hasBeenRounded))/\(end.flags.contains(.hasBeenRounded))")
        }
        precondition(Int64(padded) == CMTimeConvertScale(gap, timescale: 48_000, method: .roundTowardZero).value,
                     "ISO leading silence must cover whole missing source samples without allocating an extra sample for fractional clock residue")
        try await inspect(programURL, isoURL: isoURL, result: result)
        let stats = store.statistics()
        precondition(stats.retainedFrames == 0 && stats.retainedBytes == 0)
        log("PASS: actual decoded guest→due Composer/mixer→Program and associated pinned ISO; original shared host PTS, recorded flash-tone, common endpoints and privacy/retirement boundaries")
    }

    struct DecodedFile {
        let duration, videoEnd, audioEnd, flash, tone: Double
        let videoFrames, audioFrames, redFrames: Int
        let endsBlack: Bool
        let finalAudioPeak: Float
        let audioStart, toneTime: CMTime
        let audioValues: [Float]
    }
    static func decode(_ url: URL) async throws -> DecodedFile {
        let asset = AVURLAsset(url: url)
        let videos = try await asset.loadTracks(withMediaType: .video), audios = try await asset.loadTracks(withMediaType: .audio)
        precondition(videos.count == 1 && audios.count == 1)
        let duration = try await asset.load(.duration).seconds
        let videoRange = try await videos[0].load(.timeRange), audioRange = try await audios[0].load(.timeRange)
        let reader = try AVAssetReader(asset: asset)
        let picture = AVAssetReaderTrackOutput(track: videos[0], outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        let sound = AVAssetReaderTrackOutput(track: audios[0], outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false])
        reader.add(picture); reader.add(sound); precondition(reader.startReading())
        var flash: Double?, tone: Double?, videoFrames = 0, audioFrames = 0, redFrames = 0
        var endsBlack = false, finalAudioPeak: Float = 0
        var audioStart: CMTime?, toneTime: CMTime?, audioValues: [Float] = []
        while let sample = picture.copyNextSampleBuffer() {
            videoFrames += 1
            guard let pixels = CMSampleBufferGetImageBuffer(sample) else { preconditionFailure("Decoded image missing") }
            CVPixelBufferLockBaseAddress(pixels, .readOnly)
            let offset = CVPixelBufferGetBytesPerRow(pixels) * (CVPixelBufferGetHeight(pixels) / 2)
                + (CVPixelBufferGetWidth(pixels) / 2) * 4
            let bytes = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
            if flash == nil && bytes[offset] > 200 && bytes[offset + 1] > 200 && bytes[offset + 2] > 200 {
                flash = sample.presentationTimeStamp.seconds
            }
            if bytes[offset + 2] > 200 && bytes[offset] < 30 && bytes[offset + 1] < 30 { redFrames += 1 }
            endsBlack = bytes[offset] < 5 && bytes[offset + 1] < 5 && bytes[offset + 2] < 5
            CVPixelBufferUnlockBaseAddress(pixels, .readOnly)
        }
        while let sample = sound.copyNextSampleBuffer() {
            if audioStart == nil { audioStart = sample.presentationTimeStamp }
            precondition(CMTimeCompare(sample.presentationTimeStamp,
                audioStart! + CMTime(value: Int64(audioFrames), timescale: 48_000)) == 0,
                "Decoded audio must occupy one contiguous rational sample grid")
            audioFrames += CMSampleBufferGetNumSamples(sample)
            let values = ProgramGuestProbe.pcmValues(sample)
            precondition(audioValues.count + values.count <= 960_000, "Bounded ten-second stereo analysis")
            audioValues += values
            let decoded = ProgramGuestProbe.sound(sample)
            if tone == nil { tone = decoded.cue; toneTime = decoded.cueTime }
            finalAudioPeak = decoded.peak
        }
        precondition(reader.status == .completed, reader.error?.localizedDescription ?? "AssetReader failed")
        precondition(flash != nil && tone != nil, "Actual compressed flash/tone must survive the complete receive/mix/render/write path")
        return .init(duration: duration, videoEnd: CMTimeRangeGetEnd(videoRange).seconds,
                     audioEnd: CMTimeRangeGetEnd(audioRange).seconds, flash: flash!, tone: tone!, videoFrames: videoFrames,
                     audioFrames: audioFrames, redFrames: redFrames, endsBlack: endsBlack, finalAudioPeak: finalAudioPeak,
                     audioStart: audioStart!, toneTime: toneTime!, audioValues: audioValues)
    }
    static func inspect(_ programURL: URL, isoURL: URL, result: ProgramRecordingSession.Result) async throws {
        let program = try await decode(programURL), iso = try await decode(isoURL)
        for (name, file) in [("Program", program), ("Guest ISO", iso)] {
            log("Recorded \(name): duration=\(file.duration)s videoFrames=\(file.videoFrames) audioFrames=\(file.audioFrames) flash=\(file.flash)s tone=\(file.tone)s delta=\(file.flash - file.tone)s ends=\(file.videoEnd)/\(file.audioEnd)")
            precondition(file.videoFrames > 50 && file.audioFrames > 96_000)
            precondition(file.redFrames > 20 && file.endsBlack && file.finalAudioPeak < 0.0001,
                         "Actual encoded camera must survive admission and end black/silent after backstage revocation")
            precondition(abs(file.flash - file.tone) < 0.05)
            precondition(abs(file.videoEnd - file.audioEnd) < 0.04)
        }
        precondition(abs(program.duration - iso.duration) < 0.04)
        precondition(abs(program.flash - iso.flash) < 0.04)
        // Actual decoded files demonstrated a threshold-only one-sample
        // difference: .028855238 versus .02494631 at the same frame, while
        // both tracks started at 0/48000 and contained 137671 frames. Exact
        // rational comparison includes that boundary without Double epsilon;
        // the waveform test below separately rejects a real sample shift.
        let cueDifference = CMTimeAbsoluteValue(program.toneTime - iso.toneTime)
        precondition(CMTimeCompare(cueDifference, CMTime(value: 1, timescale: 48_000)) <= 0,
                     "Independent AAC cue thresholds may differ by at most one exact sample")
        let cueFrame = max(CMTimeConvertScale(program.toneTime - program.audioStart, timescale: 48_000, method: .default).value,
                           CMTimeConvertScale(iso.toneTime - iso.audioStart, timescale: 48_000, method: .default).value)
        let window = (Int(cueFrame) + 1_000)..<(Int(cueFrame) + 10_000)
        precondition(window.upperBound + 1 < min(program.audioFrames, iso.audioFrames))
        var errors: [Int: Double] = [:], signal = 0.0
        for lag in -1...1 {
            var squaredError = 0.0
            for frame in window { for channel in 0..<2 {
                let actual = Double(program.audioValues[frame * 2 + channel])
                let isolated = Double(iso.audioValues[(frame + lag) * 2 + channel])
                squaredError += (actual - isolated) * (actual - isolated)
                if lag == 0 { signal += actual * actual }
            } }
            errors[lag] = squaredError
        }
        log("Recorded rational audio: origin=\(program.audioStart.value)/\(program.audioStart.timescale) cueDifference=\(cueDifference.value)/\(cueDifference.timescale); normalized waveform error lag−1/0/+1=\(sqrt(errors[-1]! / signal))/\(sqrt(errors[0]! / signal))/\(sqrt(errors[1]! / signal))")
        precondition(signal > 0 && errors[0]! < errors[-1]! && errors[0]! < errors[1]!,
                     "Decoded tone vectors must match best at zero shift, rather than conceal a one-sample displacement")
        precondition(CMTimeCompare(program.audioStart, iso.audioStart) == 0 && program.audioFrames == iso.audioFrames,
                     "Independent files must retain the same rational audio origin and sample count")
        precondition(zip(program.audioValues, iso.audioValues).allSatisfy { $0.bitPattern == $1.bitPattern },
                     "The complete owned synthetic PCM sequence must decode identically through both AAC writers")
        log("Recorded full decoded PCM: \(program.audioValues.count) Float32 values match exact bits; common origin, sample count, cue and silent tail PASS")
        let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: isoURL.appendingPathExtension("video-isolated.json"))) as! [String: Any]
        precondition(metadata["commonSourceStartSeconds"] as? Double == result.progress.sessionStartSourceSeconds)
        precondition(metadata["programFile"] as? String == programURL.lastPathComponent)
        precondition((metadata["context"] as? [String: Any])?["projectID"] as? String == "synthetic-guest-show")
    }
}
