
@main @MainActor enum OwnedTalkbackHoldProbe {
    static func main() {
        guard CGSessionCopyCurrentDictionary() != nil else {
            print("UNQUALIFIED: owned AppKit hold control requires WindowServer"); exit(77)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory); app.finishLaunching()
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 420, height: 180),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let button = NativeTalkbackHoldButton.HoldButton(title: "Owned PTT", target: nil, action: nil)
        button.frame = NSRect(x: 20, y: 50, width: 300, height: 32); button.bezelStyle = .rounded
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 180))
        container.addSubview(button); window.contentView = container
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(button)
        var transitions: [Bool] = [], times: [Double] = []
        button.change = { held in transitions.append(held); times.append(ProcessInfo.processInfo.systemUptime) }
        func key(_ type: NSEvent.EventType, repeatKey: Bool = false, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: " ", charactersIgnoringModifiers: " ", isARepeat: repeatKey, keyCode: 49)!
        }
        button.keyDown(with: key(.keyDown)); button.keyDown(with: key(.keyDown, repeatKey: true))
        precondition(transitions == [true], "Space repeat recreated a private hold")
        button.keyUp(with: key(.keyUp)); precondition(transitions == [true, false], "Space release failed")
        button.keyDown(with: key(.keyDown, modifiers: .option))
        precondition(transitions == [true, false], "Modified Space unexpectedly began a private hold")
        button.keyDown(with: key(.keyDown)); _ = button.resignFirstResponder()
        precondition(transitions == [true, false, true, false], "Responder loss failed to release")
        let number = window.windowNumber
        let timer = Timer(timeInterval: 0.15, repeats: false) { _ in MainActor.assumeIsolated {
            let up = NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: 100, y: 65), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: number, context: nil,
                eventNumber: 2, clickCount: 1, pressure: 0)!
            NSApplication.shared.postEvent(up, atStart: false)
        } }
        RunLoop.main.add(timer, forMode: .common)
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 100, y: 65), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: number, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1)!
        button.mouseDown(with: down)
        precondition(transitions.suffix(2) == [true, false], "Mouse tracking failed to release")
        precondition(times.last! - times[times.count - 2] > 0.08, "Mouse hold ended before its owned mouse-up")
        button.keyDown(with: key(.keyDown)); button.removeFromSuperview()
        precondition(transitions.suffix(2) == [true, false], "Window detach failed to release")
        window.close()
        print("PASS: actual AppKit PTT mouse tracking, Space down/repeat/up, modifier refusal, responder loss and view removal; no capture or permissions")
    }
}
