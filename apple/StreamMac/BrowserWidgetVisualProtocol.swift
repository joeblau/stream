import CoreGraphics
import Darwin
import Foundation

/// Qualification viewport bound, intentionally narrower than the existing in-app backend.
/// The IPC is raw premultiplied BGRA; no image decompression or arbitrary file access occurs.
struct BrowserWidgetPageOptions: Codable, Sendable {
    var width = 480, height = 270
    var allowsInteraction = false
    var hidden = false
    var css = ""
    static let maximumWidth = 1_920, maximumHeight = 1_080
    func validate() throws {
        guard (16...Self.maximumWidth).contains(width), (16...Self.maximumHeight).contains(height),
              css.utf8.count <= 16_384 else { throw BrowserWidgetAudioCommand.CommandError.invalidContent }
    }
}

struct BrowserWidgetInteraction: Codable, Sendable {
    enum Kind: String, Codable, Sendable { case mouseDown, mouseUp, mouseDragged, mouseMoved, scroll, keyDown, keyUp }
    var kind: Kind
    /// Top-left viewport coordinates; converted to the helper's window coordinates exactly once.
    var x = 0.0, y = 0.0
    var deltaX = 0.0, deltaY = 0.0
    var keyCode: UInt16 = 0
    var text = ""
    var modifiers: UInt64 = 0
    func validate() throws {
        guard [x, y, deltaX, deltaY].allSatisfy(\.isFinite),
              (0...Double(BrowserWidgetPageOptions.maximumWidth)).contains(x),
              (0...Double(BrowserWidgetPageOptions.maximumHeight)).contains(y),
              abs(deltaX) <= 1_000, abs(deltaY) <= 1_000, text.utf8.count <= 128,
              modifiers & ~UInt64(0x1f0000) == 0 else { throw BrowserWidgetAudioCommand.CommandError.invalidContent }
    }
}

struct BrowserWidgetVisualHeader: Codable, Sendable {
    var widgetID: UUID, generation: UUID, requestID: UUID
    var width: Int, height: Int
    var requestedHostSeconds: Double, completedHostSeconds: Double
    var byteCount: Int { width * height * 4 }
    func validate() throws {
        guard (16...BrowserWidgetPageOptions.maximumWidth).contains(width),
              (16...BrowserWidgetPageOptions.maximumHeight).contains(height),
              requestedHostSeconds.isFinite, completedHostSeconds.isFinite,
              requestedHostSeconds > 0, completedHostSeconds >= requestedHostSeconds,
              completedHostSeconds - requestedHostSeconds < 5 else { throw BrowserWidgetVisualTransport.TransportError.invalidFrame }
    }
}

enum BrowserWidgetVisualTransport {
    enum TransportError: Error { case closed, invalidFrame, timeout }
    static let maximumHeaderBytes = 2_048
    static let maximumFrameBytes = BrowserWidgetPageOptions.maximumWidth * BrowserWidgetPageOptions.maximumHeight * 4

    static func write(header: BrowserWidgetVisualHeader, pixels: Data, descriptor: Int32) throws {
        try header.validate()
        guard pixels.count == header.byteCount else { throw TransportError.invalidFrame }
        let metadata = try JSONEncoder().encode(header)
        guard metadata.count <= maximumHeaderBytes else { throw TransportError.invalidFrame }
        var size = UInt32(metadata.count).bigEndian
        let prefix = withUnsafeBytes(of: &size) { Data($0) }
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        try writeAll(prefix, descriptor: descriptor, deadline: deadline)
        try writeAll(metadata, descriptor: descriptor, deadline: deadline)
        try writeAll(pixels, descriptor: descriptor, deadline: deadline)
    }

    /// Only the four-byte prefix can wait for an idle peer. Once a frame starts, its full bounded
    /// header/body must arrive within five seconds; malformed streams are closed, never resynced.
    static func read(descriptor: Int32) throws -> (BrowserWidgetVisualHeader, Data) {
        let prefix = try readExact(4, descriptor: descriptor, deadline: nil)
        let size = prefix.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard size > 0, size <= maximumHeaderBytes else { throw TransportError.invalidFrame }
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        let header = try JSONDecoder().decode(BrowserWidgetVisualHeader.self,
            from: readExact(Int(size), descriptor: descriptor, deadline: deadline))
        try header.validate()
        let pixels = try readExact(header.byteCount, descriptor: descriptor, deadline: deadline)
        return (header, pixels)
    }

    private static func readExact(_ size: Int, descriptor: Int32, deadline: Double?) throws -> Data {
        var data = Data(count: size)
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < size {
                try ready(descriptor, writing: false, deadline: deadline)
                let count = Darwin.read(descriptor, bytes.baseAddress!.advanced(by: offset), min(65_536, size - offset))
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw TransportError.closed }
                offset += count
            }
        }
        return data
    }
    private static func writeAll(_ data: Data, descriptor: Int32, deadline: Double) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < data.count {
                try ready(descriptor, writing: true, deadline: deadline)
                let count = Darwin.send(descriptor, bytes.baseAddress!.advanced(by: offset), min(65_536, data.count - offset), 0)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw TransportError.closed }
                offset += count
            }
        }
    }
    private static func ready(_ descriptor: Int32, writing: Bool, deadline: Double?) throws {
        var pollDescriptor = pollfd(fd: descriptor, events: Int16(writing ? POLLOUT : POLLIN), revents: 0)
        let milliseconds: Int32
        if let deadline {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw TransportError.timeout }
            milliseconds = Int32(min(5_000, max(1, remaining * 1_000)))
        } else { milliseconds = -1 }
        var status: Int32
        repeat { status = poll(&pollDescriptor, 1, milliseconds) } while status < 0 && errno == EINTR
        guard status > 0 else { throw TransportError.timeout }
        guard pollDescriptor.revents & Int16(writing ? POLLOUT : POLLIN) != 0 else { throw TransportError.closed }
    }
}
