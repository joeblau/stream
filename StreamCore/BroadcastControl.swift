import Foundation
import notify

/// Lightweight signals shared by the ScreenCaptureKit controller and settings UI.
public enum BroadcastControl {
    /// Screen capture state changed (started / finished).
    public static let stateSignal = "com.joeblau.Stream.broadcast.state"
    /// Mic volume changed — re-read settings and apply it live.
    public static let micVolumeSignal = "com.joeblau.Stream.broadcast.micVolume"
    /// Extension → app: compact live microphone meter state (notify state payload).
    public static let micLevelState = "com.joeblau.Stream.broadcast.micLevel"

    /// Posts a Darwin notification by name. Delivered to observers in every
    /// process on the device, including our other target.
    public static func post(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString),
            nil,
            nil,
            true
        )
    }
}

/// Low-overhead transport for the live microphone meter. A notifyd state value
/// carries a Float32 level and monotonic timestamp in one UInt64, allowing 10 Hz
/// updates without file I/O or notification delivery.
public final class MicrophoneLevelChannel: @unchecked Sendable {
    private static let tickNanoseconds: UInt64 = 100_000_000
    private var token: Int32 = 0
    private let isRegistered: Bool

    public init() {
        var registeredToken: Int32 = 0
        let status = BroadcastControl.micLevelState.withCString {
            notify_register_check($0, &registeredToken)
        }
        token = registeredToken
        isRegistered = status == NOTIFY_STATUS_OK
    }

    deinit {
        if isRegistered { notify_cancel(token) }
    }

    public func publish(_ level: Float) {
        guard isRegistered else { return }
        let clamped = max(0, min(level, 1))
        let tick = UInt32(truncatingIfNeeded:
            DispatchTime.now().uptimeNanoseconds / Self.tickNanoseconds)
        let state = (UInt64(tick) << 32) | UInt64(clamped.bitPattern)
        notify_set_state(token, state)
    }

    /// Returns nil when no fresh meter update has arrived within `maxAge`.
    public func read(maxAge: TimeInterval = 0.6) -> Float? {
        guard isRegistered else { return nil }
        var state: UInt64 = 0
        guard notify_get_state(token, &state) == NOTIFY_STATUS_OK else { return nil }
        let writtenTick = UInt32(truncatingIfNeeded: state >> 32)
        let currentTick = UInt32(truncatingIfNeeded:
            DispatchTime.now().uptimeNanoseconds / Self.tickNanoseconds)
        let elapsedTicks = currentTick &- writtenTick
        guard Double(elapsedTicks) * 0.1 <= maxAge else { return nil }
        let level = Float(bitPattern: UInt32(truncatingIfNeeded: state))
        guard level.isFinite else { return nil }
        return max(0, min(level, 1))
    }
}

/// Observes a single Darwin notification for the lifetime of this object and
/// invokes `handler` on the main queue each time it fires. The C callback captures
/// nothing (it routes through the observer pointer), so it is trivially
/// concurrency-safe; the owner just has to keep the instance alive.
public final class DarwinSignalObserver {
    private let name: String
    private let handler: @Sendable () -> Void

    public init(name: String, handler: @escaping @Sendable () -> Void) {
        self.name = name
        self.handler = handler
        let raw = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            raw,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let this = Unmanaged<DarwinSignalObserver>.fromOpaque(observer)
                    .takeUnretainedValue()
                let handler = this.handler
                DispatchQueue.main.async { handler() }
            },
            name as CFString,
            nil,
            .deliverImmediately
        )
    }

    deinit {
        let raw = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            raw,
            CFNotificationName(name as CFString),
            nil
        )
    }
}

/// The broadcast liveness snapshot the capture controller publishes.
public struct BroadcastState: Codable, Sendable {
    public var isBroadcasting: Bool
    /// `Date().timeIntervalSince1970` of the extension's last write. A recent
    /// value proves the capture pipeline is still alive.
    public var heartbeat: TimeInterval

    public init(isBroadcasting: Bool, heartbeat: TimeInterval) {
        self.isBroadcasting = isBroadcasting
        self.heartbeat = heartbeat
    }
}

/// Reads/writes the broadcast state file in the shared App Group container.
public enum BroadcastStateStore {
    private static func fileURL() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier)?
            .appendingPathComponent("broadcast.state.json")
    }

    public static func write(_ state: BroadcastState) {
        guard let url = fileURL(), let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: url, options: .atomic)
    }

    public static func read() -> BroadcastState? {
        guard let url = fileURL(), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(BroadcastState.self, from: data)
    }

    /// True only when broadcasting and the heartbeat is recent.
    public static func isLive(staleAfter: TimeInterval = 8) -> Bool {
        guard let state = read(), state.isBroadcasting else { return false }
        return Date().timeIntervalSince1970 - state.heartbeat < staleAfter
    }
}
