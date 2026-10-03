import CoreMedia
import Darwin
import Foundation

/// Append-only, bounded and independent of the media writer. A broken/full
/// archive volume preserves the valid prefix and never stops media or network
/// output. Only accepted video frames may produce visibility records.
final class RecordingChatArchive: @unchecked Sendable {
    let url: URL
    private let timeline: RecordingTimeline
    private let preferences: RecordingChatPreferences
    private let queue = DispatchQueue(label: "com.joeblau.Stream.recording.public-chat")
    private let lock = NSLock()
    private enum Input {
        case message(RecordingChatMessage, Double, Bool)
        case frame(RecordingChatFrame, [RecordingChatBinding])
        case marker(RecordingMarker)
        var bytes: Int {
            switch self {
            case .message(let m, _, _): return m.text.utf8.count + 1024
            case .frame(_, let b): return b.reduce(128) { $0 + $1.message.text.utf8.count + 1024 }
            case .marker(let m): return m.title.utf8.count + 128
            }
        }
    }
    private var incoming: [Input] = []
    private var incomingBytes = 0
    private var dropped = 0
    private var latestAcceptedEnd = 0.0
    private var accepting = true
    // Queue confined.
    private var pending: [(RecordingChatRecord, Int)] = []
    private var order = 0
    private var otherDrops = 0
    private var active: [RecordingChatPaint: RecordingChatMessage] = [:]
    private var seen: Set<String> = []
    private var seenOrder: [String] = []
    private var handle: FileHandle?
    private var ownsFile = false
    private var timer: DispatchSourceTimer?
    private var summary: RecordingChatSummary
    private var headerWritten = false
    private var lastFrameTime = Date()
    private var lastSummaryTime = Date.distantPast
    private var videoEnd = 0.0
    private var lastWrittenSeconds = 0.0
    private var failed = false
    private var finished = false
    private let update: @Sendable (RecordingChatSummary) -> Void

