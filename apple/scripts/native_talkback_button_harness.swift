
@main @MainActor enum OwnedTalkbackHoldProbe {
    static func externalPress(_ label: String, client: String) async throws -> (Int32, String) {
        let parent = getpid()
        return try await Task.detached {
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: client)
            process.arguments = [String(parent), "press", label]
            process.standardOutput = output; process.standardError = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }.value
    }
    static func main() {
        setbuf(stdout, nil)
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
        button.change = { held in transitions.append(held); times.append(ProcessInfo.processInfo.systemUptime); return true }
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

        // Public accessibility Press cannot send key/mouse-up. It therefore
        // starts a clearly named, bounded interval or ends the current one.
        container.addSubview(button)
        button.reconcile(active: false)
        button.isEnabled = false
        let disabledCount = transitions.count
        precondition(!button.accessibilityPerformPress() && transitions.count == disabledCount,
                     "Disabled accessibility activation began private speech")
        button.isEnabled = true
        var refused = 0
        button.change = { held in if held { refused += 1 }; return false }
        precondition(!button.accessibilityPerformPress() && refused == 1 && button.accessibilityValue() as? String == "Inactive",
                     "A stale/unavailable begin must fail without latching or claiming an active microphone")
        button.change = { held in transitions.append(held); times.append(ProcessInfo.processInfo.systemUptime); return true }
        precondition(button.accessibilityPerformPress() && transitions.last == true,
                     "Public accessibility Press failed to begin through the same accepted callback")
        precondition(button.accessibilityTitle() == "Stop private talkback" && button.accessibilityLabel() == "Stop private talkback" && button.accessibilityValue() as? String == "Private microphone active",
                     "Accessible state does not announce the stop action and private interval")
        precondition(button.accessibilityPerformPress() && transitions.suffix(2) == [true, false],
                     "A second accessibility Press failed to release the exact local hold")
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        precondition(button.accessibilityPerformPress(), "Second accessibility interval failed")
        let boundedStart = ProcessInfo.processInfo.systemUptime
        RunLoop.main.run(until: Date().addingTimeInterval(9.85))
        precondition(transitions.last == true, "An invalidated prior accessibility deadline ended a newer interval")
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        precondition(transitions.suffix(2) == [true, false] && times.last! - boundedStart >= 9.95 && times.last! - boundedStart < 10.25,
                     "Accessibility activation failed its ten-second maximum release")
        precondition(button.accessibilityTitle() == "Start private talkback (10 seconds maximum)" && button.accessibilityLabel() == "Start private talkback (10 seconds maximum)" && button.accessibilityValue() as? String == "Inactive",
                     "Automatic release left stale accessible state")
        precondition(button.accessibilityPerformPress(), "Accessibility interval before focus loss failed")
        _ = button.resignFirstResponder()
        precondition(transitions.suffix(2) == [true, false], "Accessibility focus loss failed to release")
        precondition(button.accessibilityPerformPress(), "Accessibility interval before removal failed")
        button.removeFromSuperview()
        precondition(transitions.suffix(2) == [true, false], "Accessibility control removal failed to release")
        container.addSubview(button)
        precondition(button.accessibilityPerformPress(), "Accessibility interval before manager revocation failed")
        let revokedCount = transitions.count
        button.reconcile(active: false)
        precondition(transitions.count == revokedCount && button.accessibilityValue() as? String == "Inactive",
                     "Manager revocation must clear local state without issuing another owner's release")
        precondition(button.accessibilityPerformPress(), "A manager-revoked interval prevented a fresh deliberate start")
        button.isEnabled = false
        precondition(button.accessibilityPerformPress() && transitions.suffix(2) == [true, false],
                     "Disabling new starts prevented an existing accessibility interval from being stopped")
        print("PASS: actual AppKit PTT mouse tracking, Space down/repeat/up, modifier refusal, responder loss and view removal; public accessibility Press begin/stop, disabled/stale refusal, exact ten-second automatic release, prior-timer cancellation, manager revocation and fresh restart; no capture or permissions")
        if CommandLine.arguments.contains("--external-ax") {
            guard let client = ProcessInfo.processInfo.environment["STREAM_TALKBACK_AX_CLIENT"] else { window.close(); exit(77) }
            button.isEnabled = true; button.reconcile(active: false)
            transitions.removeAll()
            Task { @MainActor in
                do {
                    let begin = try await externalPress("Start private talkback (10 seconds maximum)", client: client)
                    guard begin.0 != 77 else { print("UNQUALIFIED: \(begin.1)"); window.close(); exit(77) }
                    precondition(begin.0 == 0 && transitions == [true], "Owned public AX begin failed: \(begin)")
                    let stop = try await externalPress("Stop private talkback", client: client)
                    precondition(stop.0 == 0 && transitions == [true, false], "Owned public AX release failed: \(stop)")
                    print("PASS: separate owned public AXUIElement client resolves the real Start/Stop AX titles and activates/releases the exact shipping control")
                    window.close(); exit(0)
                } catch { print("FAIL: \(error)"); window.close(); exit(1) }
            }
            app.run()
        }
        window.close()
    }
}
