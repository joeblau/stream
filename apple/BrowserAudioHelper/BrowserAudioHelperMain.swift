import AppKit
import AVFoundation
import CoreMedia
import WebKit

@main struct BrowserAudioHelperMain {
    @MainActor static func main() {
        signal(SIGPIPE, SIG_IGN)
        guard CGSessionCopyCurrentDictionary() != nil else { return }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = BrowserAudioHelperDelegate()
        app.delegate = delegate
        app.run()
    }
}

/// Qualification helper: one bundle owns up to eight pages and one shared audio identity.
/// It never changes output devices, captures system audio, or drives another app's media.
@MainActor private final class BrowserAudioHelperDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    private struct Widget {
        var view: WKWebView; var window: NSWindow; var command: BrowserWidgetAudioCommand
        var generation: UUID; var ready = false; var navigationTimeout: Timer?
    }
    private var widgets: [UUID: Widget] = [:]
    private var nativeTone: AVAudioEngine?
    private var nativeWindow: NSWindow?
    private var commandHandle = FileHandle.standardInput
    private var replyHandle = FileHandle.standardOutput
    private let reader = DispatchQueue(label: "com.joeblau.browser-helper.commands")
    private var frameWriter: BrowserWidgetFrameWriter?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let index = CommandLine.arguments.firstIndex(of: "--ipc-socket"), CommandLine.arguments.indices.contains(index + 1) {
            guard let handle = try? BrowserWidgetAudioSocket.connect(path: CommandLine.arguments[index + 1]) else { NSApplication.shared.terminate(nil); return }
            commandHandle = handle; replyHandle = handle
        }
        if let index = CommandLine.arguments.firstIndex(of: "--frame-socket"), CommandLine.arguments.indices.contains(index + 1) {
            guard let handle = try? BrowserWidgetAudioSocket.connect(path: CommandLine.arguments[index + 1]) else { NSApplication.shared.terminate(nil); return }
            frameWriter = BrowserWidgetFrameWriter(handle: handle)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--native-tone"),
           CommandLine.arguments.indices.contains(index + 1),
           let frequency = Double(CommandLine.arguments[index + 1]), (100...3_000).contains(frequency) {
            playNativeTone(frequency)
        }
        reply(.ready)
        let inputDescriptor = commandHandle.fileDescriptor
        reader.async { [weak self] in
            var bytes = Data()
            var chunk = [UInt8](repeating: 0, count: 4_096)
            while true {
                let count = Darwin.read(inputDescriptor, &chunk, chunk.count)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { break }
                bytes.append(contentsOf: chunk.prefix(count))
                guard bytes.count <= BrowserWidgetAudioCommand.maximumLineBytes else { break }
                while let end = bytes.firstIndex(of: 10) {
                    let line = Data(bytes[..<end]); bytes.removeSubrange(...end)
                    let command = try? JSONDecoder().decode(BrowserWidgetAudioCommand.self, from: line)
                    let done = DispatchSemaphore(value: 0)
                    DispatchQueue.main.async { [weak self] in
                        if let command { self?.receive(command) } else { self?.reply(.failed, failure: "invalid_command") }
                        done.signal()
                    }
                    done.wait()
                }
            }
            DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
        }
    }
    private func receive(_ command: BrowserWidgetAudioCommand) {
        do { try command.validate() } catch { reply(.failed, id: command.widgetID, failure: "invalid_command"); return }
        guard command.action != .close else { NSApplication.shared.terminate(nil); return }
        guard let id = command.widgetID else { return }
        switch command.action {
        case .load:
            guard widgets[id] != nil || widgets.count < BrowserWidgetAudioCommand.maximumWidgets else {
                reply(.failed, id: id, failure: "widget_limit"); return
            }
            stop(id)
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            config.mediaTypesRequiringUserActionForPlayback = []
            let options = command.options ?? BrowserWidgetPageOptions()
            if !options.css.isEmpty, let data = try? JSONEncoder().encode(options.css), let literal = String(data: data, encoding: .utf8) {
                let source = "var s=document.createElement('style');s.textContent=\(literal);(document.head||document.documentElement).appendChild(s);"
                config.userContentController.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
            }
            let view = WKWebView(frame: NSRect(x: 0, y: 0, width: options.width, height: options.height), configuration: config)
            view.underPageBackgroundColor = .clear
            view.navigationDelegate = self
            let window = NSWindow(contentRect: view.frame, styleMask: options.hidden ? [.borderless] : [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Stream Browser Widget Helper"
            window.contentView = view
            window.isReleasedWhenClosed = false
            window.acceptsMouseMovedEvents = true
            window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = false
            if options.hidden {
                window.alphaValue = 0.01; window.ignoresMouseEvents = true
                window.level = .statusBar; window.collectionBehavior = [.canJoinAllSpaces, .stationary]
            }
            window.orderFrontRegardless()
            let generation = command.generation ?? UUID()
            let timeout = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.widgets[id]?.generation == generation, self.widgets[id]?.ready == false else { return }
                    self.stop(id); self.reply(.failed, id: id, failure: "navigation_timeout", generation: generation)
                }
            }
            widgets[id] = Widget(view: view, window: window, command: command, generation: generation, navigationTimeout: timeout)
            if let html = command.html { view.loadHTMLString(html, baseURL: nil) }
            else if let url = command.url { view.load(URLRequest(url: url)) }
        case .reload:
            guard let widget = widgets[id] else { missing(id); return }
            var replacement = widget.command; replacement.generation = command.generation ?? widget.generation
            receive(replacement)
        case .suspend:
            guard let widget = widgets[id] else { missing(id); return }
            widget.view.setAllMediaPlaybackSuspended(true) { [weak self] in
                guard self?.widgets[id]?.view === widget.view else { return }
                self?.reply(.suspended, id: id, generation: widget.generation)
            }
        case .resume:
            guard let widget = widgets[id] else { missing(id); return }
            widget.view.setAllMediaPlaybackSuspended(false) { [weak self] in
                guard self?.widgets[id]?.view === widget.view else { return }
                self?.reply(.loaded, id: id, generation: widget.generation)
            }
        case .stop:
            stop(id); reply(.stopped, id: id)
        case .probe:
            guard let widget = widgets[id] else { missing(id); return }
            widget.view.evaluateJavaScript("String(window.__widgetAudioState || 'unknown')") { [weak self] value, _ in
                let allowed = ["running", "suspended", "closed", "unknown"]
                let state = value as? String ?? "unknown"
                self?.reply(.probe, id: id, mediaState: allowed.contains(state) ? state : "unknown")
            }
        case .snapshot: snapshot(command, id: id)
        case .interact:
            guard let widget = widgets[id], widget.ready,
                  widget.command.options?.allowsInteraction == true, let interaction = command.interaction,
                  command.generation == widget.generation else { reply(.failed, id: id, failure: "interaction_unavailable", request: command.requestID); return }
            interact(interaction, widget: widget)
        case .evaluate:
            guard let widget = widgets[id], widget.ready, command.generation == widget.generation,
                  let expression = command.expression else { reply(.failed, id: id, failure: "widget_missing", request: command.requestID); return }
            widget.view.evaluateJavaScript(expression) { [weak self] value, error in
                guard self?.widgets[id]?.view === widget.view else { return }
                let result = (value as? String) ?? value.map { String(describing: $0) }
                guard error == nil, (result?.utf8.count ?? 0) <= 4_096 else {
                    self?.reply(.failed, id: id, failure: "trigger_failed", request: command.requestID); return
                }
                self?.reply(.evaluated, id: id, request: command.requestID, result: result, generation: widget.generation)
            }
        case .close: break
        }
    }
    private func missing(_ id: UUID) { reply(.failed, id: id, failure: "widget_missing") }
    private func stop(_ id: UUID) {
        guard let widget = widgets.removeValue(forKey: id) else { return }
        widget.navigationTimeout?.invalidate()
        widget.view.setAllMediaPlaybackSuspended(true)
        widget.view.stopLoading(); widget.view.loadHTMLString("", baseURL: nil)
        widget.window.close()
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let id = widgets.first(where: { $0.value.view === webView })?.key {
            widgets[id]?.ready = true; widgets[id]?.navigationTimeout?.invalidate()
            reply(.loaded, id: id, generation: widgets[id]?.generation)
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard action.targetFrame != nil else { decisionHandler(.cancel); return }
        if action.targetFrame?.isMainFrame == true, let url = action.request.url,
           url.absoluteString != "about:blank", url.scheme?.lowercased() != "https" {
            decisionHandler(.cancel); failed(webView); return
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { failed(webView) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { failed(webView) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { failed(webView) }
    private func failed(_ view: WKWebView) {
        if let id = widgets.first(where: { $0.value.view === view })?.key {
            let generation = widgets[id]?.generation
            stop(id); reply(.failed, id: id, failure: "widget_failed", generation: generation)
        }
    }
    private func reply(_ state: BrowserWidgetAudioReply.State, id: UUID? = nil, mediaState: String? = nil, failure: String? = nil,
                       request: UUID? = nil, result: String? = nil, generation: UUID? = nil) {
        let response = BrowserWidgetAudioReply(state: state, widgetID: id, mediaState: mediaState,
                                              failure: failure, helperPID: ProcessInfo.processInfo.processIdentifier,
                                              requestID: request, result: result, generation: generation)
        if var data = try? JSONEncoder().encode(response) { data.append(10); try? replyHandle.write(contentsOf: data) }
    }
    private func playNativeTone(_ frequency: Double) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Named Independent Audio Fixture"
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        nativeWindow = window
        let engine = AVAudioEngine()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let source = NativeToneRender.makeNode(format: format, frequency: frequency)
        engine.attach(source); engine.connect(source, to: engine.mainMixerNode, format: format)
        do { try engine.start(); nativeTone = engine } catch { reply(.failed, failure: "native_tone_unavailable") }
    }
    func applicationWillTerminate(_ notification: Notification) {
        for id in Array(widgets.keys) { stop(id) }
        nativeTone?.stop()
        nativeWindow?.close()
    }

    private func snapshot(_ command: BrowserWidgetAudioCommand, id: UUID) {
        guard let widget = widgets[id], widget.ready, command.generation == widget.generation,
              let request = command.requestID, let writer = frameWriter, writer.reserve() else {
            reply(.failed, id: id, failure: "snapshot_unavailable", request: command.requestID); return
        }
        let requested = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        let config = WKSnapshotConfiguration(); config.snapshotWidth = NSNumber(value: widget.view.bounds.width)
        config.afterScreenUpdates = true
        widget.view.takeSnapshot(with: config) { [weak self] image, _ in
            guard let self, self.widgets[id]?.view === widget.view, self.widgets[id]?.generation == command.generation,
                  let cgImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                writer.release(); self?.reply(.failed, id: id, failure: "snapshot_failed", request: request); return
            }
            let width = Int(widget.view.bounds.width), height = Int(widget.view.bounds.height)
            var pixels = Data(count: width * height * 4)
            let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
                guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return false }
                context.clear(CGRect(x: 0, y: 0, width: width, height: height))
                context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height)); return true
            }
            guard drawn else { writer.release(); self.reply(.failed, id: id, failure: "snapshot_failed", request: request); return }
            let header = BrowserWidgetVisualHeader(widgetID: id, generation: widget.generation, requestID: request,
                width: width, height: height, requestedHostSeconds: requested,
                completedHostSeconds: CMClockGetTime(CMClockGetHostTimeClock()).seconds)
            writer.post(header: header, pixels: pixels)
        }
    }

    private func interact(_ input: BrowserWidgetInteraction, widget: Widget) {
        guard input.x <= widget.view.bounds.width, input.y <= widget.view.bounds.height else { return }
        let point = NSPoint(x: input.x, y: widget.view.bounds.height - input.y)
        let flags = NSEvent.ModifierFlags(rawValue: UInt(input.modifiers))
        let now = ProcessInfo.processInfo.systemUptime
        let event: NSEvent?
        switch input.kind {
        case .keyDown, .keyUp:
            widget.window.makeFirstResponder(widget.view)
            event = NSEvent.keyEvent(with: input.kind == .keyDown ? .keyDown : .keyUp, location: point,
                modifierFlags: flags, timestamp: now, windowNumber: widget.window.windowNumber, context: nil,
                characters: input.text, charactersIgnoringModifiers: input.text, isARepeat: false, keyCode: input.keyCode)
        case .scroll:
            // A bare CG wheel event has windowNumber == 0. Start with a local public AppKit
            // mouse event so the converted wheel retains this window's coordinate association.
            guard let mouse = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: flags,
                timestamp: now, windowNumber: widget.window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 0, pressure: 0), let cgEvent = mouse.cgEvent?.copy() else { return }
            // Local event dispatch only. This never posts an event into another process or uses accessibility privileges.
            cgEvent.type = .scrollWheel
            cgEvent.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            cgEvent.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(input.deltaY))
            cgEvent.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(input.deltaX))
            cgEvent.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: input.deltaY)
            cgEvent.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: input.deltaX)
            event = NSEvent(cgEvent: cgEvent)
        default:
            let type: NSEvent.EventType = switch input.kind {
                case .mouseDown: .leftMouseDown
                case .mouseUp: .leftMouseUp
                case .mouseDragged: .leftMouseDragged
                default: .mouseMoved
            }
            event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: now,
                windowNumber: widget.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        if let event {
            if input.kind == .scroll {
                widget.view.scrollWheel(with: event)
            }
            else { widget.window.sendEvent(event) }
        }
    }
}