    init(programURL: URL, sessionID: String, segmentIndex: Int, context: RecordingContext,
         timeline: RecordingTimeline, preferences: RecordingChatPreferences,
         update: @escaping @Sendable (RecordingChatSummary) -> Void = { _ in }) {
        url = programURL.appendingPathExtension("chat.jsonl")
        self.timeline = timeline; self.preferences = preferences; self.update = update
        RecordingChatPaintDemand.shared.acquire()
        summary = .init(header: .init(sessionID: sessionID, segmentIndex: segmentIndex,
            programFile: programURL.lastPathComponent, context: context, createdAt: Date(), includesAuthors: preferences.includeAuthors))
        queue.async { [self] in
            let descriptor = open(url.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { fail("Chat archive could not be created. Recording continues."); return }
            ownsFile = true
            handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(25))
            timer.setEventHandler { [weak self] in self?.pump() }
            self.timer = timer; timer.resume()
        }
    }
    deinit { RecordingChatPaintDemand.shared.release() }
    func receive(_ message: RecordingChatMessage, at sourceTime: CMTime) {
        let clock = timeline.snapshot()
        let frozen = clock.paused || clock.waitingForResume
        let seconds: Double
        if frozen { lock.lock(); seconds = latestAcceptedEnd; lock.unlock() }
        else if clock.origin.isNumeric { seconds = (sourceTime - clock.offset - clock.origin).seconds }
        else { return } // Countdown/preparing chat is outside the media timeline.
        guard message.isValid, seconds.isFinite, seconds >= 0 else { return }
        enqueue(.message(message, seconds, frozen))
    }
    func frame(_ frame: RecordingChatFrame, bindings: [RecordingChatBinding]) {
        guard frame.seconds.isFinite, frame.seconds >= 0, frame.endSeconds.isFinite else { return }
        lock.lock(); latestAcceptedEnd = max(latestAcceptedEnd, frame.endSeconds); lock.unlock()
        enqueue(.frame(frame, Array(bindings.prefix(32))))
    }
    func marker(_ value: RecordingMarker) { enqueue(.marker(value)) }
    private func enqueue(_ value: Input) {
        lock.lock(); defer { lock.unlock() }
        guard accepting else { return }
        guard incoming.count < 128, incomingBytes + value.bytes <= 4_000_000 else { dropped += 1; return }
        incoming.append(value); incomingBytes += value.bytes
    }
    func finish(completed: Bool, completion: @escaping @Sendable () -> Void) {
        lock.lock(); accepting = false; lock.unlock()
        queue.async { [self] in
            guard !finished else { completion(); return }
            pump(final: true)
            if !failed {
                for paint in active.keys.sorted(by: Self.paintOrder) {
                    add(.init(type: "hide", seconds: videoEnd, slotID: paint.slotID, messageID: paint.messageID, pageIndex: paint.pageIndex, pageCount: paint.pageCount))
                }
                active.removeAll(); flush(upTo: videoEnd, final: true)
                summary.status = completed ? "complete" : "partial"
            }
            summary.completedAt = Date(); summary.durationSeconds = videoEnd
            do { try handle?.synchronize(); try handle?.close() }
            catch { fail("Chat archive could not be finalized. Its valid prefix is preserved.") }
            handle = nil; timer?.cancel(); timer = nil; finished = true
            saveSummary(); completion()
        }
    }
    private static func paintOrder(_ a: RecordingChatPaint, _ b: RecordingChatPaint) -> Bool {
        (a.slotID, a.messageID, a.fingerprint) < (b.slotID, b.messageID, b.fingerprint)
    }
    private func pump(final: Bool = false) {
        guard !failed, !finished else { return }
        let clock = timeline.snapshot()
        if !headerWritten, clock.origin.isNumeric {
            summary.header.sourceStartSeconds = clock.origin.seconds
            write(summary.header); headerWritten = !failed
        }
        // A first accepted frame can arrive after the clock snapshot above.
        // Keep its bounded batch until the next pump can write the header.
        guard headerWritten else { return }
        lock.lock(); let batch = incoming; incoming.removeAll(keepingCapacity: true); incomingBytes = 0
        summary.droppedEvents = dropped + otherDrops; lock.unlock()
        for value in batch {
            switch value {
            case .message(var message, let seconds, let paused):
                guard !seen.contains(message.id) else { continue }
                seen.insert(message.id); seenOrder.append(message.id)
                if seenOrder.count > 4000 { seen.remove(seenOrder.removeFirst()) }
                if !preferences.includeAuthors { message.author = nil }
                add(.init(type: "message", seconds: seconds, message: message, whilePaused: paused))
            case .marker(let marker):
                add(.init(type: "marker", seconds: marker.seconds, title: String(marker.title.prefix(500))))
            case .frame(let frame, let bindings):
                lastFrameTime = Date(); videoEnd = max(videoEnd, frame.endSeconds)
                let next = Dictionary(bindings.map { ($0.paint, $0.message) }, uniquingKeysWith: { first, _ in first })
                for paint in active.keys.filter({ next[$0] == nil }).sorted(by: Self.paintOrder) {
                    add(.init(type: "hide", seconds: frame.seconds, slotID: paint.slotID, messageID: paint.messageID, pageIndex: paint.pageIndex, pageCount: paint.pageCount))
                }
                for paint in next.keys.filter({ active[$0] == nil }).sorted(by: Self.paintOrder) {
                    var message = next[paint]!
                    if !preferences.includeAuthors { message.author = nil }
                    add(.init(type: "show", seconds: frame.seconds, message: message, slotID: paint.slotID, messageID: paint.messageID,
                        bodyUTF16Start: paint.bodyUTF16Start, bodyUTF16Length: paint.bodyUTF16Length,
                        pageIndex: paint.pageIndex, pageCount: paint.pageCount))
                }
                active = next
            }
        }
        // A short holdback merges host-clock receipts with encoder-delayed
        // frames in order. A pause freezes receipts at the shared media end.
        let paused = clock.paused || clock.waitingForResume
        let watermark = paused && Date().timeIntervalSince(lastFrameTime) > 0.2 ? videoEnd : max(0, videoEnd - 0.2)
        flush(upTo: final ? videoEnd : watermark, final: final)
        summary.durationSeconds = videoEnd
        if summary.droppedEvents > 0 { summary.warning = "Chat archive dropped \(summary.droppedEvents) events under load." }
        if !final, Date().timeIntervalSince(lastSummaryTime) >= 1 {
            do { try handle?.synchronize() }
            catch { fail("Chat archive could not be checkpointed. Recording continues."); return }
            saveSummary(); lastSummaryTime = Date()
        }
    }
    private func add(_ value: RecordingChatRecord) {
        guard value.isValid else { return }
        guard pending.count < 256 else { otherDrops += 1; summary.droppedEvents += 1; return }
        pending.append((value, order)); order += 1
    }
    private func flush(upTo seconds: Double, final: Bool) {
        pending.sort { $0.0.seconds == $1.0.seconds ? $0.1 < $1.1 : $0.0.seconds < $1.0.seconds }
        var remaining: [(RecordingChatRecord, Int)] = []
        for (var record, ordinal) in pending {
            if record.seconds > seconds { if !final { remaining.append((record, ordinal)) } else { otherDrops += 1; summary.droppedEvents += 1 }; continue }
            // Extremely late encoder delivery retains ordering and reports
            // the coarsened time instead of claiming frame-accurate ordering.
            if record.seconds < lastWrittenSeconds { record.seconds = lastWrittenSeconds; otherDrops += 1; summary.droppedEvents += 1 }
            write(record); lastWrittenSeconds = record.seconds; summary.records += 1
        }
        pending = remaining
    }
    private func write<Value: Encodable>(_ value: Value) {
        guard !failed else { return }
        do {
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
            var data = try encoder.encode(value); data.append(10)
            guard summary.records < 500_000, summary.bytes + Int64(data.count) <= 256_000_000 else {
                fail("Chat archive reached its size limit. Recording continues."); return
            }
            try handle?.write(contentsOf: data); summary.bytes += Int64(data.count)
        } catch { fail("Chat archive write failed. Its valid prefix is preserved; recording continues.") }
    }
    private func fail(_ warning: String) {
        failed = true; summary.status = "partial"; summary.warning = warning
        lock.lock(); accepting = false; incoming.removeAll(); incomingBytes = 0; lock.unlock()
        timer?.cancel(); timer = nil
        try? handle?.close(); handle = nil
        saveSummary()
    }
    private func saveSummary() {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        if ownsFile, let data = try? encoder.encode(summary) { try? data.write(to: url.appendingPathExtension("summary.json"), options: .atomic) }
        update(summary)
    }
}
