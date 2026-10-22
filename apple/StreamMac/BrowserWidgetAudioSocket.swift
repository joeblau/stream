import Darwin
import Foundation
import Security

/// Production never falls back to private /tmp. Prototype authority is absent from shipped code.
final class BrowserWidgetAudioSocket: @unchecked Sendable {
    enum SocketError: Error { case unavailable, invalidPeer, invalidSignature, invalidContainer }
    enum Policy: Sendable {
        case production
        #if STREAM_NATIVE_VALIDATION
        case prototypeForQualification
        #endif
    }
    struct Principal: Equatable, Sendable { let pid: Int32; let auditToken: Data; let codeHash: Data }
    struct Connection: @unchecked Sendable { let handle: FileHandle; let principal: Principal }
    final class Authority: @unchecked Sendable {
        private struct Identity {
            let executable: URL; let identifier: String; let codeHash: Data
            let team: String?; let entitlements: [String: Any]
        }
        static let group = "group.com.joeblau.Stream", hostIdentifier = "com.joeblau.StreamMac"
        private static let flags = SecCSFlags(rawValue: 0)
        private let expected: Identity, requirement: SecRequirement, root: URL?
        private let production: Bool
        private init(expected: Identity, requirement: SecRequirement, root: URL?, production: Bool) {
            self.expected = expected; self.requirement = requirement; self.root = root; self.production = production
        }
        static func host(helperURL: URL, policy: Policy = .production) throws -> Authority {
            switch policy {
            case .production:
                let own = try validatedSelf(identifier: hostIdentifier)
                let bundle = Bundle.main.bundleURL.resolvingSymlinksInPath()
                let packaged = bundle.appendingPathComponent("Contents/Helpers/StreamBrowserAudioHelper.app").resolvingSymlinksInPath()
                guard packaged.path.hasPrefix(bundle.path + "/Contents/Helpers/"), helperURL.resolvingSymlinksInPath() == packaged else { throw SocketError.invalidSignature }
                let requirement = try signedRequirement(identifier: BrowserWidgetAudioIdentity.helperBundleID, team: own.team!)
                let peer = try staticIdentity(at: packaged, requirement: requirement)
                guard peer.executable.path.hasPrefix(packaged.path + "/"),
                      peer.executable == packaged.appendingPathComponent("Contents/MacOS/StreamBrowserAudioHelper").resolvingSymlinksInPath() else { throw SocketError.invalidSignature }
                try requireSandboxGroup(peer)
                return Authority(expected: peer, requirement: requirement, root: try container(), production: true)
            #if STREAM_NATIVE_VALIDATION
            case .prototypeForQualification: return try prototype(peerURL: helperURL)
            #endif
            }
        }
        static func helper() throws -> Authority {
            let own = try validatedSelf(identifier: BrowserWidgetAudioIdentity.helperBundleID)
            let bundle = Bundle.main.bundleURL.resolvingSymlinksInPath()
            let host = bundle.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            guard bundle == host.appendingPathComponent("Contents/Helpers/StreamBrowserAudioHelper.app") else { throw SocketError.invalidSignature }
            let requirement = try signedRequirement(identifier: hostIdentifier, team: own.team!)
            let peer = try staticIdentity(at: host, requirement: requirement)
            guard peer.executable.path.hasPrefix(host.path + "/"),
                  peer.executable == host.appendingPathComponent("Contents/MacOS/StreamMac").resolvingSymlinksInPath() else { throw SocketError.invalidSignature }
            try requireSandboxGroup(peer)
            return Authority(expected: peer, requirement: requirement, root: try container(), production: true)
        }
        #if STREAM_NATIVE_VALIDATION
        /// Real pinned signature/path checks, never Apple/team/group authorization.
        static func prototype(peerURL: URL) throws -> Authority {
            let peer = try staticIdentity(at: peerURL, requirement: nil)
            let hash = peer.codeHash.map { String(format: "%02x", $0) }.joined()
            return Authority(expected: peer, requirement: try compile("cdhash H\"\(hash)\""), root: nil, production: false)
        }
        #endif
        private static func validatedSelf(identifier: String) throws -> Identity {
            var code: SecCode?
            guard SecCodeCopySelf(flags, &code) == errSecSuccess, let code,
                  SecCodeCheckValidity(code, flags, try compile("anchor apple generic and identifier \"\(identifier)\"")) == errSecSuccess else { throw SocketError.invalidSignature }
            let own = try dynamicIdentity(code)
            guard let team = own.team, team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil,
                  let executable = Bundle.main.executableURL,
                  own.executable == executable.resolvingSymlinksInPath() else { throw SocketError.invalidSignature }
            let requirement = try signedRequirement(identifier: identifier, team: team)
            guard SecCodeCheckValidity(code, flags, requirement) == errSecSuccess else { throw SocketError.invalidSignature }
            _ = try staticIdentity(at: Bundle.main.bundleURL, requirement: requirement)
            try requireSandboxGroup(own)
            return own
        }
        private static func signedRequirement(identifier: String, team: String) throws -> SecRequirement {
            guard team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else { throw SocketError.invalidSignature }
            return try compile("anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\"")
        }
        private static func compile(_ text: String) throws -> SecRequirement {
            var result: SecRequirement?
            guard SecRequirementCreateWithString(text as CFString, flags, &result) == errSecSuccess, let result else { throw SocketError.invalidSignature }
            return result
        }
        private static func requireSandboxGroup(_ identity: Identity) throws {
            guard identity.entitlements["com.apple.security.app-sandbox"] as? Bool == true,
                  (identity.entitlements["com.apple.security.application-groups"] as? [String])?.contains(group) == true,
                  identity.entitlements["com.apple.security.get-task-allow"] as? Bool != true else { throw SocketError.invalidSignature }
        }
        private static func container() throws -> URL {
            guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { throw SocketError.invalidContainer }
            return url.resolvingSymlinksInPath()
        }
        private static func staticIdentity(at url: URL, requirement: SecRequirement?) throws -> Identity {
            var code: SecStaticCode?
            guard SecStaticCodeCreateWithPath(url.resolvingSymlinksInPath() as CFURL, flags, &code) == errSecSuccess, let code,
                  SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else { throw SocketError.invalidSignature }
            return try information(code)
        }
        private static func dynamicIdentity(_ code: SecCode) throws -> Identity {
            var file: SecStaticCode?
            guard SecCodeCopyStaticCode(code, flags, &file) == errSecSuccess, let file else { throw SocketError.invalidSignature }
            return try information(file)
        }
        private static func information(_ code: SecStaticCode) throws -> Identity {
            var values: CFDictionary?
            guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &values) == errSecSuccess,
                  let values = values as? [String: Any], let path = values[kSecCodeInfoMainExecutable as String] as? URL,
                  let identifier = values[kSecCodeInfoIdentifier as String] as? String,
                  let hash = values[kSecCodeInfoUnique as String] as? Data, hash.count == 20 else { throw SocketError.invalidSignature }
            return Identity(executable: path.resolvingSymlinksInPath(), identifier: identifier, codeHash: hash,
                team: values[kSecCodeInfoTeamIdentifier as String] as? String,
                entitlements: values[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:])
        }
        fileprivate func createDirectory() throws -> URL {
            let parent: URL
            if let root { parent = root }
            else {
                #if STREAM_NATIVE_VALIDATION
                guard !production else { throw SocketError.invalidContainer }
                parent = URL(fileURLWithPath: "/tmp", isDirectory: true)
                #else
                throw SocketError.invalidContainer
                #endif
            }
            let directory = parent.appendingPathComponent("bwa-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16), isDirectory: true)
            _ = try BrowserWidgetAudioSocket.address(directory.appendingPathComponent("s").path)
            guard mkdir(directory.path, 0o700) == 0 else { throw SocketError.invalidContainer }
            return directory
        }
        fileprivate func validatePath(_ path: String) throws {
            if let root {
                let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
                guard url.path.hasPrefix(root.path + "/"), url.deletingLastPathComponent().deletingLastPathComponent() == root else { throw SocketError.invalidContainer }
            } else if production { throw SocketError.invalidContainer }
        }
        fileprivate func authenticate(_ descriptor: Int32, expectedPID: Int32) throws -> Principal {
            var uid: uid_t = 0, gid: gid_t = 0, pid: Int32 = 0
            var pidSize = socklen_t(MemoryLayout<Int32>.size), token = audit_token_t()
            var tokenSize = socklen_t(MemoryLayout<audit_token_t>.size)
            guard expectedPID > 0, getpeereid(descriptor, &uid, &gid) == 0, uid == geteuid(),
                  getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &pidSize) == 0, pidSize == MemoryLayout<Int32>.size, pid == expectedPID,
                  getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &tokenSize) == 0, tokenSize == MemoryLayout<audit_token_t>.size else { throw SocketError.invalidPeer }
            let audit = withUnsafeBytes(of: &token) { Data($0) }
            var code: SecCode?
            guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit as String: audit] as CFDictionary, Self.flags, &code) == errSecSuccess,
                  let code, SecCodeCheckValidity(code, Self.flags, requirement) == errSecSuccess else { throw SocketError.invalidSignature }
            let peer = try Self.dynamicIdentity(code)
            guard peer.executable == expected.executable, peer.identifier == expected.identifier,
                  peer.codeHash == expected.codeHash, peer.team == expected.team else { throw SocketError.invalidSignature }
            if production { try Self.requireSandboxGroup(peer) }
            return Principal(pid: pid, auditToken: audit, codeHash: peer.codeHash)
        }
    }
    let path: String
    private let directory: URL, authority: Authority
    private let lock = NSLock()
    private var acceptedPrincipal: Principal?
    var principal: Principal? { lock.withLock { acceptedPrincipal } }
    private var descriptor: Int32 = -1
    init(authority: Authority) throws {
        self.authority = authority; directory = try authority.createDirectory(); path = directory.appendingPathComponent("s").path
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw SocketError.unavailable }
        guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else { Darwin.close(descriptor); descriptor = -1; throw SocketError.unavailable }
        var address = try Self.address(path)
        let status = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard status == 0, chmod(path, 0o600) == 0, listen(descriptor, 1) == 0 else { throw SocketError.unavailable }
    }
    func accept(expectedPID: Int32) async throws -> FileHandle {
        let listening = descriptor, authority = authority
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue(label: "browser-helper.accept").async { [self] in
                var ready = pollfd(fd: listening, events: Int16(POLLIN), revents: 0)
                guard poll(&ready, 1, 5_000) > 0 else { continuation.resume(throwing: SocketError.unavailable); return }
                let peer = Darwin.accept(listening, nil, nil)
                guard peer >= 0 else { continuation.resume(throwing: SocketError.unavailable); return }
                do {
                    guard fcntl(peer, F_SETFD, FD_CLOEXEC) == 0 else { throw SocketError.unavailable }
                    let principal = try authority.authenticate(peer, expectedPID: expectedPID)
                    lock.withLock { acceptedPrincipal = principal }
                    continuation.resume(returning: FileHandle(fileDescriptor: peer, closeOnDealloc: true))
                } catch { Darwin.close(peer); continuation.resume(throwing: error) }
            }
        }
    }
    static func connect(path: String, expectedPID: Int32, authority: Authority) throws -> Connection {
        try authority.validatePath(path)
        var address = try address(path)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw SocketError.unavailable }
        guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else { Darwin.close(descriptor); throw SocketError.unavailable }
        let status = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        do {
            guard status == 0 else { throw SocketError.unavailable }
            let principal = try authority.authenticate(descriptor, expectedPID: expectedPID)
            return Connection(handle: FileHandle(fileDescriptor: descriptor, closeOnDealloc: true), principal: principal)
        } catch { Darwin.close(descriptor); throw error }
    }
    private static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un(); let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw SocketError.unavailable }
        address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }; return address
    }
    deinit { if descriptor >= 0 { Darwin.close(descriptor) }; unlink(path); try? FileManager.default.removeItem(at: directory) }
}
