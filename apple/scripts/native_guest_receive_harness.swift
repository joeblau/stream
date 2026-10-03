import AVFoundation
import Foundation

private final class GuestSignalBridge: @unchecked Sendable {
    let lock = NSLock()
    weak var receiver: NativeGuestReceiver?
    var peer: OpaquePointer?
    var failed = false
    func hasFailed() -> Bool { lock.lock(); defer { lock.unlock() }; return failed }
    func incoming(_ type: String, _ value: String, _ mid: String) {
        if type == "offer" { if receiver?.offer(value) != true { lock.lock(); failed = true; lock.unlock() } }
        else if type == "candidate" { if receiver?.candidate(value, mid: mid) != true { lock.lock(); failed = true; lock.unlock() } }
    }
    func outgoing(_ type: String, _ value: String, _ mid: String) {
        lock.lock(); let peer = peer; lock.unlock()
        if SGPeerFixtureSignal(peer, type, value, mid) == 0 { lock.lock(); failed = true; lock.unlock() }
    }
}
private func guestFixtureSignal(_ context: UnsafeMutableRawPointer?, _ type: UnsafePointer<CChar>?, _ value: UnsafePointer<CChar>?, _ mid: UnsafePointer<CChar>?) {
    guard let context, let type, let value, let mid else { return }
    Unmanaged<GuestSignalBridge>.fromOpaque(context).takeUnretainedValue().incoming(String(cString: type), String(cString: value), String(cString: mid))
}
private final class GuestReceipts: @unchecked Sendable {
    struct Video { let role: GuestReceiveRole, pts: Double, r: Int, g: Int, b: Int }
    struct Audio { let pts: Double, frames: Int, rms: Double, rightRMS: Double, cuePTS: Double? }
    let lock = NSLock()
    var video: [Video] = [], audio: [Audio] = []
    func receive(_ frame: GuestVideoFrame) {
        let p = frame.pixels; CVPixelBufferLockBaseAddress(p, .readOnly); defer { CVPixelBufferUnlockBaseAddress(p, .readOnly) }
        precondition(CVPixelBufferGetWidth(p) == 320 && CVPixelBufferGetHeight(p) == 180)
        let bytes = CVPixelBufferGetBaseAddress(p)!.assumingMemoryBound(to: UInt8.self)
        let sample = CVPixelBufferGetBytesPerRow(p) * 90 + 4 * 160
        lock.lock(); video.append(.init(role: frame.role, pts: frame.pts.seconds, r: Int(bytes[sample + 2]), g: Int(bytes[sample + 1]), b: Int(bytes[sample]))); lock.unlock()
    }
    func receive(_ frame: GuestAudioFrame) {
        precondition(frame.pcm.format.sampleRate == 48_000 && frame.pcm.format.channelCount == 2)
        let n = Int(frame.pcm.frameLength), values = frame.pcm.floatChannelData![0]
        let rms = sqrt((0..<n).reduce(0.0) { $0 + Double(values[$1] * values[$1]) } / Double(n))
        let right = frame.pcm.floatChannelData![1]
        let rightRMS = sqrt((0..<n).reduce(0.0) { $0 + Double(right[$1] * right[$1]) } / Double(n))
        let cue = (0..<n).first { abs(values[$0]) > 0.025 }.map { frame.pts.seconds + Double($0) / 48_000 }
        precondition(frame.duration.value == Int64(n) && frame.duration.timescale == 48_000)
        lock.lock(); audio.append(.init(pts: frame.pts.seconds, frames: n, rms: rms, rightRMS: rightRMS, cuePTS: cue)); lock.unlock()
    }
    func snapshot() -> ([Video], [Audio]) { lock.lock(); defer { lock.unlock() }; return (video, audio) }
}
@main struct NativeGuestReceiveHarness {
    static func print(_ message: String) { FileHandle.standardOutput.write(Data((message + "\n").utf8)) }
    static func be32(_ n: UInt32) -> [UInt8] { [UInt8(truncatingIfNeeded: n >> 24), UInt8(truncatingIfNeeded: n >> 16), UInt8(truncatingIfNeeded: n >> 8), UInt8(truncatingIfNeeded: n)] }
    static func packet(role: Int32, sequence: UInt16, timestamp: UInt32, payload: [UInt8], marker: Bool, decorated: Bool = true) -> Data {
        let pt: UInt8 = role == 2 ? 111 : 96
        var bytes: [UInt8] = [decorated ? 0xb1 : 0x80, pt | (marker ? 128 : 0), UInt8(sequence >> 8), UInt8(truncatingIfNeeded: sequence)]
        bytes += be32(timestamp) + be32(1001 + UInt32(role))
        if decorated { bytes += [0, 0, 0, 7, 0xbe, 0xde, 0, 1, 0x10, 0xaa, 0, 0] }
        bytes += payload
        if decorated { bytes += [0, 0, 0, 4] }
        return Data(bytes)
    }
    static func send(_ data: Data, role: Int32, peer: OpaquePointer) {
        let sent = data.withUnsafeBytes { SGPeerFixtureSend(peer, role, $0.bindMemory(to: UInt8.self).baseAddress!, $0.count) }
        if sent == 0 { print("Guest fixture rejected send role=\(role) bytes=\(data.count) sequence=\(data.count >= 4 ? Int(data[2]) * 256 + Int(data[3]) : -1)") }
        precondition(sent != 0, "Actual peer transport rejected a fixture packet")
    }
    static func sr(_ role: Int32, rtp: UInt32, seconds: Double, peer: OpaquePointer) {
        let whole = UInt32(seconds), fraction = UInt32((seconds - Double(whole)) * 4_294_967_296)
        let bytes: [UInt8] = [128, 200, 0, 6] + be32(1001 + UInt32(role)) + be32(whole) + be32(fraction) + be32(rtp) + be32(0) + be32(0)
        send(Data(bytes), role: role, peer: peer)
    }
    static func frames(_ data: Data) -> [[[UInt8]]] {
        let bytes = [UInt8](data); var starts: [(Int, Int)] = [], index = 0
        while index + 3 <= bytes.count {
            if bytes[index] == 0 && bytes[index + 1] == 0 {
                if bytes[index + 2] == 1 { starts.append((index, 3)); index += 3; continue }
                if index + 4 <= bytes.count && bytes[index + 2] == 0 && bytes[index + 3] == 1 { starts.append((index, 4)); index += 4; continue }
            }; index += 1
        }
        var frames: [[[UInt8]]] = [], current: [[UInt8]] = []
        for (i, start) in starts.enumerated() {
            let end = i + 1 < starts.count ? starts[i + 1].0 : bytes.count
            let nal = Array(bytes[(start.0 + start.1)..<end]); if nal.isEmpty { continue }
            if nal[0] & 31 == 9, !current.isEmpty { frames.append(current); current = [] }
            current.append(nal)
        }
        if !current.isEmpty { frames.append(current) }; return frames
    }
    static func video(_ frame: [[UInt8]], role: Int32, timestamp: UInt32, sequence: inout UInt16, peer: OpaquePointer) {
        for (index, nal) in frame.enumerated() {
            let last = index == frame.count - 1
            if nal.count <= 240 {
                send(packet(role: role, sequence: sequence, timestamp: timestamp, payload: nal, marker: last), role: role, peer: peer); sequence &+= 1
            } else {
                var position = 1
                while position < nal.count {
                    let end = min(nal.count, position + 240)
                    let payload = [nal[0] & 0xe0 | 28, (nal[0] & 31) | (position == 1 ? 128 : 0) | (end == nal.count ? 64 : 0)] + Array(nal[position..<end])
                    send(packet(role: role, sequence: sequence, timestamp: timestamp, payload: payload, marker: last && end == nal.count), role: role, peer: peer); sequence &+= 1; position = end
                }
            }
        }
    }
    @MainActor static func wait(_ predicate: () -> Bool) async {
        for _ in 0..<1000 { if predicate() { return }; try? await Task.sleep(for: .milliseconds(10)) }
        preconditionFailure("Bounded peer/decode deadline")
    }
    static func main() async throws {
        let folder = URL(fileURLWithPath: CommandLine.arguments[1]), receipts = GuestReceipts(), bridge = GuestSignalBridge()
        let lease = GuestReceiveLease(slot: UUID(), peerID: UUID(), negotiation: UUID(), generation: 7)
        let receiver = try NativeGuestReceiver(admitted: lease, cameraMID: "camera-mid", screenMID: "screen-mid", audioMID: "audio-mid",
            video: { receipts.receive($0) }, audio: { receipts.receive($0) }, signal: { bridge.outgoing($0, $1, $2) })
        bridge.receiver = receiver
        let peer = SGPeerFixtureCreate(guestFixtureSignal, Unmanaged.passUnretained(bridge).toOpaque())!
        bridge.peer = peer
        defer { receiver.stop(); SGPeerFixtureDestroy(peer) }
        precondition(SGPeerFixtureStart(peer) != 0)
        await wait { SGPeerFixtureReady(peer) != 0 }
        precondition(!bridge.hasFailed())
        print("Guest receive: actual public SDK peer DTLS/SRTP connected")
        let camera = frames(try Data(contentsOf: folder.appendingPathComponent("camera.h264")))
        let screen = frames(try Data(contentsOf: folder.appendingPathComponent("screen.h264")))
        precondition(camera.count == 14 && screen.count == 14)
        let cameraBase: UInt32 = 0xffff_e000, screenBase: UInt32 = 123_000_000, audioBase: UInt32 = 0xffff_a000
        sr(0, rtp: cameraBase, seconds: 4_000_000_000, peer: peer)
        try await Task.sleep(for: .milliseconds(80))
        sr(2, rtp: audioBase, seconds: 4_000_000_000, peer: peer)
        try await Task.sleep(for: .milliseconds(80))
        sr(1, rtp: screenBase, seconds: 4_000_000_000.3, peer: peer)
        try await Task.sleep(for: .milliseconds(20))
        var cameraSequence: UInt16 = 65_534, screenSequence: UInt16 = 2, audioSequence: UInt16 = 65_534
        for tick in 0..<70 {
            let opus = try Data(contentsOf: folder.appendingPathComponent(String(format: "opus-%03d.bin", tick)))
            send(packet(role: 2, sequence: audioSequence, timestamp: audioBase &+ UInt32(tick * 960), payload: [UInt8](opus), marker: true), role: 2, peer: peer); audioSequence &+= 1
            if tick % 5 == 0 {
                let index = tick / 5
                video(camera[index], role: 0, timestamp: cameraBase &+ UInt32(index * 9000), sequence: &cameraSequence, peer: peer)
                video(screen[index], role: 1, timestamp: screenBase &+ UInt32(index * 9000), sequence: &screenSequence, peer: peer)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        await wait { let (v, a) = receipts.snapshot(); return v.count == 28 && a.reduce(0) { $0 + $1.frames } >= 67_080 || receiver.counters.errors > 0 }
        await receiver.finishAudio()
        let (v, a) = receipts.snapshot()
        print("Guest decode counts video=\(v.count) audio=\(a.count) errors=\(receiver.counters.errors) dropped=\(receiver.counters.dropped) unsynchronized=\(receiver.counters.unsynchronized)")
        print("Guest PCM samples=\(a.reduce(0) { $0 + $1.frames }); first tone offset=\((a.first { $0.rms > 0.025 }?.pts ?? 0) - (v.first { $0.role == .camera }?.pts ?? 0))s")
        precondition(receiver.counters.errors == 0 && v.count == 28)
        let cameras = v.filter { $0.role == .camera }, screens = v.filter { $0.role == .screen }
        precondition(cameras.count == 14 && screens.count == 14 && cameras[0].r > 200 && cameras[0].b < 30 && screens[0].b > 200 && screens[0].r < 30)
        precondition(a.reduce(0) { $0 + $1.frames } == 67_200)
        precondition(abs(a[0].pts - cameras[0].pts) <= 0.00001)
        let flash = cameras.first { $0.r > 200 && $0.g > 200 && $0.b > 200 }!, tone = a.first { $0.rms > 0.025 }!
        let av = tone.pts - flash.pts, roleOffset = screens[0].pts - cameras[0].pts
        print("Guest decoded cue AV delta=\(av)s screen camera offset=\(roleOffset)s; 320x180 H264 pixels + 48k stereo Opus PCM")
        precondition(abs(av) <= 0.025 && abs(roleOffset - 0.3) <= 0.00001)
        struct Reference: Decodable { let frames: Int, cueFrame: Int }
        let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: folder.appendingPathComponent("opus-reference.json")))
        let actualCue = a.compactMap(\.cuePTS).first! - a[0].pts
        precondition(a.reduce(0) { $0 + $1.frames } == reference.frames && abs(actualCue - Double(reference.cueFrame) / 48_000) < 1.0 / 48_000)
        print("Guest raw Opus reference sample count/cue matches: \(reference.frames) frames cue=\(reference.cueFrame)/48000 PASS")
        for role in [GuestReceiveRole.camera, .screen, .audio] {
            let stats = receiver.transportStats(role)
            precondition(stats.frames == (role == .audio ? 70 : 14) && stats.pending_bytes == 0 && stats.pending_packets == 0 && stats.rejected == 0)
        }
        // Real encrypted transport reaches the actual guard with malformed RTP
        // and duplicate/reordered Opus. Rejected packets cannot produce PCM.
        let countsBefore = receipts.snapshot()
        let lastOpus = try Data(contentsOf: folder.appendingPathComponent("opus-069.bin"))
        for timestamp in [audioBase &+ 69 * 960, audioBase &+ 68 * 960] {
            send(packet(role: 2, sequence: audioSequence, timestamp: timestamp, payload: [UInt8](lastOpus), marker: true), role: 2, peer: peer); audioSequence &+= 1
        }
        var badExtension = packet(role: 0, sequence: cameraSequence, timestamp: cameraBase &+ 126_000, payload: [0x65, 1, 2], marker: true)
        badExtension[18] = 0xff; badExtension[19] = 0xff
        precondition(receiver.validationPacket(badExtension, role: .camera))
        cameraSequence &+= 1
        var badPadding = packet(role: 0, sequence: cameraSequence, timestamp: cameraBase &+ 126_000, payload: [0x65, 1, 2], marker: true)
        badPadding[badPadding.count - 1] = 255
        precondition(receiver.validationPacket(badPadding, role: .camera))
        cameraSequence &+= 1
        await wait { receiver.transportStats(.audio).rejected == 2 && receiver.transportStats(.camera).rejected == 2 }
        let countsAfter = receipts.snapshot(); precondition(countsBefore.0.count == countsAfter.0.count && countsBefore.1.count == countsAfter.1.count)
        // An unfinished FU expires without the pinned SDK retaining any of it.
        send(packet(role: 0, sequence: cameraSequence, timestamp: cameraBase &+ 126_000, payload: [0x7c, 0x85, 1, 2], marker: false), role: 0, peer: peer); cameraSequence &+= 1
        await wait { receiver.transportStats(.camera).pending_packets == 1 }
        try await Task.sleep(for: .milliseconds(350))
        precondition(receiver.transportStats(.camera).pending_packets == 0 && receiver.transportStats(.camera).pending_bytes == 0)
        // FU-A continuation may not change the NAL's type/NRI.
        send(packet(role: 0, sequence: cameraSequence, timestamp: cameraBase &+ 135_000, payload: [0x7c, 0x85, 1, 2], marker: false), role: 0, peer: peer); cameraSequence &+= 1
        send(packet(role: 0, sequence: cameraSequence, timestamp: cameraBase &+ 135_000, payload: [0x5c, 0x45, 1, 2], marker: true), role: 0, peer: peer); cameraSequence &+= 1
        await wait { receiver.transportStats(.camera).rejected == 3 }
        // Loss recovery emits a complete real IDR after the malformed AU.
        sr(0, rtp: cameraBase &+ 135_000, seconds: 4_000_000_001.5, peer: peer)
        video(camera[0], role: 0, timestamp: cameraBase &+ 135_000, sequence: &cameraSequence, peer: peer)
        await wait { receipts.snapshot().0.count == countsBefore.0.count + 1 }
        let hugeFU = [UInt8](repeating: 1, count: 4000)
        for index in 0..<512 {
            let payload = [UInt8(0x7c), UInt8(index == 0 ? 0x85 : 0x05)] + hugeFU
            precondition(receiver.validationPacket(packet(role: 0, sequence: UInt16(index), timestamp: cameraBase &+ 144_000, payload: payload, marker: false, decorated: false), role: .camera))
        }
        let full = receiver.transportStats(.camera)
        precondition(full.pending_packets == 512 && full.pending_bytes <= 2_097_152 && full.peak_bytes <= 2_097_152)
        precondition(receiver.validationPacket(packet(role: 0, sequence: 512, timestamp: cameraBase &+ 144_000, payload: [0x7c, 0x05, 1], marker: false, decorated: false), role: .camera))
        let capped = receiver.transportStats(.camera)
        precondition(capped.pending_packets == 0 && capped.pending_bytes == 0 && capped.rejected == 4)
        print("Guest receive: actual guard512-packet/2MiB AU cap clears stalled assembly PASS")
        print("Guest receive: actual transported duplicate/reordered timestamps/FU identity/IDR recovery; actual guard injected malformed headers and250ms partial-AU expiry PASS")
        receiver.stop()
        let before = receipts.snapshot()
        _ = packet(role: 2, sequence: audioSequence, timestamp: audioBase, payload: [0xf8, 0xff, 0xfe], marker: true).withUnsafeBytes {
            SGPeerFixtureSend(peer, 2, $0.bindMemory(to: UInt8.self).baseAddress!, $0.count)
        }
        try await Task.sleep(for: .milliseconds(100))
        let after = receipts.snapshot(); precondition(before.0.count == after.0.count && before.1.count == after.1.count)
        print("Guest receive: explicit admission, distinct MIDs, CSRC/extension/padding normalization, sequence/RTP wrap, actual H264/Opus decoded AV timing, stop stale media PASS")
        try await longCall(folder)
    }
    @MainActor static func longCall(_ folder: URL) async throws {
        let receipts = GuestReceipts(), bridge = GuestSignalBridge()
        let receiver = try NativeGuestReceiver(admitted: .init(slot: UUID(), peerID: UUID(), negotiation: UUID(), generation: 8),
            cameraMID: "camera-mid", screenMID: "screen-mid", audioMID: "audio-mid",
            video: { receipts.receive($0) }, audio: { receipts.receive($0) }, signal: { bridge.outgoing($0, $1, $2) })
        bridge.receiver = receiver
        let peer = SGPeerFixtureCreate(guestFixtureSignal, Unmanaged.passUnretained(bridge).toOpaque())!; bridge.peer = peer
        defer { receiver.stop(); SGPeerFixtureDestroy(peer) }
        precondition(SGPeerFixtureStart(peer) != 0); await wait { SGPeerFixtureReady(peer) != 0 }
        let camera = frames(try Data(contentsOf: folder.appendingPathComponent("camera.h264")))[0]
        let screen = frames(try Data(contentsOf: folder.appendingPathComponent("screen.h264")))[0]
        let opus = [UInt8](try Data(contentsOf: folder.appendingPathComponent("opus-000.bin")))
        let began = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        var cameraSequence: UInt16 = 1, screenSequence: UInt16 = 1, audioSequence: UInt16 = 1
        print("Guest receive: >13s actual host-clock sender-report refresh; first screen report deliberately delayed")
        for second in 0...13 {
            if second > 0 { try await Task.sleep(for: .seconds(1)) }
            let elapsed = CMClockGetTime(CMClockGetHostTimeClock()).seconds - began
            let videoTime = UInt32(elapsed * 90_000), audioTime = UInt32(elapsed * 48_000)
            sr(0, rtp: videoTime, seconds: 4_000_000_000 + elapsed, peer: peer)
            sr(2, rtp: audioTime, seconds: 4_000_000_000 + elapsed, peer: peer)
            video(camera, role: 0, timestamp: videoTime, sequence: &cameraSequence, peer: peer)
            send(packet(role: 2, sequence: audioSequence, timestamp: audioTime, payload: opus, marker: true), role: 2, peer: peer); audioSequence &+= 1
            if second == 13 {
                sr(1, rtp: videoTime, seconds: 4_000_000_000 + elapsed + 0.3, peer: peer)
                video(screen, role: 1, timestamp: videoTime, sequence: &screenSequence, peer: peer)
            }
        }
        await wait { receipts.snapshot().0.count == 15 && receipts.snapshot().1.count == 14 }
        let (video, audio) = receipts.snapshot()
        precondition(receiver.counters.errors == 0 && receiver.counters.unsynchronized == 0)
        let cameras = video.filter { $0.role == .camera }, screens = video.filter { $0.role == .screen }
        precondition(cameras.last!.pts - cameras[0].pts > 13 && abs(screens[0].pts - cameras.last!.pts - 0.3) < 0.00001)
        precondition(audio.allSatisfy { $0.frames == 960 })
        print("Guest receive: common mapping survives13s; late first screen SR and explicit audio reset after source gaps PASS")
        struct OpusCase: Decodable { let label: String, packets: Int, frames: Int, channels: Int, duration: Double, config: Int, channelRMS: [[Double]] }
        let cases = try JSONDecoder().decode([OpusCase].self, from: Data(contentsOf: folder.appendingPathComponent("opus-cases.json")))
        for item in cases {
            let baseline = receipts.snapshot().1.count
            let elapsed = CMClockGetTime(CMClockGetHostTimeClock()).seconds - began + 0.04
            let base = UInt32(elapsed * 48_000)
            sr(2, rtp: base, seconds: 4_000_000_000 + elapsed, peer: peer)
            let frames = UInt32(item.duration * 48)
            for index in 0..<item.packets {
                let data = try Data(contentsOf: folder.appendingPathComponent(String(format: "%@-%03d.bin", item.label, index)))
                send(packet(role: 2, sequence: audioSequence, timestamp: base &+ UInt32(index) * frames, payload: [UInt8](data), marker: true), role: 2, peer: peer); audioSequence &+= 1
                try await Task.sleep(for: .milliseconds(item.duration))
            }
            await wait { receipts.snapshot().1.count == baseline + item.packets || receiver.counters.errors > 0 }
            precondition(receiver.counters.errors == 0)
            let actual = Array(receipts.snapshot().1.dropFirst(baseline))
            precondition(actual.reduce(0) { $0 + $1.frames } == item.frames && actual.allSatisfy { $0.frames == Int(frames) })
            let loud = actual.max { $0.rms < $1.rms }!
            print("Guest Opus case \(item.label) actualchannelRMS=\(loud.rms)/\(loud.rightRMS)")
            if item.channels == 1 { precondition(abs(loud.rms - loud.rightRMS) < 0.00001) }
            else { precondition(loud.rms > loud.rightRMS * 2 && loud.rightRMS > 0.005) }
            for (actual, reference) in zip(actual, item.channelRMS) {
                precondition(abs(actual.rms - reference[0]) < 0.002 && abs(actual.rightRMS - reference[1]) < 0.002)
            }
            for pair in zip(actual, actual.dropFirst()) { precondition(abs(pair.1.pts - pair.0.pts - item.duration / 1000) < 0.00001) }
            print("Guest actual RTP Opus \(item.label) config=\(item.config) packets=\(item.packets) decodedframes=\(item.frames) referencecount/channel/timestamp PASS")
        }
    }
}
