import Darwin
import Foundation

@main private struct BrowserSocketAuthorityHarness {
    static func main() async throws {
        signal(SIGPIPE, SIG_IGN); setbuf(stdout, nil)
        let args = CommandLine.arguments
        if args.count > 1, args[1] == "child" {
            do {
                let authority = try BrowserWidgetAudioSocket.Authority.prototype(peerURL: URL(fileURLWithPath: args[4]))
                let connection = try BrowserWidgetAudioSocket.connect(path: args[2], expectedPID: Int32(args[3])!, authority: authority)
                try connection.handle.write(contentsOf: Data("authenticated".utf8))
                _ = try connection.handle.read(upToCount: 1); try connection.handle.close()
                exit(0)
            } catch { exit(23) }
        }
        precondition(args.count == 4)
        let peer = URL(fileURLWithPath: args[1]), sameCodeOtherPath = URL(fileURLWithPath: args[2]), otherCode = URL(fileURLWithPath: args[3])
        let host = Bundle.main.executableURL!.resolvingSymlinksInPath()
        let group = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Group Containers/" + BrowserWidgetAudioSocket.Authority.group)
        let groupExisted = FileManager.default.fileExists(atPath: group.path)
        do { _ = try BrowserWidgetAudioSocket.Authority.host(helperURL: peer); preconditionFailure("Ad hoc process gained production authority") }
        catch BrowserWidgetAudioSocket.SocketError.invalidSignature {}
        precondition(FileManager.default.fileExists(atPath: group.path) == groupExisted)
        print("PASS default production rejects ad hoc self before group access; no profile/container created")

        func exchange(_ label: String, expectedCode: URL, expectedPIDOffset: Int32 = 0,
                      clientHost: URL? = nil, clientPIDOffset: Int32 = 0, accepted: Bool?, clientAccepted: Bool = true) async throws {
            let authority = try BrowserWidgetAudioSocket.Authority.prototype(peerURL: expectedCode)
            let listener = try BrowserWidgetAudioSocket(authority: authority)
            let process = Process(); process.executableURL = peer
            process.arguments = ["child", listener.path, String(getpid() + clientPIDOffset), (clientHost ?? host).path]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run()
            var received = Data(), didAccept = false
            do {
                let handle = try await listener.accept(expectedPID: process.processIdentifier + expectedPIDOffset)
                didAccept = true
                while received.count < 13 {
                    let bytes = try handle.read(upToCount: 13 - received.count) ?? Data()
                    if bytes.isEmpty { break }; received.append(bytes)
                }
                if !received.isEmpty { try handle.write(contentsOf: Data([1])) }
                try handle.close()
            } catch {}
            process.waitUntilExit()
            if let accepted { precondition(didAccept == accepted, "Wrong server outcome: \(label)") }
            if accepted == true || !clientAccepted { precondition((process.terminationStatus == 0) == clientAccepted, "Wrong client outcome: \(label)") }
            precondition(received == (accepted == true && clientAccepted ? Data("authenticated".utf8) : Data()), "Content crossed refused peer: \(label)")
            if didAccept { precondition(listener.principal?.pid == process.processIdentifier && listener.principal?.auditToken.count == MemoryLayout<audit_token_t>.size) }
            print("PASS \(label): kernel socket + live SecCode; server=\(didAccept), client=\(process.terminationStatus)")
        }
        try await exchange("bidirectional exact PID/code/hash/path", expectedCode: peer, accepted: true)
        try await exchange("server rejects wrong PID", expectedCode: peer, expectedPIDOffset: 1, accepted: false)
        try await exchange("server rejects same signed bytes at wrong expected path", expectedCode: sameCodeOtherPath, accepted: false)
        try await exchange("server rejects different identifier/hash", expectedCode: otherCode, accepted: false)
        try await exchange("client rejects wrong host PID", expectedCode: peer, clientPIDOffset: 1, accepted: nil, clientAccepted: false)
        try await exchange("client rejects same signed host bytes at wrong expected path", expectedCode: peer, clientHost: URL(fileURLWithPath: host.path + ".copy"), accepted: nil, clientAccepted: false)
        let mutable = peer.deletingLastPathComponent().appendingPathComponent("peer.mutable")
        let pinned = try BrowserWidgetAudioSocket.Authority.prototype(peerURL: mutable)
        let resign = Process(); resign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        resign.arguments = ["--force", "--sign", "-", "--identifier", "com.joeblau.OwnedReplacedPeer", mutable.path]
        resign.standardOutput = FileHandle.nullDevice; resign.standardError = FileHandle.nullDevice
        try resign.run(); resign.waitUntilExit(); precondition(resign.terminationStatus == 0)
        let changed = try BrowserWidgetAudioSocket(authority: pinned)
        let replacement = Process(); replacement.executableURL = mutable
        replacement.arguments = ["child", changed.path, String(getpid()), host.path]
        replacement.standardOutput = FileHandle.nullDevice; replacement.standardError = FileHandle.nullDevice; try replacement.run()
        do { _ = try await changed.accept(expectedPID: replacement.processIdentifier); preconditionFailure("Re-signed replacement passed pinned code authority") }
        catch BrowserWidgetAudioSocket.SocketError.invalidSignature {}
        replacement.waitUntilExit()
        print("PASS same-path re-sign after authority snapshot is rejected by the live code requirement")
        // Separate processes with the same executable cannot impersonate one helper incarnation on channel two.
        let authority = try BrowserWidgetAudioSocket.Authority.prototype(peerURL: peer)
        let one = try BrowserWidgetAudioSocket(authority: authority), two = try BrowserWidgetAudioSocket(authority: authority)
        let first = Process(), second = Process()
        for (process, listener) in [(first, one), (second, two)] {
            process.executableURL = peer; process.arguments = ["child", listener.path, String(getpid()), host.path]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice; try process.run()
        }
        let firstHandle = try await one.accept(expectedPID: first.processIdentifier)
        _ = try firstHandle.read(upToCount: 13); try firstHandle.write(contentsOf: Data([1])); try firstHandle.close()
        do { _ = try await two.accept(expectedPID: first.processIdentifier); preconditionFailure("Different process impersonated frame peer") } catch BrowserWidgetAudioSocket.SocketError.invalidPeer {}
        first.waitUntilExit(); second.waitUntilExit()
        print("PASS channel two rejects a different kernel principal even with identical signed executable")
        precondition(!BrowserWidgetAudioIdentity.productionRouteQualified)
        print("PASS prototype identity proof only; production shared-group/sandbox and real browser audio remain unqualified")
    }
}
