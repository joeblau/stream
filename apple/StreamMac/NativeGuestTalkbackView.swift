import AppKit
import SwiftUI

/// Mouse/key holds and bounded accessibility intervals share the exact press
/// token. Release, removal and focus loss stop it; reconnect never replays it.
struct NativeGuestTalkbackView: View {
    @ObservedObject var manager: NativeInterviewManager
    @ObservedObject var dispatcher: StudioCommandDispatcher
    let context: NativeInterviewPeerLease
    @State private var press: UUID?
    private let source = AudioChannelID.microphone(deviceUID: nil)
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            NativeTalkbackHoldButton(active: manager.talkback?.context == context,
                enabled: manager.talkback?.context == context || dispatcher.canExecute(.interview(.beginTalkback(context, source, UUID()))),
                change: { held in
                    if held {
                        // A manager deadline/revocation may have ended the last
                        // press before SwiftUI delivered its next view update.
                        if let press, manager.talkback?.press != press { self.press = nil }
                        guard press == nil else { return false }
                        let token = UUID()
                        guard dispatcher.execute(.interview(.beginTalkback(context, source, token))).error == nil else { return false }
                        press = token
                    } else if !held, let token = press {
                        _ = dispatcher.execute(.interview(.endTalkback(context, token))); press = nil
                    }
                    return true
                }).frame(height: 28)
            Text("Hold to send the already running primary microphone privately to this guest. Its Program, Monitor, Aux and isolated tracks are silent; other sources keep their routes. Private speech bypasses microphone effects. Release or safety cancellation restores its prior routes, so continuing speech may be public. Ends after ten seconds, focus loss or reconnect.")
                .font(.caption).foregroundStyle(.secondary)
            Text("With assistive technology, activate to start a private interval of up to ten seconds; activate again to stop early.")
                .font(.caption).foregroundStyle(.secondary)
        }.onChange(of: manager.talkback?.press) { _, current in
            if let press, current != press { self.press = nil }
        }.onDisappear {
            if let press { _ = dispatcher.execute(.interview(.endTalkback(context, press))) }
            press = nil
        }
    }
}

private struct NativeTalkbackHoldButton: NSViewRepresentable {
    let active: Bool, enabled: Bool
    let change: (Bool) -> Bool
    final class HoldButton: NSButton {
        var change: ((Bool) -> Bool)?
        private var held = false
        private var accessibilityRelease: Timer?
        @discardableResult private func setHeld(_ value: Bool) -> Bool {
            guard held != value else { return true }
            held = value
            if !value { accessibilityRelease?.invalidate(); accessibilityRelease = nil }
            let accepted = change?(value) ?? false
            if value && !accepted { held = false }
            updateAccessibleState()
            return accepted
        }
        private func updateAccessibleState() {
            let action = held ? "Stop private talkback" : "Start private talkback (10 seconds maximum)"
            // AppKit retains the visual button title as AXTitle unless it is
            // explicitly overridden; clients commonly read it before AXLabel.
            setAccessibilityTitle(action)
            setAccessibilityLabel(action)
            setAccessibilityValue(held ? "Private microphone active" : "Inactive")
            setAccessibilityHelp("Activate to start a private microphone interval of up to ten seconds; activate again to stop. Space or mouse holds end on release. Focus loss, removal and connection changes also stop it. Speech after stopping may return to public outputs.")
        }
        /// AX Press has no matching release event. Give it explicit bounded
        /// start/stop semantics, using the same accepted press and cancellation
        /// path as pointer/keyboard holds, never an unbounded latch.
        override func accessibilityPerformPress() -> Bool {
            if held { return setHeld(false) }
            guard isEnabled, setHeld(true) else { return false }
            let timer = Timer(timeInterval: 10, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { _ = self?.setHeld(false) }
            }
            accessibilityRelease = timer
            RunLoop.main.add(timer, forMode: .common)
            return true
        }
        /// Manager state is authoritative after a deadline, revoked lease or
        /// rejected begin. Do not release another owner's press in response to
        /// a view refresh, or keep a stale local accessibility interval alive.
        func reconcile(active: Bool) {
            if !active && held {
                held = false
                accessibilityRelease?.invalidate(); accessibilityRelease = nil
            }
            updateAccessibleState()
        }
        override func mouseDown(with event: NSEvent) {
            guard isEnabled, setHeld(true) else { return }
            defer { setHeld(false) }; super.mouseDown(with: event)
        }
        override func keyDown(with event: NSEvent) {
            guard isEnabled, event.keyCode == 49,
                  event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else {
                super.keyDown(with: event); return
            }
            if !event.isARepeat { setHeld(true) }
        }
        override func keyUp(with event: NSEvent) {
            if event.keyCode == 49 { setHeld(false) } else { super.keyUp(with: event) }
        }
        override func resignFirstResponder() -> Bool { setHeld(false); return super.resignFirstResponder() }
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { setHeld(false) }; super.viewWillMove(toWindow: newWindow)
        }
    }
    func makeNSView(context: Context) -> HoldButton {
        let button = HoldButton(title: "Hold to Talk Privately", target: nil, action: nil)
        button.bezelStyle = .rounded; button.setAccessibilityIdentifier("interview.privateTalkback")
        button.change = change; button.reconcile(active: active); return button
    }
    func updateNSView(_ button: HoldButton, context: Context) {
        button.change = change; button.isEnabled = enabled
        button.reconcile(active: active)
        button.title = active ? "Private Microphone Active — Release" : "Hold to Talk Privately"
    }
}
