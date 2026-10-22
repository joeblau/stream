import AppKit
import Foundation
import StreamCore

@MainActor private final class HeldEdge {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

private final class HeldPTZTransport: PTZTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    private var held: HeldEdge?
    private var handler: (@Sendable (PTZConnectionState) -> Void)?
    var events: [String] { lock.withLock { log } }
    func hold(_ gate: HeldEdge) { lock.withLock { held = gate } }
    func connect() async { lock.withLock { log.append("connect") } }
    func send(_ packet: Data) async {
        let hex = packet.map { String(format: "%02x", $0) }.joined()
        let gate = lock.withLock { () -> HeldEdge? in
            log.append("begin:" + hex); let result = held; held = nil; return result
        }
        if let gate { await gate.wait() }
        lock.withLock { log.append("end:" + hex) }
    }
    func disconnect() async { lock.withLock { log.append("disconnect") } }
    func setStateHandler(_ handler: (@Sendable (PTZConnectionState) -> Void)?) { lock.withLock { self.handler = handler } }
    func capturedStateHandler() -> (@Sendable (PTZConnectionState) -> Void)? { lock.withLock { handler } }
}

@main @MainActor private struct PTZControlAuthorityHarness {
    static func until(_ label: String, _ check: () -> Bool) async throws {
        for _ in 0..<1000 { if check() { return }; try await Task.sleep(for: .milliseconds(1)) }
        preconditionFailure("Deadline: " + label)
    }
    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
    static func main() async throws {
        setbuf(stdout, nil)
        let store = PTZPresetStore(documentStore: nil)
        let target = PTZTarget(name: "Owned memory target", host: "unused.invalid", cameraAddress: 2)
        store.addTarget(target)
        let transport = HeldPTZTransport(), gate = HeldEdge()
        let controller = PTZController(store: store, transportFactory: { _ in transport })
        transport.hold(gate)
        controller.move(target.id, direction: .left, panSpeed: 12, tiltSpeed: 10)
        try await until("held drive send") { gate.entered }
        controller.stop(target.id)
        controller.disconnectTarget(target.id)
        // Give independently queued baseline stop/disconnect tasks a chance
        // to overtake the still-held send. No network or device is involved.
        try await Task.sleep(for: .milliseconds(30))
        let early = transport.events
        gate.release()
        try await until("retired transport") { transport.events.contains("disconnect") }
        try await Task.sleep(for: .milliseconds(10))
        let events = transport.events
        print("TRACE held send / exact Stop / disconnect: \(events)")
        let drive = "end:" + hex(VISCAPacket.panTiltDrive(address: 2, direction: .left, panSpeed: 12, tiltSpeed: 10))
        let pan = "end:" + hex(VISCAPacket.panTiltStop(address: 2))
        let zoom = "end:" + hex(VISCAPacket.zoomStop(address: 2))
        precondition(!early.contains("disconnect"), "Disconnect overtook an outstanding drive/Stop send")
        precondition(events.firstIndex(of: drive)! < events.lastIndex(of: pan)! && events.lastIndex(of: pan)! < events.lastIndex(of: zoom)! && events.lastIndex(of: zoom)! < events.firstIndex(of: "disconnect")!, "Exact old-target Stop pair must finish before disconnect")
        print("PASS actual controller holds disconnect behind the original drive and exact Stop pair")
        try await supersession()
        try await reconfiguration()
        try await nativeButton()
        print("PASS owned PTZ authority only; no network/device, visible window, global input or complete AX qualification")
    }

