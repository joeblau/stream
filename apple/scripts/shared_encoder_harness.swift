import AVFoundation
import CoreMedia
import Darwin
import Foundation
import StreamCore

private actor EncodedPublisherProbe: Publisher {
    nonisolated let supportsSharedH264AAC: Bool
    nonisolated let events: AsyncStream<PublisherEvent>
    nonisolated let continuation: AsyncStream<PublisherEvent>.Continuation
    private(set) var video: [CMSampleBuffer] = []
    private(set) var audio: [SharedEncodedAudio] = []
    private(set) var raw = 0, configured = false
    private var held = false
    private var gate: CheckedContinuation<Void, Never>?
    private var holdsStop = false
    private var stopGate: CheckedContinuation<Void, Never>?
    init(shared: Bool = true) { supportsSharedH264AAC = shared; (events, continuation) = AsyncStream.makeStream(of: PublisherEvent.self) }
    func configureEncodedInput() async -> Bool { configured = true; return true }
    func start(_ settings: StreamSettings) async throws { continuation.yield(.published) }
    func stop() async { release(); if holdsStop { await withCheckedContinuation { stopGate = $0 } } }
    func pause() async {}
    func resume() async {}
    func setOutputSize(_ size: CGSize, nativeShortEdge: Int) async {}
    func appendVideo(_ sample: CMSampleBuffer) async { raw += 1 }
    func appendEncodedVideo(_ sample: CMSampleBuffer) async -> Bool {
        if held { await withCheckedContinuation { gate = $0 } }
        video.append(sample); return false
    }
    func appendEncodedAudio(_ sample: SharedEncodedAudio) async -> Bool { audio.append(sample); return false }
    nonisolated func enqueueMic(_ sample: CMSampleBuffer) {}
    nonisolated func enqueueApp(_ sample: CMSampleBuffer) {}
    nonisolated func enqueueProgram(_ sample: CMSampleBuffer) {}
    func setMicVolume(_ volume: Double) async {}
    func setThermalCeiling(bitRateScale: Double, frameRateCap: Int) async {}
    func statsSnapshot() async -> LiveStats? { nil }
    func hold() { held = true }
    func release() { held = false; gate?.resume(); gate = nil }
    func reset() { video.removeAll(); audio.removeAll() }
    func holdStop() { holdsStop = true }
    func releaseStop() { holdsStop = false; stopGate?.resume(); stopGate = nil }
}

