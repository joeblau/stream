import AppKit
import AVFoundation
import Foundation
import StreamCore

/// Real native dispatcher -> composition/mixer -> RTMPPublisher -> owned
/// localhost FFmpeg receiver, plus the independent real recording writer.
/// The generated tool denies microphone capture and uses no-op Keychain.
@MainActor enum DeckTransportFixtures {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw NSError(domain: "DeckTransportFixtures", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func until(_ condition: () -> Bool, message: String) async throws {
        for _ in 0..<1500 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        try check(false, message)
    }
    static func listening(_ receiver: Process, port: Int) -> Bool {
        guard receiver.isRunning else { return false }
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-a", "-p", String(receiver.processIdentifier), "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0 && !pipe.fileHandleForReading.readDataToEndOfFile().isEmpty
    }
    static func receiverExecutable() throws -> String {
        let environment = ProcessInfo.processInfo.environment
        let candidates = environment["STREAM_FFMPEG_BIN"].map { [$0] } ??
            (environment["PATH"] ?? "").split(separator: ":", omittingEmptySubsequences: false)
                .map { URL(fileURLWithPath: $0.isEmpty ? "." : String($0)).appendingPathComponent("ffmpeg").path }
            + ["/opt/homebrew/opt/ffmpeg/bin/ffmpeg", "/usr/local/opt/ffmpeg/bin/ffmpeg",
               "/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg", "/usr/local/opt/ffmpeg-full/bin/ffmpeg"]
        guard let executable = candidates.first(where: { path in
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &directory)
                && !directory.boolValue && FileManager.default.isExecutableFile(atPath: path)
        }) else {
            throw NSError(domain: "DeckTransportFixtures", code: 3, userInfo: [NSLocalizedDescriptionKey:
                "Select an executable receiver with STREAM_FFMPEG_BIN or PATH; explicit overrides never fall back. Run scripts/ffmpeg_receiver.py to validate RTMP/listen, H.264/AAC and MP4 capabilities."])
        }
        return executable
    }
    static func run(directory: URL) async throws {
        let ffmpeg = try receiverExecutable()
        let folder = directory.appendingPathComponent("actual-transport")
        try DesktopStorage.prepare(folder)
        let scene = Scene(name: "Local transport fixture", layers: [], background: .solid(colorHex: "#174A69"))
        try JSONEncoder().encode(SceneDocument(sources: [], scenes: [scene], selectedID: scene.id)).write(to: folder.appendingPathComponent("stream.scenes.v2.json"))
        let destination = StreamDestination(name: "Owned localhost", transport: .rtmp)
        try JSONEncoder().encode([destination]).write(to: folder.appendingPathComponent("destinations.json"))
        var profile = StreamSettings.default
        profile.outputProfile = .init(canvasWidth: 320, canvasHeight: 180, frameRate: 25)
        profile.micVolume = 0; profile.audioInputs = []
        DesktopSettingsStore().saveNonSecret(profile)
        let scenes = SceneStore(), preview = PreviewProgramModel(selected: scenes.selected)
        let controller = StreamController(sceneStore: scenes, previewProgram: preview, permissions: PermissionsManager())
        let suite = "stream.deck.transport.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        let recordings = folder.appendingPathComponent("Recordings")
        let recorder = RecordingController(defaults: defaults, defaultDirectory: recordings)
        let dispatcher = StudioCommandDispatcher(controller: controller, sceneStore: scenes,
            session: SettingsSession(controller: controller), recorder: recorder, previewProgram: preview)
        let port = Int.random(in: 20_000...40_000)
        let receiver = Process(), receivedFile = folder.appendingPathComponent("received.mp4"), receiverLog = folder.appendingPathComponent("receiver.log")
        FileManager.default.createFile(atPath: receiverLog.path, contents: nil)
        let log = try FileHandle(forWritingTo: receiverLog)
        receiver.executableURL = URL(fileURLWithPath: ffmpeg)
        receiver.arguments = ["-y", "-hide_banner", "-loglevel", "error", "-listen", "1", "-i", "rtmp://127.0.0.1:\(port)/live/fixture", "-map", "0:v:0", "-map", "0:a:0", "-c", "copy", receivedFile.path]
        receiver.standardOutput = log; receiver.standardError = log
        defer {
            recorder.stop(); controller.stopStream(); controller.stopPreview(); scenes.flushPendingWrites()
            if receiver.isRunning { receiver.terminate() }
            try? log.close(); defaults.removePersistentDomain(forName: suite)
        }
        try receiver.run()
        try await until({ listening(receiver, port: port) }, message: "Owned RTMP receiver failed to listen")
        controller.destinations.credentials[destination.id] = .init(endpoint: "rtmp://127.0.0.1:\(port)/live", streamKey: "fixture")
        try check(controller.destinations.apply(), "Save isolated localhost credentials")
        func run(_ id: String) throws {
            guard let command = dispatcher.catalogueActions().first(where: { $0.id == id })?.command else {
                throw NSError(domain: "DeckTransportFixtures", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing \(id)"])
            }
            try check(dispatcher.execute(command).error == nil, "Native command rejected: \(id)")
        }
        let prefix = "destination.\(destination.id.uuidString)"
        try run(prefix + ".start")
        try check(dispatcher.controllerTransportSnapshot().destinations.first?.state != "live", "Start request invented immediate Live")
        try await until({ controller.streamState.isLive }, message: "Selected destination did not acknowledge actual RTMP publication: \(controller.errorMessage ?? "")")
        try check(dispatcher.controllerTransportSnapshot().destinations.first?.state == "live", "Native feedback failed to report acknowledged Live")
        recorder.preferences.countdownSeconds = 2
        try run("output.record.start")
        try check(dispatcher.controllerRecordingCountdown() == 2 && recorder.state == .preparing, "Native recording countdown missing")
        try run("output.record.stop")
        try await until({ recorder.state == .idle }, message: "Cancelled countdown did not retire")
        try check(controller.streamState.isLive && recorder.currentOutputURL == nil, "Cancelling recording countdown affected publisher")
        recorder.preferences.countdownSeconds = 0
        try run("output.record.start")
        try await until({ recorder.state == .recording }, message: "Native program writer did not acknowledge media: \(recorder.lastError ?? "")")
        try await Task.sleep(for: .milliseconds(500))
        try run("output.record.pause")
        try await until({ recorder.state == .paused }, message: "Pause did not reach real recording writer")
        try check(controller.streamState.isLive, "Pause stopped local publisher")
        try run("output.record.resume")
        try await until({ recorder.state == .recording }, message: "Resume did not reach real recording writer")
        try await Task.sleep(for: .milliseconds(500))
        let firstFile = recorder.currentOutputURL
        try run("output.record.split")
        try await until({ recorder.state == .recording && recorder.currentOutputURL != firstFile && recorder.canSplit }, message: "New recording file did not finalize and resume")
        try await Task.sleep(for: .milliseconds(500))
        try run(prefix + ".stop")
        try await until({ !controller.streamState.isActive }, message: "Selected local stop lacked an acknowledged teardown")
        try check(recorder.state == .recording, "Selected destination stop stopped independent recording")
        try run("output.record.stop")
        try await until({ recorder.state == .idle }, message: "Recording stop did not finalize writer")
        try await until({ !receiver.isRunning }, message: "Owned RTMP receiver did not finish")
        try check(receiver.terminationStatus == 0, "Owned receiver rejected real native media")
        let files = try FileManager.default.contentsOfDirectory(at: recordings, includingPropertiesForKeys: nil).filter { $0.pathExtension == "mp4" }
        try check(files.count == 2, "Native new-file action did not finalize two segments")
        for file in files + [receivedFile] {
            let asset = AVURLAsset(url: file)
            let video = try await asset.loadTracks(withMediaType: .video), audio = try await asset.loadTracks(withMediaType: .audio)
            let duration = try await asset.load(.duration).seconds
            try check(!video.isEmpty && !audio.isEmpty && duration > 0, "Actual transport/recording media is incomplete: \(file.lastPathComponent)")
        }
        let decoder = Process()
        decoder.executableURL = URL(fileURLWithPath: ffmpeg)
        decoder.arguments = ["-v", "error", "-xerror", "-i", receivedFile.path, "-f", "null", "-"]
        decoder.standardOutput = FileHandle.nullDevice; decoder.standardError = log
        try decoder.run(); decoder.waitUntilExit()
        try check(decoder.terminationStatus == 0, "Actual RTMP output failed decoding")
        print("PASS: native selected destination Start/Stop -> actual localhost RTMP acknowledgement and decodable H.264/AAC; independent recording countdown cancellation, Start/Pause/Resume/New File/Stop finalized two real segments")
    }
}
