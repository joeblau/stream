import CoreMIDI
import Darwin
import Foundation

@MainActor enum DesktopStorage { static let projectDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("stream-controller-harness-unused") }
private func require(_ value: Bool, _ message: String) {
    if !value { FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8)); exit(1) }
}
private func expectRejected(_ work: () throws -> Void) {
    do { try work(); fatalError("Expected rejection") } catch {}
}
private final class MIDIWords: @unchecked Sendable {
    private let lock = NSLock()
    private var words: [UInt32] = []
    func append(_ list: UnsafePointer<MIDIEventList>) {
        let packets = UnsafeRawPointer(list).advanced(by: MemoryLayout<MIDIEventList>.offset(of: \MIDIEventList.packet)!).assumingMemoryBound(to: MIDIEventPacket.self)
        let values = UnsafeRawPointer(packets).advanced(by: MemoryLayout<MIDIEventPacket>.offset(of: \MIDIEventPacket.words)!).assumingMemoryBound(to: UInt32.self)
        lock.lock(); words.append(contentsOf: UnsafeBufferPointer(start: values, count: Int(packets.pointee.wordCount))); lock.unlock()
    }
    func snapshot() -> [UInt32] { lock.lock(); defer { lock.unlock() }; return words }
}
private final class UDP {
    private(set) var fd: Int32
    let port: UInt16
    init() {
        let socketID = socket(AF_INET, SOCK_DGRAM, 0)
        require(socketID >= 0, "UDP socket")
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socketID, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        require(bound == 0, "UDP bind")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(socketID, $0, &length) } }
        fd = socketID
        port = UInt16(bigEndian: address.sin_port)
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
    }
    func send(_ data: Data, port: UInt16) {
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1"); address.sin_port = port.bigEndian
        let sent = data.withUnsafeBytes { bytes in withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } }
        require(sent == data.count, "UDP send")
    }
    func read() -> Data? {
        var bytes = [UInt8](repeating: 0, count: 8192)
        let count = recv(fd, &bytes, bytes.count, 0)
        return count > 0 ? Data(bytes.prefix(count)) : nil
    }
    func release() { if fd >= 0 { close(fd); fd = -1 } }
    deinit { if fd >= 0 { close(fd) } }
}
@MainActor private final class HarnessState {
    var title = "First scene", exists = true, available = true, commands = 0, gain = 0.5, valueCalls = 0
    var runningMacro: UUID?, cancelled = 0
}
@main struct ControllerHarness {
    nonisolated static func notificationBlock() -> MIDINotifyBlock { { _ in } }
    nonisolated private static func feedbackBlock(_ words: MIDIWords) -> MIDIReceiveBlock { { list, _ in words.append(list) } }
    @MainActor static func wait(_ milliseconds: Int = 200) async { try? await Task.sleep(for: .milliseconds(milliseconds)) }
    static func bundle(_ elements: [Data], time: UInt64 = 1) -> Data {
        var data = Data("#bundle\0".utf8), stamp = time.bigEndian
        withUnsafeBytes(of: &stamp) { data.append(contentsOf: $0) }
        for element in elements { var count = UInt32(element.count).bigEndian; withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }; data.append(element) }
        return data
    }
    static func deliver(_ endpoint: MIDIEndpointRef, _ words: [UInt32]) {
        let bytes = 4096
        let storage = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: MemoryLayout<MIDIEventList>.alignment)
        defer { storage.deallocate() }
        let list = storage.bindMemory(to: MIDIEventList.self, capacity: 1)
        let first = MIDIEventListInit(list, ._1_0)
        words.withUnsafeBufferPointer { _ = MIDIEventListAdd(list, bytes, first, 0, $0.count, $0.baseAddress!) }
        require(MIDIReceivedEventList(endpoint, list) == noErr, "Virtual MIDI send")
    }
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stream-controllers-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "stream.controller.harness.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let url = root.appendingPathComponent("mappings.json")
        let manager = StudioControllerManager(url: url, defaults: defaults)
        require(!manager.midiEnabled && !manager.oscEnabled, "New inputs disabled")
        let state = HarnessState()
        manager.targets = {
            guard state.exists else { return [] }
            return [.init(id: "scene.stable.select", title: state.title, kind: .command, normalizedValue: state.commands > 0 ? 1 : 0, unavailableReason: state.available ? nil : "Locked", execute: { _ in state.commands += 1; return nil }),
                    .init(id: "audio.microphone.gain", title: "Microphone", kind: .value, normalizedValue: state.gain, unavailableReason: nil, execute: { value in state.gain = value!; state.valueCalls += 1; return nil })]
        }
        require(manager.add(.init(input: .osc("/take"), targetID: "scene.stable.select", kind: .command)), "OSC map")
        require(manager.add(.init(input: .osc("/gain"), targetID: "audio.microphone.gain", kind: .value)), "OSC value map")
        require(manager.add(.init(input: .osc("/take-second"), targetID: "scene.stable.select", kind: .command)), "Multiple target bindings")
        require(!manager.add(.init(input: .osc("/take"), targetID: "other", kind: .command)), "Duplicate input conflict")
        require(!manager.add(.init(input: .osc("/_stream/feedback/echo"), targetID: "other", kind: .command)), "Feedback namespace input forbidden")
        let packet = StudioOSC.encode(address: "/gain", value: 0.75)
        require(try StudioOSC.decode(packet) == [.init(address: "/gain", value: 0.75)], "OSC float round trip")
        expectRejected { _ = try StudioOSC.decode(bundle([packet], time: 2)) }
        expectRejected { _ = try StudioOSC.decode(bundle([packet, Data(repeating: 1, count: 8)])) }
        expectRejected { _ = try StudioOSC.decode(StudioOSC.encode(address: "/gain", value: .nan)) }
        expectRejected { _ = try StudioOSC.decode(Data(repeating: 0, count: 4100)) }
        expectRejected { _ = try StudioOSC.decode(StudioOSC.encode(address: "/g*", value: 1)) }
        expectRejected { _ = try StudioOSC.decode(bundle(Array(repeating: packet, count: 33))) }
        var deep = packet
        for _ in 0..<6 { deep = bundle([deep]) }
        expectRejected { _ = try StudioOSC.decode(deep) }
        require(StudioMIDIEvent.decode(words: [0x30100000, 0x20903C7F, 0x20B0077F], sourceID: 3).count == 1, "SysEx payload does not become a note")
        let feedback = UDP(), sender = UDP(), vacant = UDP(); let oscPort = vacant.port
        // The vacant socket reserves the test port; close it before NWListener binds.
        vacant.release()
        manager.configureOSC(port: oscPort, feedbackPort: feedback.port); manager.setOSCEnabled(true); manager.start()
        await wait()
        require(manager.osc.listeningPort == oscPort, "Real loopback listener ready")
        sender.send(StudioOSC.encode(address: "/take", value: 1), port: oscPort); await wait()
        require(state.commands == 1, "OSC command wire dispatch")
        sender.send(StudioOSC.encode(address: "/take", value: 1), port: oscPort); await wait()
        require(state.commands == 1, "Held command suppressed")
        state.title = "Renamed scene"
        sender.send(bundle([StudioOSC.encode(address: "/take", value: 0), StudioOSC.encode(address: "/take", value: 1)]), port: oscPort); await wait()
        require(state.commands == 2, "Rename preserves stable target")
        state.available = false
        sender.send(bundle([StudioOSC.encode(address: "/take", value: 0), StudioOSC.encode(address: "/take", value: 1)]), port: oscPort); await wait()
        require(state.commands == 2, "Fresh availability enforced")
        state.available = true; state.exists = false
        sender.send(StudioOSC.encode(address: "/take-second", value: 1), port: oscPort); await wait()
        require(state.commands == 2 && manager.document.mappings.count == 3, "Deleted target retained and rejected")
        state.exists = true
        sender.send(bundle([StudioOSC.encode(address: "/gain", value: 0.2), StudioOSC.encode(address: "/gain", value: 0.8)]), port: oscPort); await wait()
        require(abs(state.gain - 0.8) < 0.00001 && state.valueCalls == 1, "Numeric coalescing authoritative value")
        sender.send(bundle([StudioOSC.encode(address: "/take-second", value: 0), StudioOSC.encode(address: "/take-second", value: 1), StudioOSC.encode(address: "/gain", value: 3)]), port: oscPort); await wait()
        require(state.commands == 2 && state.valueCalls == 1, "Out-of-range bundle performs no work")
        sender.send(bundle([StudioOSC.encode(address: "/take", value: 0), Data(repeating: 1, count: 8)]), port: oscPort); await wait()
        require(state.commands == 2, "Malformed packet performs no work")
        var sawFeedback = false
        while let data = feedback.read() {
            let messages = try StudioOSC.decode(data)
            require(messages.allSatisfy { $0.address.hasPrefix("/_stream/feedback/") }, "Feedback reserved namespace")
            sender.send(data, port: oscPort); sawFeedback = true
        }
        await wait(); require(sawFeedback && state.commands == 2, "OSC feedback echo cannot execute")
        manager.setOSCEnabled(false); sender.send(StudioOSC.encode(address: "/take", value: 1), port: oscPort); await wait()
        require(state.commands == 2, "Disabled OSC input ignored")
        manager.setOSCEnabled(true); await wait()
        sender.send(StudioOSC.encode(address: "/take", value: 1), port: oscPort); await wait()
        require(state.commands == 3, "Reconnected OSC starts with clean edge state")

        var client = MIDIClientRef(), source = MIDIEndpointRef(), destination = MIDIEndpointRef()
        require(MIDIClientCreateWithBlock("Stream Controller Harness" as CFString, &client, notificationBlock()) == noErr, "Native MIDI client")
        defer { MIDIClientDispose(client) }
        let midiID = Int32.random(in: 100_000_000..<200_000_000), destID = midiID + 1
        require(MIDISourceCreateWithProtocol(client, "Harness Source" as CFString, ._1_0, &source) == noErr, "Virtual MIDI source")
        require(MIDIObjectSetIntegerProperty(source, kMIDIPropertyUniqueID, midiID) == noErr, "Stable MIDI identity")
        let feedbackWords = MIDIWords()
        require(MIDIDestinationCreateWithProtocol(client, "Harness Feedback" as CFString, ._1_0, &destination, feedbackBlock(feedbackWords)) == noErr, "Virtual feedback destination")
        require(MIDIObjectSetIntegerProperty(destination, kMIDIPropertyUniqueID, destID) == noErr, "Feedback identity")
        manager.configureMIDI(source: midiID, destination: 0, feedbackChannel: 15)
        manager.learn(targetID: "scene.stable.select", kind: .command)
        deliver(source, [0x20903C7F]); await wait()
        require(manager.document.mappings.count == 4 && state.commands == 3 && !manager.midiEnabled, "Native MIDI learn is exclusive and does not enable input")
        manager.learn(targetID: "audio.microphone.gain", kind: .value)
        deliver(source, [0x20903D7F]); await wait()
        require(manager.learningTarget != nil, "Numeric learn ignores notes")
        deliver(source, [0x20B0077F]); await wait()
        require(manager.document.mappings.count == 5, "Native CC learn")
        manager.configureMIDI(source: midiID, destination: destID, feedbackChannel: 15); manager.setMIDIEnabled(true)
        var unrelatedSource = MIDIEndpointRef()
        require(MIDISourceCreateWithProtocol(client, "Unselected Harness Source" as CFString, ._1_0, &unrelatedSource) == noErr, "Unselected source")
        deliver(unrelatedSource, [0x20903C7F]); await wait(); require(state.commands == 3, "Only explicitly selected source executes")
        deliver(source, [0x20903C7F, 0x20903C7F]); await wait()
        require(state.commands == 4, "Native MIDI held note fires once")
        deliver(source, [0x20803C00, 0x20903C7F]); await wait()
        require(state.commands == 5, "Native note release resets edge")
        deliver(source, [0x20B00700]); await wait()
        require(state.gain == 0, "MIDI CC lower bound")
        deliver(source, [0x20B0077F]); await wait()
        require(state.gain == 1, "MIDI CC upper bound")
        let previousValueCalls = state.valueCalls
        deliver(source, [0x20B0077F]); await wait(); require(state.valueCalls == previousValueCalls, "Authoritative numeric value prevents redundant dispatch")
        require(feedbackWords.snapshot().contains(where: { ($0 >> 16) & 15 == 15 }), "Real MIDI feedback on isolated channel")
        deliver(source, feedbackWords.snapshot()); await wait()
        require(state.commands == 5 && state.gain == 1, "MIDI feedback echo cannot execute")
        MIDIEndpointDispose(source); manager.refreshEndpoints(); require(manager.midiStatus.contains("Disconnected"), "Native MIDI disconnect state")
        require(MIDISourceCreateWithProtocol(client, "Renamed Harness Source" as CFString, ._1_0, &source) == noErr, "Recreated source")
        require(MIDIObjectSetIntegerProperty(source, kMIDIPropertyUniqueID, midiID) == noErr, "Same identity reconnect")
        manager.refreshEndpoints(); deliver(source, [0x20903C7F]); await wait()
        require(state.commands == 6 && manager.midiStatus.contains("Connected"), "Stable MIDI reconnect and clean edge")

        manager.currentRunID = { state.runningMacro }
        manager.cancelRun = { id in if state.runningMacro == id { state.cancelled += 1; state.runningMacro = nil } }
        manager.targets = { [.init(id: "scene.stable.select", title: state.title, kind: .command, normalizedValue: 1, unavailableReason: nil, execute: { _ in state.runningMacro = UUID(); return nil })] }
        deliver(source, [0x20803C00, 0x20903C7F]); await wait()
        require(state.runningMacro != nil, "Controller-owned macro started")
        MIDIEndpointDispose(source); manager.refreshEndpoints()
        require(state.cancelled == 1 && state.runningMacro == nil, "Disconnect cancels controller-owned macro")
        manager.targets = { [.init(id: "scene.stable.select", title: state.title, kind: .command, normalizedValue: 1, unavailableReason: nil, execute: { _ in state.commands += 1; return nil })] }
        manager.interactionBlocked = { true }
        manager.receiveMIDI([.init(address: .init(sourceID: midiID, channel: 0, kind: .note, number: 60), value: 127)]); await wait(); require(state.commands == 6, "Interaction gate")
        manager.interactionBlocked = { false }
        manager.scopeIsCurrent = { false }
        manager.receiveMIDI([.init(address: .init(sourceID: midiID, channel: 0, kind: .note, number: 60), value: 127)]); await wait(); require(state.commands == 6, "Late input cannot cross project switch")
        manager.shutdown()
        let restored = StudioControllerManager(url: url, defaults: UserDefaults(suiteName: suite + ".fresh")!)
        require(restored.document.mappings == manager.document.mappings && !restored.midiEnabled && !restored.oscEnabled, "Project export cannot arm another machine")
        let future = root.appendingPathComponent("future.json"), data = Data("{\"version\":2,\"mappings\":[]}".utf8)
        try data.write(to: future)
        let blocked = StudioControllerManager(url: future, defaults: defaults)
        require(blocked.persistenceBlocked && !blocked.add(.init(input: .osc("/x"), targetID: "studio.take", kind: .command)), "Future project mapping fails closed")
        require(try Data(contentsOf: future) == data, "Future mappings preserved")
        print("PASS: controller mapping model, bounded OSC parser, real loopback UDP, virtual CoreMIDI learn/feedback/disconnect/reconnect, scope and disabled defaults")
    }
}
