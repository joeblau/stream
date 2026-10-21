import AppKit
import SwiftUI

/// A real hold control: mouse/key release, removal and focus loss all release
/// the exact press token. There is no persistent toggle or reconnect replay.
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
                    if held, press == nil {
                        let token = UUID()
                        if dispatcher.execute(.interview(.beginTalkback(context, source, token))).error == nil { press = token }
                    } else if !held, let token = press {
                        _ = dispatcher.execute(.interview(.endTalkback(context, token))); press = nil
                    }
                }).frame(height: 28)
            Text("Hold to send the already running primary microphone privately to this guest. Its Program, Monitor, Aux and isolated tracks are silent; other sources keep their routes. Private speech bypasses microphone effects. Release or safety cancellation restores its prior routes, so continuing speech may be public. Ends after ten seconds, focus loss or reconnect.")
                .font(.caption).foregroundStyle(.secondary)
        }.onDisappear {
            if let press { _ = dispatcher.execute(.interview(.endTalkback(context, press))) }
            press = nil
        }
    }
}

private struct NativeTalkbackHoldButton: NSViewRepresentable {
    let active: Bool, enabled: Bool
    let change: (Bool) -> Void
    final class HoldButton: NSButton {
        var change: ((Bool) -> Void)?
        private var held = false
        private func setHeld(_ value: Bool) {
            guard held != value else { return }; held = value; change?(value)
        }
        override func mouseDown(with event: NSEvent) {
            guard isEnabled else { return }
            setHeld(true); defer { setHeld(false) }; super.mouseDown(with: event)
        }
        override func keyDown(with event: NSEvent) {
            guard isEnabled, event.keyCode == 49 else { super.keyDown(with: event); return }
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
        button.change = change; return button
    }
    func updateNSView(_ button: HoldButton, context: Context) {
        button.change = change; button.isEnabled = enabled
        button.title = active ? "Private Microphone Active — Release" : "Hold to Talk Privately"
    }
}
