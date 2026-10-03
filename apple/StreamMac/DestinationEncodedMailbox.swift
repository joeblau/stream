import CoreMedia
import Foundation

/// The queue keeps contiguous compressed references. On overflow it clears the
/// queued GOP, sheds audio/video until a new IDR and requests that IDR once.
/// An in-flight old frame may finish; no subsequent dependent frame is sent.
final class DestinationEncodedMailbox: @unchecked Sendable {
    private enum Packet {
        case video(CMSampleBuffer)
        case audio(SharedEncodedAudio)
        var bytes: Int {
            switch self { case .video(let s): return s.totalSampleSize; case .audio(let a): return Int(a.buffer.byteLength) }
        }
    }
    private let lock = NSLock()
    private var packets: [Packet] = []
    private var bytes = 0, drops = 0
    private var enabled = false, accepting = true, needsKeyframe = true
    private let maximumPackets: Int, maximumBytes: Int
    private let continuation: AsyncStream<Void>.Continuation
    private var consumer: Task<Void, Never>?
    private let requestKeyframe: @Sendable () -> Void
    init(publisher: any Publisher, maximumPackets: Int = 64, maximumBytes: Int = 4 * 1024 * 1024,
         requestKeyframe: @escaping @Sendable () -> Void) {
        self.maximumPackets = maximumPackets; self.maximumBytes = maximumBytes; self.requestKeyframe = requestKeyframe
        let (signal, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        self.continuation = continuation
        consumer = Task { [weak self] in
            for await _ in signal {
                guard let self else { return }
                while !Task.isCancelled, let packet = self.next() {
                    switch packet {
                    case .video(let sample): if await publisher.appendEncodedVideo(sample) { self.requestKeyframe() }
                    case .audio(let sample): if await publisher.appendEncodedAudio(sample) { self.requestKeyframe() }
                    }
                }
            }
        }
    }
    private func next() -> Packet? {
        lock.lock(); defer { lock.unlock() }
        guard accepting, enabled, !packets.isEmpty else { return nil }
        let packet = packets.removeFirst(); bytes -= packet.bytes; return packet
    }
    func setPublished(_ published: Bool) {
        lock.lock(); enabled = published; needsKeyframe = true; packets.removeAll(); bytes = 0; lock.unlock()
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
        if needsKeyframe && !keyframe { drops += 1; lock.unlock(); return }
        if packet.bytes > maximumBytes || packets.count >= maximumPackets || bytes + packet.bytes > maximumBytes {
            drops += packets.count + 1; packets.removeAll(); bytes = 0; needsKeyframe = true
            lock.unlock(); requestKeyframe(); return
        }
        if keyframe { needsKeyframe = false }
        packets.append(packet); bytes += packet.bytes
        lock.unlock(); continuation.yield(())
    }
    func statistics() -> (depth: Int, drops: Int, bytes: Int, waitingForKeyframe: Bool) {
        lock.lock(); defer { lock.unlock() }; return (packets.count, drops, bytes, needsKeyframe)
    }
    func stop() {
        lock.lock(); accepting = false; enabled = false; packets.removeAll(); bytes = 0; lock.unlock()
        continuation.finish(); consumer?.cancel()
    }
}
