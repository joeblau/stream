import AVFoundation
import CoreMedia
import Foundation
import StreamCore

private actor CadencePublisher: Publisher {
    nonisolated let supportsSharedH264AAC = true
    nonisolated let events: AsyncStream<PublisherEvent>
    nonisolated let continuation: AsyncStream<PublisherEvent>.Continuation
    private(set) var video: [CMSampleBuffer] = []
    init() { (events, continuation) = AsyncStream.makeStream(of: PublisherEvent.self) }
    func configureEncodedInput() async -> Bool { true }
    func start(_ settings: StreamSettings) async throws { continuation.yield(.published) }
    func stop() async {}
    func pause() async {}
    func resume() async {}
    func setOutputSize(_ size: CGSize, nativeShortEdge: Int) async {}
    func appendVideo(_ sample: CMSampleBuffer) async {}
    func appendEncodedVideo(_ sample: CMSampleBuffer) async -> Bool { video.append(sample); return false }
    func appendEncodedAudio(_ sample: SharedEncodedAudio) async -> Bool { false }
    nonisolated func enqueueMic(_ sample: CMSampleBuffer) {}
    nonisolated func enqueueApp(_ sample: CMSampleBuffer) {}
    nonisolated func enqueueProgram(_ sample: CMSampleBuffer) {}
    func setMicVolume(_ volume: Double) async {}
    func setThermalCeiling(bitRateScale: Double, frameRateCap: Int) async {}
    func statsSnapshot() async -> LiveStats? { nil }
}