    static func fixture() -> (PTZPresetStore, PTZTarget) {
        let store = PTZPresetStore(documentStore: nil)
        let target = PTZTarget(name: "Owned PTZ", host: "unused.invalid", cameraAddress: 2)
        store.addTarget(target); return (store, target)
    }
    static func supersession() async throws {
        let (store, target) = fixture(), transport = HeldPTZTransport()
        let timer = HeldEdge()
        let controller = PTZController(store: store, transportFactory: { _ in transport }, nudgeWait: { await timer.wait() })
        controller.nudge(target.id, direction: .left, panSpeed: 12, tiltSpeed: 10)
        try await until("old nudge timer") { timer.entered && transport.events.count >= 3 }
        let oldPointer = controller.motionLease(for: target.id)!
        controller.move(target.id, direction: .right, panSpeed: 12, tiltSpeed: 10)
        let currentPointer = controller.motionLease(for: target.id)!
        timer.release()
        controller.stop(oldPointer)
        await controller.waitForPendingOperations()
        let stop = "end:" + hex(VISCAPacket.panTiltStop(address: 2))
        precondition(!transport.events.contains(stop), "A stale timer or old pointer release stopped a newer motion")
        controller.stop(currentPointer); await controller.waitForPendingOperations()
        precondition(transport.events.filter { $0 == stop }.count == 1)
        controller.disconnectTarget(target.id); await controller.waitForPendingOperations()

        let (queuedStore, queuedTarget) = fixture(), queued = HeldPTZTransport(), send = HeldEdge(), expiry = HeldEdge()
        let bounded = PTZController(store: queuedStore, transportFactory: { _ in queued }, nudgeWait: { await expiry.wait() })
        queued.hold(send)
        bounded.nudge(queuedTarget.id, direction: .up, panSpeed: 12, tiltSpeed: 10)
        try await until("held nudge write") { send.entered && expiry.entered }
        expiry.release()
        try await until("expired motion authority") { bounded.motionLease(for: queuedTarget.id) == nil }
        precondition(!queued.events.contains(stop), "Stop overtook a held write")
        send.release(); await bounded.waitForPendingOperations()
        precondition(queued.events.suffix(2) == ["begin:" + hex(VISCAPacket.zoomStop(address: 2)), "end:" + hex(VISCAPacket.zoomStop(address: 2))])
        bounded.disconnectTarget(queuedTarget.id); await bounded.waitForPendingOperations()
        print("PASS stale timer/pointer leases cannot Stop newer motion; expired nudge still orders its exact Stop after held send")

        let (lastStore, lastTarget) = fixture(), last = HeldPTZTransport(), held = HeldEdge()
        let latest = PTZController(store: lastStore, transportFactory: { _ in last })
        last.hold(held); latest.move(lastTarget.id, direction: .left, panSpeed: 12, tiltSpeed: 10)
        try await until("first queued write") { held.entered }
        latest.move(lastTarget.id, direction: .right, panSpeed: 12, tiltSpeed: 10)
        latest.endInteractiveControl(); held.release(); await latest.waitForPendingOperations()
        precondition(!last.events.contains("begin:" + hex(VISCAPacket.panTiltDrive(address: 2, direction: .right, panSpeed: 12, tiltSpeed: 10))), "Queued stale movement began after focus cleanup")
        latest.disconnectTarget(lastTarget.id); await latest.waitForPendingOperations()
        print("PASS focus cleanup cancels unsent movement before ordered Stop")
    }
    static func reconfiguration() async throws {
        let (store, target) = fixture(), first = HeldPTZTransport(), second = HeldPTZTransport()
        var factories = 0
        let controller = PTZController(store: store, transportFactory: { _ in factories += 1; return factories == 1 ? first : second })
        controller.move(target.id, direction: .left, panSpeed: 12, tiltSpeed: 10)
        await controller.waitForPendingOperations()
        let oldLease = controller.motionLease(for: target.id)!, oldHandler = first.capturedStateHandler()
        var replacement = target; replacement.host = "replacement.invalid"; replacement.cameraAddress = 5
        store.updateTarget(replacement)
        controller.move(target.id, direction: .right, panSpeed: 12, tiltSpeed: 10)
        controller.stop(oldLease)
        await controller.waitForPendingOperations()
        precondition(first.events.contains("end:" + hex(VISCAPacket.panTiltStop(address: 2))))
        precondition(!first.events.contains("end:" + hex(VISCAPacket.panTiltStop(address: 5))))
        precondition(!second.events.contains("end:" + hex(VISCAPacket.panTiltStop(address: 5))))
        second.capturedStateHandler()?(.connected)
        try await until("new connection state") { controller.connectionStates[target.id] == .connected }
        oldHandler?(.failed("old connection callback"))
        try await Task.sleep(for: .milliseconds(10))
        precondition(controller.connectionStates[target.id] == .connected)
        controller.disconnectTarget(target.id); await controller.waitForPendingOperations()
        print("PASS old immutable target/address Stop and callbacks cannot affect replacement connection")
    }
    static func nativeButton() async throws {
        _ = NSApplication.shared
        let (store, target) = fixture(), transport = HeldPTZTransport()
        let controller = PTZController(store: store, transportFactory: { _ in transport })
        let button = PTZMotionNSButton(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
        button.title = "Owned PTZ nudge"; button.setAccessibilityLabel("Owned PTZ: move left")
        var nudges = 0, presses = 0, releases = 0
        button.onNudge = {
            nudges += 1; controller.nudge(target.id, direction: .left, panSpeed: 12, tiltSpeed: 10)
            return controller.motionLease(for: target.id)
        }
        button.onPress = {
            presses += 1; controller.move(target.id, direction: .right, panSpeed: 12, tiltSpeed: 10)
            return controller.motionLease(for: target.id)
        }
        button.onStop = { lease in releases += 1; controller.stop(lease) }
        button.onWindowDeactivated = { controller.endInteractiveControl() }
        let reference = NSButton(title: "Owned reference", target: nil, action: nil)
        print("TRACE local AppKit role=\(String(describing: button.accessibilityRole())) reference=\(String(describing: reference.accessibilityRole())) focus=\(button.acceptsFirstResponder) element=\(button.isAccessibilityElement())")
        precondition(button.acceptsFirstResponder)
        let platformAXAvailable = button.accessibilityRole() == .button && reference.accessibilityRole() == .button
        if !platformAXAvailable {
            print("UNQUALIFIED77: plain NSButton and PTZ native button both report AXUnknown offscreen on this host; no keyboard/AX delivery qualification or role override")
        }
        button.performClick(nil)
        await controller.waitForPendingOperations()
        precondition(nudges == 1 && transport.events.filter { $0 == "end:" + hex(VISCAPacket.panTiltStop(address: 2)) }.count == 1)
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 0.1,
            windowNumber: 0, context: nil, eventNumber: 2, clickCount: 1, pressure: 0)!
        button.mouseDown(with: down)
        try await until("native pointer returns so async drive can run") { transport.events.contains("end:" + hex(VISCAPacket.panTiltDrive(address: 2, direction: .right, panSpeed: 12, tiltSpeed: 10))) }
        button.performClick(nil) // A release/activation cannot add a second pulse while tracking.
        let originalStop = button.onStop
        button.onStop = { _ in preconditionFailure("An updated view callback stole an older input's cleanup") }
        button.mouseUp(with: up); button.mouseUp(with: up)
        button.onStop = originalStop
        await controller.waitForPendingOperations()
        precondition(nudges == 1 && presses == 1 && releases == 1)
        if platformAXAvailable {
            precondition(button.accessibilityPerformPress(), "Native button AX target-action was unavailable")
            await controller.waitForPendingOperations(); precondition(nudges == 2)
        }
        let expectedNudges = nudges
        button.isEnabled = false; button.performClick(nil); precondition(nudges == expectedNudges)
        controller.move(target.id, direction: .up, panSpeed: 12, tiltSpeed: 10)
        let external = controller.motionLease(for: target.id)
        await controller.waitForPendingOperations()
        button.teardownControl()
        let uninvolved = PTZMotionNSButton(frame: .zero)
        uninvolved.onStop = { controller.stop($0) }
        uninvolved.onWindowDeactivated = { controller.endInteractiveControl() }
        uninvolved.teardownControl()
        precondition(controller.motionLease(for: target.id) == external, "Stale/uninvolved button teardown stopped newer external motion")
        controller.endInteractiveControl(); controller.disconnectTarget(target.id); await controller.waitForPendingOperations()
        print("PASS native NSButton performClick nudge/Stop; local pointer begin/release is nonblocking, exactly once, with no release pulse; stale/uninvolved button teardown preserves newer motion")
    }
}
