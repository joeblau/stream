import AppKit
import AVFoundation
import CoreImage
import CoreMedia
import ScreenCaptureKit
import StreamCore

extension BrowserAudioHelperHarness {
    @MainActor static func visualChecks(build: URL, artifacts: URL) async throws {
        print("Visual qualification: one helper page for pixels, input and WebAudio"); fflush(nil)
        let noise = try await HelperProcess.launch(applicationURL: build.appendingPathComponent("StreamBrowserAudioNoiseFixture.app"), arguments: ["--native-tone", "1320"])
        defer { noise.close() }
        try await wait { noise.has(.ready) }
        let unrelated = AudioTrace(), raw = AudioTrace(), program = AudioTrace()
        let noiseCapture = AppAudioCapture()
        noiseCapture.onAudioSampleOffMain = { unrelated.append($0) }
        // LaunchServices readiness precedes SCK's window/app directory publication. Wait for
        // the exact fixture PID rather than racing discovery or selecting a different target.
        var noiseDiscovered = false
        for _ in 0..<80 {
            let content = try await SCShareableContent.current
            if content.applications.contains(where: { $0.processID == noise.pid && $0.bundleIdentifier == "com.joeblau.StreamBrowserAudioNoiseFixture" }) {
                noiseDiscovered = true; break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        precondition(noiseDiscovered, "The exact independent fixture must appear in the public SCK directory")
        await noiseCapture.start(with: .init(bundleID: "com.joeblau.StreamBrowserAudioNoiseFixture", appName: "Named noise fixture"))
        guard noiseCapture.isCapturing else {
            await noiseCapture.stop()
            print("GATED / UNQUALIFIED: named independent-app capture unavailable: \(noiseCapture.errorMessage ?? "unavailable"). Same-page capture qualification skipped; no substitution.")
            return
        }
        let mixer = AudioMixEngine()
        let channel = AudioChannelID.application(bundleID: BrowserWidgetAudioIdentity.helperBundleID)
        await mixer.setChannelGain(channel, volume: 1, isMuted: false)
        let session = BrowserWidgetHelperSession(applicationURL: build.appendingPathComponent("StreamBrowserAudioHelper.app"), mixer: mixer) {
            raw.append($0); mixer.enqueue(channel, $0)
        }
        let programURL = artifacts.appendingPathComponent("same-page-program.mp4")
        var writerConfig = ProgramRecordingSession.Configuration(); writerConfig.frameRate = 15
        let writer = ProgramRecordingSession(outputURL: programURL, configuration: writerConfig, spaceProbe: { _ in 8_000_000_000 })
        let tap = UUID()
        await mixer.addTap(bus: .program, token: tap) { program.append($0); writer.appendAudio($0) }
        await mixer.run()
        var config = BrowserOverlayConfiguration(urlString: "https://fixture.invalid", targetFPS: 15,
            pixelWidth: 480, pixelHeight: 270, allowsInteraction: true, audioRoute: .helperApp, sceneEntryRefresh: .keepAlive)
        let mainKey = "qualification:main:\(UUID())", siblingKey = "qualification:sibling:\(UUID())"
        let host = BrowserOverlayHost(configuration: config, storeKey: mainKey, helperSessionForQualification: session,
            helperHTMLForQualification: interactiveToneHTML())
        config.allowsInteraction = false
        let sibling = BrowserOverlayHost(configuration: config, storeKey: siblingKey, helperSessionForQualification: session,
            helperHTMLForQualification: toneHTML(frequency: 1_100, pan: 1))
        host.start(); sibling.start()
        try await wait { host.loadState == .ready && sibling.loadState == .ready && host.helperFrameHeader != nil && sibling.helperFrameHeader != nil && session.audioIsCapturing }
        precondition(session.demandCount == 2 && session.helperPID != nil)
        let recording = Task { @MainActor in
            var last: Double?
            while !Task.isCancelled {
                if let header = host.helperFrameHeader, header.completedHostSeconds != last,
                   let pixel = BrowserOverlayFrameStore.shared.latest(for: mainKey),
                   let sample = visualSample(pixel, at: header.completedHostSeconds) {
                    writer.appendVideo(sample); last = header.completedHostSeconds
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        try await Task.sleep(for: .seconds(2.5))
        try await wait { raw.amplitude(440, channel: 0) > 0.001 && raw.amplitude(1_100, channel: 1) > 0.001 && unrelated.amplitude(1_320, channel: 0) > 0.001 }
        precondition(raw.amplitude(1_320, channel: 0) < unrelated.amplitude(1_320, channel: 0) * 0.02)
        print("Visual initial pixel \(visualPixel(mainKey)), transparent \(visualPixel(mainKey, x: 470, y: 260))"); fflush(nil)
        try saveVisual(mainKey, to: artifacts.appendingPathComponent("initial.png"))
        precondition(visualColor(mainKey) == "red", "Actual WK snapshot must show the initial DOM state")
        let backdropAlpha = visualPixel(mainKey, x: 470, y: 260).last!
        print("Transparency qualification: public WK snapshot backdrop alpha=\(backdropAlpha). Opaque results keep transparent overlay support gated.")
        let originalToken = await host.evaluateTrigger("window.__token")
        precondition(originalToken != nil)
        host.noteSceneEntry()
        let keptToken = await host.evaluateTrigger("window.__token")
        precondition(originalToken == keptToken, "Keep Alive scene entry must preserve the actual page")

        // Real inspector NSView -> host -> private IPC -> helper NSWindow -> existing WK page.
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 270))
        let inspector = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        inspector.isReleasedWhenClosed = false; inspector.contentView = scroll
        host.attachInteraction(to: scroll)
        let remote = scroll.documentView as! BrowserWidgetRemoteInteractionView
        let clickPoint = remote.convert(NSPoint(x: 60, y: 60), to: nil)
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: clickPoint, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: inspector.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: clickPoint, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: inspector.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        remote.mouseDown(with: down); remote.mouseUp(with: up)
        print("Visual stage: forwarded click"); fflush(nil)
        try await wait { visualColor(mainKey) == "blue" && raw.amplitude(880, channel: 0) > 0.001 && raw.amplitude(440, channel: 0) < 0.0001 }
        let clickCount = await host.evaluateTrigger("String(window.__clicks)")
        precondition(clickCount == "1", "Actual native click must reach the page exactly once")
        let sameToken = await host.evaluateTrigger("window.__token")
        precondition(sameToken == originalToken, "Input, captured audio and pixels must use the same page instance")
        try saveVisual(mainKey, to: artifacts.appendingPathComponent("clicked.png"))
        let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: inspector.windowNumber, context: nil, characters: "k", charactersIgnoringModifiers: "k", isARepeat: false, keyCode: 40)!
        remote.keyDown(with: key)
        try await Task.sleep(for: .milliseconds(200))
        let keyCount = await host.evaluateTrigger("String(window.__keys)")
        precondition(keyCount == "1", "Native key dispatch must reach the same page")
        let wheelCG = up.cgEvent!.copy()!
        wheelCG.type = .scrollWheel
        wheelCG.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        wheelCG.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: 30)
        wheelCG.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 30)
        let wheel = NSEvent(cgEvent: wheelCG)!
        remote.scrollWheel(with: wheel)
        try await Task.sleep(for: .milliseconds(200))
        let wheelCount = await host.evaluateTrigger("String(window.__wheels)")
        precondition(wheelCount == "1", "Bounded wheel event must reach this widget")
        host.detachInteraction(); inspector.close()

        print("Visual stage: reload and stale generation"); fflush(nil)
        let beforeReload = host.helperFrameHeader!.generation
        let oldHeader = host.helperFrameHeader!
        var reserved = false
        for _ in 0..<20 {
            if session.requestSnapshot(id: oldHeader.widgetID, generation: oldHeader.generation) { reserved = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(reserved && !session.requestSnapshot(id: oldHeader.widgetID, generation: oldHeader.generation),
            "The shared helper frame pull must shed additional requests while one is active")
        host.reload()
        precondition(BrowserOverlayFrameStore.shared.latest(for: mainKey) == nil && host.helperFrameHeader == nil)
        try await wait { host.helperFrameHeader?.generation != nil && host.helperFrameHeader?.generation != beforeReload && visualColor(mainKey) == "red" }
        let replacedToken = await host.evaluateTrigger("window.__token")
        precondition(replacedToken != originalToken && replacedToken != nil)
        try await Task.sleep(for: .seconds(1))
        precondition(raw.amplitude(440, channel: 0) > 0.001 && raw.amplitude(1_100, channel: 1) > 0.001)
        precondition(host.helperFrameHeader?.generation != beforeReload)
        host.stop(); recording.cancel(); await recording.value
        await mixer.removeTap(tap)
        let result = await withCheckedContinuation { continuation in writer.finish { continuation.resume(returning: $0) } }
        precondition(result.completed, result.error ?? "Actual same-page recording failed")
        precondition(BrowserOverlayFrameStore.shared.latest(for: mainKey) == nil)
        try await Task.sleep(for: .seconds(0.8))
        precondition(session.demandCount == 1 && session.audioIsCapturing && sibling.loadState == .ready)
        precondition(raw.amplitude(440, channel: 0) < 0.0001 && raw.amplitude(1_100, channel: 1) > 0.001,
            "Stop must unload only this widget while sibling audio survives")
        precondition(BrowserOverlayFrameStore.shared.latest(for: mainKey) == nil && BrowserOverlayFrameStore.shared.latest(for: siblingKey) != nil)
        sibling.stop(); await session.waitUntilStopped()
        precondition(session.demandCount == 0 && !session.audioIsCapturing && session.helperPID == nil)
        let timing = await mixer.captureTimingSnapshot()
        precondition(timing.holdbackMilliseconds == 5 && timing.leaseCount == 0)
        // Re-demand uses a new LaunchServices instance; its unexpected exit must clear frames,
        // fail visibly and release only the helper capture, without touching the independent app.
        host.start()
        try await wait { host.loadState == .ready && host.helperFrameHeader != nil && session.audioIsCapturing }
        let ownedPID = session.helperPID!
        NSRunningApplication(processIdentifier: ownedPID)?.terminate()
        try await wait { if case .failed = host.loadState { return true }; return false }
        await session.waitUntilStopped()
        precondition(BrowserOverlayFrameStore.shared.latest(for: mainKey) == nil && !session.audioIsCapturing)
        let afterFailureTiming = await mixer.captureTimingSnapshot()
        precondition(afterFailureTiming.leaseCount == 0 && afterFailureTiming.holdbackMilliseconds == 5)
        precondition(unrelated.amplitude(1_320, channel: 0) > 0.001, "Unrelated audio must survive helper lifecycle actions")
        await mixer.stop(); await noiseCapture.stop()
        try await inspectVisualRecording(programURL)
        try raw.export(artifacts.appendingPathComponent("same-page-helper.caf"))
        try program.export(artifacts.appendingPathComponent("same-page-program.caf"))
        try unrelated.export(artifacts.appendingPathComponent("same-page-unrelated.caf"))
        try JSONEncoder().encode(session.statistics).write(to: artifacts.appendingPathComponent("visual-statistics.json"))
        precondition(session.statistics.receivedFrames > 30 && session.statistics.maximumReceivedFrameBytes <= BrowserWidgetVisualTransport.maximumFrameBytes)
        precondition(!BrowserWidgetAudioIdentity.productionRouteQualified)
        host.dispose(); sibling.dispose()
        print("PASS: actual same-page native click/key/wheel, BGRA pixels + isolated WebAudio, shared program recording, keep-alive/reload/stop generation fences, sibling/unrelated isolation and final holdback release. Transparency/signing/production remain gated. Artifacts: \(artifacts.path)")
    }
    private static func interactiveToneHTML() -> String {
        """
        <!DOCTYPE html><meta charset="utf-8"><style>html,body{margin:0;background:transparent}button{position:absolute;left:20px;top:20px;width:160px;height:90px;background:red;border:0;color:white}</style>
        <button id="control">Same page</button><script>
        window.__token=String(Math.random());window.__clicks=0;window.__keys=0;window.__wheels=0;
        const ctx=new AudioContext(),osc=ctx.createOscillator(),gain=ctx.createGain(),pan=ctx.createStereoPanner();
        osc.frequency.value=440;gain.gain.value=.025;pan.pan.value=-1;osc.connect(gain).connect(pan).connect(ctx.destination);osc.start();ctx.resume();
        window.__widgetAudioState=ctx.state;ctx.onstatechange=()=>window.__widgetAudioState=ctx.state;
        document.querySelector('button').onclick=()=>{window.__clicks++;osc.frequency.value=880;document.querySelector('button').style.background='blue'};
        document.onkeydown=()=>window.__keys++;document.onwheel=()=>window.__wheels++;
        </script>
        """
    }
    @MainActor private static func visualPixel(_ key: String, x: Int = 60, y: Int = 60) -> [UInt8] {
        guard let buffer = BrowserOverlayFrameStore.shared.latest(for: key) else { return [] }
        CVPixelBufferLockBaseAddress(buffer, .readOnly); defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let bytes = CVPixelBufferGetBaseAddress(buffer)!.advanced(by: y * CVPixelBufferGetBytesPerRow(buffer) + x * 4).assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: bytes, count: 4))
    }
    @MainActor private static func visualColor(_ key: String) -> String {
        let bytes = visualPixel(key)
        guard bytes.count == 4 else { return "missing" }
        if bytes[2] > 180 && bytes[0] < 50 { return "red" }
        if bytes[0] > 180 && bytes[2] < 50 { return "blue" }
        return "other"
    }
    @MainActor private static func saveVisual(_ key: String, to url: URL) throws {
        let image = CIImage(cvPixelBuffer: BrowserOverlayFrameStore.shared.latest(for: key)!)
        try CIContext().writePNGRepresentation(of: image, to: url, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }
    private static func visualSample(_ pixel: CVPixelBuffer, at time: Double) -> CMSampleBuffer? {
        var format: CMVideoFormatDescription?, sample: CMSampleBuffer?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixel, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 15),
            presentationTimeStamp: CMTime(seconds: time, preferredTimescale: 48_000), decodeTimeStamp: .invalid)
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixel, formatDescription: format!, sampleTiming: &timing, sampleBufferOut: &sample)
        return sample
    }
    static func inspectVisualRecording(_ url: URL) async throws {
        let asset = AVURLAsset(url: url)
        let reader = try AVAssetReader(asset: asset)
        let video = try await asset.loadTracks(withMediaType: .video), audio = try await asset.loadTracks(withMediaType: .audio)
        precondition(video.count == 1 && audio.count == 1)
        let visual = AVAssetReaderTrackOutput(track: video[0], outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        let sound = AVAssetReaderTrackOutput(track: audio[0], outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false])
        reader.add(visual); reader.add(sound); precondition(reader.startReading())
        var firstBlue: Double?, first880: Double?, redFrames = 0, blueFrames = 0
        while let sample = visual.copyNextSampleBuffer() {
            let pixel = sample.imageBuffer!
            CVPixelBufferLockBaseAddress(pixel, .readOnly)
            let bytes = CVPixelBufferGetBaseAddress(pixel)!.advanced(by: 60 * CVPixelBufferGetBytesPerRow(pixel) + 60 * 4).assumingMemoryBound(to: UInt8.self)
            if bytes[0] > 180 && bytes[2] < 50 { blueFrames += 1; firstBlue = firstBlue ?? sample.presentationTimeStamp.seconds }
            if bytes[2] > 180 && bytes[0] < 50 { redFrames += 1 }
            CVPixelBufferUnlockBaseAddress(pixel, .readOnly)
        }
        while let sample = sound.copyNextSampleBuffer() {
            guard let block = sample.dataBuffer else { continue }
            let count = CMBlockBufferGetDataLength(block) / 4
            var values = [Float](repeating: 0, count: count)
            values.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * 4, destination: $0.baseAddress!) }
            func amplitude(_ frequency: Double) -> Double {
                var real = 0.0, imaginary = 0.0
                for n in 0..<(count / 2) { let phase = Double(n) * 2 * .pi * frequency / 48_000; real += Double(values[n * 2]) * cos(phase); imaginary += Double(values[n * 2]) * sin(phase) }
                return hypot(real, imaginary) / Double(max(1, count / 2))
            }
            if amplitude(880) > 0.001 && amplitude(880) > amplitude(440) * 3 { first880 = first880 ?? sample.presentationTimeStamp.seconds }
        }
        precondition(reader.status == .completed && redFrames > 15 && blueFrames > 3 && firstBlue != nil && first880 != nil)
        print("Decoded same-page transition: blue at \(firstBlue!), 880 Hz at \(first880!), delta \(firstBlue! - first880!) seconds"); fflush(nil)
        precondition(abs(firstBlue! - first880!) < 0.18, "Local actual snapshot/tone transition exceeds measured A/V envelope")
    }
}
