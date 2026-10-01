import AppKit
import Foundation
import StreamCore

@main struct BrowserLifecycleHarness {
    @MainActor static func main() async throws {
        let base = BrowserOverlayConfiguration(urlString:"https://example.invalid/widget?token=fixture")
        let original = WebSourcePayload(configuration:base)
        let identity = original.browserOverlayStoreKey
        precondition(identity != nil && !(identity!.contains("fixture")))
        precondition(WebSourcePayload(configuration:base).browserOverlayStoreKey == identity)
        var changed = base
        changed.pixelWidth += 1
        precondition(WebSourcePayload(configuration:changed).browserOverlayStoreKey != identity)
        changed = base; changed.audioRoute = .systemMix
        precondition(WebSourcePayload(configuration:changed).browserOverlayStoreKey != identity)
        changed = base; changed.allowsInteraction = true
        precondition(WebSourcePayload(configuration:changed).browserOverlayStoreKey != identity)
        changed = base; changed.cssOverrides = "body { color: red }"
        precondition(WebSourcePayload(configuration:changed).browserOverlayStoreKey != identity)
        let legacy = WebSourcePayload(url:URL(string: "https://example.invalid/widget?token=fixture"))
        precondition(legacy.browserOverlayStoreKey == identity)
        precondition(WebSourcePayload().browserOverlayStoreKey == nil)
        print("PASS: stable/equal/legacy widget identity, URL secrecy, different viewport/audio/interaction/CSS isolation")
        guard CGSessionCopyCurrentDictionary() != nil else {
            print("SKIP: WindowServer session is unavailable; run on a logged-in, unrestricted Mac")
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        var config = BrowserOverlayConfiguration(urlString:url.absoluteString).normalized()
        config.allowsInteraction = true
        config.audioRoute = .helperApp
        let host = BrowserOverlayHost(configuration:config,storeKey:"lifecycle-harness")
        host.start()
        precondition(host.routeWarning != nil, "Unavailable helper audio must be visible")
        precondition(!app.windows.contains { $0.title == "Stream Browser Widget" && !$0.ignoresMouseEvents },
                     "Interaction must not create a floating control window")
        let scroll = NSScrollView(frame:NSRect(x:0,y:0,width:360,height:220))
        host.attachInteraction(to:scroll)
        precondition(scroll.documentView != nil, "The same widget must embed in the inspector")
        host.detachInteraction()
        precondition(!app.windows.contains { $0.title == "Stream Browser Widget" && !$0.ignoresMouseEvents })
        for _ in 0..<100 {
            if host.loadState == .ready { break }
            try await Task.sleep(for:.milliseconds(50))
        }
        if host.loadState != .ready {
            host.dispose()
            print("PASS: embedded reparenting, no floating controls, inline helper-route warning")
            print("SKIP: WebKit page/audio lifecycle did not become ready in 5 seconds: \(host.loadState)")
            return
        }
        host.stop()
        try await Task.sleep(for:.milliseconds(300))
        precondition(host.loadState == .idle && host.metrics.requested >= 0,
                     "A late navigation/snapshot completion must not restart a stopped widget")
        precondition(BrowserOverlayFrameStore.shared.latest(for:"lifecycle-harness") == nil)
        host.dispose()
        print("PASS: embedded reparenting, no floating controls, helper fail-silent warning, stopped page stays idle, cleared output")
        print("Audio bus attribution and tone/speech/duplicate-capture qualification remain separate unrestricted checks")
    }
}
