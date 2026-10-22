import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import StreamCore

private func require(_ value: Bool, _ message: String) { precondition(value, message) }
private func pixel(_ image: CVPixelBuffer, _ x: Int, _ y: Int) -> [Int] {
    CVPixelBufferLockBaseAddress(image, .readOnly); defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
    let p = CVPixelBufferGetBaseAddress(image)!.advanced(by: y * CVPixelBufferGetBytesPerRow(image) + x * 4).assumingMemoryBound(to: UInt8.self)
    return (0..<4).map { Int(p[$0]) }
}
private struct FrameProof: Sendable { let corner: [Int], red: [Int], green: [Int], white: [Int] }
private final class Frames: @unchecked Sendable {
    private let lock = NSLock(); private var frames: [FrameProof] = []
    func append(_ frame: CompositedFrame) {
        guard let image = frame.pixelBuffer else { return }
        let value = FrameProof(corner: pixel(image, 470, 260), red: pixel(image, 40, 40), green: pixel(image, 240, 40), white: pixel(image, 400, 40))
        lock.lock(); if frames.count == 120 { frames.removeFirst() }; frames.append(value); lock.unlock()
    }
    var snapshot: [FrameProof] { lock.lock(); defer { lock.unlock() }; return frames }
}
@MainActor private final class NoCapture: BrowserWidgetAudioDriver {
    let requiresScreenCaptureAccess = false; let isCapturing = false
    var onFailure: (@MainActor (String) -> Void)?
    func start(helperPID: Int32) async throws { preconditionFailure("Visual proof must never start audio capture") }
    func invalidateInput() {}
    func stop() async {}
}
@main @MainActor struct BrowserWidgetPDFProgramHarness {
    static func wait(_ label: String, _ predicate: () -> Bool) async throws {
        for _ in 0..<400 { if predicate() { return }; try await Task.sleep(for: .milliseconds(25)) }
        throw NSError(domain: "BrowserPDFProgram", code: 1, userInfo: [NSLocalizedDescriptionKey: label])
    }
    static func main() async {
        setbuf(stdout, nil); NSApplication.shared.setActivationPolicy(.prohibited)
        do { try await run() } catch { print("FAIL: \(error)"); exit(1) }
    }
    static func run() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let html = "<style>html,body{margin:0;background:transparent}div{position:absolute;top:20px;width:80px;height:80px}#red{left:20px;background:red}#green{left:200px;background:rgba(0,255,0,.5)}#white{left:360px;background:white}</style><div id=red></div><div id=green></div><div id=white></div>"
        let asset = UUID().uuidString, url = directory.appendingPathComponent("owned.html")
        try Data(html.utf8).write(to: url)
        BrowserOverlayAssetResolver.access = { $0 == asset ? ResolvedAssetAccess(url: url, needsSecurityScope: false) : nil }
        defer { BrowserOverlayAssetResolver.access = nil }
        var hosts: [BrowserOverlayHost] = [], payloads: [WebSourcePayload] = []
        for index in 0..<8 {
            var config = BrowserOverlayConfiguration(targetFPS: 15, pixelWidth: 1920, pixelHeight: 1080)
            config.localHTMLAssetIdentifier = asset; config.cssOverrides = ":root{--owned-host:\(index)}"
            let payload = WebSourcePayload(configuration: config), key = payload.browserOverlayStoreKey!
            let host = BrowserOverlayHost(configuration: config, storeKey: key)
            hosts.append(host); payloads.append(payload); host.start()
        }
        do {
            try await wait("All eight actual legacy hosts must produce fresh public PDF frames") {
                hosts.allSatisfy { $0.metrics.succeeded >= 10 && BrowserOverlayFrameStore.shared.latest(for: $0.storeKey) != nil }
            }
        } catch {
            for host in hosts { print("Legacy host failure: state=\(host.loadState) occluded=\(host.isOccluded) metrics=\(host.metrics)") }
            throw error
        }
        for host in hosts {
            let raw = BrowserOverlayFrameStore.shared.latest(for: host.storeKey)!
            require(pixel(raw, 470, 260) == [0, 0, 0, 0] && pixel(raw, 240, 40) == [0, 128, 0, 128], "Actual legacy host lost PDF alpha")
        }
        let initial = hosts.map { $0.metrics.succeeded }
        try await Task.sleep(for: .seconds(2))
        require(zip(hosts, initial).allSatisfy { $0.0.metrics.succeeded > $0.1 + 10 }, "A later actual host starved under sustained eight-host demand")
        print("PASS eight actual legacy hosts sustain fresh alpha frames: totals=\(hosts.map { $0.metrics.succeeded }), twoSecondDeltas=\(zip(hosts, initial).map { $0.0.metrics.succeeded - $0.1 })")
        let retained = hosts[0]
        for host in hosts.dropFirst() { host.stop() }
        hosts = [retained]; payloads = [payloads[0]]
        let mixer = AudioMixEngine(), driver = NoCapture()
        let helper = BrowserWidgetHelperSession(applicationURL: directory.appendingPathComponent("../browser-audio-helper/StreamBrowserAudioHelper.app"), mixer: mixer, validationAudioDriver: driver, ipcPolicy: .prototypeForQualification)
        let config = BrowserOverlayConfiguration(urlString: "https://owned-fixture.invalid", targetFPS: 15, pixelWidth: 480, pixelHeight: 270, audioRoute: .helperApp)
        let payload = WebSourcePayload(configuration: config)
        let helperHost = BrowserOverlayHost(configuration: config, storeKey: payload.browserOverlayStoreKey!, helperSessionForQualification: helper, helperHTMLForQualification: html)
        helperHost.start(); hosts.append(helperHost); payloads.append(payload)
        try await wait("Actual helper IPC PDF frame") { helperHost.metrics.succeeded >= 3 }
        for (index, payload) in [payloads[0], payloads.last!].enumerated() {
            let canvas = CGSize(width: payload.browserOverlay.pixelWidth, height: payload.browserOverlay.pixelHeight)
            let frames = Frames(), engine = CompositionEngine(screenProvider: { nil }, cameraProvider: { nil },
                sourcePayloadProvider: { [:] }, overlayContextProvider: { .empty }, sceneRegistryProvider: { [:] },
                transitionRequestProvider: { nil }, annotationProvider: { .empty }, canvasSize: canvas, frameRate: 15)
            let output = directory.appendingPathComponent("program-\(index)-\(UUID()).mp4")
            var settings = ProgramRecordingSession.Configuration(); settings.requiresAudio = false; settings.frameRate = 15
            let writer = ProgramRecordingSession(outputURL: output, configuration: settings, spaceProbe: { _ in 8_000_000_000 })
            let token = UUID()
            await engine.addSink(token: token, capacity: 4) { frame in frames.append(frame); writer.appendVideo(frame.sampleBuffer) }
            let baseline = Scene(name: "Owned magenta", layers: [], background: .solid(colorHex: "#FF00FF"))
            await engine.run(scene: baseline, canvasSize: canvas, frameRate: 15)
            try await wait("Actual Program baseline") { frames.snapshot.count >= 8 }
            let background = frames.snapshot.last!.corner
            require(background[0] > 180 && background[2] > 180 && background[1] < 90, "Actual baseline is not magenta")
            var scene = baseline; scene.layers = [.init(name: "Owned PDF widget", payload: .web(payload), transform: .fullscreen)]
            await engine.updateScene(scene)
            try await wait("Actual Program widget preserves magenta and foreground") {
                frames.snapshot.contains { $0.corner == background && $0.red[2] > 220 && $0.red[0] < 30
                    && zip($0.green, [127,128,127,255]).allSatisfy { abs($0 - $1) <= 2 }
                    && $0.white.prefix(3).allSatisfy { $0 > 240 } }
            }
            try await Task.sleep(for: .seconds(1))
            await engine.stop(); await engine.removeSink(token)
            let result = await withCheckedContinuation { continuation in writer.finish { continuation.resume(returning: $0) } }
            require(result.completed, "Actual Program writer failed: \(result.error ?? "unknown")")
            let asset = AVURLAsset(url: output), tracks = try await asset.loadTracks(withMediaType: .video)
            require(tracks.count == 1, "Actual Program recording lost video")
            let reader = try AVAssetReader(asset: asset), stream = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            reader.add(stream); require(reader.startReading(), "Actual Program decoder did not start")
            var first: [Int]?, last: [Int]?, count = 0, redFrames = 0
            while let sample = stream.copyNextSampleBuffer(), let image = sample.imageBuffer {
                let corner = pixel(image, 470, 260); if first == nil { first = corner }; last = corner; count += 1
                if pixel(image, 40, 40)[2] > 180 && pixel(image, 40, 40)[0] < 60 { redFrames += 1 }
            }
            require(reader.status == .completed && count >= 20 && redFrames > 5, "Actual Program recording lost widget composition")
            require(zip(first!, last!).allSatisfy { abs($0 - $1) < 12 }, "Transparent Program corner changed relative to same-codec magenta baseline")
            print("PASS \(index == 0 ? "legacy" : "helper") actual host→Program Composer→shipping writer→native H264 decode: \(count)frames/\(redFrames)red, rawMagenta=\(background), decodedBefore=\(first!),after=\(last!), file=\(output.path)")
        }
        for host in hosts { host.stop() }; await helper.waitUntilStopped()
        require(!BrowserWidgetAudioIdentity.productionRouteQualified && !driver.isCapturing, "Independent audio route must remain disabled")
        print("PASS actual legacy/helper PDF alpha, bounded eight-host freshness and Program composition/recording; synthetic silent HTML only, no capture permissions or audio activation")
    }
}