@main @MainActor struct SharedEncoderHarness {
    static func report(_ value: String) { FileHandle.standardOutput.write(Data((value + "\n").utf8)) }
    static func check(_ value: Bool, _ message: String) throws {
        if !value { throw NSError(domain: "SharedEncoderHarness", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func settle(seconds: Double = 3, file: String = #fileID, line: Int = #line, _ check: @escaping @MainActor () async -> Bool) async throws {
        for _ in 0..<Int(seconds * 100) { if await check() { return }; try await Task.sleep(for: .milliseconds(10)) }
        throw NSError(domain: "SharedEncoderHarness", code: 2, userInfo: [NSLocalizedDescriptionKey: "Timed out awaiting actual encoder/output at \(file):\(line)"])
    }
    static func bytes(_ sample: CMSampleBuffer) -> Data {
        guard let block = sample.dataBuffer else { return Data() }
        let count = CMBlockBufferGetDataLength(block)
        var bytes = Data(count: count)
        bytes.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count, destination: $0.baseAddress!) }
        return bytes
    }
    static func keyframe(_ sample: CMSampleBuffer) -> Bool {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[String: Any]]
        return attachments?.first?[kCMSampleAttachmentKey_NotSync as String] as? Bool != true
    }
    private static func write(_ probe: EncodedPublisherProbe, to url: URL) async throws {
        let video = await probe.video, audio = await probe.audio
        try check(!video.isEmpty && !audio.isEmpty, "Compressed AV output missing")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let v = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: video[0].formatDescription)
        let a = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audio[0].sample.formatDescription)
        writer.add(v); writer.add(a)
        try check(writer.startWriting(), "Compressed container cannot start")
        writer.startSession(atSourceTime: video[0].presentationTimeStamp)
        for sample in video {
            try await settle { v.isReadyForMoreMediaData || writer.status == .failed }
            try check(v.append(sample), "Compressed video append failed: \(String(describing: writer.error))")
        }
        v.markAsFinished()
        for sample in audio where sample.sample.presentationTimeStamp >= video[0].presentationTimeStamp {
            try await settle { a.isReadyForMoreMediaData || writer.status == .failed }
            try check(a.append(sample.sample), "Compressed audio append failed: \(String(describing: writer.error))")
        }
        a.markAsFinished()
        await writer.finishWriting()
        try check(writer.status == .completed, "Compressed container failed: \(String(describing: writer.error))")
    }
    static func feed(_ outputs: DestinationOutputController, start: Int, ticks: Int, canvas: OutputCanvas = .program) async throws {
        for tick in start..<(start + ticks) {
            let time = Double(tick) / 100
            if tick % 4 == 0 { outputs.fanout.enqueueVideo(try ProgramRecordingFixtures.video(at: time), canvas: canvas) }
            outputs.fanout.enqueueAudio(try ProgramRecordingFixtures.audio(at: time))
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    static func receiverReady(_ process: Process, transport: StreamCore.StreamProtocol, port: Int) -> Bool {
        guard process.isRunning else { return false }
        // A TCP connection probe would consume FFmpeg's single accepted input.
        // Inspect the receiver PID's actual bound socket without connecting.
        let probe = Process(); probe.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        probe.arguments = ["-a", "-p", String(process.processIdentifier), "-nP", "-i\(transport == .srt ? "UDP" : "TCP"):\(port)"]
            + (transport == .srt ? [] : ["-sTCP:LISTEN"])
        probe.standardOutput = FileHandle.nullDevice; probe.standardError = FileHandle.nullDevice
        do { try probe.run(); probe.waitUntilExit(); return probe.terminationStatus == 0 } catch { return false }
    }
    static func localhostTransports(directory: URL, settings: StreamSettings) async throws {
        guard let path = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"].first(where: FileManager.default.isExecutableFile(atPath:)) else {
            report("UNQUALIFIED: localhost transport fixtures require ffmpeg with libsrt/RTMP; no transport acceptance claimed")
            return
        }
        let ffmpeg = URL(fileURLWithPath: path)
        var processes: [Process] = [], handles: [FileHandle] = [], ports: [Int] = []
        let transports: [StreamCore.StreamProtocol] = [.rtmp, .srt]
        defer {
            for process in processes where process.isRunning { process.interrupt() }
            for handle in handles { try? handle.close() }
        }
        for transport in transports {
            let port = Int.random(in: 20_000...40_000); ports.append(port)
            let file = directory.appendingPathComponent("localhost-\(transport.rawValue).mp4")
            let log = directory.appendingPathComponent("localhost-\(transport.rawValue).log")
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let handle = try FileHandle(forWritingTo: log); handles.append(handle)
            let process = Process(); process.executableURL = ffmpeg
            let listen = transport == .srt ? ["-i", "srt://127.0.0.1:\(port)?mode=listener&latency=50000"] : ["-listen", "1", "-i", "rtmp://127.0.0.1:\(port)/live/shared"]
            process.arguments = ["-y", "-hide_banner", "-loglevel", "error"] + listen + ["-map", "0:v:0", "-map", "0:a:0", "-c", "copy", file.path]
            process.standardOutput = handle; process.standardError = handle
            try process.run(); processes.append(process)
        }
        let receivers = processes
        try await settle(seconds: 10) {
            transports.enumerated().allSatisfy { receiverReady(receivers[$0.offset], transport: $0.element, port: ports[$0.offset]) }
        }
        let outputs = DestinationOutputController(factory: { transport in
            if transport == .rtmp { return RTMPPublisher() }
            return SessionPublisher(protocol: .srt)
        })
        outputs.sharedEncodingEnabled = true
        outputs.sharedSourceFrameRate = 25
        defer { outputs.stopAll() }
        for (index, transport) in transports.enumerated() {
            var local = settings; local.selectedProtocol = transport
            local.rtmpURL = transport == .srt ? "srt://127.0.0.1:\(ports[index])?mode=caller&latency=50" : "rtmp://127.0.0.1:\(ports[index])/live"
            local.streamKey = transport == .rtmp ? "shared" : ""
            outputs.start(StreamDestination(name: "Actual localhost \(transport.rawValue)", transport: transport), settings: local)
        }
        do { try await settle(seconds: 10) { outputs.liveCount == 2 } }
        catch {
            fflush(nil)
            report("Localhost startup states: \(outputs.names) \(outputs.states); receivers running: \(receivers.map(\.isRunning))")
            throw error
        }
        try check(outputs.encoderSessionCount == 1, "Actual RTMP/SRT adapters did not share one fixed encoder owner")
        try await feed(outputs, start: 0, ticks: 400)
        outputs.stopAll()
        // FFmpeg closes its input without replying to RTMP Unpublish.Success.
        // HaishinKit waits its documented 3-second request timeout before local
        // teardown completes; the encoder itself must already be finalized.
        try await settle { outputs.encoderSessionCount == 0 }
        try await settle(seconds: 10) { outputs.activeCount == 0 }
        for _ in 0..<100 { if receivers.allSatisfy({ !$0.isRunning }) { break }; try await Task.sleep(for: .milliseconds(20)) }
        for process in receivers where process.isRunning { process.interrupt() }
        try await settle { receivers.allSatisfy({ !$0.isRunning }) }
        for transport in transports {
            let file = directory.appendingPathComponent("localhost-\(transport.rawValue).mp4")
            try check(FileManager.default.fileExists(atPath: file.path), "Actual localhost output missing for \(transport.rawValue)")
            try await ProgramRecordingFixtures.inspect(file, expectedDuration: nil, checkSync: true)
        }
        report("PASS: one actual fixed encoder -> RTMPPublisher/RTMPStream and SessionPublisher/SRTStream compressed passthrough -> simultaneous localhost ffmpeg MP4 receivers; H.264/AAC decode/sync/metadata, SRT startup primer and independent acknowledged stops")
    }
    static func rawFinalization(settings: StreamSettings) async throws {
        let failed = EncodedPublisherProbe(shared: false), retry = EncodedPublisherProbe(shared: false)
        var pending = [failed, retry]
        let outputs = DestinationOutputController(factory: { _ in pending.removeFirst() })
        outputs.sharedEncodingEnabled = true
        outputs.sharedSourceFrameRate = 25
        let target = StreamDestination(name: "Separate fallback", transport: .whip)
        outputs.start(target, settings: settings)
        try await settle { outputs.liveCount == 1 }
        await failed.holdStop()
        failed.continuation.yield(.failed(message: "injected"))
        try await settle { outputs.activeCount == 0 }
        try check(outputs.encoderSessionCount == 1, "Failed raw publisher released its encoder before teardown")
        outputs.start(target, settings: settings)
        try await settle { outputs.liveCount == 1 }
        try check(outputs.encoderSessionCount == 2, "Stable-ID retry hid the previous finalizing raw owner")
        await failed.releaseStop()
        try await settle { outputs.encoderSessionCount == 1 }
        await retry.holdStop(); outputs.stopAll()
        try check(outputs.encoderSessionCount == 1, "Stop released a raw owner before actual completion")
        await retry.releaseStop()
        try await settle { outputs.encoderSessionCount == 0 && outputs.activeCount == 0 }
        report("PASS: unsupported adapter stays separate; failed stable-ID retry and deliberate stop retain every raw encoder reservation until actual teardown")
    }
    static func canvasAndEncoderFailure(settings: StreamSettings) async throws {
        let primary = EncodedPublisherProbe(), secondary = EncodedPublisherProbe(), secondaryCopy = EncodedPublisherProbe()
        var pending = [primary, secondary, secondaryCopy]
        let outputs = DestinationOutputController(factory: { _ in pending.removeFirst() })
        outputs.sharedEncodingEnabled = true
        outputs.sharedSourceFrameRate = 25
        let a = StreamDestination(name: "Program", transport: .rtmp)
        var b = StreamDestination(name: "Secondary", transport: .srt); b.canvas = .secondary
        var c = b.duplicated(); c.isEnabled = true
        outputs.start(a, settings: settings); outputs.start(b, settings: settings); outputs.start(c, settings: settings)
        try await settle { outputs.liveCount == 3 }
        try check(outputs.encoderSessionCount == 2, "Different compositions shared an encoder because their profiles matched")
        for tick in 0..<20 {
            let time = Double(tick) / 100
            if tick % 4 == 0 {
                outputs.fanout.enqueueVideo(try ProgramRecordingFixtures.video(at: time, eventSeconds: 0))
                outputs.fanout.enqueueVideo(try ProgramRecordingFixtures.video(at: time, eventSeconds: 10), canvas: .secondary)
            }
            outputs.fanout.enqueueAudio(try ProgramRecordingFixtures.audio(at: time))
            try await Task.sleep(for: .milliseconds(10))
        }
        try await settle {
            let p = await primary.video.count, s = await secondary.video.count, t = await secondaryCopy.video.count
            return p >= 4 && s >= 4 && t >= 4
        }
        let p = await primary.video, s = await secondary.video, t = await secondaryCopy.video
        try check(p[0] !== s[0] && bytes(p[0]) != bytes(s[0]) && s[0] === t[0], "Canvas content identity was not respected by actual compressed fanout")
        outputs.fanout.enqueueVideo(try ProgramRecordingFixtures.audio(at: 0.2), canvas: .secondary)
        try await settle {
            if case .failed = outputs.states[b.id], case .failed = outputs.states[c.id] { return true }; return false
        }
        try await settle { outputs.encoderSessionCount == 1 }
        let before = await primary.video.count
        try await feed(outputs, start: 20, ticks: 20)
        let after = await primary.video.count
        try check(outputs.states[a.id] == .live && after > before, "Failure in one shared encoder ended an unrelated composition")
        outputs.stopAll(); try await settle { outputs.activeCount == 0 && outputs.encoderSessionCount == 0 }
        report("PASS: identical profiles on distinct canvases encode distinct content; a real shared encoder input failure ends its own members while the other canvas keeps publishing")
    }
    static func fixedCadence(directory: URL, settings: StreamSettings) async throws {
        let target = EncodedPublisherProbe()
        let outputs = DestinationOutputController(factory: { _ in target })
        outputs.sharedEncodingEnabled = true; outputs.sharedSourceFrameRate = 60
        var profile = settings; profile.outputProfile = profile.outputProfile.with(frameRate: 24)
        outputs.start(StreamDestination(name: "60 to24"), settings: profile)
        try await settle { outputs.liveCount == 1 }
        var sourceFrame = 0
        for tick in 0..<200 {
            let time = Double(tick) / 100
            while Double(sourceFrame) / 60 <= time {
                outputs.fanout.enqueueVideo(try ProgramRecordingFixtures.video(at: Double(sourceFrame) / 60))
                sourceFrame += 1
            }
            outputs.fanout.enqueueAudio(try ProgramRecordingFixtures.audio(at: time))
            try await Task.sleep(for: .milliseconds(10))
        }
        try await settle { await target.video.count >= 47 }
        let count = await target.video.count
        try check((47...49).contains(count), "Fixed 24fps group undershot while sampling 60fps content: \(count) frames/2s")
        try await write(target, to: directory.appendingPathComponent("60-to-24.mp4"))
        try await ProgramRecordingFixtures.inspect(directory.appendingPathComponent("60-to-24.mp4"), expectedDuration: 2, checkSync: true)
        outputs.stopAll(); try await settle { outputs.encoderSessionCount == 0 && outputs.activeCount == 0 }
        report("PASS: actual 60fps source ->24fps fixed encoder preserves admission phase, produces \(count) compressed/decoded frames over two seconds and keeps audio/video synchronization")
    }
    static func higherRateFallback(settings: StreamSettings) async throws {
        let a = EncodedPublisherProbe(), b = EncodedPublisherProbe()
        var pending = [a, b]
        let outputs = DestinationOutputController(factory: { _ in pending.removeFirst() })
        outputs.sharedEncodingEnabled = true; outputs.sharedSourceFrameRate = 24
        var faster = settings; faster.outputProfile = faster.outputProfile.with(frameRate: 60)
        outputs.start(StreamDestination(name: "Higher rate RTMP", transport: .rtmp), settings: faster)
        outputs.start(StreamDestination(name: "Higher rate SRT", transport: .srt), settings: faster)
        try await settle { outputs.liveCount == 2 }
        try check(outputs.encoderSessionCount == 2, "Higher-than-source fixed rate received a false sharing discount")
        outputs.fanout.enqueueVideo(try ProgramRecordingFixtures.video(at: 0))
        try await settle { let av = await a.raw, bv = await b.raw; return av == 1 && bv == 1 }
        let configuredA = await a.configured, configuredB = await b.configured
        try check(!configuredA && !configuredB, "Higher-than-source fallback configured compressed input")
        outputs.stopAll(); try await settle { outputs.encoderSessionCount == 0 && outputs.activeCount == 0 }
        report("PASS: fixed profiles requesting more fps than the taken canvas use actual separate raw publishers and receive no sharing budget discount")
    }
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("stream-shared-encoder-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let first = EncodedPublisherProbe(), second = EncodedPublisherProbe(), separate = EncodedPublisherProbe(), rejoin = EncodedPublisherProbe()
        var pending = [first, second, separate, rejoin]
        let outputs = DestinationOutputController(factory: { _ in pending.removeFirst() })
        outputs.sharedEncodingEnabled = true
        outputs.sharedSourceFrameRate = 25
        var settings = StreamSettings.default
        settings.outputProfile = .init(canvasWidth: 320, canvasHeight: 180, frameRate: 25)
        settings.videoBitrate = 500_000; settings.audioBitrate = 128_000
        let a = StreamDestination(name: "RTMP", transport: .rtmp), b = StreamDestination(name: "SRT", transport: .srt)
        outputs.start(a, settings: settings); outputs.start(b, settings: settings)
        try await settle { outputs.liveCount == 2 }
        try check(outputs.encoderSessionCount == 1, "Compatible started targets did not share one actual owner")
        try await feed(outputs, start: 0, ticks: 200)
        let observedFirst = await first.video.count, observedSecond = await second.video.count
        FileHandle.standardOutput.write(Data("Observed first-feed frames \(observedFirst)/\(observedSecond), states \(outputs.states)\n".utf8))
        try await settle { let a = await first.video.count; let b = await second.video.count; return a >= 45 && b >= 45 }
        let av = await first.video, bv = await second.video, aa = await first.audio, ba = await second.audio
        try check(av.count == bv.count && aa.count == ba.count, "Compatible destinations received different sample counts")
        for (x, y) in zip(av, bv) {
            try check(x === y && bytes(x) == bytes(y) && x.presentationTimeStamp == y.presentationTimeStamp,
                      "Compatible video was re-encoded or retimed per destination")
        }
        for (x, y) in zip(aa, ba) { try check(x === y && x.sample === y.sample && bytes(x.sample) == bytes(y.sample), "AAC packet was not reused") }
        let firstRaw = await first.raw, secondRaw = await second.raw, firstConfigured = await first.configured, secondConfigured = await second.configured
        try check(firstRaw == 0 && secondRaw == 0 && firstConfigured && secondConfigured, "Shared route reached raw encoder ingress")
        try await write(first, to: directory.appendingPathComponent("first.mp4"))
        try await write(second, to: directory.appendingPathComponent("second.mp4"))
        try await ProgramRecordingFixtures.inspect(directory.appendingPathComponent("first.mp4"), expectedDuration: 2, checkSync: true)
        try await ProgramRecordingFixtures.inspect(directory.appendingPathComponent("second.mp4"), expectedDuration: 2, checkSync: true)
        report("PASS: same compressed H.264 CMSampleBuffer and AAC packet identities/bytes/timestamps reused by RTMP/SRT endpoints; two actual containers decode with matching samples and flash/tone")

        var different = settings; different.outputProfile = .init(canvasWidth: 160, canvasHeight: 90, frameRate: 25)
        let c = StreamDestination(name: "Different profile", transport: .rtmps)
        outputs.start(c, settings: different)
        try await settle { outputs.liveCount == 3 }
        try check(outputs.encoderSessionCount == 2, "Different profile was incorrectly merged")
        await second.hold()
        try await feed(outputs, start: 200, ticks: 160)
        let beforeStop = await first.video.count
        let diagnostics = await outputs.diagnosticsSnapshot()
        let stalled = diagnostics.first { $0.id == b.id.uuidString }!
        try check(stalled.videoMailboxDrops > 0 && stalled.videoQueueDepth <= 64, "Compressed slow mailbox was unbounded or did not shed")
        await second.release()
        try await feed(outputs, start: 360, ticks: 80)
        let bAfter = await second.video
        let originalCount = bv.count
        try check(bAfter.count > originalCount + 1 && keyframe(bAfter[originalCount + 1]), "Slow endpoint resumed dependent frames without an IDR")
        let separateFrames = await separate.video
        try check(CMVideoFormatDescriptionGetDimensions(separateFrames[0].formatDescription!).width == 160, "Destination profile mutated unrelated dimensions")
        outputs.stop(b.id)
        try await settle { outputs.states[b.id] == .idle }
        try check(outputs.states[a.id] == .live && outputs.encoderSessionCount == 2, "Independent stop ended the shared survivor")
        outputs.start(b, settings: settings)
        second.continuation.yield(.published) // Late prior-session acknowledgment.
        try await settle { outputs.states[b.id] == .live }
        try await feed(outputs, start: 440, ticks: 80)
        let joined = await rejoin.video
        try check(!joined.isEmpty && keyframe(joined[0]) && outputs.encoderSessionCount == 2, "Rejoin failed to reuse owner/start at IDR")
        try check(await first.video.count > beforeStop, "Healthy output stopped under another target's overflow/rejoin")
        rejoin.continuation.yield(.failed(message: "fixture target failure"))
        try await settle { if case .failed = outputs.states[b.id] { return true }; return false }
        try check(outputs.states[a.id] == .live && outputs.encoderSessionCount == 2, "One target failure ended the healthy group")
        outputs.stopAll()
        try await settle { outputs.activeCount == 0 && outputs.encoderSessionCount == 0 }
        report("PASS: distinct profiles separate owners; compressed overflow sheds GOP/audio and recovers at IDR, healthy target advances, independent stop/rejoin and late receipt isolation; real encoders finish before reservation count reaches zero")
        try JSONEncoder().encode([StreamDestination]()).write(to: directory.appendingPathComponent("destinations.json"))
        let preferences = DestinationSession(fileURL: directory.appendingPathComponent("destinations.json"), settings: .default)
        try check(!preferences.sharesFixedH264AAC, "Sharing must default off")
        preferences.sharesFixedH264AAC = true
        let reloaded = DestinationSession(fileURL: directory.appendingPathComponent("destinations.json"), settings: .default)
        try check(reloaded.sharesFixedH264AAC, "Profile sharing policy did not persist")
        let policyFile = directory.appendingPathComponent("destination-encoding.v1.json")
        let future = Data("{\"version\":2,\"sharesFixedH264AAC\":true}".utf8)
        try future.write(to: policyFile)
        let preserved = DestinationSession(fileURL: directory.appendingPathComponent("destinations.json"), settings: .default)
        preserved.sharesFixedH264AAC = true
        try check(try Data(contentsOf: policyFile) == future, "Future profile policy bytes were overwritten")
        try check(!preserved.sharesFixedH264AAC && preserved.errorMessage != nil, "Unsupported preference silently enabled an unsaved mode")
        try FileManager.default.removeItem(at: policyFile)
        try FileManager.default.createDirectory(at: policyFile, withIntermediateDirectories: false)
        let unreadable = DestinationSession(fileURL: directory.appendingPathComponent("destinations.json"), settings: .default)
        unreadable.sharesFixedH264AAC = true
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: policyFile.path, isDirectory: &isDirectory)
        try check(!unreadable.sharesFixedH264AAC && unreadable.errorMessage != nil && exists && isDirectory.boolValue,
            "Existing unreadable policy path was overwritten or its failed setting remained enabled: mode=\(unreadable.sharesFixedH264AAC), error=\(String(describing: unreadable.errorMessage)), exists=\(exists), directory=\(isDirectory)")
        report("PASS: profile fixed-sharing opt-in defaults off, persists independently and preserves unsupported document bytes")
        try await rawFinalization(settings: settings)
        try await canvasAndEncoderFailure(settings: settings)
        try await fixedCadence(directory: directory, settings: settings)
        try await higherRateFallback(settings: settings)
        try await localhostTransports(directory: directory, settings: settings)
        report("Artifacts: \(directory.path)")
    }
}
