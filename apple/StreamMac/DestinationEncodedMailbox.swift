import CoreMedia
import Foundation

/// A bounded compressed GOP queue. At publication/rejoin, retain the IDR until
/// its nearest content-timestamped AAC packet is known: both transport libraries
/// independently zero their first audio/video timestamps. Starting arbitrary
/// callback-order packets would otherwise discard their actual clock offset.
final class DestinationEncodedMailbox: @unchecked Sendable {
    private enum Packet {
        case prepareAudio(SharedEncodedAudio)
        case video(CMSampleBuffer)
        case audio(SharedEncodedAudio)
        var bytes: Int {
            switch self {
            case .prepareAudio: return 0 // The queued audio owns this same reference.
            case .video(let s): return s.totalSampleSize
            case .audio(let a): return Int(a.buffer.byteLength)
            }
        }
    }
    private let lock = NSLock()
    private var packets: [Packet] = []
    private var startupVideo: [CMSampleBuffer] = []
    private var startupAudio: [SharedEncodedAudio] = []
    private var bytes = 0, drops = 0
    private var enabled = false, accepting = true, stopped = false, inFlight = false, needsKeyframe = true
    private let maximumPackets: Int, maximumBytes: Int
    private let continuation: AsyncStream<Void>.Continuation
    private var consumer: Task<Void, Never>?
    private let requestKeyframe: @Sendable () -> Void
    init(publisher: any Publisher, maximumPackets: Int = 64, maximumBytes: Int = 4 * 1024 * 1024,
         requestKeyframe: @escaping @Sendable () -> Void) {
        self.maximumPackets = max(4, maximumPackets); self.maximumBytes = maximumBytes; self.requestKeyframe = requestKeyframe
        let (signal, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        self.continuation = continuation
        consumer = Task { [weak self] in
            for await _ in signal {
                guard let self else { return }
                while !Task.isCancelled, let packet = self.next() {
                    switch packet {
                    case .prepareAudio(let sample): await publisher.prepareEncodedAudio(sample)
                    case .video(let sample): if await publisher.appendEncodedVideo(sample) { self.requestKeyframe() }
                    case .audio(let sample): if await publisher.appendEncodedAudio(sample) { self.requestKeyframe() }
                    }
                    self.consumed()
                }
            }
        }
    }
    private var depth: Int { packets.count + startupVideo.count + startupAudio.count }
    private func clearLocked() {
        packets.removeAll(); startupVideo.removeAll(); startupAudio.removeAll(); bytes = 0; needsKeyframe = true
    }
    private func next() -> Packet? {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, enabled, !packets.isEmpty else { return nil }
        let packet = packets.removeFirst(); bytes -= packet.bytes; inFlight = true; return packet
    }
    private func consumed() {
        lock.lock(); inFlight = false; lock.unlock()
    }
    func setPublished(_ published: Bool) {
        lock.lock(); enabled = published; clearLocked(); lock.unlock()
        if published { requestKeyframe() }
    }
    func enqueueVideo(_ sample: CMSampleBuffer) {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[String: Any]]
        let keyframe = attachments?.first?[kCMSampleAttachmentKey_NotSync as String] as? Bool != true
        enqueue(.video(sample), keyframe: keyframe)
    }
    func enqueueAudio(_ sample: SharedEncodedAudio) { enqueue(.audio(sample), keyframe: false) }
    private func enqueue(_ packet: Packet, keyframe: Bool) {
        lock.lock()
        guard accepting, enabled else { lock.unlock(); return }
        if needsKeyframe, case .video = packet, startupVideo.isEmpty, !keyframe {
            drops += 1; lock.unlock(); return
        }
        // Reserve one control entry for AAC-format preparation at startup.
        if packet.bytes > maximumBytes || depth >= maximumPackets - (needsKeyframe ? 1 : 0) || bytes + packet.bytes > maximumBytes {
            drops += depth + 1; clearLocked()
            lock.unlock(); requestKeyframe(); return
        }
        bytes += packet.bytes
        if needsKeyframe {
            switch packet {
            case .video(let sample): startupVideo.append(sample)
            case .audio(let sample): startupAudio.append(sample)
            case .prepareAudio: break
            }
            if startupVideo.isEmpty {
                // Keep a short look-behind while awaiting an IDR, rather than
                // accumulating audio indefinitely when video is unavailable.
                while startupAudio.count > min(8, maximumPackets - 1) {
                    bytes -= Int(startupAudio.removeFirst().buffer.byteLength); drops += 1
                }
            } else if let anchor = startupVideo.first?.presentationTimeStamp,
                      let latest = startupAudio.last?.sample.presentationTimeStamp, latest >= anchor,
                      let nearest = startupAudio.indices.min(by: {
                          abs((startupAudio[$0].sample.presentationTimeStamp - anchor).seconds) < abs((startupAudio[$1].sample.presentationTimeStamp - anchor).seconds)
                      }) {
                let audio = startupAudio[nearest]
                // A stale IDR outside the retained audio window cannot establish
                // a common origin. Request a current one instead of publishing
                // a silently shifted timeline.
                guard abs((audio.sample.presentationTimeStamp - anchor).seconds) <= 1024.0 / 48_000 else {
                    drops += startupVideo.count
                    bytes -= startupVideo.reduce(0) { $0 + $1.totalSampleSize }; startupVideo.removeAll()
                    lock.unlock(); requestKeyframe(); return
                }
                for old in startupAudio[..<nearest] { bytes -= Int(old.buffer.byteLength); drops += 1 }
                packets = [.prepareAudio(audio), .video(startupVideo[0]), .audio(audio)]
                packets += startupVideo.dropFirst().map(Packet.video)
                packets += startupAudio.dropFirst(nearest + 1).map(Packet.audio)
                startupAudio.removeAll(); startupVideo.removeAll(); needsKeyframe = false
            }
        } else {
            packets.append(packet)
        }
        lock.unlock(); continuation.yield(())
    }
    func statistics() -> (depth: Int, drops: Int, bytes: Int, waitingForKeyframe: Bool) {
        lock.lock(); defer { lock.unlock() }; return (depth, drops, bytes, needsKeyframe)
    }
    /// The encoder has stopped admitting input and delivered its EOS packets.
    /// Drain this destination only; a stalled adapter cannot hold other outputs.
    func finish(timeout: Double = 1) async -> Bool {
        lock.withLock {
            accepting = false
            // Startup/recovery without an IDR has no decodable GOP to drain.
            if needsKeyframe { drops += depth; clearLocked() }
        }
        continuation.yield(())
        let deadline = ContinuousClock.now.advanced(by: .seconds(max(0, min(2, timeout))))
        repeat {
            if lock.withLock({ packets.isEmpty && !inFlight }) { return true }
            if Task.isCancelled { return false }
            do { try await Task.sleep(for: .milliseconds(5)) } catch { return false }
        } while ContinuousClock.now < deadline
        return false
    }
    func stop() {
        lock.lock(); accepting = false; enabled = false; stopped = true; clearLocked(); lock.unlock()
        continuation.finish(); consumer?.cancel()
    }
}
