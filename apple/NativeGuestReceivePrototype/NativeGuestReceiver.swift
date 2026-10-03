import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation
import VideoToolbox

private enum GuestDecodeError: Error { case unsupported, malformed, codec(OSStatus), audioFrames(expected: UInt32, actual: UInt32, code: Int?) }
private func hostSeconds() -> Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }

/// One admitted peer prototype. Its callbacks are isolated media receipts; this
/// class never registers an audio source, stages a scene or publishes output.
final class NativeGuestReceiver: @unchecked Sendable {
    struct CodecStatus: Sendable {
        let stage: String, status: OSStatus, detail: UInt32
    }
    struct DecodeDiagnostics: Sendable {
        let role: GuestReceiveRole, received: Int, decoded: Int, expired: Int, queued: Int, bytes: Int, working: Bool
        let senderReportAge: Double?, statuses: [CodecStatus]
        let awaitingIDR: Bool, lossEpoch: UInt64
    }
    private struct Input { let data: Data, pts: Double, arrival: Double }
    private struct SenderReport { let rtp: UInt32, ntp: Double, received: Double }
    private let lock = NSLock(), transportLock = NSLock(), outputGate = NSRecursiveLock()
    let lease: GuestReceiveLease
    private var active = true, handle: OpaquePointer?
    private var ntpOrigin: Double?, hostOrigin: Double?, originReceived: Double?
    private var reports: [Int32: SenderReport] = [:]
    private var lastPTS: [Double?] = [nil, nil, nil]
    private var pending: [[Input]] = [[], [], []], bytes = [0, 0, 0], working = [false, false, false]
    private var needsIDR = [true, true], lossEpoch: [UInt64] = [0, 0]
    private var screenApproved: Bool
    private var keyframePending = [false, false], lastKeyframe = [-Double.infinity, -Double.infinity]
    private var audioResetPending = false
    private let mappingGeneration = UUID()
    private var signals: [(String, String, String)] = [], signalBytes = 0, signalWorking = false
    private let signalQueue = DispatchQueue(label: "stream.guest.signaling")
    private let queues = (0..<3).map { DispatchQueue(label: "stream.guest.decode.\($0)", qos: .userInitiated) }
    private var videos: [GuestH264Decoder?] = [nil, nil]
    private var audio: GuestOpusDecoder?
    private var expiry: Task<Void, Never>?
    private var decodeErrors = 0, drops = 0, unsynchronized = 0
    private var receivedUnits = [0, 0, 0], decodedUnits = [0, 0, 0], expiredUnits = [0, 0, 0]
    private var codecStatuses: [[String: CodecStatus]] = [[:], [:], [:]]
    private let videoOutput: @Sendable (GuestVideoFrame) -> Void
    private let audioOutput: @Sendable (GuestAudioFrame) -> Void
    private let signalOutput: @Sendable (String, String, String) -> Void
    init(admitted lease: GuestReceiveLease, cameraMID: String, screenMID: String, audioMID: String, screenApproved: Bool = false,
         video: @escaping @Sendable (GuestVideoFrame) -> Void,
         audio: @escaping @Sendable (GuestAudioFrame) -> Void,
         signal: @escaping @Sendable (String, String, String) -> Void) throws {
        guard lease.generation > 0 else { throw GuestDecodeError.malformed }
        self.lease = lease; self.screenApproved = screenApproved; videoOutput = video; audioOutput = audio; signalOutput = signal
        handle = SGReceiverCreate(lease.generation, cameraMID, screenMID, audioMID, { context, generation, role, event, data, size, rtp, ntp in
            guard let context else { return }
            Unmanaged<NativeGuestReceiver>.fromOpaque(context).takeUnretainedValue().receive(generation: generation, role: role, event: event, data: data, count: size, rtp: rtp, ntp: ntp)
        }, { context, type, value, mid in
            guard let context, let type, let value, let mid else { return }
            let owner = Unmanaged<NativeGuestReceiver>.fromOpaque(context).takeUnretainedValue()
            owner.signal(String(cString: type), String(cString: value), String(cString: mid))
        }, Unmanaged.passUnretained(self).toOpaque())
        guard handle != nil else { throw GuestDecodeError.unsupported }
        expiry = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled, let self else { return }
                self.expire()
            }
        }
    }
    func offer(_ sdp: String) -> Bool { transportLock.lock(); defer { transportLock.unlock() }; return SGReceiverOffer(handle, sdp) != 0 }
    func candidate(_ candidate: String, mid: String) -> Bool { transportLock.lock(); defer { transportLock.unlock() }; return SGReceiverCandidate(handle, candidate, mid) != 0 }
    func startHost() -> Bool { transportLock.lock(); defer { transportLock.unlock() }; return SGReceiverStartHost(handle) != 0 }
    func answer(_ sdp: String) -> Bool { transportLock.lock(); defer { transportLock.unlock() }; return SGReceiverAnswer(handle, sdp) != 0 }
    var hostReady: Bool { transportLock.lock(); defer { transportLock.unlock() }; return SGReceiverHostReady(handle) != 0 }
    func approveScreen(_ approved: Bool) -> Bool {
        // Synchronous revocation must finish any already-entered callback before
        // returning. Callers must not hold their receipt sink lock here.
        outputGate.lock(); lock.lock()
        if !approved { screenApproved = false; pending[1].removeAll(); bytes[1] = 0; requireIDRLocked(1) }
        let current = active; lock.unlock(); outputGate.unlock()
        guard current else { return false }
        let data = try? JSONSerialization.data(withJSONObject: ["type": "screen-approval", "negotiation": lease.negotiation.uuidString.lowercased(), "approved": approved])
        guard let data, let message = String(data: data, encoding: .utf8) else { return false }
        transportLock.lock(); let sent = SGReceiverSendControl(handle, message) != 0; transportLock.unlock()
        outputGate.lock(); lock.lock(); screenApproved = active && sent && approved
        if !screenApproved { pending[1].removeAll(); bytes[1] = 0 }; requireIDRLocked(1); lock.unlock(); outputGate.unlock()
        if sent && approved { requestKeyframe(1) }; return sent
    }
    func transportStats(_ role: GuestReceiveRole) -> SGReceiveStats { transportLock.lock(); defer { transportLock.unlock() }; return SGReceiverStats(handle, role.rawValue) }
    #if STREAM_GUEST_VALIDATION
    func validationPacket(_ data: Data, role: GuestReceiveRole) -> Bool {
        transportLock.lock(); defer { transportLock.unlock() }
        return data.withUnsafeBytes { SGReceiverValidationPacket(handle, role.rawValue, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) != 0 }
    }
    #endif
    var counters: (errors: Int, dropped: Int, unsynchronized: Int) {
        lock.lock(); defer { lock.unlock() }; return (decodeErrors, drops, unsynchronized)
    }
    func diagnosticSnapshot() -> [DecodeDiagnostics] {
        lock.lock(); defer { lock.unlock() }
        let now = hostSeconds()
        return (0..<3).map { index -> DecodeDiagnostics in
            let role = GuestReceiveRole(rawValue: Int32(index))!
            let age: Double? = reports[Int32(index)].map { now - $0.received }
            let statuses = codecStatuses[index].values.sorted { $0.stage < $1.stage }
            let awaiting = index < 2 ? needsIDR[index] : false
            let epoch: UInt64 = index < 2 ? lossEpoch[index] : 0
            return DecodeDiagnostics(role: role, received: receivedUnits[index], decoded: decodedUnits[index],
                expired: expiredUnits[index], queued: pending[index].count, bytes: bytes[index], working: working[index],
                senderReportAge: age, statuses: statuses, awaitingIDR: awaiting, lossEpoch: epoch)
        }
    }
    private func requireIDRLocked(_ index: Int) {
        needsIDR[index] = true; lossEpoch[index] &+= 1
    }
    private func codecStatus(role: Int32, stage: String, status: OSStatus, detail: UInt32) {
        lock.lock(); defer { lock.unlock() }
        // Stages are fixed application constants, never remote strings.
        codecStatuses[Int(role)][stage] = .init(stage: stage, status: status, detail: detail)
        if stage == "video-output", status != noErr {
            decodeErrors += 1; requireIDRLocked(Int(role))
        }
    }
    private func expire() { transportLock.lock(); defer { transportLock.unlock() }; SGReceiverExpire(handle) }
    private func keyframe(_ role: Int32) { transportLock.lock(); defer { transportLock.unlock() }; _ = SGReceiverRequestKeyframe(handle, role) }
    private func requestKeyframe(_ role: Int32) {
        let index = Int(role); lock.lock()
        guard active, index < 2, !keyframePending[index], hostSeconds() - lastKeyframe[index] >= 0.25 else { lock.unlock(); return }
        keyframePending[index] = true; lastKeyframe[index] = hostSeconds(); lock.unlock()
        signalQueue.async { [weak self] in
            guard let self else { return }; self.keyframe(role)
            self.lock.lock(); self.keyframePending[index] = false; self.lock.unlock()
        }
    }
    private func signal(_ type: String, _ value: String, _ mid: String) {
        lock.lock()
        if type == "control-closed" { screenApproved = false; pending[1].removeAll(); bytes[1] = 0; requireIDRLocked(1) }
        if type == "control" {
            guard let data = value.data(using: .utf8), data.count <= 1024,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == "screen-state", object["negotiation"] as? String == lease.negotiation.uuidString.lowercased(),
                  object["sharing"] is Bool, object.count == 3 else { drops += 1; lock.unlock(); return }
        }
        let size = type.utf8.count + value.utf8.count + mid.utf8.count
        guard active, size <= 65_600, signals.count < 32, signalBytes + size <= 196_608 else { drops += 1; lock.unlock(); return }
        signals.append((type, value, mid)); signalBytes += size
        let start = !signalWorking; signalWorking = true; lock.unlock()
        if start { signalQueue.async { [weak self] in self?.drainSignals() } }
    }
    private func drainSignals() {
        while true {
            lock.lock()
            guard active, !signals.isEmpty else { signalWorking = false; lock.unlock(); return }
            let next = signals.removeFirst(); signalBytes -= next.0.utf8.count + next.1.utf8.count + next.2.utf8.count; lock.unlock()
            outputGate.lock(); lock.lock(); let current = active; lock.unlock()
            if current { signalOutput(next.0, next.1, next.2) }; outputGate.unlock()
        }
    }
    private func receive(generation: UInt64, role: Int32, event: Int32, data: UnsafePointer<UInt8>?, count: Int, rtp: UInt32, ntp: UInt64) {
        lock.lock()
        guard active, generation == lease.generation, (0...2).contains(role) else { lock.unlock(); return }
        let now = hostSeconds(), index = Int(role)
        if event == SG_SENDER_REPORT {
            let seconds = Double(ntp >> 32) + Double(ntp & 0xffff_ffff) / 4_294_967_296
            if ntpOrigin == nil { ntpOrigin = seconds; hostOrigin = now + 0.12; originReceived = now }
            // Keep one origin throughout the call. Compare new reports with
            // the previous report and elapsed host time, not total call age.
            let previous = reports[role]
            let plausible = previous.map {
                let sourceElapsed = Double(Int32(bitPattern: rtp &- $0.rtp)) / (index == 2 ? 48_000 : 90_000)
                return seconds >= $0.ntp && abs((seconds - $0.ntp) - (now - $0.received)) <= 2 && abs(sourceElapsed - (seconds - $0.ntp)) <= 0.2
            } ??
                (abs((seconds - ntpOrigin!) - (now - originReceived!)) <= 2)
            if plausible {
                reports[role] = .init(rtp: rtp, ntp: seconds, received: now)
            }
            let request = plausible && index < 2 && needsIDR[index] && (index != 1 || screenApproved)
            lock.unlock(); if request { requestKeyframe(role) }; return
        }
        if index == 1 && !screenApproved { drops += 1; lock.unlock(); return }
        guard let data, count > 0, count <= (index == 2 ? 1275 : 2_097_152),
              let report = reports[role], now - report.received <= 3, let ntpOrigin, let hostOrigin else {
            unsynchronized += 1; lock.unlock(); return
        }
        let offset = Double(Int32(bitPattern: rtp &- report.rtp)) / (index == 2 ? 48_000 : 90_000)
        let pts = hostOrigin + report.ntp - ntpOrigin + offset
        guard offset >= -0.5, offset <= 3, abs(pts - now) <= 3 else { unsynchronized += 1; lock.unlock(); return }
        guard lastPTS[index].map({ pts > $0 }) ?? true else { drops += 1; lock.unlock(); return }
        lastPTS[index] = pts
        let payload = Data(bytes: data, count: count)
        receivedUnits[index] += 1
        if index < 2, needsIDR[index], !GuestH264Decoder.hasIDR(payload) { drops += 1; lock.unlock(); return }
        let capacity = index == 2 ? 32 : 3, byteLimit = index == 2 ? 40_800 : 2_097_152
        if pending[index].count >= capacity || bytes[index] + count > byteLimit {
            drops += pending[index].count + 1; pending[index].removeAll(); bytes[index] = 0
            if index < 2 { requireIDRLocked(index) }
            else { audioResetPending = true }
            lock.unlock(); if index < 2 { requestKeyframe(role) }; return
        }
        pending[index].append(.init(data: payload, pts: pts, arrival: now)); bytes[index] += count
        let start = !working[index]; working[index] = true; lock.unlock()
        if start { queues[index].async { [weak self] in self?.drain(role) } }
    }
    private func drain(_ role: Int32) {
        let index = Int(role)
        while true {
            lock.lock()
            let resetAudio = index == 2 && audioResetPending
            if resetAudio { audioResetPending = false }
            if resetAudio { lock.unlock(); audio = nil; lock.lock() }
            guard active, !pending[index].isEmpty else { working[index] = false; lock.unlock(); return }
            let input = pending[index].removeFirst(); bytes[index] -= input.data.count
            if hostSeconds() - input.arrival > 0.12 {
                drops += 1; expiredUnits[index] += 1; if index < 2 { requireIDRLocked(index) } else { audioResetPending = true }; lock.unlock()
                if index < 2 { requestKeyframe(role) }; continue
            }
            // A preceding queued AU may have expired since admission. Do
            // not submit a dependent P frame on a now-missing reference.
            if index < 2, needsIDR[index], !GuestH264Decoder.hasIDR(input.data) {
                drops += 1; lock.unlock(); requestKeyframe(role); continue
            }
            let submittedEpoch = index < 2 ? lossEpoch[index] : 0
            lock.unlock()
            do {
                if index == 2 {
                    if audio?.accepts(input.pts) == false { audio = nil }
                    if audio == nil { audio = try GuestOpusDecoder { [weak self] stage, status, detail in
                        self?.codecStatus(role: role, stage: stage, status: status, detail: detail)
                    } }
                    emitAudio(try audio!.decode(input.data, pts: input.pts))
                } else {
                    if videos[index] == nil {
                        videos[index] = GuestH264Decoder(output: { [weak self] pixels, pts, idr, submittedEpoch in
                            guard let self else { return }
                            self.outputGate.lock(); self.lock.lock()
                            self.decodedUnits[index] += 1
                            let current = self.active && (index != 1 || self.screenApproved)
                            if current && idr && self.lossEpoch[index] == submittedEpoch { self.needsIDR[index] = false }
                            self.lock.unlock()
                            if current { self.videoOutput(.init(lease: self.lease, role: GuestReceiveRole(rawValue: role)!, pixels: pixels, pts: pts,
                                duration: .invalid, mappingGeneration: self.mappingGeneration, clockQuality: .senderReportAligned)) }
                            self.outputGate.unlock()
                        }, diagnostic: { [weak self] stage, status, detail in
                            self?.codecStatus(role: role, stage: stage, status: status, detail: detail)
                        })
                    }
                    try videos[index]!.decode(input.data, pts: CMTime(seconds: input.pts, preferredTimescale: 1_000_000_000), lossEpoch: submittedEpoch)
                }
            } catch {
                FileHandle.standardError.write(Data("Guest decoder role \(role): \(error)\n".utf8))
                lock.lock(); decodeErrors += 1; if index < 2 { requireIDRLocked(index) } else { audioResetPending = true }; lock.unlock()
                if index < 2 { requestKeyframe(role) }
            }
        }
    }
    private func emitAudio(_ chunks: [GuestOpusDecoder.Chunk]) {
        for chunk in chunks {
            outputGate.lock(); lock.lock(); decodedUnits[2] += 1; let current = active; lock.unlock()
            if current { audioOutput(.init(lease: lease, pcm: chunk.pcm, pts: CMTime(seconds: chunk.pts, preferredTimescale: 1_000_000_000),
                duration: CMTime(value: Int64(chunk.pcm.frameLength), timescale: 48_000), mappingGeneration: mappingGeneration,
                clockQuality: .senderReportAligned)) }
            outputGate.unlock()
        }
    }
    func finishAudio() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queues[2].async { [weak self] in
                defer { continuation.resume() }; guard let self else { return }
                do { if let audio = self.audio { self.emitAudio(try audio.finish()) } }
                catch { FileHandle.standardError.write(Data("Guest decoder drain: \(error)\n".utf8)); self.lock.lock(); self.decodeErrors += 1; self.lock.unlock() }
            }
        }
    }
    func stop() {
        outputGate.lock(); lock.lock(); active = false; pending = [[], [], []]; signals.removeAll(); bytes = [0, 0, 0]; reports.removeAll(); lock.unlock(); outputGate.unlock()
        expiry?.cancel(); expiry = nil
        transportLock.lock(); if let handle { SGReceiverDestroy(handle); self.handle = nil }; transportLock.unlock()
        for index in 0..<2 { queues[index].async { [weak self] in self?.videos[index]?.close(); self?.videos[index] = nil } }
        queues[2].async { [weak self] in self?.audio = nil }
    }
    deinit { stop() }
}

