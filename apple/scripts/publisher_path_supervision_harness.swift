import AVFoundation
import CoreMedia
import Foundation
import StreamCore

/// Only NWPathMonitor delivery is replaced. The shipping RTMP path callback,
/// reconnect/backoff, real sockets, both publishers and shared encoder run.
enum OwnedPublisherPathFeed {
    static let updates = AsyncStream<NetworkPathSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(32))
    static func send(_ path: NetworkPathSnapshot) { updates.continuation.yield(path) }
}

@MainActor enum PublisherPathSupervisionHarness {
    static func run(directory: URL) async throws {
        guard let ffmpeg = try SharedEncoderHarness.receiverExecutable() else { exit(77) }
        var processes: [Process] = [], handles: [FileHandle] = []
        defer {
            OwnedPublisherPathFeed.updates.continuation.finish()
            for process in processes where process.isRunning { process.interrupt() }
            for handle in handles { try? handle.close() }
        }
        let rtmpPort = Int.random(in: 20_000...30_000), srtPort = Int.random(in: 30_001...40_000)
        func launch(_ transport: StreamCore.StreamProtocol, port: Int, name: String) throws -> Process {
            let log = directory.appendingPathComponent(name + ".log")
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let handle = try FileHandle(forWritingTo: log); handles.append(handle)
            let process = Process(); process.executableURL = ffmpeg
            let input = transport == .srt ? ["-i", "srt://127.0.0.1:\(port)?mode=listener&latency=50000"]
                : ["-listen", "1", "-i", "rtmp://127.0.0.1:\(port)/live/shared"]
            process.arguments = ["-y", "-hide_banner", "-loglevel", "error"] + input
                + ["-map", "0:v:0", "-map", "0:a:0", "-c", "copy", directory.appendingPathComponent(name + ".mp4").path]
            process.standardOutput = handle; process.standardError = handle
            try process.run(); processes.append(process); return process
        }
        let first = try launch(.rtmp, port: rtmpPort, name: "path-rtmp-before")
        let survivor = try launch(.srt, port: srtPort, name: "path-srt-continuous")
        try await SharedEncoderHarness.settle(seconds: 10) {
            SharedEncoderHarness.receiverReady(first, transport: .rtmp, port: rtmpPort)
                && SharedEncoderHarness.receiverReady(survivor, transport: .srt, port: srtPort)
        }
        let publisher = RTMPPublisher()
        var factoryCalls = 0
        let outputs = DestinationOutputController(factory: { transport in
            factoryCalls += 1
            return transport == .rtmp ? publisher : SessionPublisher(protocol: .srt)
        })
        outputs.sharedEncodingEnabled = true; outputs.sharedSourceFrameRate = 25
        defer { outputs.stopAll() }
        var settings = StreamSettings.default
        settings.outputProfile = .init(canvasWidth: 320, canvasHeight: 180, frameRate: 25)
        settings.videoBitrate = 500_000; settings.audioBitrate = 128_000
        var rtmp = settings; rtmp.rtmpURL = "rtmp://127.0.0.1:\(rtmpPort)/live"; rtmp.streamKey = "shared"
        var srt = settings; srt.selectedProtocol = .srt; srt.rtmpURL = "srt://127.0.0.1:\(srtPort)?mode=caller&latency=50"; srt.streamKey = ""
        let interrupted = StreamDestination(name: "Owned route-controlled RTMP", transport: .rtmp)
        let healthy = StreamDestination(name: "Owned continuous SRT", transport: .srt)
        let usable = NetworkPathSnapshot(isSatisfied: true, interface: .wiredEthernet, interfaceName: "owned-loopback")
        let unavailable = NetworkPathSnapshot(isSatisfied: false, interface: .none, interfaceName: "")
        OwnedPublisherPathFeed.send(usable)
        outputs.start(interrupted, settings: rtmp); outputs.start(healthy, settings: srt)
        try await SharedEncoderHarness.settle(seconds: 10) { outputs.liveCount == 2 }
        let before = await outputs.diagnosticsSnapshot()
        let healthyStart = before.first { $0.id == healthy.id.uuidString }?.startedAt
        let interruptedStart = before.first { $0.id == interrupted.id.uuidString }?.startedAt
        try SharedEncoderHarness.check(healthyStart != nil && interruptedStart != nil && factoryCalls == 2,
                                       "Initial real publishers were not acknowledged")
        let producer = Task { @MainActor in
            for tick in 0..<1600 {
                let time = Double(tick) / 100
                if tick % 4 == 0 { outputs.fanout.enqueueVideo(try ProgramRecordingFixtures.video(at: time, eventSeconds: time < 6 ? 0.5 : 12)) }
                outputs.fanout.enqueueAudio(try ProgramRecordingFixtures.audio(at: time, eventSeconds: time < 6 ? 0.5 : 12))
                try SharedEncoderHarness.check(outputs.states[healthy.id] == .live && outputs.encoderSessionCount == 1 && factoryCalls == 2,
                                               "Path recovery disturbed the healthy SRT output/shared encoder")
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        defer { producer.cancel() }
        try await Task.sleep(for: .milliseconds(1100))
        // Metadata-only churn must leave both acknowledged sessions intact.
        let metadata = NetworkPathSnapshot(isSatisfied: true, interface: .wiredEthernet, interfaceName: "owned-loopback", isExpensive: true)
        OwnedPublisherPathFeed.send(metadata)
        try await SharedEncoderHarness.settle { await publisher.pathFixtureCurrent == metadata }
        let afterMetadata = await outputs.diagnosticsSnapshot()
        try SharedEncoderHarness.check(afterMetadata.first { $0.id == interrupted.id.uuidString }?.startedAt == interruptedStart,
                                       "Metadata-only route update recycled a healthy RTMP publisher")
        OwnedPublisherPathFeed.send(unavailable)
        try await SharedEncoderHarness.settle(seconds: 4) { await publisher.pathFixtureDetached }
        // Restored route + detached live socket starts a real reconnect. Do not
        // restart the receiver yet: later snapshots must still be consumed.
        OwnedPublisherPathFeed.send(usable)
        try await SharedEncoderHarness.settle(seconds: 5) { await publisher.pathFixtureRecovering }
        OwnedPublisherPathFeed.send(unavailable)
        try await SharedEncoderHarness.settle(seconds: 1) { await publisher.pathFixtureCurrent == unavailable }
        print("PASS: actual RTMP route callback consumes a second path loss during reconnect; observation does not await the reconnect loop")
        try await SharedEncoderHarness.settle(seconds: 10) { !first.isRunning }
        let resumed = try launch(.rtmp, port: rtmpPort, name: "path-rtmp-after")
        try await SharedEncoderHarness.settle(seconds: 10) { SharedEncoderHarness.receiverReady(resumed, transport: .rtmp, port: rtmpPort) }
        OwnedPublisherPathFeed.send(usable)
        try await SharedEncoderHarness.settle(seconds: 10) { outputs.states[interrupted.id] == .live }
        try await producer.value
        let final = await outputs.diagnosticsSnapshot()
        try SharedEncoderHarness.check(final.first { $0.id == healthy.id.uuidString }?.startedAt == healthyStart && factoryCalls == 2,
                                       "Recovered route changed the healthy publisher's original ownership")
        outputs.stopAll()
        try await SharedEncoderHarness.settle { outputs.encoderSessionCount == 0 }
        try await SharedEncoderHarness.settle(seconds: 10) { outputs.activeCount == 0 && processes.allSatisfy { !$0.isRunning } }
        // Keep the original receiver fixture's strict track/sync checks. This
        // test does not repair or hide an independent encoded-media defect.
        for name in ["path-rtmp-before", "path-rtmp-after", "path-srt-continuous"] {
            try await ProgramRecordingFixtures.inspect(directory.appendingPathComponent(name + ".mp4"), expectedDuration: nil,
                                                       checkSync: name != "path-rtmp-after")
        }
        try await checkHealthyTimeline(directory.appendingPathComponent("path-srt-continuous.mp4"))
        // A late route emission after acknowledged stop cannot allocate output.
        OwnedPublisherPathFeed.send(unavailable); OwnedPublisherPathFeed.send(usable)
        try await Task.sleep(for: .milliseconds(100))
        try SharedEncoderHarness.check(outputs.activeCount == 0 && factoryCalls == 2 && outputs.encoderSessionCount == 0,
                                       "Late path update resurrected a stopped output")
        print("PASS: metadata/loss/restoration/loss/restoration through real RTMP path callbacks, same two publisher owners, continuous decoded healthy SRT, original sync/endpoints, acknowledged stops and no surprise Go Live")
    }

    private static func checkHealthyTimeline(_ url: URL) async throws {
        let asset = AVURLAsset(url: url)
        let reader = try AVAssetReader(asset: asset)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let decoded = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(decoded); try SharedEncoderHarness.check(reader.startReading(), "Healthy SRT decode could not start")
        var previous: Double?, frames = 0, firstFlash: Double?, lateFlash: Double?
        while let sample = decoded.copyNextSampleBuffer() {
            let pts = sample.presentationTimeStamp.seconds
            if let previous { try SharedEncoderHarness.check(pts > previous && pts - previous < 0.0415, "Healthy SRT lost an original cadence tick") }
            previous = pts; frames += 1
            if let image = sample.imageBuffer {
                CVPixelBufferLockBaseAddress(image, .readOnly)
                let bright = CVPixelBufferGetBaseAddress(image)!.load(as: UInt8.self)
                CVPixelBufferUnlockBaseAddress(image, .readOnly)
                if bright > 150 { if firstFlash == nil { firstFlash = pts }; if pts > 11 && lateFlash == nil { lateFlash = pts } }
            }
        }
        try SharedEncoderHarness.check(reader.status == .completed && firstFlash != nil && lateFlash != nil,
                                       "Healthy SRT did not retain both independent original source cues")
        try SharedEncoderHarness.check(abs(lateFlash! - firstFlash! - 11.48) < 0.0415
            && abs((previous ?? 0) - firstFlash! - 15.44) < 0.0415, "Path recovery shifted/truncated the healthy original timeline")
        print("Healthy SRT: \(frames) continuous decoded frames, source flashes \(firstFlash!)/\(lateFlash!)s, final PTS \(previous ?? -1)s")
    }
}
