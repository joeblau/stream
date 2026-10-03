import Darwin
import Foundation

enum RecordingChatError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil }
}

struct RecordingChatInspection: Sendable {
    let header: RecordingChatHeader
    let summary: RecordingChatSummary?
    let recovered: Bool
    let records: Int
    let duration: Double
}

enum RecordingChatReader {
    static func basename(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 255 && ![".", ".."].contains(name)
            && !name.contains("/") && !name.contains("\\") && !name.contains("\0")
    }
    static func summary(_ url: URL) -> RecordingChatSummary? {
        guard let file = try? FileHandle(forReadingFrom: url.appendingPathExtension("summary.json")) else { return nil }
        defer { try? file.close() }
        guard let data = try? file.read(upToCount: 65_537), data.count <= 65_536 else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(RecordingChatSummary.self, from: data)
    }
    /// Stream bounded lines; a truncated final line or damaged later record
    /// preserves the ordered valid prefix. Unknown headers are never guessed.
    @discardableResult static func scan(_ url: URL,
        header acceptHeader: (RecordingChatHeader) throws -> Void = { _ in },
        record acceptRecord: (RecordingChatRecord) throws -> Void = { _ in }) throws -> RecordingChatInspection {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw RecordingChatError.invalid("The chat archive is unavailable.") }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        let size = try file.seekToEnd(); try file.seek(toOffset: 0)
        guard size <= 256_000_000 else { throw RecordingChatError.invalid("The chat archive exceeds its size limit.") }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var header: RecordingChatHeader?
        var bytes = Data(), recovered = false, count = 0, time = 0.0, stopped = false
        while !stopped, let chunk = try file.read(upToCount: 16_384), !chunk.isEmpty {
            bytes.append(chunk)
            while let end = bytes.firstIndex(of: 10) {
                let line = Data(bytes[..<end]); bytes.removeSubrange(...end)
                guard line.count <= 65_536 else { recovered = true; stopped = true; break }
                if header == nil {
                    let value = try decoder.decode(RecordingChatHeader.self, from: line)
                    guard value.type == "header", value.version == 1, basename(value.programFile),
                          value.segmentIndex > 0, UUID(uuidString: value.sessionID) != nil,
                          (value.sourceStartSeconds.map { $0.isFinite && $0 >= 0 } ?? true) else {
                        throw RecordingChatError.invalid("Unsupported or invalid chat archive header.")
                    }
                    header = value; try acceptHeader(value)
                } else {
                    guard count < 500_000, var value = try? decoder.decode(RecordingChatRecord.self, from: line),
                          value.isValid, value.seconds >= time else { recovered = true; stopped = true; break }
                    if header?.includesAuthors == false { value.message?.author = nil }
                    time = value.seconds; count += 1; try acceptRecord(value)
                }
            }
            if bytes.count > 65_536 { recovered = true; stopped = true }
        }
        guard let header else { throw RecordingChatError.invalid("The chat archive has no valid header yet.") }
        if !bytes.isEmpty { recovered = true }
        var summary = summary(url)
        if let value = summary, !value.durationSeconds.isFinite || value.durationSeconds < time || value.durationSeconds >= 31_536_000
            || value.header.programFile != header.programFile || value.header.context != header.context {
            summary = nil
        }
        if summary?.version != 1 || summary?.status != "complete" || summary?.bytes != Int64(size) || summary?.records != count
            || summary?.header.sessionID != header.sessionID || summary?.header.segmentIndex != header.segmentIndex { recovered = true }
        return .init(header: header, summary: summary, recovered: recovered, records: count,
            duration: max(time, summary?.durationSeconds ?? 0))
    }

    static func export(_ source: URL, format: RecordingChatFormat, to output: URL) throws {
        guard source.standardizedFileURL != output.standardizedFileURL else { throw RecordingChatError.invalid("Choose a new file to preserve the archive.") }
        let descriptor = open(output.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw RecordingChatError.invalid("Choose an unused output file name in a writable folder.") }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var success = false
        defer { try? file.close(); if !success { try? FileManager.default.removeItem(at: output) } }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        func write(_ text: String) throws { try file.write(contentsOf: Data(text.utf8)) }
        var first = true, cueNumber = 0
        var active: [String: RecordingChatRecord] = [:]
        func key(_ value: RecordingChatRecord) -> String { (value.slotID ?? "") + ":" + (value.messageID ?? value.message?.id ?? "") + ":" + (value.pageIndex.map(String.init) ?? "") }
        func cue(_ value: RecordingChatRecord, until end: Double) throws {
            guard let message = value.message, end > value.seconds else { return }
            cueNumber += 1
            let body = [message.author, value.paintedBody].compactMap { $0 }.joined(separator: "\n")
                .replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\r", with: "")
                .split(separator: "\n", omittingEmptySubsequences: true).joined(separator: "\n")
            let separator = format == .srt ? "," : "."
            try write("\(cueNumber)\n\(timestamp(value.seconds, separator)) --> \(timestamp(end, separator))\n\(body)\n\n")
        }
        let inspection = try scan(source, header: { header in
            switch format {
            case .json: try write("{\"header\":"); try file.write(contentsOf: encoder.encode(header)); try write(",\"events\":[\n")
            case .csv: try write("seconds,type,slot_id,message_id,platform,author,text,provider_timestamp,receipt_timestamp,while_paused,title,page_index,page_count,painted_text\n")
            case .vtt: try write("WEBVTT\n\n")
            case .srt: break
            }
        }, record: { value in
            switch format {
            case .json:
                if !first { try write(",\n") }; first = false
                try file.write(contentsOf: encoder.encode(value))
            case .csv:
                let m = value.message
                var cells: [String] = [String(format: "%.6f", value.seconds), value.type, value.slotID ?? "", value.messageID ?? m?.id ?? "",
                    m?.platform ?? "", m?.author ?? "", m?.text ?? "", m.map { ISO8601DateFormatter().string(from: $0.providerTimestamp) } ?? "",
                    m.map { String($0.timestampIsReceiptTime) } ?? "", value.whilePaused.map(String.init) ?? "", value.title ?? ""]
                cells.append(value.pageIndex.map(String.init) ?? "")
                cells.append(value.pageCount.map(String.init) ?? "")
                cells.append(value.type == "show" ? value.paintedBody ?? "" : "")
                try write(cells.map(csvCell).joined(separator: ",") + "\n")
            case .vtt, .srt:
                let id = key(value)
                if value.type == "hide", let previous = active.removeValue(forKey: id) { try cue(previous, until: value.seconds) }
                else if value.type == "show" {
                    if let previous = active.removeValue(forKey: id) { try cue(previous, until: value.seconds) }
                    guard active.count < 32 else { throw RecordingChatError.invalid("Archive exceeds the featured-comment limit.") }
                    active[id] = value
                }
            }
        })
        if format == .json { try write("\n],\"recovered\":\(inspection.recovered)}\n") }
        if format == .vtt || format == .srt {
            for value in active.values.sorted(by: { $0.seconds < $1.seconds }) { try cue(value, until: inspection.duration) }
        }
        try file.synchronize(); success = true
    }
    private static func csvCell(_ value: String) -> String {
        // Public chat must not become a spreadsheet formula on export.
        let risky = value.first.map { "=+-@\t\r".contains($0) } ?? false
        let safe = (risky ? "'" : "") + value
        return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
    private static func timestamp(_ seconds: Double, _ separator: String) -> String {
        let ms = Int((max(0, seconds) * 1000).rounded())
        return String(format: "%02d:%02d:%02d%@%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, separator, ms % 1000)
    }
    /// Retention is opt-in, profile scoped and only removes our closed complete
    /// archives. Media and interrupted/unknown archives are always preserved.
    static func applyRetention(directory: URL, context: RecordingContext, days: Int, now: Date = Date()) throws {
        guard days > 0, context.projectID != nil, context.profileID != nil else { return }
        let expiry = now.addingTimeInterval(-Double(min(3650, days)) * 86_400)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        for url in files.prefix(10_000) where url.lastPathComponent.hasSuffix(".chat.jsonl") {
            guard let info = summary(url), info.version == 1, info.status == "complete", let date = info.completedAt, date < expiry,
                  info.header.context.projectID == context.projectID, info.header.context.profileID == context.profileID,
                  let inspection = try? scan(url), !inspection.recovered else { continue }
            try FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.appendingPathExtension("summary.json"))
        }
    }
}
