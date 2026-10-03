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
    func clearCalibration() { lock.lock(); video.removeAll(); audio.removeAll(); lock.unlock() }
}
private final class GuestRevokeBarrier: @unchecked Sendable {
    let lock = NSLock(), release = DispatchSemaphore(value: 0)
    private var entered = false, returned = false
    func blockFirstScreen() {
        lock.lock(); let first = !entered; entered = true; lock.unlock()
        if first { precondition(release.wait(timeout: .now() + 3) == .success) }
    }
    func markReturned() { lock.lock(); returned = true; lock.unlock() }
    func snapshot() -> (Bool, Bool) { lock.lock(); defer { lock.unlock() }; return (entered, returned) }
}
@main struct NativeGuestReceiveHarness {
    // FileHandle writes bypass stdio buffering so a fatal assertion retains diagnostics.
    static func writeLine(_ message: String) { FileHandle.standardOutput.write(Data((message + "\n").utf8)) }
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
        if sent == 0 { writeLine("Guest fixture rejected send role=\(role) bytes=\(data.count) sequence=\(data.count >= 4 ? Int(data[2]) * 256 + Int(data[3]) : -1)") }
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
    private static func progress(_ receiver: NativeGuestReceiver, _ receipts: GuestReceipts) -> String {
        // Snapshot Swift state before taking any transport lock. Never hold a
        // receipt/decoder lock across the SDK, whose callbacks enter Swift.
        let snapshots = receiver.diagnosticSnapshot(), counts = receiver.counters
        let (video, audio) = receipts.snapshot()
        let roles = snapshots.map { snapshot in
            let transport = receiver.transportStats(snapshot.role)
            let statuses = snapshot.statuses.map { "\($0.stage):\($0.status):\($0.detail)" }.joined(separator: ",")
            return "role=\(snapshot.role.rawValue) received=\(snapshot.received) decoded=\(snapshot.decoded) expired=\(snapshot.expired) queued=\(snapshot.queued)/\(snapshot.bytes) working=\(snapshot.working) awaitingIDR=\(snapshot.awaitingIDR) lossEpoch=\(snapshot.lossEpoch) srAge=\(snapshot.senderReportAge.map { String(format: "%.3f", $0) } ?? "none") transportFrames=\(transport.frames) rejected=\(transport.rejected) pending=\(transport.pending_packets)/\(transport.pending_bytes) codec=[\(statuses)]"
        }.joined(separator: " | ")
        return "video=\(video.count) audio=\(audio.count)/\(audio.reduce(0) { $0 + $1.frames }) errors=\(counts.errors) drops=\(counts.dropped) unsynchronized=\(counts.unsynchronized) \(roles)"
    }
    @MainActor private static func wait(_ phase: String, _ receiver: NativeGuestReceiver, _ receipts: GuestReceipts, _ predicate: () -> Bool) async {
        let began = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        writeLine("Guest phase start \(phase): \(progress(receiver, receipts))")
        // Preserve the original 1000 ten-millisecond waits. The elapsed clock
        // exposes scheduler starvation instead of increasing any deadline.
        for iteration in 0..<1000 {
            if predicate() {
                writeLine("Guest phase complete \(phase) elapsed=\(CMClockGetTime(CMClockGetHostTimeClock()).seconds - began)s: \(progress(receiver, receipts))")
                return
            }
            if iteration > 0 && iteration % 100 == 0 {
                writeLine("Guest phase waiting \(phase) iteration=\(iteration) elapsed=\(CMClockGetTime(CMClockGetHostTimeClock()).seconds - began)s: \(progress(receiver, receipts))")
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        writeLine("Guest phase deadline \(phase) elapsed=\(CMClockGetTime(CMClockGetHostTimeClock()).seconds - began)s: \(progress(receiver, receipts))")
        preconditionFailure("Bounded peer/decode deadline: \(phase)")
    }
    @MainActor private static func startupReports(_ reports: [(Int32, UInt32, Double)],
        peer: OpaquePointer, receiver: NativeGuestReceiver, receipts: GuestReceipts) async {
        // The outgoing peer can report connected before the receiving endpoint
        // can authenticate its first RTCP packet. Explicit bounded setup retry:
        // no calibration or measured media is sent until real report receipts.
        let sender = Task {
            for attempt in 0..<50 {
                guard !Task.isCancelled else { return }
                writeLine("Guest explicit startup SR transmission attempt=\(attempt + 1) roles=\(reports.count), original calibration RTP/NTP unchanged")
                for (role, rtp, ntp) in reports { sr(role, rtp: rtp, seconds: ntp, peer: peer) }
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            }
        }
        await wait("startup-SR-readiness-before-calibration-media", receiver, receipts) {
            let snapshots = receiver.diagnosticSnapshot()
            return reports.allSatisfy { role, _, _ in
                snapshots[Int(role)].senderReportAge.map { $0 <= 3 } ?? false
            }
        }
        sender.cancel()
    }
    static func main() async throws {
        let folder = URL(fileURLWithPath: CommandLine.arguments[1])
        if CommandLine.arguments.contains("--validation-held-idr") {
            try await heldIDRDependentFrame(folder); return
        }
        let receipts = GuestReceipts(), bridge = GuestSignalBridge()
        let lease = GuestReceiveLease(slot: UUID(), peerID: UUID(), negotiation: UUID(), generation: 7)
        let receiver = try NativeGuestReceiver(admitted: lease, cameraMID: "camera-mid", screenMID: "screen-mid", audioMID: "audio-mid", screenApproved: true,
            video: { receipts.receive($0) }, audio: { receipts.receive($0) }, signal: { bridge.outgoing($0, $1, $2) })
        bridge.receiver = receiver
        let peer = SGPeerFixtureCreate(guestFixtureSignal, Unmanaged.passUnretained(bridge).toOpaque())!
        bridge.peer = peer
        defer { receiver.stop(); SGPeerFixtureDestroy(peer) }
        precondition(SGPeerFixtureStart(peer) != 0)
        await wait("initial-peer-connected", receiver, receipts) { SGPeerFixtureReady(peer) != 0 }
        precondition(!bridge.hasFailed())
        writeLine("Guest receive: actual public SDK peer DTLS/SRTP connected")
        let camera = frames(try Data(contentsOf: folder.appendingPathComponent("camera.h264")))
        let screen = frames(try Data(contentsOf: folder.appendingPathComponent("screen.h264")))
        precondition(camera.count == 14 && screen.count == 14)
        let cameraCalibration: UInt32 = 0xffff_e000, screenCalibration: UInt32 = 123_000_000, audioCalibration: UInt32 = 0xffff_a000
        var calibrationCameraSequence: UInt16 = 65_000, calibrationScreenSequence: UInt16 = 65_000
        // Real compressed calibration initializes this same pair of decoders.
        // It is separately counted and never substitutes for measured pixels.
        await startupReports([(0, cameraCalibration, 4_000_000_000),
                              (2, audioCalibration, 4_000_000_000),
                              (1, screenCalibration, 4_000_000_000.3)],
                             peer: peer, receiver: receiver, receipts: receipts)
        video(camera[0], role: 0, timestamp: cameraCalibration, sequence: &calibrationCameraSequence, peer: peer)
        video(screen[0], role: 1, timestamp: screenCalibration, sequence: &calibrationScreenSequence, peer: peer)
        send(packet(role: 2, sequence: 65_000, timestamp: audioCalibration,
                    payload: [UInt8](try Data(contentsOf: folder.appendingPathComponent("opus-000.bin"))), marker: true), role: 2, peer: peer)
        await wait("real-compressed-codec-calibration", receiver, receipts) {
            let (v, a) = receipts.snapshot()
            return (v.count == 2 && a.count == 1 && receiver.diagnosticSnapshot().allSatisfy { !$0.working }) || receiver.counters.errors > 0
        }
        let calibration = receipts.snapshot()
        precondition(receiver.counters.errors == 0 && calibration.0.count == 2 && calibration.1.count == 1 && calibration.1[0].frames == 960)
        let calibrationPTS = calibration.0.first { $0.role == .camera }!.pts
        // Advance the SAME RTP/NTP/host mapping after actual readiness. A
        // 1/6000s grid is exact for both90k and48k source counters.
        let sourceFrontier = ceil(max(1, CMClockGetTime(CMClockGetHostTimeClock()).seconds - calibrationPTS + 0.12) * 6_000) / 6_000
        let sourceNTP = 4_000_000_000 + sourceFrontier
        let cameraBase = cameraCalibration &+ UInt32((sourceFrontier * 90_000).rounded())
        let screenBase = screenCalibration &+ UInt32((sourceFrontier * 90_000).rounded())
        let audioBase = audioCalibration &+ UInt32((sourceFrontier * 48_000).rounded())
        receipts.clearCalibration()
        writeLine("Guest real codec calibration PASS actualcamera=1/screen=1/audio=960; excluded measured receipts, common mapping retained sourceFrontier=\(sourceFrontier)s")
        var cameraSequence: UInt16 = 65_534, screenSequence: UInt16 = 2, audioSequence: UInt16 = 65_534
        let scheduledAt = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        let sourceClock = ContinuousClock()
        let sourceStart = sourceClock.now.advanced(by: .seconds(max(0, calibrationPTS + sourceFrontier - 0.12 - scheduledAt)))
        try await sourceClock.sleep(until: sourceStart)
        let feedBegan = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        let delayedScheduler = CommandLine.arguments.contains("--validation-delayed-scheduler")
        writeLine("Guest initial paced feed start scheduler=\(delayedScheduler ? "controlled-80ms" : "absolute-source-clock"): \(progress(receiver, receipts))")
        for tick in 0..<70 {
            let sourceElapsed = Double(tick) * 0.02
            let deadline = sourceStart.advanced(by: .seconds(sourceElapsed))
            if delayedScheduler {
                // Simulate a coarse/late scheduler, then catch up on the
                // ORIGINAL source grid. This changes neither RTP nor NTP.
                if sourceClock.now < deadline { try await Task.sleep(for: .milliseconds(80)) }
            } else { try await sourceClock.sleep(until: deadline) }
            if tick % 10 == 0 {
                // Reports describe the same source frontier as the packets.
                // Repeating the original NTP or rebasing to wall arrival would
                // change the common mapping and hide the actual cue contract.
                let videoFrontier = UInt32(tick * 1_800)
                sr(0, rtp: cameraBase &+ videoFrontier, seconds: sourceNTP + sourceElapsed, peer: peer)
                sr(2, rtp: audioBase &+ UInt32(tick * 960), seconds: sourceNTP + sourceElapsed, peer: peer)
                sr(1, rtp: screenBase &+ videoFrontier, seconds: sourceNTP + 0.3 + sourceElapsed, peer: peer)
            }
            let opus = try Data(contentsOf: folder.appendingPathComponent(String(format: "opus-%03d.bin", tick)))
            send(packet(role: 2, sequence: audioSequence, timestamp: audioBase &+ UInt32(tick * 960), payload: [UInt8](opus), marker: true), role: 2, peer: peer); audioSequence &+= 1
            if tick % 5 == 0 {
                let index = tick / 5
                video(camera[index], role: 0, timestamp: cameraBase &+ UInt32(index * 9000), sequence: &cameraSequence, peer: peer)
                video(screen[index], role: 1, timestamp: screenBase &+ UInt32(index * 9000), sequence: &screenSequence, peer: peer)
            }
            if tick % 10 == 9 {
                writeLine("Guest paced feed tick=\(tick + 1) sourceElapsed=\(Double(tick + 1) * 0.02)s hostElapsed=\(CMClockGetTime(CMClockGetHostTimeClock()).seconds - feedBegan)s: \(progress(receiver, receipts))")
            }
        }
        await wait("initial-h264-opus-decode", receiver, receipts) { let (v, a) = receipts.snapshot(); return v.count == 28 && a.reduce(0) { $0 + $1.frames } >= 67_080 || receiver.counters.errors > 0 }
        await receiver.finishAudio()
        let (v, a) = receipts.snapshot()
        writeLine("Guest decode counts video=\(v.count) audio=\(a.count) errors=\(receiver.counters.errors) dropped=\(receiver.counters.dropped) unsynchronized=\(receiver.counters.unsynchronized)")
        writeLine("Guest PCM samples=\(a.reduce(0) { $0 + $1.frames }); first tone offset=\((a.first { $0.rms > 0.025 }?.pts ?? 0) - (v.first { $0.role == .camera }?.pts ?? 0))s")
        precondition(receiver.counters.errors == 0 && v.count == 28)
        let cameras = v.filter { $0.role == .camera }, screens = v.filter { $0.role == .screen }
        precondition(cameras.count == 14 && screens.count == 14 && cameras[0].r > 200 && cameras[0].b < 30 && screens[0].b > 200 && screens[0].r < 30)
        precondition(a.reduce(0) { $0 + $1.frames } == 67_200)
        precondition(abs(a[0].pts - cameras[0].pts) <= 0.00001)
        let flash = cameras.first { $0.r > 200 && $0.g > 200 && $0.b > 200 }!, tone = a.first { $0.rms > 0.025 }!
        let av = tone.pts - flash.pts, roleOffset = screens[0].pts - cameras[0].pts
        writeLine("Guest decoded cue AV delta=\(av)s screen camera offset=\(roleOffset)s; 320x180 H264 pixels + 48k stereo Opus PCM")
        precondition(abs(av) <= 0.025 && abs(roleOffset - 0.3) <= 0.00001)
        struct Reference: Decodable { let frames: Int, cueFrame: Int }
        let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: folder.appendingPathComponent("opus-reference.json")))
        let actualCue = a.compactMap(\.cuePTS).first! - a[0].pts
        precondition(a.reduce(0) { $0 + $1.frames } == reference.frames && abs(actualCue - Double(reference.cueFrame) / 48_000) < 1.0 / 48_000)
        writeLine("Guest raw Opus reference sample count/cue matches: \(reference.frames) frames cue=\(reference.cueFrame)/48000 PASS")
        for role in [GuestReceiveRole.camera, .screen, .audio] {
            let stats = receiver.transportStats(role)
            precondition(stats.frames == (role == .audio ? 71 : 15) && stats.pending_bytes == 0 && stats.pending_packets == 0 && stats.rejected == 0)
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
        await wait("malformed-reorder-rejected", receiver, receipts) { receiver.transportStats(.audio).rejected == 2 && receiver.transportStats(.camera).rejected == 2 }
        let countsAfter = receipts.snapshot(); precondition(countsBefore.0.count == countsAfter.0.count && countsBefore.1.count == countsAfter.1.count)
        // An unfinished FU expires without the pinned SDK retaining any of it.
        send(packet(role: 0, sequence: cameraSequence, timestamp: cameraBase &+ 126_000, payload: [0x7c, 0x85, 1, 2], marker: false), role: 0, peer: peer); cameraSequence &+= 1
        await wait("unfinished-fu-pending", receiver, receipts) { receiver.transportStats(.camera).pending_packets == 1 }
        try await Task.sleep(for: .milliseconds(350))
        precondition(receiver.transportStats(.camera).pending_packets == 0 && receiver.transportStats(.camera).pending_bytes == 0)
        // FU-A continuation may not change the NAL's type/NRI.
        send(packet(role: 0, sequence: cameraSequence, timestamp: cameraBase &+ 135_000, payload: [0x7c, 0x85, 1, 2], marker: false), role: 0, peer: peer); cameraSequence &+= 1
        send(packet(role: 0, sequence: cameraSequence, timestamp: cameraBase &+ 135_000, payload: [0x5c, 0x45, 1, 2], marker: true), role: 0, peer: peer); cameraSequence &+= 1
        await wait("fu-identity-rejected", receiver, receipts) { receiver.transportStats(.camera).rejected == 3 }
        // Loss recovery emits a complete real IDR after the malformed AU.
        sr(0, rtp: cameraBase &+ 135_000, seconds: sourceNTP + 1.5, peer: peer)
        video(camera[0], role: 0, timestamp: cameraBase &+ 135_000, sequence: &cameraSequence, peer: peer)
        await wait("actual-idr-recovery", receiver, receipts) { receipts.snapshot().0.count == countsBefore.0.count + 1 }
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
        writeLine("Guest receive: actual guard512-packet/2MiB AU cap clears stalled assembly PASS")
        writeLine("Guest receive: actual transported duplicate/reordered timestamps/FU identity/IDR recovery; actual guard injected malformed headers and250ms partial-AU expiry PASS")
        receiver.stop()
        let before = receipts.snapshot()
        _ = packet(role: 2, sequence: audioSequence, timestamp: audioBase, payload: [0xf8, 0xff, 0xfe], marker: true).withUnsafeBytes {
            SGPeerFixtureSend(peer, 2, $0.bindMemory(to: UInt8.self).baseAddress!, $0.count)
        }
        try await Task.sleep(for: .milliseconds(100))
        let after = receipts.snapshot(); precondition(before.0.count == after.0.count && before.1.count == after.1.count)
        writeLine("Guest receive: explicit admission, distinct MIDs, CSRC/extension/padding normalization, sequence/RTP wrap, actual H264/Opus decoded AV timing, stop stale media PASS")
        try await longCall(folder)
        try await revokeBoundary(folder)
        try await queuedReferenceLoss(folder, overflow: false)
        try await queuedReferenceLoss(folder, overflow: true)
        try await heldIDRDependentFrame(folder)
    }
    @MainActor static func longCall(_ folder: URL) async throws {
        let receipts = GuestReceipts(), bridge = GuestSignalBridge()
        let receiver = try NativeGuestReceiver(admitted: .init(slot: UUID(), peerID: UUID(), negotiation: UUID(), generation: 8),
            cameraMID: "camera-mid", screenMID: "screen-mid", audioMID: "audio-mid", screenApproved: true,
            video: { receipts.receive($0) }, audio: { receipts.receive($0) }, signal: { bridge.outgoing($0, $1, $2) })
        bridge.receiver = receiver
        let peer = SGPeerFixtureCreate(guestFixtureSignal, Unmanaged.passUnretained(bridge).toOpaque())!; bridge.peer = peer
        defer { receiver.stop(); SGPeerFixtureDestroy(peer) }
        precondition(SGPeerFixtureStart(peer) != 0); await wait("long-call-peer-connected", receiver, receipts) { SGPeerFixtureReady(peer) != 0 }
        let camera = frames(try Data(contentsOf: folder.appendingPathComponent("camera.h264")))[0]
        let screen = frames(try Data(contentsOf: folder.appendingPathComponent("screen.h264")))[0]
        let opus = [UInt8](try Data(contentsOf: folder.appendingPathComponent("opus-000.bin")))
        let began = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        await startupReports([(0, 0, 4_000_000_000), (2, 0, 4_000_000_000)],
                             peer: peer, receiver: receiver, receipts: receipts)
        var cameraSequence: UInt16 = 1, screenSequence: UInt16 = 1, audioSequence: UInt16 = 1
        writeLine("Guest receive: >13s actual host-clock sender-report refresh; first screen report deliberately delayed")
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
        await wait("long-call-late-screen-decode", receiver, receipts) { receipts.snapshot().0.count == 15 && receipts.snapshot().1.count == 14 }
        let (video, audio) = receipts.snapshot()
        precondition(receiver.counters.errors == 0 && receiver.counters.unsynchronized == 0)
        let cameras = video.filter { $0.role == .camera }, screens = video.filter { $0.role == .screen }
        precondition(cameras.last!.pts - cameras[0].pts > 13 && abs(screens[0].pts - cameras.last!.pts - 0.3) < 0.00001)
        precondition(audio.allSatisfy { $0.frames == 960 })
        writeLine("Guest receive: common mapping survives13s; late first screen SR and explicit audio reset after source gaps PASS")
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
            await wait("opus-case-\(item.label)", receiver, receipts) { receipts.snapshot().1.count == baseline + item.packets || receiver.counters.errors > 0 }
            precondition(receiver.counters.errors == 0)
            let actual = Array(receipts.snapshot().1.dropFirst(baseline))
            precondition(actual.reduce(0) { $0 + $1.frames } == item.frames && actual.allSatisfy { $0.frames == Int(frames) })
            let loud = actual.max { $0.rms < $1.rms }!
            writeLine("Guest Opus case \(item.label) actualchannelRMS=\(loud.rms)/\(loud.rightRMS)")
            if item.channels == 1 { precondition(abs(loud.rms - loud.rightRMS) < 0.00001) }
            else { precondition(loud.rms > loud.rightRMS * 2 && loud.rightRMS > 0.005) }
            for (actual, reference) in zip(actual, item.channelRMS) {
                precondition(abs(actual.rms - reference[0]) < 0.002 && abs(actual.rightRMS - reference[1]) < 0.002)
            }
            for pair in zip(actual, actual.dropFirst()) { precondition(abs(pair.1.pts - pair.0.pts - item.duration / 1000) < 0.00001) }
            writeLine("Guest actual RTP Opus \(item.label) config=\(item.config) packets=\(item.packets) decodedframes=\(item.frames) referencecount/channel/timestamp PASS")
        }
    }
    @MainActor static func revokeBoundary(_ folder: URL) async throws {
        let receipts = GuestReceipts(), bridge = GuestSignalBridge(), barrier = GuestRevokeBarrier()
        let receiver = try NativeGuestReceiver(admitted: .init(slot: UUID(), peerID: UUID(), negotiation: UUID(), generation: 9),
            cameraMID: "camera-mid", screenMID: "screen-mid", audioMID: "audio-mid", screenApproved: true,
            video: { if $0.role == .screen { barrier.blockFirstScreen() }; receipts.receive($0) },
            audio: { receipts.receive($0) }, signal: { bridge.outgoing($0, $1, $2) })
        bridge.receiver = receiver
        let peer = SGPeerFixtureCreate(guestFixtureSignal, Unmanaged.passUnretained(bridge).toOpaque())!; bridge.peer = peer
        defer { receiver.stop(); SGPeerFixtureDestroy(peer) }
        precondition(SGPeerFixtureStart(peer) != 0); await wait("revoke-peer-connected", receiver, receipts) { SGPeerFixtureReady(peer) != 0 }
        let frame = frames(try Data(contentsOf: folder.appendingPathComponent("screen.h264")))[0]
        await startupReports([(1, 0, 4_000_000_000)],
                             peer: peer, receiver: receiver, receipts: receipts)
        var screenSequence: UInt16 = 1, cameraSequence: UInt16 = 1
        video(frame, role: 1, timestamp: 0, sequence: &screenSequence, peer: peer)
        await wait("revoke-screen-callback-entered", receiver, receipts) { barrier.snapshot().0 }
        let revoke = Task.detached { let sent = receiver.approveScreen(false); barrier.markReturned(); return sent }
        try await Task.sleep(for: .milliseconds(60))
        precondition(!barrier.snapshot().1, "Revoke returned while a prior screen callback still owned the gate")
        barrier.release.signal(); let sent = await revoke.value
        precondition(!sent, "Legacy source-offer fixture has no remote approval channel; local revocation still gates media")
        let count = receipts.snapshot().0.filter { $0.role == .screen }.count
        video(frame, role: 1, timestamp: 9000, sequence: &screenSequence, peer: peer)
        sr(0, rtp: 0, seconds: 4_000_000_000, peer: peer)
        video(frames(try Data(contentsOf: folder.appendingPathComponent("camera.h264")))[0], role: 0, timestamp: 0, sequence: &cameraSequence, peer: peer)
        sr(2, rtp: 0, seconds: 4_000_000_000, peer: peer)
        send(packet(role: 2, sequence: 1, timestamp: 0, payload: [UInt8](try Data(contentsOf: folder.appendingPathComponent("opus-000.bin"))), marker: true), role: 2, peer: peer)
        await wait("revoke-camera-audio-health", receiver, receipts) { receipts.snapshot().0.contains { $0.role == .camera } && !receipts.snapshot().1.isEmpty }
        try await Task.sleep(for: .milliseconds(80))
        precondition(receipts.snapshot().0.filter { $0.role == .screen }.count == count)
        writeLine("Guest receive: actual blocked decoded callback fences synchronous screen revoke; later screen rejected, camera/audio continue PASS")
    }
    @MainActor static func heldIDRDependentFrame(_ folder: URL) async throws {
        let receipts = GuestReceipts(), bridge = GuestSignalBridge(), barrier = GuestRevokeBarrier()
        let receiver = try NativeGuestReceiver(admitted: .init(slot: UUID(), peerID: UUID(), negotiation: UUID(), generation: 12),
            cameraMID: "camera-mid", screenMID: "screen-mid", audioMID: "audio-mid", screenApproved: true,
            video: { if $0.role == .screen { barrier.blockFirstScreen() }; receipts.receive($0) },
            audio: { receipts.receive($0) }, signal: { bridge.outgoing($0, $1, $2) })
        bridge.receiver = receiver
        let peer = SGPeerFixtureCreate(guestFixtureSignal, Unmanaged.passUnretained(bridge).toOpaque())!; bridge.peer = peer
        defer { barrier.release.signal(); receiver.stop(); SGPeerFixtureDestroy(peer) }
        precondition(SGPeerFixtureStart(peer) != 0)
        await wait("held-IDR-peer", receiver, receipts) { SGPeerFixtureReady(peer) != 0 }
        let camera = frames(try Data(contentsOf: folder.appendingPathComponent("camera.h264")))
        let screen = frames(try Data(contentsOf: folder.appendingPathComponent("screen.h264")))
        let opus = [UInt8](try Data(contentsOf: folder.appendingPathComponent("opus-000.bin")))
        await startupReports([(0, 0, 4_000_000_000), (1, 0, 4_000_000_000.3), (2, 0, 4_000_000_000)],
                             peer: peer, receiver: receiver, receipts: receipts)
        var cameraSequence: UInt16 = 1, screenSequence: UInt16 = 1
        video(screen[0], role: 1, timestamp: 0, sequence: &screenSequence, peer: peer)
        await wait("held-IDR-screen-actual-callback", receiver, receipts) { barrier.snapshot().0 }
        video(camera[0], role: 0, timestamp: 0, sequence: &cameraSequence, peer: peer)
        await wait("held-IDR-camera-actual-pixels-before-reference-commit", receiver, receipts) {
            let state = receiver.diagnosticSnapshot()[0]
            return state.awaitingIDR && state.decoded == 0 && state.statuses.contains {
                $0.stage == "video-output" && $0.status == 0 && $0.detail & 0x8000_0000 != 0
            }
        }
        video(camera[1], role: 0, timestamp: 9_000, sequence: &cameraSequence, peer: peer)
        await wait("held-IDR-dependent-P-admitted-within-bounds", receiver, receipts) {
            let state = receiver.diagnosticSnapshot()[0]
            return state.queued == 1 || receiver.counters.dropped != 0
        }
        let queued = receiver.diagnosticSnapshot()[0]
        precondition(queued.awaitingIDR && queued.queued == 1 && queued.bytes <= 2_097_152
                     && receiver.counters.dropped == 0,
                     "A queued P behind an in-flight IDR must wait for the actual decode result, not create a reference gap")
        send(packet(role: 2, sequence: 1, timestamp: 0, payload: opus, marker: true), role: 2, peer: peer)
        barrier.release.signal()
        await wait("held-IDR-actual-IDR-plus-queued-P-and-other-roles", receiver, receipts) {
            let (v, a) = receipts.snapshot()
            return v.filter { $0.role == .camera }.count == 2 && v.filter { $0.role == .screen }.count == 1
                && a.count == 1 && !receiver.diagnosticSnapshot()[0].working
        }
        video(camera[2], role: 0, timestamp: 18_000, sequence: &cameraSequence, peer: peer)
        video(screen[1], role: 1, timestamp: 9_000, sequence: &screenSequence, peer: peer)
        send(packet(role: 2, sequence: 2, timestamp: 960, payload: opus, marker: true), role: 2, peer: peer)
        await wait("held-IDR-next-dependent-P-remains-decodable", receiver, receipts) {
            let (v, a) = receipts.snapshot()
            return v.filter { $0.role == .camera }.count == 3 && v.filter { $0.role == .screen }.count == 2 && a.count == 2
        }
        let final = receiver.diagnosticSnapshot()[0]
        precondition(!final.awaitingIDR && final.lossEpoch == 0 && final.expired == 0
                     && receiver.counters.errors == 0 && receiver.counters.dropped == 0)
        writeLine("Guest receive: actual held in-flight IDR retains bounded queued P; successful pixels establish references before dependent decode, next P/screen/audio remain healthy PASS")
    }
    @MainActor static func queuedReferenceLoss(_ folder: URL, overflow: Bool) async throws {
        let receipts = GuestReceipts(), bridge = GuestSignalBridge(), barrier = GuestRevokeBarrier()
        let blockedRole: GuestReceiveRole = overflow ? .screen : .camera
        let receiver = try NativeGuestReceiver(admitted: .init(slot: UUID(), peerID: UUID(), negotiation: UUID(), generation: overflow ? 11 : 10),
            cameraMID: "camera-mid", screenMID: "screen-mid", audioMID: "audio-mid", screenApproved: true,
            video: { if $0.role == blockedRole { barrier.blockFirstScreen() }; receipts.receive($0) },
            audio: { receipts.receive($0) }, signal: { bridge.outgoing($0, $1, $2) })
        bridge.receiver = receiver
        let peer = SGPeerFixtureCreate(guestFixtureSignal, Unmanaged.passUnretained(bridge).toOpaque())!; bridge.peer = peer
        defer { barrier.release.signal(); receiver.stop(); SGPeerFixtureDestroy(peer) }
        let label = overflow ? "loss-epoch-overflow" : "queued-P-expiry"
        precondition(SGPeerFixtureStart(peer) != 0)
        await wait("\(label)-peer", receiver, receipts) { SGPeerFixtureReady(peer) != 0 }
        let camera = frames(try Data(contentsOf: folder.appendingPathComponent("camera.h264")))
        let screen = frames(try Data(contentsOf: folder.appendingPathComponent("screen.h264")))
        let opus = [UInt8](try Data(contentsOf: folder.appendingPathComponent("opus-000.bin")))
        await startupReports([(0, 0, 4_000_000_000), (1, 0, 4_000_000_000.3), (2, 0, 4_000_000_000)],
                             peer: peer, receiver: receiver, receipts: receipts)
        var cameraSequence: UInt16 = 1, screenSequence: UInt16 = 1
        if overflow { video(screen[0], role: 1, timestamp: 0, sequence: &screenSequence, peer: peer) }
        else { video(camera[0], role: 0, timestamp: 0, sequence: &cameraSequence, peer: peer) }
        await wait("\(label)-actual-pixels-held", receiver, receipts) { barrier.snapshot().0 }
        let recoveryTimestamp: UInt32
        if overflow {
            // Camera's real IDR callback waits behind the entered screen gate.
            // Its submit epoch predates the subsequent camera queue loss.
            video(camera[0], role: 0, timestamp: 0, sequence: &cameraSequence, peer: peer)
            await wait("\(label)-IDR-submitted-before-loss", receiver, receipts) {
                receiver.diagnosticSnapshot()[0].statuses.contains { $0.stage == "video-output" && $0.status == 0 && $0.detail & 0x8000_0000 != 0 }
            }
            for index in 1...4 { video(camera[0], role: 0, timestamp: UInt32(index * 9_000), sequence: &cameraSequence, peer: peer) }
            await wait("\(label)-bounded-queue-cleared", receiver, receipts) {
                let state = receiver.diagnosticSnapshot()[0]; return state.lossEpoch == 1 && state.queued == 0
            }
            recoveryTimestamp = 54_000
        } else {
            // The first queued P will expire. The second arrives fresh but
            // depends on that missing frame, so it must never reach VT.
            video(camera[1], role: 0, timestamp: 9_000, sequence: &cameraSequence, peer: peer)
            await wait("\(label)-first-P-queued", receiver, receipts) { receiver.diagnosticSnapshot()[0].queued == 1 }
            try await Task.sleep(for: .milliseconds(300))
            video(camera[2], role: 0, timestamp: 18_000, sequence: &cameraSequence, peer: peer)
            await wait("\(label)-dependent-P-queued", receiver, receipts) { receiver.diagnosticSnapshot()[0].queued == 2 }
            video(screen[0], role: 1, timestamp: 0, sequence: &screenSequence, peer: peer)
            recoveryTimestamp = 27_000
        }
        send(packet(role: 2, sequence: 1, timestamp: 0, payload: opus, marker: true), role: 2, peer: peer)
        barrier.release.signal()
        await wait("\(label)-old-callback-and-loss-drained", receiver, receipts) {
            let (v, a) = receipts.snapshot(), state = receiver.diagnosticSnapshot()[0]
            return v.filter { $0.role == .camera }.count == 1 && v.filter { $0.role == .screen }.count == 1
                && a.count == 1 && !state.working && state.queued == 0 && state.awaitingIDR
        }
        let state = receiver.diagnosticSnapshot()[0]
        precondition(receiver.counters.errors == 0 && state.lossEpoch == 1)
        if overflow {
            precondition(state.expired == 0 && receiver.counters.dropped == 4,
                         "An old successful IDR cannot clear a newer queue-loss epoch")
            video(camera[1], role: 0, timestamp: 45_000, sequence: &cameraSequence, peer: peer)
            await wait("\(label)-dependent-P-denied", receiver, receipts) { receiver.counters.dropped == 5 }
        } else {
            precondition(state.expired == 1 && receiver.counters.dropped == 2,
                         "Fresh queued P must be denied after an earlier queued reference expires")
        }
        video(camera[0], role: 0, timestamp: recoveryTimestamp, sequence: &cameraSequence, peer: peer)
        await wait("\(label)-actual-fresh-IDR-recovery", receiver, receipts) {
            receipts.snapshot().0.filter { $0.role == .camera }.count == 2 && !receiver.diagnosticSnapshot()[0].awaitingIDR
        }
        video(camera[1], role: 0, timestamp: recoveryTimestamp + 9_000, sequence: &cameraSequence, peer: peer)
        video(screen[1], role: 1, timestamp: 9_000, sequence: &screenSequence, peer: peer)
        send(packet(role: 2, sequence: 2, timestamp: 960, payload: opus, marker: true), role: 2, peer: peer)
        await wait("\(label)-healthy-dependent-frame-and-other-roles", receiver, receipts) {
            let (v, a) = receipts.snapshot()
            return v.filter { $0.role == .camera }.count == 3 && v.filter { $0.role == .screen }.count == 2 && a.count == 2
        }
        precondition(receiver.counters.errors == 0 && receiver.transportStats(.camera).rejected == 0)
        writeLine("Guest receive: actual \(label) denies missing-reference P without VT errors; fresh decoded IDR recovers, independent screen/audio continue PASS")
    }

}