private final class GuestH264Decoder {
    private var sps: Data?, pps: Data?, format: CMVideoFormatDescription?, session: VTDecompressionSession?
    private final class DecodeContext {
        let idr: Bool, lossEpoch: UInt64
        init(idr: Bool, lossEpoch: UInt64) { self.idr = idr; self.lossEpoch = lossEpoch }
    }
    private let output: (CVPixelBuffer, CMTime, Bool, UInt64) -> Void
    private let diagnostic: @Sendable (String, OSStatus, UInt32) -> Void
    init(output: @escaping (CVPixelBuffer, CMTime, Bool, UInt64) -> Void,
         diagnostic: @escaping @Sendable (String, OSStatus, UInt32) -> Void) {
        self.output = output; self.diagnostic = diagnostic
    }
    static func nals(_ data: Data) -> [Data] {
        let bytes = [UInt8](data); var starts: [(Int, Int)] = [], i = 0
        while i + 3 <= bytes.count {
            if bytes[i] == 0 && bytes[i + 1] == 0 {
                if bytes[i + 2] == 1 { if starts.count >= 512 { return [] }; starts.append((i, 3)); i += 3; continue }
                if i + 4 <= bytes.count && bytes[i + 2] == 0 && bytes[i + 3] == 1 { if starts.count >= 512 { return [] }; starts.append((i, 4)); i += 4; continue }
            }; i += 1
        }
        return starts.enumerated().compactMap { index, start in
            let end = index + 1 < starts.count ? starts[index + 1].0 : bytes.count
            return end > start.0 + start.1 ? Data(bytes[(start.0 + start.1)..<end]) : nil
        }
    }
    static func hasIDR(_ data: Data) -> Bool { nals(data).contains { $0.first.map { $0 & 31 == 5 } == true } }
    func decode(_ data: Data, pts: CMTime, lossEpoch: UInt64) throws {
        let units = Self.nals(data)
        for unit in units {
            guard let first = unit.first, first & 128 == 0, unit.count <= 2_097_152 else { throw GuestDecodeError.malformed }
            if first & 31 == 7, unit != sps { guard unit.count <= 65_536 else { throw GuestDecodeError.malformed }; sps = unit; close() }
            if first & 31 == 8, unit != pps { guard unit.count <= 65_536 else { throw GuestDecodeError.malformed }; pps = unit; close() }
        }
        if session == nil {
            guard let sps, let pps else { throw GuestDecodeError.malformed }
            let status = sps.withUnsafeBytes { a in pps.withUnsafeBytes { b in
                var pointers = [a.bindMemory(to: UInt8.self).baseAddress!, b.bindMemory(to: UInt8.self).baseAddress!]
                var sizes = [a.count, b.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: 2, parameterSetPointers: &pointers, parameterSetSizes: &sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &format)
            } }
            diagnostic("video-format", status, 0)
            guard status == noErr, let format else { throw GuestDecodeError.codec(status) }
            let dimensions = CMVideoFormatDescriptionGetDimensions(format)
            guard (1...1920).contains(dimensions.width), (1...1080).contains(dimensions.height) else { throw GuestDecodeError.unsupported }
            var callback = VTDecompressionOutputCallbackRecord(decompressionOutputCallback: { refcon, frameRefcon, status, flags, pixels, pts, _ in
                guard let refcon else { return }
                let owner = Unmanaged<GuestH264Decoder>.fromOpaque(refcon).takeUnretainedValue()
                owner.diagnostic("video-output", status, flags.rawValue | (pixels == nil ? 0 : 0x8000_0000))
                guard status == noErr, let pixels, let frameRefcon else { return }
                let input = Unmanaged<DecodeContext>.fromOpaque(frameRefcon).takeUnretainedValue()
                owner.output(pixels, pts, input.idr, input.lossEpoch)
            }, decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque())
            let created = VTDecompressionSessionCreate(allocator: nil, formatDescription: format,
                decoderSpecification: nil, imageBufferAttributes: [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as CFDictionary,
                outputCallback: &callback, decompressionSessionOut: &session)
            diagnostic("video-create", created, 0)
            guard created == noErr, session != nil else { throw GuestDecodeError.codec(created) }
        }
        var avcc = Data()
        for unit in units where [1, 5, 6].contains(Int(unit.first! & 31)) {
            var length = UInt32(unit.count).bigEndian; withUnsafeBytes(of: &length) { avcc.append(contentsOf: $0) }; avcc.append(unit)
        }
        guard !avcc.isEmpty else { throw GuestDecodeError.malformed }
        var block: CMBlockBuffer?, sample: CMSampleBuffer?
        let created = CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: avcc.count, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: avcc.count, flags: 0, blockBufferOut: &block)
        guard created == noErr, let block else { throw GuestDecodeError.codec(created) }
        let copied = avcc.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: $0.count) }
        guard copied == noErr else { throw GuestDecodeError.codec(copied) }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid), size = avcc.count
        let ready = CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        guard ready == noErr, let sample, let session else { throw GuestDecodeError.codec(ready) }
        let input = DecodeContext(idr: units.contains { $0.first.map { $0 & 31 == 5 } == true }, lossEpoch: lossEpoch)
        // One serial submit per role. Extend this sole callback context through
        // actual asynchronous completion, including errors/dropped output.
        try withExtendedLifetime(input) {
            var flags = VTDecodeInfoFlags()
            let decoded = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [],
                frameRefcon: Unmanaged.passUnretained(input).toOpaque(), infoFlagsOut: &flags)
            diagnostic("video-submit", decoded, flags.rawValue)
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            guard decoded == noErr else { throw GuestDecodeError.codec(decoded) }
        }
    }
    func close() { if let session { VTDecompressionSessionWaitForAsynchronousFrames(session); VTDecompressionSessionInvalidate(session) }; session = nil; format = nil }
    deinit { close() }
}
private final class GuestOpusDecoder {
    struct Chunk { let pcm: AVAudioPCMBuffer, pts: Double }
    private let codec: AudioCodec, pcmFormat: AVAudioFormat
    private var nextPTS: Double?, ended = false
    private let diagnostic: @Sendable (String, OSStatus, UInt32) -> Void
    func accepts(_ pts: Double) -> Bool { nextPTS.map { abs(pts - $0) <= 1.0 / 48_000 } ?? true }
    init(diagnostic: @escaping @Sendable (String, OSStatus, UInt32) -> Void) throws {
        self.diagnostic = diagnostic
        // Public AudioCodec exposes decoder trimming before initialization.
        // AVAudioConverter's default decoder omits120 leading CELT samples on
        // the qualified current OS; configuring this property after initialize
        // is a state error. RTP carries no Ogg pre-skip or private cookie.
        var description = AudioComponentDescription(componentType: kAudioDecoderComponentType, componentSubType: kAudioFormatOpus,
            componentManufacturer: 0, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else { throw GuestDecodeError.unsupported }
        var instance: AudioComponentInstance?
        let created = AudioComponentInstanceNew(component, &instance)
        diagnostic("opus-create", created, 0)
        guard created == noErr, let instance else { throw GuestDecodeError.codec(created) }
        var initialized = false
        defer { if !initialized { AudioComponentInstanceDispose(instance) } }
        var propertySize: UInt32 = 0, writable: DarwinBoolean = false
        let info = AudioCodecGetPropertyInfo(instance, kAudioCodecPropertyPrimeInfo, &propertySize, &writable)
        diagnostic("opus-prime-info", info, propertySize | (writable.boolValue ? 0x8000_0000 : 0))
        guard info == noErr, writable.boolValue, propertySize == MemoryLayout<AudioCodecPrimeInfo>.size else { throw GuestDecodeError.unsupported }
        var prime = AudioCodecPrimeInfo(leadingFrames: 0, trailingFrames: 0)
        let configured = AudioCodecSetProperty(instance, kAudioCodecPropertyPrimeInfo, propertySize, &prime)
        diagnostic("opus-prime-set", configured, 0)
        guard configured == noErr else { throw GuestDecodeError.codec(configured) }
        var input = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: 0, mBytesPerFrame: 0, mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
        var output = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8, mFramesPerPacket: 1,
            mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        guard let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false) else { throw GuestDecodeError.unsupported }
        let ready = AudioCodecInitialize(instance, &input, &output, nil, 0)
        diagnostic("opus-initialize", ready, 0)
        guard ready == noErr else { throw GuestDecodeError.codec(ready) }
        initialized = true; codec = instance; pcmFormat = pcm
    }
    static func duration(_ data: Data) throws -> UInt32 {
        guard let toc = data.first else { throw GuestDecodeError.malformed }
        let config = Int(toc >> 3), samples: UInt32
        if config < 12 { samples = [480, 960, 1920, 2880][config & 3] }
        else if config < 16 { samples = [480, 960][config & 1] }
        else { samples = [120, 240, 480, 960][config & 3] }
        let count: UInt32
        switch toc & 3 { case 0: count = 1; case 1, 2: count = 2; default:
            guard data.count >= 2 else { throw GuestDecodeError.malformed }; count = UInt32(data[data.startIndex + 1] & 63) }
        guard count > 0, count <= 48, samples * count <= 5760 else { throw GuestDecodeError.malformed }
        return samples * count
    }
    func decode(_ data: Data, pts: Double) throws -> [Chunk] {
        let frames = try Self.duration(data)
        guard !ended, accepts(pts), data.count <= 1275 else { throw GuestDecodeError.malformed }
        var bytes = UInt32(data.count), packets: UInt32 = 1
        var packet = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: frames, mDataByteSize: bytes)
        let appended = data.withUnsafeBytes { AudioCodecAppendInputData(codec, $0.baseAddress!, &bytes, &packets, &packet) }
        diagnostic("opus-append", appended, packets)
        guard appended == noErr, packets == 1, bytes == data.count else { throw GuestDecodeError.codec(appended) }
        var samples = [Float](repeating: 0, count: 5760 * 2), outputBytes: UInt32 = 5760 * 8, outputFrames: UInt32 = 5760, status: UInt32 = 0
        let decoded = AudioCodecProduceOutputPackets(codec, &samples, &outputBytes, &outputFrames, nil, &status)
        diagnostic("opus-output", decoded, outputFrames)
        guard decoded == noErr, outputFrames == frames, outputBytes == frames * 8,
              status == kAudioCodecProduceOutputPacketSuccess || status == kAudioCodecProduceOutputPacketSuccessHasMore else {
            throw GuestDecodeError.audioFrames(expected: frames, actual: outputFrames, code: Int(decoded))
        }
        guard let pcm = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: frames) else { throw GuestDecodeError.unsupported }
        pcm.frameLength = frames
        for channel in 0..<2 { for index in 0..<Int(frames) { pcm.floatChannelData![channel][index] = samples[index * 2 + channel] } }
        nextPTS = pts + Double(frames) / 48_000
        return [.init(pcm: pcm, pts: pts)]
    }
    func finish() throws -> [Chunk] { ended = true; return [] } // no retained samples: every packet's actual count was checked
    deinit { AudioCodecUninitialize(codec); AudioComponentInstanceDispose(codec) }
}
