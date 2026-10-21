import AppKit
import AVFoundation
import CoreMedia
import Foundation

private final class SnapshotHelper: @unchecked Sendable {
    let process = Process(), input = Pipe(), output = Pipe()
    let listener: BrowserWidgetAudioSocket
    private var frames: FileHandle?
    private let lock = NSLock()
    private var replies: [BrowserWidgetAudioReply] = []
    init(executable: URL) throws {
        listener = try BrowserWidgetAudioSocket()
        process.executableURL = executable
        process.arguments = ["--frame-socket", listener.path]
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        DispatchQueue(label: "browser-alpha.replies").async { [self] in
            var pending = Data()
            var bytes = [UInt8](repeating: 0, count: 4_096)
            while true {
                let count = Darwin.read(output.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { break }
                pending.append(contentsOf: bytes.prefix(count))
                guard pending.count <= BrowserWidgetAudioCommand.maximumLineBytes else { break }
                while let end = pending.firstIndex(of: 10) {
                    let line = Data(pending[..<end]); pending.removeSubrange(...end)
                    if let reply = try? JSONDecoder().decode(BrowserWidgetAudioReply.self, from: line) {
                        lock.withLock { if replies.count == 128 { replies.removeFirst() }; replies.append(reply) }
                    }
                }
            }
        }
    }
    func connect() async throws { frames = try await listener.accept(expectedPID: process.processIdentifier) }
    func send(_ command: BrowserWidgetAudioCommand) throws { try input.fileHandleForWriting.write(contentsOf: command.encodedLine()) }
    func wait(_ state: BrowserWidgetAudioReply.State, id: UUID? = nil, generation: UUID? = nil,
              request: UUID? = nil, category: String? = nil) async throws {
        for _ in 0..<200 {
            if lock.withLock({ replies.contains { $0.state == state && (id == nil || $0.widgetID == id)
                && (generation == nil || $0.generation == generation) && (request == nil || $0.requestID == request)
                && (category == nil || $0.failure == category) } }) { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        let observed = lock.withLock { replies.suffix(6).map { "\($0.state.rawValue):\($0.failure ?? "none")" }.joined(separator: ",") }
        throw failure("Helper did not acknowledge \(state)/\(category ?? "none"); observed \(observed)")
    }
    func snapshot(id: UUID, generation: UUID) async throws -> (BrowserWidgetVisualHeader, Data) {
        let request = UUID()
        try send(.init(action: .snapshot, widgetID: id, requestID: request, generation: generation))
        let descriptor = frames!.fileDescriptor
        let result = try await Task.detached { try BrowserWidgetVisualTransport.read(descriptor: descriptor) }.value
        guard result.0.widgetID == id, result.0.generation == generation, result.0.requestID == request else { throw failure("Actual helper returned a mismatched frame lease") }
        return result
    }
    func close() {
        try? send(.init(action: .close)); try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        try? frames?.close()
    }
}

private func failure(_ message: String) -> NSError { NSError(domain: "BrowserSnapshotAlpha", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
private func pixel(_ bytes: Data, _ x: Int, _ y: Int) -> [UInt8] { Array(bytes[(y * 480 + x) * 4..<(y * 480 + x) * 4 + 4]) }
private func image(_ bytes: Data) -> CGImage {
    CGImage(width: 480, height: 270, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 480 * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
        provider: CGDataProvider(data: bytes as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}
private func save(_ bytes: Data, to url: URL) throws {
    let representation = NSBitmapImageRep(cgImage: image(bytes))
    try representation.representation(using: .png, properties: [:])!.write(to: url)
}
private func composite(_ bytes: Data) -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(nil, 480, 270, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &buffer)
    let result = buffer!
    CVPixelBufferLockBaseAddress(result, []); defer { CVPixelBufferUnlockBaseAddress(result, []) }
    let context = CGContext(data: CVPixelBufferGetBaseAddress(result), width: 480, height: 270, bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(result), space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    context.setFillColor(CGColor(red: 1, green: 0, blue: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 480, height: 270))
    context.draw(image(bytes), in: CGRect(x: 0, y: 0, width: 480, height: 270))
    return result
}
private func tone(frame: Int) throws -> CMSampleBuffer {
    let frames = 3_200
    var values = [Float](repeating: 0, count: frames * 2)
    for n in 0..<frames { let value = Float(sin(Double(frame * frames + n) * 2 * .pi * 1_000 / 48_000) * 0.1); values[n * 2] = value; values[n * 2 + 1] = value }
    var block: CMBlockBuffer?
    guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: values.count * 4, blockAllocator: nil,
        customBlockSource: nil, offsetToData: 0, dataLength: values.count * 4, flags: 0, blockBufferOut: &block) == noErr else { throw failure("PCM allocation failed") }
    _ = values.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: $0.count) }
    var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8, mFramesPerPacket: 1,
        mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
    var format: CMAudioFormatDescription?
    CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000), presentationTimeStamp: CMTime(value: Int64(frame * frames), timescale: 48_000), decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?, size = 8
    guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: frames,
        sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr else { throw failure("PCM sample creation failed") }
    return sample!
}
@MainActor private func recordAndDecode(_ bytes: Data, at url: URL) async throws -> [String: Any] {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let video = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 480, AVVideoHeightKey: 270])
    let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    writer.add(video); writer.add(audio)
    guard writer.startWriting() else { throw failure("AV writer did not start") }; writer.startSession(atSourceTime: .zero)
    let buffer = composite(bytes)
    // Inputs have independent backpressure. Waiting for BOTH to be ready
    // before appending either can starve the muxer when one awaits its peer.
    var videoFrame = 0, audioFrame = 0
    var deadline = ContinuousClock.now + .seconds(3)
    while videoFrame < 30 || audioFrame < 30 {
        var advanced = false
        if videoFrame < 30, video.isReadyForMoreMediaData {
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(videoFrame), timescale: 15)) else { throw failure("AV fixture video append failed") }
            videoFrame += 1; advanced = true
            if videoFrame == 30 { video.markAsFinished() }
        }
        if audioFrame < 30, audio.isReadyForMoreMediaData {
            guard audio.append(try tone(frame: audioFrame)) else { throw failure("AV fixture audio append failed") }
            audioFrame += 1; advanced = true
            if audioFrame == 30 { audio.markAsFinished() }
        }
        if advanced { deadline = ContinuousClock.now + .seconds(3) }
        else {
            guard ContinuousClock.now < deadline else {
                throw failure("AV fixture stalled: video=\(videoFrame), audio=\(audioFrame), writer=\(writer.status.rawValue), error=\(String(describing: writer.error))")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    await writer.finishWriting()
    guard writer.status == .completed else { throw failure("AV fixture did not finalize") }
    let asset = AVURLAsset(url: url)
    let reader = try AVAssetReader(asset: asset)
    let videoTrack = try await asset.loadTracks(withMediaType: .video).first!, audioTrack = try await asset.loadTracks(withMediaType: .audio).first!
    let visual = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    let sound = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false])
    reader.add(visual); reader.add(sound); guard reader.startReading() else { throw failure("Native AV decode did not start") }
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    let expectedPointer = CVPixelBufferGetBaseAddress(buffer)!.advanced(by: 260 * CVPixelBufferGetBytesPerRow(buffer) + 470 * 4).assumingMemoryBound(to: UInt8.self)
    let expectedCorner = Array(UnsafeBufferPointer(start: expectedPointer, count: 4))
    CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
    var decodedFrames = 0, corner: [UInt8] = [], audioFrames = 0, square = 0.0
    var toneReal = 0.0, toneImaginary = 0.0
    while let sample = visual.copyNextSampleBuffer() {
        let frame = sample.imageBuffer!; CVPixelBufferLockBaseAddress(frame, .readOnly)
        let pointer = CVPixelBufferGetBaseAddress(frame)!.advanced(by: 260 * CVPixelBufferGetBytesPerRow(frame) + 470 * 4).assumingMemoryBound(to: UInt8.self)
        corner = Array(UnsafeBufferPointer(start: pointer, count: 4)); CVPixelBufferUnlockBaseAddress(frame, .readOnly); decodedFrames += 1
    }
    while let sample = sound.copyNextSampleBuffer(), let block = sample.dataBuffer {
        let count = CMBlockBufferGetDataLength(block) / 4
        var values = [Float](repeating: 0, count: count)
        _ = values.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
        square += values.reduce(0) { $0 + Double($1 * $1) }
        for n in 0..<(count / 2) {
            let phase = Double(audioFrames + n) * 2 * .pi * 1_000 / 48_000
            toneReal += Double(values[n * 2]) * cos(phase); toneImaginary += Double(values[n * 2]) * sin(phase)
        }
        audioFrames += sample.numSamples
    }
    guard reader.status == .completed, decodedFrames == 30, audioFrames >= 95_000, corner.count == 4, square > 100 else { throw failure("Decoded AV fixture lost actual snapshot frames or synthetic PCM") }
    let amplitude = 2 * hypot(toneReal, toneImaginary) / Double(audioFrames)
    guard zip(corner.prefix(3), expectedCorner.prefix(3)).allSatisfy({ abs(Int($0.0) - Int($0.1)) < 12 }), amplitude > 0.05 else {
        throw failure("Native decode changed the composited snapshot corner or lost its synthetic 1000Hz PCM")
    }
    return ["decodedVideoFrames": decodedFrames, "decodedAudioFrames": audioFrames, "decodedCornerBGRA": corner,
        "sourceCompositedCornerBGRA": expectedCorner, "decoded1000HzAmplitude": amplitude,
        "audioSource": "fixture-generated 1000Hz PCM, never WebKit/system capture", "durationSeconds": try await asset.load(.duration).seconds]
}