/// Reservations include both in-flight WK snapshots and serialized socket writes. At most two
/// bounded BGRA frames exist here; a blocked peer cannot accumulate images or stall the main actor.
private final class BrowserWidgetFrameWriter: @unchecked Sendable {
    private let handle: FileHandle, lock = NSLock()
    private let queue = DispatchQueue(label: "com.joeblau.browser-helper.frames", qos: .userInitiated)
    private var pending = 0, failed = false
    init(handle: FileHandle) { self.handle = handle }
    func reserve() -> Bool { lock.withLock { guard !failed, pending < 2 else { return false }; pending += 1; return true } }
    func release() { lock.withLock { pending = max(0, pending - 1) } }
    func post(header: BrowserWidgetVisualHeader, pixels: Data) {
        queue.async { [self] in
            defer { release() }
            do { try BrowserWidgetVisualTransport.write(header: header, pixels: pixels, descriptor: handle.fileDescriptor) }
            catch {
                lock.withLock { failed = true }
                DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
            }
        }
    }
}

/// The AVAudio render block is created outside MainActor isolation and its oscillator state is
/// owned exclusively by this one serialized source-node callback.
private enum NativeToneRender {
    nonisolated static func makeNode(format: AVAudioFormat, frequency: Double) -> AVAudioSourceNode {
        nonisolated(unsafe) var frame: Double = 0
        return AVAudioSourceNode(format: format) { _, _, count, buffers in
            let output = UnsafeMutableAudioBufferListPointer(buffers)
            for n in 0..<Int(count) {
                let sample = Float(sin(frame * 2 * .pi * frequency / 48_000) * 0.025)
                for buffer in output { buffer.mData?.assumingMemoryBound(to: Float.self)[n] = sample }
                frame += 1
            }
            return noErr
        }
    }
}
