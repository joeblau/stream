import AppKit
import SwiftUI

/// A real native button supplies keyboard/AX target-action. Pointer driving
/// does not enter NSButton's nested tracking loop, which would delay async sends.
struct PTZMotionButton: NSViewRepresentable {
    let title: String
    var systemImage: String?
    let accessibilityLabel: String
    let onNudge: () -> PTZController.MotionLease?
    let onPress: () -> PTZController.MotionLease?
    let onStop: (PTZController.MotionLease) -> Void
    let onWindowDeactivated: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    func makeNSView(context: Context) -> PTZMotionNSButton { PTZMotionNSButton(frame: .zero) }
    func updateNSView(_ button: PTZMotionNSButton, context: Context) {
        button.title = title
        button.image = systemImage.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        button.imagePosition = systemImage == nil ? .noImage : .imageOnly
        button.bezelStyle = systemImage == nil ? .rounded : .regularSquare
        button.controlSize = .small
        button.setAccessibilityLabel(accessibilityLabel)
        button.toolTip = "\(accessibilityLabel). Hold to drive; activate with keyboard or accessibility for a 250 ms nudge."
        button.onNudge = onNudge; button.onPress = onPress
        button.onStop = onStop; button.onWindowDeactivated = onWindowDeactivated
        if !isEnabled { button.invalidateControl() }
        button.isEnabled = isEnabled
    }
    static func dismantleNSView(_ button: PTZMotionNSButton, coordinator: Void) { button.teardownControl() }
}

@MainActor final class PTZMotionNSButton: NSButton {
    var onNudge: () -> PTZController.MotionLease? = { nil }
    var onPress: () -> PTZController.MotionLease? = { nil }
    var onStop: (PTZController.MotionLease) -> Void = { _ in }
    var onWindowDeactivated: () -> Void = {}
    private var inputStop: (() -> Void)?
    private var pointerDriving = false
    private var releaseMonitor: Any?
    private var observers: [NSObjectProtocol] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        setButtonType(.momentaryPushIn)
        target = self; action = #selector(activateNative)
    }
    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }
    @objc private func activateNative() {
        guard isEnabled, !pointerDriving else { return }
        ownInput(onNudge())
    }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled, !pointerDriving else { return }
        window?.makeFirstResponder(self)
        pointerDriving = true; highlight(true)
        releaseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            MainActor.assumeIsolated { self?.finishPointer() }
            return event
        }
        ownInput(onPress())
        // Return immediately so the MainActor can send the drive while held.
    }
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { finishPointer() }
    private func finishPointer() {
        guard pointerDriving else { return }
        pointerDriving = false; highlight(false)
        if let releaseMonitor { NSEvent.removeMonitor(releaseMonitor); self.releaseMonitor = nil }
        stopOwnedInput()
    }
    private func stopOwnedInput() {
        let stop = inputStop; inputStop = nil; stop?()
    }
    private func ownInput(_ lease: PTZController.MotionLease?) {
        // SwiftUI may replace callbacks while this native view is retained.
        // Cleanup belongs to the controller that accepted this exact input.
        let stop = onStop
        inputStop = lease.map { lease in { stop(lease) } }
    }
    func invalidateControl() { finishPointer(); stopOwnedInput() }
    func teardownControl() {
        invalidateControl()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }
    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { invalidateControl() }
        return result
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window != nil, window !== newWindow { invalidateControl() }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        if let newWindow {
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                object: newWindow, queue: .main) { [weak self, weak newWindow] _ in
                    MainActor.assumeIsolated {
                        guard let self, let newWindow, self.window === newWindow, !newWindow.isKeyWindow else { return }
                        self.invalidateControl(); self.onWindowDeactivated()
                    }
                })
            observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, !NSApplication.shared.isActive else { return }
                        self.invalidateControl(); self.onWindowDeactivated()
                    }
                })
        }
        super.viewWillMove(toWindow: newWindow)
    }
}
