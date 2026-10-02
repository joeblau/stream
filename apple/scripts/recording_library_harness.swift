import AVFoundation
import Foundation

@main struct RecordingLibraryHarness {
    @MainActor static func main() async throws {
        let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).standardizedFileURL
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let output = folder.appendingPathComponent("show.mp4")
        var config = ProgramRecordingSession.Configuration(); config.frameRate = 60
        config.context = RecordingContext(projectID: "project-a", profileID: "profile-a", projectName: "Project A", profileName: "Studio")
        let writer = ProgramRecordingSession(outputURL: output, configuration: config)
        try await feed(writer, offset: 0)
        writer.addMarker(title: "He said, \"hello\"\nSecond line")
        try await feed(writer, offset: 1)
        let result = await withCheckedContinuation { continuation in writer.finish { continuation.resume(returning: $0) } }
        precondition(result.completed, result.error ?? "Library fixture failed")
        let original = try Data(contentsOf: output)
        let orphan = folder.appendingPathComponent("orphan.mp4")
        let active = folder.appendingPathComponent("active.mp4")
        try original.write(to: orphan); try original.write(to: active)
        let corrupt = folder.appendingPathComponent("corrupt.mov")
        try Data("corrupt media".utf8).write(to: corrupt)
        let model = RecordingLibraryModel()
        await model.refresh(access: RecordingDirectoryAccess(url: folder, scoped: false), activeURLs: [active])
        precondition(!model.loading && model.error == nil && model.entries.count == 4)
        let item = model.entries.first { $0.url == output }!
        precondition(item.status == "complete" && item.canExport && item.thumbnail != nil)
        precondition(item.bytes == Int64(original.count) && abs(item.duration - 2) < 0.08 && item.tracks.count == 2)
        precondition(item.context == config.context && item.segmentIndex == 1, "Project/profile session metadata must survive")
        precondition(item.markers.count == 1 && (0.95...1.05).contains(item.markers[0].seconds), "Marker must use the actual recording timeline")
        precondition(model.entries.first { $0.url == orphan }!.status == "recoverable")
        precondition(model.entries.first { $0.url == corrupt }!.status == "partial")
        precondition(!model.entries.first { $0.url == active }!.canExport)
        print("PASS: library actual tracks/duration/size/thumbnail, session project/profile metadata, completed/recoverable/partial/active classification")
        for format in RecordingMarkerFormat.allCases {
            let destination = folder.appendingPathComponent("markers.\(format.rawValue)")
            model.exportMarkers(item, format: format, to: destination)
            precondition(model.error == nil)
            let data = try Data(contentsOf: destination)
            if format == .json {
                let decoded = try JSONDecoder().decode([RecordingMarker].self, from: data)
                precondition(decoded == item.markers)
            } else if format == .csv {
                precondition(String(decoding: data, as: UTF8.self).contains("\"He said, \"\"hello\"\"\nSecond line\""), "CSV must quote embedded quotes/newlines")
            }
        }
        print("PASS: timestamped marker JSON/CSV/text exports, including Unicode-safe quoted CSV")
        let clip = folder.appendingPathComponent("clip.mp4")
        await model.exportClip(item, from: 0.4, to: 1.2, output: clip)
        precondition(model.error == nil && !model.exporting, model.error ?? "Clip export failed")
        try await ProgramRecordingFixtures.inspect(clip, expectedDuration: 0.8, checkSync: true)
        let retained = try Data(contentsOf: output)
        precondition(retained == original, "Clip export must preserve the source")
        await model.exportClip(item, from: -1, to: 1, output: folder.appendingPathComponent("invalid.mp4"))
        precondition(model.error != nil)
        await model.exportClip(item, from: 0, to: 1, output: output)
        precondition(model.error != nil)
        print("PASS: actual trimmed H.264/AAC clip duration/sync, source preservation, invalid-range and overwrite rejection")
        if CommandLine.arguments.count > 2, !CommandLine.arguments[2].isEmpty {
            let isolatedFolder = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
            for name in ["before.wav", "after.m4a", "actual-mix.mp4"] {
                let source = isolatedFolder.appendingPathComponent(name), destination = folder.appendingPathComponent(name)
                try FileManager.default.copyItem(at: source, to: destination)
                let suffix = name.hasSuffix("mp4") ? "recording.json" : "isolated.json"
                try FileManager.default.copyItem(at: source.appendingPathExtension(suffix), to: destination.appendingPathExtension(suffix))
            }
            await model.refresh(access: RecordingDirectoryAccess(url: folder, scoped: false), activeURLs: [])
            let isolated = model.entries.first { $0.url.lastPathComponent == "before.wav" }!
            let processed = model.entries.first { $0.url.lastPathComponent == "after.m4a" }!
            let program = model.entries.first { $0.url.lastPathComponent == "actual-mix.mp4" }!
            precondition(isolated.status == "complete" && isolated.canExport && isolated.tracks.count == 1)
            precondition(processed.status == "complete" && processed.canExport && processed.tracks.count == 1)
            precondition(isolated.sessionID == program.sessionID && processed.sessionID == program.sessionID)
            precondition(isolated.context == program.context && isolated.context.profileID == "profile")
            precondition(isolated.manifestSummary.contains("Before Inserts") && isolated.manifestSummary.contains("missing source frames"))
            precondition(processed.manifestSummary.contains("After Inserts"))
            let audioClip = folder.appendingPathComponent("audio-clip.m4a")
            await model.exportClip(isolated, from: 0.4, to: 0.9, output: audioClip)
            precondition(model.error == nil, model.error ?? "Audio clip failed")
            let clippedAsset = AVURLAsset(url: audioClip)
            let audioTracks = try await clippedAsset.loadTracks(withMediaType: .audio)
            let clipDuration = try await clippedAsset.load(.duration).seconds
            precondition(audioTracks.count == 1 && abs(clipDuration - 0.5) < 0.025)
            print("PASS: real isolated WAV/M4A library media, source/processing/gap manifests, profile/session grouping and trimmed AAC audio export")
        }
    }

    static func feed(_ writer: ProgramRecordingSession, offset: Double) async throws {
        let clock = ContinuousClock(); let start = clock.now
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for index in 0..<60 {
                    let time = Double(index) / 60
                    try await clock.sleep(until: start.advanced(by: .seconds(time)))
                    writer.appendVideo(try ProgramRecordingFixtures.video(at: time + offset))
                }
            }
            group.addTask {
                for index in 0..<100 {
                    let time = Double(index) / 100
                    try await clock.sleep(until: start.advanced(by: .seconds(time)))
                    writer.appendAudio(try ProgramRecordingFixtures.audio(at: time + offset))
                }
            }
            try await group.waitForAll()
        }
    }
}
