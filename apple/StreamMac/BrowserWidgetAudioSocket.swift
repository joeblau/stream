import Darwin
import Foundation

/// Qualification IPC for a true Launch Services helper launch. A private 0700 directory and
/// same-user / exact-PID peer check keep widget content out of command lines and shared files.
final class BrowserWidgetAudioSocket: @unchecked Sendable {
    enum SocketError: Error { case unavailable, invalidPeer }
    let path: String
    private let directory: URL
    private var descriptor: Int32 = -1

    init() throws {
        directory = URL(fileURLWithPath: "/tmp/stream-browser-audio-\(UUID().uuidString)", isDirectory: true)
        path = directory.appendingPathComponent("ipc.sock").path
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw SocketError.unavailable }
        var address = try Self.address(path)
        let status = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard status == 0, chmod(path, 0o600) == 0, listen(descriptor, 1) == 0 else { throw SocketError.unavailable }
    }

    func accept(expectedPID: Int32) async throws -> FileHandle {
        let listening = descriptor
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue(label: "browser-helper-fixture.accept").async {
                var ready = pollfd(fd: listening, events: Int16(POLLIN), revents: 0)
                guard poll(&ready, 1, 5_000) > 0 else { continuation.resume(throwing: SocketError.unavailable); return }
                let peer = Darwin.accept(listening, nil, nil)
                guard peer >= 0 else { continuation.resume(throwing: SocketError.unavailable); return }
                var uid: uid_t = 0, gid: gid_t = 0, pid: Int32 = 0
                var size = socklen_t(MemoryLayout<Int32>.size)
                guard getpeereid(peer, &uid, &gid) == 0, uid == geteuid(),
                      getsockopt(peer, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0, pid == expectedPID else {
                    Darwin.close(peer); continuation.resume(throwing: SocketError.invalidPeer); return
                }
                continuation.resume(returning: FileHandle(fileDescriptor: peer, closeOnDealloc: true))
            }
        }
    }

    static func connect(path: String) throws -> FileHandle {
        var address = try address(path)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw SocketError.unavailable }
        let status = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        var uid: uid_t = 0, gid: gid_t = 0
        guard status == 0, getpeereid(descriptor, &uid, &gid) == 0, uid == geteuid() else {
            Darwin.close(descriptor); throw SocketError.unavailable
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
    private static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw SocketError.unavailable }
        address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }
    deinit {
        if descriptor >= 0 { Darwin.close(descriptor) }
        unlink(path)
        try? FileManager.default.removeItem(at: directory)
    }
}
