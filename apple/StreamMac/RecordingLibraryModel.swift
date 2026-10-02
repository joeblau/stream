import AppKit
import AVFoundation
import Combine
import Foundation

struct RecordingLibraryEntry: Identifiable {
    var id: URL { url }
    let url: URL
    let sessionID: String
    let segmentIndex: Int
    let startedAt: Date
    let context: RecordingContext
    let duration: Double
    let bytes: Int64
    let tracks: [String]
    let manifestSummary: String
    let status: String
    let error: String?
    let markers: [RecordingMarker]
    let thumbnail: NSImage?
    let canExport: Bool
    var chatURL: URL? = nil
    var chatSummary: RecordingChatSummary? = nil
}

private struct RecordingJournalSummary: Decodable, Sendable {
    let sessionID: String?
    let segmentIndex: Int?
    let startedAt: Date?
    let context: RecordingContext?
    let status: String?
    let error: String?
    let markers: [RecordingMarker]?
    let isolatedFiles: [String]?
    let chatArchiveFile: String?
    let videoStartOffsetSeconds: Double?
    let audioStartOffsetSeconds: Double?
    let progress: TrackSummary?
    struct TrackSummary: Decodable, Sendable {
        let videoStatus: String?
        let audioStatus: String?
        let droppedVideo: Int?
        let droppedAudio: Int?
    }
}

private struct IsolatedJournalSummary: Decodable, Sendable {
    let sessionID: String
    let segmentIndex: Int
    let programFile: String
    let selection: IsolatedRecordingSelection
    let context: RecordingContext
    let startOffsetSeconds: Double?
    let pauseOffsetSeconds: Double
    let gaps: [Gap]
    let progress: IsolatedTrackProgress
    struct Gap: Decodable, Sendable { let reason: String; let missingFrames: Int64 }
}
private struct IsolatedVideoJournalSummary: Decodable, Sendable {
    let sessionID: String
    let segmentIndex: Int
    let programFile: String
    let selection: IsolatedVideoSelection
    let context: RecordingContext
    let sourceStartOffsetSeconds: Double?
    let gaps: [Gap]
    let progress: IsolatedVideoProgress
    struct Gap: Decodable, Sendable { let reason: String; let durationSeconds: Double }
}

enum RecordingMarkerFormat: String, CaseIterable {
    case json, csv, txt
    var title: String { rawValue.uppercased() }
}

/// Reads actual media and journals rather than treating every orphan as a
/// successful recording. Async asset inspection/thumbnail generation does not
/// run decoding on the UI actor. The selected folder grant lives with the model.
@MainActor final class RecordingLibraryModel: ObservableObject {
    @Published private(set) var entries: [RecordingLibraryEntry] = []
    @Published private(set) var loading = false
    @Published private(set) var exporting = false
    @Published private(set) var error: String?
    private var access: RecordingDirectoryAccess?
    private var requestID = UUID()

