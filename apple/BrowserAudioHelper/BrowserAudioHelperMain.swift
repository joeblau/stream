import AppKit
import AVFoundation
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
    private struct Widget { var view: WKWebView; var window: NSWindow; var command: BrowserWidgetAudioCommand }
    private var widgets: [UUID: Widget] = [:]
    private var nativeTone: AVAudioEngine?
    private var nativeWindow: NSWindow?
    private var commandHandle = FileHandle.standardInput
    private var replyHandle = FileHandle.standardOutput
    private let reader = DispatchQueue(label: "com.joeblau.browser-helper.commands")

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let index = CommandLine.arguments.firstIndex(of: "--ipc-socket"), CommandLine.arguments.indices.contains(index + 1) {
            guard let handle = try? BrowserWidgetAudioSocket.connect(path: CommandLine.arguments[index + 1]) else { NSApplication.shared.terminate(nil); return }
            commandHandle = handle; replyHandle = handle
        }
        reply(.ready)
        if let index = CommandLine.arguments.firstIndex(of: "--native-tone"),
           CommandLine.arguments.indices.contains(index + 1),
           let frequency = Double(CommandLine.arguments[index + 1]), (100...3_000).contains(frequency) {
            playNativeTone(frequency)
        }
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
            let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 270), configuration: config)
            view.navigationDelegate = self
            let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Stream Browser Audio Qualification"
            window.contentView = view
            window.isReleasedWhenClosed = false
            window.orderFrontRegardless()
            widgets[id] = Widget(view: view, window: window, command: command)
            if let html = command.html { view.loadHTMLString(html, baseURL: nil) }
            else if let url = command.url { view.load(URLRequest(url: url)) }
        case .reload:
            guard let widget = widgets[id] else { missing(id); return }
            receive(widget.command)
        case .suspend:
            guard let widget = widgets[id] else { missing(id); return }
            widget.view.setAllMediaPlaybackSuspended(true) { [weak self] in self?.reply(.suspended, id: id) }
        case .resume:
            guard let widget = widgets[id] else { missing(id); return }
            widget.view.setAllMediaPlaybackSuspended(false) { [weak self] in self?.reply(.loaded, id: id) }
        case .stop:
            stop(id); reply(.stopped, id: id)
        case .probe:
            guard let widget = widgets[id] else { missing(id); return }
            widget.view.evaluateJavaScript("String(window.__widgetAudioState || 'unknown')") { [weak self] value, _ in
                let allowed = ["running", "suspended", "closed", "unknown"]
                let state = value as? String ?? "unknown"
                self?.reply(.probe, id: id, mediaState: allowed.contains(state) ? state : "unknown")
            }
        case .close: break
        }
    }
    private func missing(_ id: UUID) { reply(.failed, id: id, failure: "widget_missing") }
    private func stop(_ id: UUID) {
        guard let widget = widgets.removeValue(forKey: id) else { return }
        widget.view.setAllMediaPlaybackSuspended(true)
        widget.view.stopLoading(); widget.view.loadHTMLString("", baseURL: nil)
        widget.window.close()
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let id = widgets.first(where: { $0.value.view === webView })?.key { reply(.loaded, id: id) }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { failed(webView) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { failed(webView) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { failed(webView) }
    private func failed(_ view: WKWebView) {
        if let id = widgets.first(where: { $0.value.view === view })?.key {
            stop(id); reply(.failed, id: id, failure: "widget_failed")
        }
    }
    private func reply(_ state: BrowserWidgetAudioReply.State, id: UUID? = nil, mediaState: String? = nil, failure: String? = nil) {
        let response = BrowserWidgetAudioReply(state: state, widgetID: id, mediaState: mediaState,
                                              failure: failure, helperPID: ProcessInfo.processInfo.processIdentifier)
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