@main @MainActor struct BrowserSnapshotAlphaHarness {
    static func main() async {
        setbuf(stdout, nil); signal(SIGPIPE, SIG_IGN)
        do { try await run() } catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
    }
    static func run() async throws {
        guard CGSessionCopyCurrentDictionary() != nil else { print("UNQUALIFIED: browser alpha needs a logged-in WindowServer"); exit(77) }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let artifacts = root.appendingPathComponent("run-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        var reports: [[String: Any]] = [], transparent = true
        for variant in ["baseline", "public-opacity"] {
            let helper = try SnapshotHelper(executable: root.appendingPathComponent("helper-" + variant))
            defer { helper.close() }
            try await helper.connect(); try await helper.wait(.ready)
            let id = UUID(), generation = UUID()
            let html = "<style>html,body{margin:0;background:transparent}div{position:absolute;top:20px;width:80px;height:80px}#red{left:20px;background:red}#green{left:200px;background:rgba(0,255,0,.5)}#white{left:360px;background:white}</style><div id=red></div><div id=green></div><div id=white></div>"
            try helper.send(.init(action: .load, widgetID: id, html: html, options: .init(hidden: true), generation: generation))
            try await helper.wait(.loaded, id: id); try await Task.sleep(for: .milliseconds(300))
            let (header, bytes) = try await helper.snapshot(id: id, generation: generation)
            let clear = pixel(bytes, 470, 260), red = pixel(bytes, 40, 40), green = pixel(bytes, 240, 40), white = pixel(bytes, 400, 40)
            guard red[2] > 240 && red[0] < 10 && white.allSatisfy({ $0 > 240 }) else { throw failure("Helper snapshot did not contain actual synthetic DOM colors") }
            transparent = transparent && clear[3] < 5 && (120...135).contains(Int(green[3]))
            try save(bytes, to: artifacts.appendingPathComponent(variant + ".png"))
            var report: [String: Any] = ["variant": variant, "clearBGRA": clear, "redBGRA": red, "halfGreenBGRA": green, "opaqueWhiteBGRA": white,
                "snapshotMilliseconds": (header.completedHostSeconds - header.requestedHostSeconds) * 1_000]
            report["recording"] = try await recordAndDecode(bytes, at: artifacts.appendingPathComponent(variant + ".mp4"))
            reports.append(report)
            let nextGeneration = UUID()
            try helper.send(.init(action: .load, widgetID: id, html: html.replacingOccurrences(of: "background:red", with: "background:blue"),
                options: .init(hidden: true), generation: nextGeneration))
            try await helper.wait(.loaded, id: id, generation: nextGeneration)
            for action in [BrowserWidgetAudioCommand.Action.suspend, .resume] {
                let staleRequest = UUID()
                try helper.send(.init(action: action, widgetID: id, requestID: staleRequest, generation: generation))
                try await helper.wait(.failed, id: id, generation: generation, request: staleRequest, category: "stale_generation")
                let currentRequest = UUID()
                try helper.send(.init(action: action, widgetID: id, requestID: currentRequest, generation: nextGeneration))
                try await helper.wait(action == .suspend ? .suspended : .loaded, id: id, generation: nextGeneration, request: currentRequest)
                let (_, currentPixels) = try await helper.snapshot(id: id, generation: nextGeneration)
                guard pixel(currentPixels, 40, 40)[0] > 240 else { throw failure("Current page snapshots failed after media lifecycle acknowledgments") }
            }
            let staleStop = UUID()
            try helper.send(.init(action: .stop, widgetID: id, requestID: staleStop, generation: generation))
            try await helper.wait(.failed, id: id, generation: generation, request: staleStop, category: "stale_generation")
            let (_, afterStaleStop) = try await helper.snapshot(id: id, generation: nextGeneration)
            guard pixel(afterStaleStop, 40, 40)[0] > 240 else { throw failure("Stale Stop retired the replacement page") }
            print("PASS \(variant): replaced page rejects old-generation Suspend, Resume and Stop; current-generation acknowledgments and actual blue-page snapshots survive")
            try helper.send(.init(action: .stop, widgetID: id, generation: nextGeneration)); try await helper.wait(.stopped, id: id)
            print("MEASURED \(variant): clear=\(clear), halfGreen=\(green), opaqueWhite=\(white); actual helper IPC→snapshot→composited H264/AAC→native decode complete")
        }
        try JSONSerialization.data(withJSONObject: reports, options: [.prettyPrinted, .sortedKeys]).write(to: artifacts.appendingPathComponent("report.json"))
        print("Artifacts: \(artifacts.path)")
        guard !BrowserWidgetAudioIdentity.productionRouteQualified else { throw failure("Production helper route must remain disabled") }
        print("SCOPE: exact shipping helper and generated public-opacity candidate; synthetic page/pixels/PCM only; no audio playback, capture, permissions, app install or signing operation")
        if !transparent { print("UNQUALIFIED: public under-page color and NSView opacity retain an opaque white snapshot backdrop; alpha transport is not transparency qualification"); exit(77) }
        print("PASS: public snapshot preserves transparent and half-transparent DOM pixels; production signing/IPC/audio exclusion/demand gates remain open")
    }
}