/// Actual compressed samples and decoded file frames, not an admission counter.
@MainActor enum SharedEncoderCadenceHarness {
    static func raw(root: URL) async throws {
        let allCases: [(StreamCore.StreamProtocol,Int,Int?)] = [(.rtmp,30,nil),(.rtmp,15,nil),(.rtmp,30,15),(.srt,30,nil)]
        let cases = ProcessInfo.processInfo.environment["ISO_RAW_SRT_ONLY"] == "1" ? allCases.filter { $0.0 == .srt } : allCases
        for (transport,targetFPS,thermalCap) in cases {
            let label = "\(transport.rawValue)-30-to-\(targetFPS)-cap\(thermalCap ?? targetFPS)"
            let network = root.appendingPathComponent("raw-jitter-\(label).mp4")
            let log = root.appendingPathComponent("raw-jitter-\(label).log")
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let handle = try FileHandle(forWritingTo: log), receiver = Process()
            let port = Int.random(in: 20_000...45_000)
            receiver.executableURL = try RecordingStorageNetworkHarness.receiverExecutable()
            let input = transport == .srt ? ["-i","srt://127.0.0.1:\(port)?mode=listener&latency=50000"] : ["-listen","1","-i","rtmp://127.0.0.1:\(port)/live/cadence"]
            receiver.arguments = ["-y","-hide_banner","-loglevel","error"] + input + ["-map","0:v:0","-map","0:a:0","-c","copy",network.path]
            receiver.standardOutput = handle; receiver.standardError = handle; try receiver.run()
            defer { if receiver.isRunning { receiver.interrupt() }; try? handle.close() }
            try await IsolatedSustainedHarness.wait("Cadence actual RTMP receiver did not listen") { RecordingStorageNetworkHarness.receiverReady(receiver,transport:transport,port:port) }
            let publisher: any Publisher = transport == .rtmp ? RTMPPublisher() : SessionPublisher(protocol: .srt)
            let outputs = DestinationOutputController(factory: { _ in publisher })
            outputs.sharedEncodingEnabled = false; outputs.sharedSourceFrameRate = 30
            var settings = StreamSettings.default
            settings.outputProfile = .init(canvasWidth:320,canvasHeight:180,frameRate:targetFPS)
            settings.frameRate = targetFPS; settings.videoBitrate = 500_000; settings.audioBitrate = 128_000
            settings.rtmpURL = transport == .srt ? "srt://127.0.0.1:\(port)?mode=caller&latency=50" : "rtmp://127.0.0.1:\(port)/live"
            settings.streamKey = transport == .srt ? "" : "cadence"
            settings.voicePolishEnabled = false; settings.selectedProtocol = transport
            outputs.start(StreamDestination(name:"Owned actual raw jitter",transport:transport),settings:settings)
            try await IsolatedSustainedHarness.wait("Raw cadence destination did not start") { outputs.liveCount == 1 }
            try await Task.sleep(for:.milliseconds(100))
            if let thermalCap { await publisher.setThermalCeiling(bitRateScale:1,frameRateCap:thermalCap) }
            var frame = 0, sourcePTS:[Double] = []
            for tick in 0..<200 {
                outputs.fanout.enqueueAudio(try ProgramRecordingFixtures.audio(at:Double(tick)/100))
                while frame < 60 && Double(frame)/30 <= Double(tick)/100 {
                    let jitter = frame == 0 ? 0 : (frame % 2 == 0 ? -0.0012 : 0.0012)
                    let sample = try ProgramRecordingFixtures.video(at:Double(frame)/30+jitter)
                    sourcePTS.append(sample.presentationTimeStamp.seconds); outputs.fanout.enqueueVideo(sample);frame += 1
                }
                try await Task.sleep(for:.milliseconds(10))
            }
            try await Task.sleep(for:.milliseconds(200))
            outputs.stopAll(); try await IsolatedSustainedHarness.wait("Raw cadence output did not stop") { outputs.activeCount == 0 && outputs.encoderSessionCount == 0 }
            try await IsolatedSustainedHarness.wait("Actual raw receiver did not finish") { !receiver.isRunning }
            try IsolatedSustainedHarness.check(receiver.terminationStatus == 0,"Actual cadence receiver failed")
            let asset = AVURLAsset(url: network)
            let tracks = try await asset.loadTracks(withMediaType:.video)
            let output = AVAssetReaderTrackOutput(track:tracks[0],outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
            // Reader outputs must use the identical asset instance.
            let actualReader = try AVAssetReader(asset:asset)
            actualReader.add(output); try IsolatedSustainedHarness.check(actualReader.startReading(),"Actual raw network decoder did not start")
            var decodedPTS:[Double] = []
            while let sample = output.copyNextSampleBuffer() { try IsolatedSustainedHarness.check(sample.imageBuffer != nil,"Network decode returned no pixels");decodedPTS.append(sample.presentationTimeStamp.seconds) }
            try IsolatedSustainedHarness.check(actualReader.status == .completed,"Network video decode failed")
            try JSONEncoder().encode(["sourcePTS":sourcePTS,"decodedPTS":decodedPTS]).write(to:root.appendingPathComponent("raw-jitter-\(label).json"))
            print("ACTUAL RAW CADENCE label=\(label) source=30 target=\(targetFPS) originalPTS=\(sourcePTS) decoded=\(decodedPTS.count) decodedPTS=\(decodedPTS) file=\(network.path)")
            let expected = min(targetFPS,thermalCap ?? targetFPS)*2
            // AVAssetReader can materialize a leading empty edit as a zero-time
            // pixel. Use the actual track range to exclude that gap, retaining
            // every real source frame and the transport's original time grid.
            let trackRange = try await tracks[0].load(.timeRange)
            let mediaPTS = decodedPTS.filter { $0 >= trackRange.start.seconds-0.000001 }
            print("ACTUAL MEDIA CADENCE label=\(label) packetsDecoded=\(mediaPTS.count) trackStart=\(trackRange.start.seconds) expected=\(expected)")
            try IsolatedSustainedHarness.check((expected-1...expected+1).contains(mediaPTS.count),"Actual raw RTMP lost source cadence despite uncongested declared Program rate")
            try IsolatedSustainedHarness.check(!mediaPTS.isEmpty,"No actual source media was decoded")
            for (index,pts) in mediaPTS.enumerated() {
                let relative = pts-mediaPTS[0]
                if min(targetFPS,thermalCap ?? targetFPS) == 30 {
                    try IsolatedSustainedHarness.check(abs(relative-(sourcePTS[index]-sourcePTS[0])) <= 0.0011,"Raw publisher changed or skipped original jittered source PTS")
                } else {
                    try IsolatedSustainedHarness.check(sourcePTS.contains { abs(relative-($0-sourcePTS[0])) <= 0.0011 },"Lower rate publisher invented a source timestamp")
                }
            }
        }
        print("PASS: actual raw RTMP/SRT preserve jittered30→30; intentional30→15 profile and real thermal15fps cap remain enforced through decoded network media")
    }
    static func run(root: URL) async throws {
        let hardware = ProcessInfo.processInfo.environment["ISO_CADENCE_SOFTWARE"] != "1"
        for (sourceFPS, targetFPS) in [(30,30), (30,15), (60,24)] {
            let publisher = CadencePublisher()
            let outputs = DestinationOutputController(factory: { _ in publisher }, sharedEncoderPrefersHardware: hardware)
            outputs.sharedEncodingEnabled = true; outputs.sharedSourceFrameRate = sourceFPS
            var settings = StreamSettings.default
            settings.outputProfile = .init(canvasWidth: 320, canvasHeight: 180, frameRate: targetFPS)
            settings.videoBitrate = 500_000; settings.audioBitrate = 128_000
            outputs.start(StreamDestination(name: "Owned jitter cadence"), settings: settings)
            try await IsolatedSustainedHarness.wait("Cadence encoder did not start") { outputs.liveCount == 1 }
            var frame = 0, inputPTS: [Double] = []
            for tick in 0..<200 {
                while frame < 2 * sourceFPS && Double(frame) / Double(sourceFPS) <= Double(tick) / 100 {
                    // A genuine monotonically increasing capture clock with bounded
                    // +/-600us scheduling jitter around its declared source cadence.
                    let jitter = frame == 0 ? 0 : (frame % 2 == 0 ? -0.0006 : 0.0006)
                    let time = Double(frame) / Double(sourceFPS) + jitter
                    let sample = try ProgramRecordingFixtures.video(at: time)
                    inputPTS.append(sample.presentationTimeStamp.seconds)
                    outputs.fanout.enqueueVideo(sample); frame += 1
                }
                outputs.fanout.enqueueAudio(try ProgramRecordingFixtures.audio(at: Double(tick) / 100))
                try await Task.sleep(for: .milliseconds(10))
            }
            outputs.stopAll()
            try await IsolatedSustainedHarness.wait("Cadence encoder resources did not drain") { outputs.activeCount == 0 && outputs.encoderSessionCount == 0 }
            let samples = await publisher.video
            let url = root.appendingPathComponent("jitter-\(sourceFPS)-to-\(targetFPS)-\(hardware ? "hardware" : "software").mp4")
            try IsolatedSustainedHarness.check(!samples.isEmpty, "Cadence codec emitted no actual samples")
            let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: samples[0].formatDescription)
            input.mediaTimeScale = 48_000
            print("COMPRESSED CADENCE source=\(sourceFPS) target=\(targetFPS) input=\(inputPTS.count) encoded=\(samples.count)")
            writer.add(input); try IsolatedSustainedHarness.check(writer.startWriting(), "Cadence file cannot start")
            let origin = samples[0].presentationTimeStamp
            writer.startSession(atSourceTime: origin)
            for sample in samples {
                try await IsolatedSustainedHarness.wait("Cadence file stalled") { input.isReadyForMoreMediaData || writer.status == .failed }
                try IsolatedSustainedHarness.check(input.append(sample), "Cadence compressed sample append failed")
                try IsolatedSustainedHarness.check(inputPTS.contains { abs($0 - sample.presentationTimeStamp.seconds) < 1e-7 }, "Encoder rewrote original source PTS")
            }
            input.markAsFinished(); await writer.finishWriting()
            try IsolatedSustainedHarness.check(writer.status == .completed, "Cadence file did not finish")
            let asset = AVURLAsset(url: url)
            let reader = try AVAssetReader(asset: asset)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let output = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            reader.add(output); try IsolatedSustainedHarness.check(reader.startReading(), "Cadence actual decoder did not start")
            var decodedPTS: [Double] = []
            while let sample = output.copyNextSampleBuffer() {
                try IsolatedSustainedHarness.check(sample.imageBuffer != nil, "Cadence decoder returned no pixels")
                decodedPTS.append(sample.presentationTimeStamp.seconds)
            }
            try IsolatedSustainedHarness.check(reader.status == .completed && decodedPTS.count == samples.count, "Cadence actual file lost encoded frames")
            for (decoded, sample) in zip(decodedPTS, samples) {
                try IsolatedSustainedHarness.check(abs(decoded - (sample.presentationTimeStamp - origin).seconds) < 0.0001, "Decoded cadence changed original timestamp grid")
            }
            let expected = 2 * targetFPS
            print("ACTUAL CADENCE source=\(sourceFPS) target=\(targetFPS) input=\(inputPTS.count) encoded=\(samples.count) decoded=\(decodedPTS.count) expected=\(expected) hardware=\(hardware) file=\(url.path)")
            try IsolatedSustainedHarness.check(samples.count == expected, "Same-rate jitter must preserve every source frame; slower fixed destination must keep its declared cadence")
        }
        print("PASS: actual H264 codec and decoded source-PTS files preserve jittered30→30, intentional30→15 and non-divisor60→24 cadence; all output/encoder resources released")
    }
}
