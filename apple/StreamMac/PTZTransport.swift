import Foundation
import Network
import StreamCore

/// E06 (issue #165): the PTZ transport layer.
///
/// Everything above this file (controller, dispatcher, UI) speaks the
/// `PTZTransport` protocol, so the production Network-framework transport
/// and a unit-test fake are interchangeable — no hardware is required to
/// test the control logic. VISCA over IP is best-effort (no retries, no
/// sequence numbers — see the pinned assumptions in StreamCore/PTZ.swift),
/// so `send` is fire-and-forget: errors surface through `onStateChange`,
/// never as thrown command failures the UI must handle inline.
///
/// UVC PTZ: USB cameras that expose pan/tilt/zoom through the UVC terminal
/// unit (class-specific GET/SET requests via IOKit) are NOT reachable from
/// this sandboxed app today — App Sandbox blocks opening USB devices without
/// the `com.apple.security.device.usb` entitlement, and AVFoundation exposes
/// no PTZ surface to translate through. `UVCPTZAdapter` is the documented,
/// honest stub: it reports `.unavailable` with the reason, so a UVC camera
/// configured as a target degrades to guidance instead of silent no-ops.
/// The seam is deliberate: adding the entitlement and an IOUSBHost
/// implementation later touches only this file.

/// Connection lifecycle the `PTZController` surfaces to the UI.
enum PTZConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case failed(String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

/// One camera connection. Implementations must be usable from any actor:
/// the controller hops to the transport's own queue semantics. All methods
/// are idempotent — a duplicate `disconnect` is a no-op.
protocol PTZTransport: AnyObject, Sendable {
    /// Brings the connection up (lazy connects may defer to the first send).
    func connect() async
    /// Sends one raw VISCA frame. Fire-and-forget: transport errors are
    /// reported via the state callback, not thrown.
    func send(_ packet: Data) async
    /// Tears the connection down. The controller always sends a VISCA stop
    /// BEFORE calling this, so a camera never keeps moving after its
    /// controls disappear.
    func disconnect() async
    /// Replaces the state-change callback (one controller per transport).
    func setStateHandler(_ handler: (@Sendable (PTZConnectionState) -> Void)?)
}

/// The production VISCA-over-IP transport: `NWConnection` in UDP or TCP
/// mode, raw serial-format frames (the pinned assumption — the common PTZ
/// cameras in the compatibility matrix all accept raw framing).
final class NWPTZTransport: PTZTransport, @unchecked Sendable {
    /// The configuration this transport was built with — compared against
    /// the store's targets to detect reconfiguration (PTZController).
    let target: PTZTarget
    private let queue = DispatchQueue(label: "stream.ptz.transport", qos: .userInitiated)
    /// Protected by `lock`: created lazily on connect/first send.
    private let lock = NSLock()
    private var connection: NWConnection?
    /// @unchecked-Sendable escape: the handler is only invoked on `queue`
    /// and replaced under `lock`.
    private var stateHandler: (@Sendable (PTZConnectionState) -> Void)?
    /// Serializes reconnect decisions on `queue` (coalesces rapid sends
    /// racing a dropped connection into one restart).
    private var state: PTZConnectionState = .disconnected

    init(target: PTZTarget) {
        self.target = target
    }

    func setStateHandler(_ handler: (@Sendable (PTZConnectionState) -> Void)?) {
        lock.lock()
        stateHandler = handler
        lock.unlock()
    }

    func connect() async {
        queue.async { self.ensureConnection() }
    }

    func send(_ packet: Data) async {
        queue.async {
            self.ensureConnection()
            guard let connection = self.connection else { return }
            // One VISCA frame per datagram/write. `.idempotent` content
            // context: no framing protocol, matching the raw-serial
            // assumption pinned in StreamCore/PTZ.swift.
            connection.send(content: packet, completion: .idempotent)
        }
    }

    func disconnect() async {
        queue.async {
            self.connection?.cancel()
            self.connection = nil
            self.publish(.disconnected)
        }
    }

    // MARK: - Internals (queue-confined)

    private func ensureConnection() {
        if connection != nil, state.isConnected || state == .connecting { return }
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(target.host),
            port: NWEndpoint.Port(rawValue: target.port)
                ?? NWEndpoint.Port(rawValue: target.kind.defaultPort)!)
        let parameters: NWParameters = target.kind == .viscaOverTCP
            ? .tcp : .udp
        let connection = NWConnection(to: endpoint, using: parameters)
        connection.stateUpdateHandler = { [weak self] nwState in
            guard let self else { return }
            switch nwState {
            case .ready:
                self.publish(.connected)
            case .failed(let error):
                self.connection?.cancel()
                self.connection = nil
                self.publish(.failed(error.localizedDescription))
            case .cancelled:
                self.connection = nil
                self.publish(.disconnected)
            default:
                break
            }
        }
        self.connection = connection
        publish(.connecting)
        connection.start(queue: queue)
    }

    private func publish(_ newState: PTZConnectionState) {
        state = newState
        lock.lock()
        let handler = stateHandler
        lock.unlock()
        handler?(newState)
    }
}

/// The honest UVC stand-in (see the file header): reports unavailable with
/// the reason, so a USB camera target fails loudly instead of silently.
/// Kept behind the same protocol so wiring in an IOUSBHost implementation
/// later is a drop-in replacement.
final class UVCPTZAdapter: PTZTransport, @unchecked Sendable {
    /// Why UVC PTZ is not reachable in this build.
    static let unavailableReason =
        "UVC PTZ needs USB device access, which the sandboxed app does not have (no com.apple.security.device.usb entitlement). Use a VISCA-over-IP target for this camera instead."

    func connect() async {}
    func send(_ packet: Data) async {}
    func disconnect() async {}
    func setStateHandler(_ handler: (@Sendable (PTZConnectionState) -> Void)?) {
        handler?(.failed(Self.unavailableReason))
    }
}
