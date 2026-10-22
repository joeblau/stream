import AppKit
import SwiftUI

@MainActor private final class OwnedFocusWindow {
    let window: NSWindow
    let first: NSTextField, second: NSTextField, fallback: NSTextField
    init(_ name: String) {
        window = NSWindow(contentRect: NSRect(x: 90, y: 90, width: 420, height: 180),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Owned focus restoration \(name)"; window.isReleasedWhenClosed = false
        first = NSTextField(string: "Owned first control")
        second = NSTextField(string: "Owned second control")
        fallback = NSTextField(string: "Owned fallback control")
        for (index, field) in [first, second, fallback].enumerated() {
            field.frame = NSRect(x: 16, y: 20 + index * 40, width: 380, height: 24)
            window.contentView!.addSubview(field)
        }
        window.orderFront(nil)
    }
    func focus(_ field: NSTextField) throws {
        guard window.makeFirstResponder(field), owns(field) else { throw Failure("Actual native field did not receive its shared field editor") }
    }
    func owns(_ field: NSTextField) -> Bool {
        let responder = window.firstResponder
        return responder === field || ((responder as? NSTextView)?.delegate as? NSTextField) === field
    }
    func close() { window.orderOut(nil); window.close() }
}
private struct Failure: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

@main @MainActor struct FocusRestorationHarness {
    static let expectStale = CommandLine.arguments.contains("--reproduce-stale")
    static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(message) }
    }
    static func drain() async throws { try await Task.sleep(for: .milliseconds(25)) }
    static func stale(_ occurred: Bool, _ description: String) throws {
        try require(occurred == expectStale, expectStale ? "Did not reproduce baseline stale focus: \(description)" : "Stale focus restoration escaped ownership: \(description)")
        print("\(expectStale ? "REPRODUCED BASELINE DEFECT" : "PASS cancelled stale restoration"): \(description)")
    }
    static func main() {
        setbuf(stdout, nil)
        guard CGSessionCopyCurrentDictionary() != nil else { print("UNQUALIFIED: owned native controls need a WindowServer session"); exit(77) }
        let app = NSApplication.shared; app.setActivationPolicy(.accessory); app.finishLaunching()
        Task { @MainActor in
            do { try await run(); exit(0) }
            catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
        }
        app.run()
    }
    static func run() async throws {
        print("SCOPE: real mounted NSTextFields/shared native field editors and actual production StudioFocusRestoration source; no virtual AX tree, global input, app activation, capture, DSP or permissions")
        do {
            let host = OwnedFocusWindow("positive"); defer { host.close() }
            let focus = StudioFocusRestoration(); focus.attach(host.window)
            try host.focus(host.first); focus.remember("settings")
            try require((host.window.firstResponder as? NSTextView)?.isFieldEditor == true,
                "Owned text field did not start its actual shared native field editor")
            try host.focus(host.second); var fallbacks = 0
            focus.restore("settings", fallback: { fallbacks += 1 })
            try await drain()
            try require(host.owns(host.first) && fallbacks == 0, "A current restoration failed to return to the exact native owner")
            // Repeated remember within one presentation keeps its first owner.
            focus.remember("settings"); try host.focus(host.second); focus.remember("settings")
            focus.restore("settings"); try await drain()
            try require(host.owns(host.first), "Repeated remember replaced the original presentation's bookmark")
            focus.remember("settings"); try host.focus(host.second)
            focus.restore("settings"); focus.attach(host.window); try await drain()
            try require(host.owns(host.first), "Routine same-window attachment update cancelled a current restoration")
            print("PASS positive: shared field-editor owner restores; repeated remember and same-window updates are idempotent")
        }
        do {
            let host = OwnedFocusWindow("removed"); defer { host.close() }
            let focus = StudioFocusRestoration(); focus.attach(host.window)
            try host.focus(host.first); focus.remember("panel")
            try host.focus(host.second); host.first.removeFromSuperview(); var fallbacks = 0
            focus.restore("panel", fallback: { fallbacks += 1; _ = host.window.makeFirstResponder(host.fallback) })
            try await drain()
            try require(fallbacks == 1 && host.owns(host.fallback), "A removed target failed to invoke its current fallback exactly once")
            print("PASS positive: removed native target uses its owned live fallback once")
        }
        do {
            let host = OwnedFocusWindow("nested presentations"); defer { host.close() }
            let focus = StudioFocusRestoration(); focus.attach(host.window)
            try host.focus(host.first); focus.remember("settings")
            try host.focus(host.second); focus.remember("native-sheet")
            try host.focus(host.fallback); focus.restore("native-sheet"); try await drain()
            try require(host.owns(host.second), "Nested child presentation did not restore its native owner")
            try host.focus(host.fallback); focus.restore("settings"); try await drain()
            try require(host.owns(host.first), "Parent presentation could not restore after child completion")
            print("PASS positive: nested child and later parent presentations retain their own native bookmarks")
        }
        do {
            let host = OwnedFocusWindow("actual attached sheet"); defer { host.close() }
            let focus = StudioFocusRestoration()
            let attachment = NSHostingView(rootView: StudioFocusAttachment(coordinator: focus))
            attachment.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
            host.window.contentView!.addSubview(attachment)
            try await drain()
            try host.focus(host.first); focus.remember("controller-sheet")
            let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
                styleMask: [.titled], backing: .buffered, defer: false)
            sheet.isReleasedWhenClosed = false
            let field = NSTextField(string: "Owned attached-sheet editor")
            field.frame = NSRect(x: 16, y: 25, width: 260, height: 24); sheet.contentView!.addSubview(field)
            host.window.beginSheet(sheet, completionHandler: { _ in })
            try require(sheet.makeFirstResponder(field), "Owned attached sheet refused native focus")
            host.window.endSheet(sheet); sheet.orderOut(nil); focus.restore("controller-sheet")
            try await Task.sleep(for: .milliseconds(500))
            try require(host.window.attachedSheet == nil && host.owns(host.first),
                "Production attachment/native notifications plus controller dismissal lost original field focus")
            sheet.close()
            print("PASS positive: mounted production attachment and real native sheet notifications compose with controller dismissal")
        }
        for replacement in ["settings", "panel-change"] {
            let host = OwnedFocusWindow("presentation \(replacement)"); defer { host.close() }
            let focus = StudioFocusRestoration(); focus.attach(host.window)
            try host.focus(host.first); focus.remember("settings")
            focus.restore("settings")
            try host.focus(host.second); focus.remember(replacement)
            try await drain()
            try stale(host.owns(host.first), "new \(replacement) presentation before queued settings completion")
            if !expectStale {
                try require(host.owns(host.second), "Cancelled restoration lost the replacement native owner")
                try host.focus(host.fallback); focus.restore(replacement); try await drain()
                try require(host.owns(host.second), "Replacement presentation could not restore its own saved owner")
            }
        }
        do {
            let old = OwnedFocusWindow("old attachment"), new = OwnedFocusWindow("replacement attachment")
            defer { old.close(); new.close() }
            let focus = StudioFocusRestoration(); focus.attach(old.window)
            try old.focus(old.first); focus.remember("panel"); var fallbacks = 0
            focus.restore("panel", fallback: { fallbacks += 1; _ = new.window.makeFirstResponder(new.fallback) })
            focus.attach(new.window); try new.focus(new.second)
            try await drain()
            try stale(fallbacks == 1 && new.owns(new.fallback), "replacement window must reject old fallback")
            if !expectStale { try require(fallbacks == 0 && new.owns(new.second), "Replacement window lost its independent native owner") }
        }
        do {
            let host = OwnedFocusWindow("detach and reattach"); defer { host.close() }
            let focus = StudioFocusRestoration(); focus.attach(host.window)
            try host.focus(host.first); focus.remember("settings"); focus.restore("settings")
            focus.attach(nil); focus.attach(host.window); try host.focus(host.second)
            try await drain()
            try stale(host.owns(host.first), "detach then reattach same native window before callback")
            if !expectStale { try require(host.owns(host.second), "Reattached window lost its independent native owner") }
        }
        do {
            let old = OwnedFocusWindow("moved bookmark old"), new = OwnedFocusWindow("moved bookmark new")
            defer { old.close(); new.close() }
            let focus = StudioFocusRestoration(); focus.attach(old.window)
            try old.focus(old.first); focus.remember("settings"); focus.restore("settings")
            old.first.removeFromSuperview(); new.window.contentView!.addSubview(old.first)
            focus.attach(new.window); try new.focus(new.second)
            try await drain()
            try stale(new.owns(old.first), "old native control moved into replacement window must not regain ownership")
            if !expectStale { try require(new.owns(new.second), "Moved control stole replacement window focus") }
        }
        do {
            let host = OwnedFocusWindow("unremembered scope"); defer { host.close() }
            let focus = StudioFocusRestoration(); focus.attach(host.window)
            try host.focus(host.second); var fallbacks = 0
            focus.restore("never-remembered", fallback: { fallbacks += 1; _ = host.window.makeFirstResponder(host.fallback) })
            try await drain()
            try stale(fallbacks == 1 && host.owns(host.fallback), "scope without a matching bookmark must not execute fallback")
        }
        print(expectStale ? "BASELINE REPRODUCTION COMPLETE: six actual stale native focus outcomes confirmed" : "PASS: current restoration plus replacement, cross-window, detach/reattach, moved-control and missing-scope ownership checks")
    }
}
