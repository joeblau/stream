import AVFoundation
import Foundation
import Darwin

/// Controlled fixture CLI only: bounded JSON lines, no devices or source/mixer.
private final class GuestHostCLI: @unchecked Sendable {
    private let lock = NSRecursiveLock(), outputLock = NSLock()
    private let commandQueue = DispatchQueue(label: "stream.guest.cli.commands")
    private let writeQueue = DispatchQueue(label: "stream.guest.cli.output")
    private var input = Data(), writes: [Data] = [], writeBytes = 0, writing = false
    private var receiver: NativeGuestReceiver?, generation: UInt64?, negotiation: String?, media: [String: String]?
    private var stopped = false, readySent = false, pendingCommands = 0
    private let completion: @Sendable () -> Void
    init(completion: @escaping @Sendable () -> Void) { self.completion = completion }
    func read(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, input.count + data.count <= 196_608 else { fail("command-budget"); return }
        input.append(data)
        while let newline = input.firstIndex(of: 10) {
            let line = input.prefix(upTo: newline); input.removeSubrange(...newline)
            guard line.count <= 98_304, pendingCommands < 32,
                  !line.isEmpty else { fail("command-shape"); return }
            let data = Data(line)
            pendingCommands += 1
            commandQueue.async { [weak self] in
                guard let self else { return }
                if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { self.command(object) }
                else { self.lock.lock(); self.fail("command-shape"); self.lock.unlock() }
                self.lock.lock(); self.pendingCommands -= 1; self.lock.unlock()
            }
        }
    }
    private func command(_ object: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, let type = object["type"] as? String else { return }
        if type == "start" {
            guard receiver == nil, let number = object["generation"] as? UInt64, number > 0,
                  let id = object["negotiation"] as? String, let uuid = UUID(uuidString: id),
                  let identities = object["media"] as? [String: String], identities.count == 3,
                  let audio = identities["audio"], let camera = identities["camera"], let screen = identities["screen"] else { fail("start-shape"); return }
            generation = number; negotiation = uuid.uuidString.lowercased(); media = identities
            do {
                receiver = try NativeGuestReceiver(admitted: .init(slot: UUID(), peerID: UUID(), negotiation: uuid, generation: number),
                    cameraMID: camera, screenMID: screen, audioMID: audio,
                    video: { [weak self] in self?.video($0) }, audio: { [weak self] in self?.audio($0) },
                    signal: { [weak self] in self?.signal($0, $1, $2) })
                guard receiver!.startHost() else { fail("host-start"); return }
            } catch { fail("host-unavailable") }
            return
        }
        guard object["generation"] as? UInt64 == generation, object["negotiation"] as? String == negotiation, let receiver else { return }
        switch type {
        case "answer":
            guard let description = object["description"] as? [String: String], description["type"] == "answer",
                  let sdp = description["sdp"], sdp.utf8.count <= 65_536, receiver.answer(sdp) else { fail("answer-rejected"); return }
        case "candidate":
            guard let candidate = object["candidate"] as? [String: Any], let value = candidate["candidate"] as? String,
                  let mid = candidate["sdpMid"] as? String, receiver.candidate(value, mid: mid) else { fail("candidate-rejected"); return }
        case "approval":
            guard let approved = object["approved"] as? Bool else { fail("approval-shape"); return }
            lock.unlock(); let sent = receiver.approveScreen(approved); lock.lock()
            if !sent && !stopped { fail("control-unavailable") }
        case "stop": lock.unlock(); stop(); lock.lock()
        default: fail("command-unsupported")
        }
    }
    private func signal(_ type: String, _ value: String, _ mid: String) {
        lock.lock(); defer { lock.unlock() }; guard !stopped else { return }
        switch type {
        case "offer": emit(["type": "offer", "description": ["type": "offer", "sdp": value], "media": media ?? [:]])
        case "candidate": emit(["type": "candidate", "candidate": ["candidate": value, "sdpMid": mid]])
        case "control-open":
            if receiver?.hostReady == true, !readySent { readySent = true; emit(["type": "ready"]) }
        case "control":
            guard let data = value.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            emit(["type": "control", "message": object])
        case "control-closed": emit(["type": "control-state", "state": "closed"])
        default: break
        }
    }
    private func video(_ frame: GuestVideoFrame) {
        lock.lock(); defer { lock.unlock() }; guard !stopped else { return }
        let pixels = frame.pixels; CVPixelBufferLockBaseAddress(pixels, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
        let bytes = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
        let position = CVPixelBufferGetBytesPerRow(pixels) * (height / 2) + 4 * (width / 2)
        emit(["type": "decoded", "role": frame.role == .camera ? "camera" : "screen", "pts": frame.pts.seconds,
              "mappingGeneration": frame.mappingGeneration.uuidString.lowercased(), "clockQuality": "senderReportAligned",
              "headerExtensions": receiver?.transportStats(frame.role).extension_packets ?? 0,
              "width": width, "height": height, "centerRGB": [Int(bytes[position + 2]), Int(bytes[position + 1]), Int(bytes[position])], "duration": NSNull()])
    }
    private func audio(_ frame: GuestAudioFrame) {
        lock.lock(); defer { lock.unlock() }; guard !stopped else { return }
        let frames = Int(frame.pcm.frameLength)
        let rms = (0..<2).map { channel in
            let samples = frame.pcm.floatChannelData![channel]
            return sqrt((0..<frames).reduce(0.0) { $0 + Double(samples[$1] * samples[$1]) } / Double(frames))
        }
        emit(["type": "decoded", "role": "audio", "pts": frame.pts.seconds,
              "mappingGeneration": frame.mappingGeneration.uuidString.lowercased(), "clockQuality": "senderReportAligned",
              "headerExtensions": receiver?.transportStats(.audio).extension_packets ?? 0,
              "sampleRate": 48_000, "channels": 2, "frames": frames, "duration": frame.duration.seconds, "rms": rms])
    }
    private func emit(_ value: [String: Any]) {
        var value = value; value["generation"] = generation; value["negotiation"] = negotiation
        guard var data = try? JSONSerialization.data(withJSONObject: value), data.count <= 98_304 else { return }; data.append(10)
        outputLock.lock()
        guard writes.count < 128, writeBytes + data.count <= 196_608 else { outputLock.unlock(); completion(); return }
        writes.append(data); writeBytes += data.count; let start = !writing; writing = true; outputLock.unlock()
        if start { writeQueue.async { [weak self] in self?.drain() } }
    }
    private func drain() {
        while true {
            outputLock.lock(); guard !writes.isEmpty else { writing = false; outputLock.unlock(); return }
            let data = writes.removeFirst(); writeBytes -= data.count; outputLock.unlock()
            let success = data.withUnsafeBytes { bytes in
                var offset = 0; let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
                while offset < bytes.count {
                    guard DispatchTime.now().uptimeNanoseconds < deadline else { return false }
                    let count = Darwin.write(STDOUT_FILENO, bytes.baseAddress! + offset, bytes.count - offset)
                    if count > 0 { offset += count; continue }
                    if count < 0 && errno == EINTR { continue }
                    guard count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK), DispatchTime.now().uptimeNanoseconds < deadline else { return false }
                    var descriptor = pollfd(fd: STDOUT_FILENO, events: Int16(POLLOUT), revents: 0); _ = poll(&descriptor, 1, 100)
                }; return true
            }
            if !success { completion(); return }
        }
    }
    private func fail(_ reason: String) { emit(["type": "error", "reason": reason]); commandQueue.async { [weak self] in self?.stop() } }
    func stop() {
        // Never wait for the media output gate while holding the CLI receipt
        // lock: a decoder callback may already be waiting for this lock.
        lock.lock(); guard !stopped else { lock.unlock(); return }; stopped = true
        let receiver = receiver; self.receiver = nil; lock.unlock()
        receiver?.stop()
        lock.lock(); emit(["type": "stopped"]); lock.unlock()
        writeQueue.async { [completion] in completion() }
    }
}
private final class GuestCLIFinish: @unchecked Sendable {
    let lock = NSLock(); var continuation: CheckedContinuation<Void, Never>?
    func finish() { lock.lock(); let value = continuation; continuation = nil; lock.unlock(); value?.resume() }
}
@main struct NativeGuestHostCLI {
    static func main() async {
        _ = Darwin.signal(SIGPIPE, SIG_IGN)
        _ = fcntl(STDOUT_FILENO, F_SETFL, fcntl(STDOUT_FILENO, F_GETFL) | O_NONBLOCK)
        let finish = GuestCLIFinish()
        await withCheckedContinuation { continuation in
            finish.continuation = continuation
            let runtime = GuestHostCLI { finish.finish() }
            FileHandle.standardInput.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil; runtime.stop() }
                else { runtime.read(data) }
            }
            Task {
                try? await Task.sleep(for: .seconds(90)); runtime.stop()
            }
        }
        FileHandle.standardInput.readabilityHandler = nil
    }
}