    func refresh(access: RecordingDirectoryAccess, activeURLs: Set<URL>) async {
        self.access = access
        let request = UUID(); requestID = request
        loading = true; error = nil
        do {
            let urls = try await Task.detached(priority: .utility) {
                try FileManager.default.contentsOfDirectory(at: access.url,
                    includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
                    .filter { ["mp4", "mov", "wav", "m4a"].contains($0.pathExtension.lowercased()) }
                    .sorted { $0.lastPathComponent > $1.lastPathComponent }
            }.value
            var loaded: [RecordingLibraryEntry] = []
            for url in urls {
                guard !Task.isCancelled, requestID == request else { return }
                loaded.append(await inspect(url, active: activeURLs.contains { $0.standardizedFileURL == url.standardizedFileURL }))
            }
            if requestID == request { entries = loaded; loading = false }
        } catch {
            if requestID == request { self.error = error.localizedDescription; loading = false }
        }
    }

    private func inspect(_ url: URL, active: Bool) async -> RecordingLibraryEntry {
        let metadata = await Task.detached(priority: .utility) {
            var journal = (try? Data(contentsOf: url.appendingPathExtension("recording.json")))
                .flatMap { try? JSONDecoder().decode(RecordingJournalSummary.self, from: $0) }
            let isolated = (try? Data(contentsOf: url.appendingPathExtension("isolated.json")))
                .flatMap { try? JSONDecoder().decode(IsolatedJournalSummary.self, from: $0) }
            let video = (try? Data(contentsOf: url.appendingPathExtension("video-isolated.json")))
                .flatMap { try? JSONDecoder().decode(IsolatedVideoJournalSummary.self, from: $0) }
            if let programFile = video?.programFile ?? isolated?.programFile,
               RecordingChatReader.basename(programFile) {
                let parent = (try? Data(contentsOf: url.deletingLastPathComponent().appendingPathComponent(programFile).appendingPathExtension("recording.json")))
                    .flatMap { try? JSONDecoder().decode(RecordingJournalSummary.self, from: $0) }
                if parent?.sessionID == (video?.sessionID ?? isolated?.sessionID),
                   parent?.segmentIndex == (video?.segmentIndex ?? isolated?.segmentIndex) { journal = parent }
            }
            let linked = (journal?.isolatedFiles ?? []).compactMap { name -> IsolatedJournalSummary? in
                guard URL(fileURLWithPath: name).lastPathComponent == name else { return nil }
                return (try? Data(contentsOf: url.deletingLastPathComponent().appendingPathComponent(name).appendingPathExtension("isolated.json")))
                    .flatMap { try? JSONDecoder().decode(IsolatedJournalSummary.self, from: $0) }
            }
            let linkedVideo = (journal?.isolatedFiles ?? []).compactMap { name -> IsolatedVideoJournalSummary? in
                guard URL(fileURLWithPath: name).lastPathComponent == name else { return nil }
                return (try? Data(contentsOf: url.deletingLastPathComponent().appendingPathComponent(name).appendingPathExtension("video-isolated.json")))
                    .flatMap { try? JSONDecoder().decode(IsolatedVideoJournalSummary.self, from: $0) }
            }
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let bytes = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            let date = attributes?[.creationDate] as? Date ?? .distantPast
            var chatURL: URL?
            var chatInfo: RecordingChatSummary?
            if let name = journal?.chatArchiveFile, RecordingChatReader.basename(name), name.hasSuffix(".chat.jsonl") {
                let candidate = url.deletingLastPathComponent().appendingPathComponent(name)
                if var info = RecordingChatReader.summary(candidate), info.version == 1, info.header.sessionID == journal?.sessionID,
                   info.header.segmentIndex == journal?.segmentIndex {
                    if !active, info.completedAt == nil { info.status = "partial"; info.warning = info.warning ?? "Interrupted archive; export recovers its valid prefix." }
                    chatURL = candidate; chatInfo = info
                } else if FileManager.default.fileExists(atPath: candidate.path),
                          let scanned = try? RecordingChatReader.scan(candidate), scanned.header.sessionID == journal?.sessionID,
                          scanned.header.segmentIndex == journal?.segmentIndex {
                    chatURL = candidate
                }
            }
            return (journal, bytes, date, isolated, linked, video, linkedVideo, chatURL, chatInfo)
        }.value
        let asset = AVURLAsset(url: url)
        var duration = 0.0
        var trackNames: [String] = []
        var thumbnail: NSImage?
        var mediaError: String?
        var readable = false
        if !active {
            do {
                duration = try await asset.load(.duration).seconds
                let tracks = try await asset.load(.tracks)
                for track in tracks {
                    let type = track.mediaType
                    let descriptions = try await track.load(.formatDescriptions)
                    let format = descriptions.first.map { Self.fourCC(CMFormatDescriptionGetMediaSubType($0)) } ?? "unknown"
                    trackNames.append("\(type == .video ? "Video" : type == .audio ? "Audio" : type.rawValue): \(format)")
                }
                readable = try await asset.load(.isPlayable)
                if trackNames.contains(where: { $0.hasPrefix("Video") }) {
                    let generator = AVAssetImageGenerator(asset: asset)
                    generator.maximumSize = CGSize(width: 160, height: 90)
                    generator.appliesPreferredTrackTransform = true
                    if let frame = try? await generator.image(at: CMTime(seconds: min(0.5, max(0, duration / 2)), preferredTimescale: 600)) {
                        thumbnail = NSImage(cgImage: frame.image, size: .zero)
                    }
                }
            } catch { mediaError = error.localizedDescription }
        }
        let journal = metadata.0
        let isolated = metadata.3
        let video = metadata.5
        let storedStatus = video?.progress.status ?? isolated?.progress.status ?? journal?.status ?? "unclassified"
        let status: String
        if active { status = "recording" }
        else if readable && storedStatus != "complete" { status = "recoverable" }
        else if !readable { status = "partial" }
        else { status = "complete" }
        var manifestParts: [String] = []
        if let video {
            manifestParts.append("\(video.selection.name): \(video.selection.processing.title)")
            manifestParts.append("Source: \(video.selection.targetID)")
            manifestParts.append("\(video.selection.resolution.title) · \(video.selection.frameRate) fps")
            manifestParts.append("Audio: \(video.selection.audioName ?? video.selection.audioTargetID ?? "Video Only")")
            if let offset = video.sourceStartOffsetSeconds { manifestParts.append(String(format: "starts %.3fs", offset)) }
            if video.progress.missingVideoFrames > 0 { manifestParts.append("\(video.progress.missingVideoFrames) missing source frames") }
            if video.progress.renderDrops > 0 { manifestParts.append("\(video.progress.renderDrops) dropped source frames") }
            if !video.gaps.isEmpty { manifestParts.append("\(video.gaps.count) documented gap windows") }
        } else if let isolated {
            manifestParts.append("\(isolated.selection.name): \(isolated.selection.processing.title)")
            manifestParts.append("Source: \(isolated.selection.targetID)")
            if let offset = isolated.startOffsetSeconds { manifestParts.append(String(format: "starts %.3fs", offset)) }
            if isolated.progress.missingSourceFrames > 0 { manifestParts.append("\(isolated.progress.missingSourceFrames) missing source frames") }
            if isolated.progress.droppedChunks > 0 { manifestParts.append("\(isolated.progress.droppedChunks) dropped chunks") }
            if !isolated.gaps.isEmpty { manifestParts.append("\(isolated.gaps.count) documented gap windows") }
        } else {
            if let video = journal?.progress?.videoStatus { manifestParts.append("Video: \(video)") }
            if let audio = journal?.progress?.audioStatus { manifestParts.append("Audio: \(audio)") }
            if let offset = journal?.videoStartOffsetSeconds { manifestParts.append(String(format: "video starts %.3fs", offset)) }
            if let offset = journal?.audioStartOffsetSeconds { manifestParts.append(String(format: "audio starts %.3fs", offset)) }
            if let dropped = journal?.progress?.droppedVideo, dropped > 0 { manifestParts.append("\(dropped) dropped video frames") }
            if let dropped = journal?.progress?.droppedAudio, dropped > 0 { manifestParts.append("\(dropped) audio gaps") }
            if let files = journal?.isolatedFiles, !files.isEmpty { manifestParts.append("\(files.count) isolated media files") }
            for track in metadata.4 {
                manifestParts.append("\(track.selection.name): \(track.progress.status)\(track.progress.error.map { " (" + $0 + ")" } ?? "")")
            }
            for track in metadata.6 {
                manifestParts.append("\(track.selection.name): \(track.progress.status)\(track.progress.error.map { " (" + $0 + ")" } ?? "")")
            }
        }
        return RecordingLibraryEntry(url: url,
            sessionID: video?.sessionID ?? isolated?.sessionID ?? journal?.sessionID ?? url.lastPathComponent,
            segmentIndex: video?.segmentIndex ?? isolated?.segmentIndex ?? journal?.segmentIndex ?? 1,
            startedAt: journal?.startedAt ?? metadata.2, context: video?.context ?? isolated?.context ?? journal?.context ?? .init(),
            duration: duration.isFinite ? max(0, duration) : 0, bytes: metadata.1,
            tracks: trackNames, manifestSummary: manifestParts.joined(separator: " · "), status: status,
            error: (video != nil ? video?.progress.error : isolated == nil ? journal?.error : isolated?.progress.error) ?? mediaError,
            markers: journal?.markers ?? [], thumbnail: thumbnail, canExport: readable && !active,
            chatURL: metadata.7, chatSummary: metadata.8)
    }

    private static func fourCC(_ value: FourCharCode) -> String {
        let code = String(bytes: [UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
                       UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)], encoding: .ascii) ?? "unknown"
        return ["avc1": "H.264", "hvc1": "HEVC", "hev1": "HEVC", "mp4a": "AAC", "aac ": "AAC", "lpcm": "PCM"][code] ?? code
    }

    static func markerData(_ markers: [RecordingMarker], format: RecordingMarkerFormat) throws -> Data {
        switch format {
        case .json:
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try encoder.encode(markers)
        case .csv:
            let rows = markers.map { "\($0.seconds),\"\($0.title.replacingOccurrences(of: "\"", with: "\"\""))\"" }
            return Data((["seconds,title"] + rows).joined(separator: "\n").appending("\n").utf8)
        case .txt:
            return Data(markers.map { String(format: "%.3f\t%@", $0.seconds, $0.title) }.joined(separator: "\n").appending("\n").utf8)
        }
    }

    func exportMarkers(_ entry: RecordingLibraryEntry, format: RecordingMarkerFormat, to url: URL) {
        do { try Self.markerData(entry.markers, format: format).write(to: url, options: .atomic); error = nil }
        catch { self.error = error.localizedDescription }
    }

    func exportChat(_ entry: RecordingLibraryEntry, format: RecordingChatFormat, to output: URL) async {
        guard !exporting, entry.status != "recording", let source = entry.chatURL else { return }
        exporting = true; error = nil
        do { try await Task.detached(priority: .utility) { try RecordingChatReader.export(source, format: format, to: output) }.value }
        catch { self.error = error.localizedDescription }
        exporting = false
    }
    func removeChat(_ entry: RecordingLibraryEntry) {
        guard entry.status != "recording", let source = entry.chatURL else { return }
        do {
            try FileManager.default.trashItem(at: source, resultingItemURL: nil)
            let summary = source.appendingPathExtension("summary.json")
            if FileManager.default.fileExists(atPath: summary.path) { try FileManager.default.trashItem(at: summary, resultingItemURL: nil) }
            if let index = entries.firstIndex(where: { $0.id == entry.id }) { entries[index].chatURL = nil; entries[index].chatSummary = nil }
        } catch { self.error = error.localizedDescription }
    }

    func exportClip(_ entry: RecordingLibraryEntry, from start: Double, to end: Double, output: URL) async {
        guard !exporting else { return }
        guard entry.canExport, start.isFinite, end.isFinite, start >= 0, end > start, end <= entry.duration else {
            error = "Choose a valid clip range inside a readable recording."; return
        }
        guard output.standardizedFileURL != entry.url.standardizedFileURL else {
            error = "Choose a new output file to preserve the recording."; return
        }
        guard !FileManager.default.fileExists(atPath: output.path) else {
            error = "Choose an unused output file name."; return
        }
        let asset = AVURLAsset(url: entry.url)
        let audioOnly = !entry.tracks.contains { $0.hasPrefix("Video") }
        guard let exporter = AVAssetExportSession(asset: asset,
            presetName: audioOnly ? AVAssetExportPresetAppleM4A : AVAssetExportPresetHighestQuality) else {
            error = "This recording cannot be exported with the available encoder."; return
        }
        exporter.outputURL = output
        let type: AVFileType = audioOnly ? .m4a : output.pathExtension.lowercased() == "mov" ? .mov : .mp4
        guard !audioOnly || output.pathExtension.lowercased() == "m4a" else { error = "Choose M4A for an audio clip."; return }
        guard exporter.supportedFileTypes.contains(type) else { error = "The selected clip container is unavailable."; return }
        exporter.outputFileType = type
        exporter.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 48_000),
                                        duration: CMTime(seconds: end - start, preferredTimescale: 48_000))
        exporting = true; error = nil
        await withCheckedContinuation { continuation in exporter.exportAsynchronously { continuation.resume() } }
        if exporter.status != .completed { error = exporter.error?.localizedDescription ?? "Clip export failed; the original recording is preserved." }
        exporting = false
    }
}
