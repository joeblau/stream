import AppKit
import AVFoundation
import Combine
import Foundation
import StreamCore

private final class PortableMediaReceipt: @unchecked Sendable {
    private let lock = NSLock()
    private var value = MediaSourceStatus()
    private var audio = 0
    func status(_ next: MediaSourceStatus) { lock.lock(); value = next; lock.unlock() }
    func sample() { lock.lock(); audio += 1; lock.unlock() }
    func snapshot() -> (MediaSourceStatus, Int) { lock.lock(); defer { lock.unlock() }; return (value, audio) }
}

/// Real owned-file encode, package transfer and playback in the sandbox app.
/// No physical capture, external publishing or user-profile edit is involved.
@MainActor enum PortableNativeMedia {
    static func stage(_ value: String) {
        try? JSONSerialization.data(withJSONObject: ["stage": value])
            .write(to: PortableNativeAppDriver.folder.appendingPathComponent("media-progress.json"), options: .atomic)
    }
    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw PortableNativeAppDriver.Failure.message(message) }
    }

    static func movie(at url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 64, AVVideoHeightKey: 48])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 48])
        writer.add(input)
        try require(writer.startWriting(), "Owned portable movie writer failed to start")
        writer.startSession(atSourceTime: .zero)
        for index in 0..<30 {
            for _ in 0..<300 {
                if input.isReadyForMoreMediaData { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, 64, 48, kCVPixelFormatType_32BGRA, nil, &buffer)
            guard let buffer else { throw PortableNativeAppDriver.Failure.message("Owned portable movie buffer missing") }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) { memset(base, Int32(80 + index), CVPixelBufferGetDataSize(buffer)) }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            try require(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 30)), "Owned movie frame rejected")
        }
        input.markAsFinished()
        await writer.finishWriting()
        try require(writer.status == .completed, "Owned portable movie did not finalize")
    }

    static func wave(at url: URL) throws {
        let frames = 48_000
        var bytes = Data("RIFF".utf8)
        func little<T: FixedWidthInteger>(_ value: T) { var value = value.littleEndian; withUnsafeBytes(of: &value) { bytes.append(contentsOf: $0) } }
        little(UInt32(36 + frames * 2)); bytes.append(Data("WAVEfmt ".utf8)); little(UInt32(16))
        little(UInt16(1)); little(UInt16(1)); little(UInt32(48_000)); little(UInt32(96_000)); little(UInt16(2)); little(UInt16(16))
        bytes.append(Data("data".utf8)); little(UInt32(frames * 2))
        for index in 0..<frames { little(Int16(sin(Double(index) * 2 * .pi * 440 / 48_000) * 6000)) }
        try bytes.write(to: url)
    }

    static func qualify(_ workspace: StudioWorkspace, decodeSoundPad: Bool = true) async throws {
        let folder = PortableNativeAppDriver.folder.appendingPathComponent("Media-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let movieURL = folder.appendingPathComponent("normal-video.mov"), waveURL = folder.appendingPathComponent("normal-pad.wav")
        stage("encoding owned movie")
        try await movie(at: movieURL); try wave(at: waveURL)
        stage("promoting and exporting media snapshots")
        guard let media = MediaSourceFactory.payload(forPickedFile: movieURL), let pad = SoundPad.make(pickedFile: waveURL),
              let track = MusicTrack.make(pickedFile: waveURL), let binding = SceneSoundBinding.make(pickedFile: waveURL, rule: .enter) else {
            throw PortableNativeAppDriver.Failure.message("Normal native media factories could not create their bookmark-backed records")
        }
        try require(media.assetIdentifier == nil && media.bookmarkData != nil, "Fixture did not exercise normal bookmark-only Add Video payload")
        var document = workspace.runtime.sceneStore.document
        let source = SourceDefinition(name: "Portable video", payload: .media(media))
        document.sources.append(source)
        document.defaultTransition = SceneTransition(style: .stinger, stingerBookmarkData: media.bookmarkData, stingerFileName: media.fileName)
        document.scenes[0].layers.append(.init(name: "Portable video", sourceID: source.id, payload: source.payload, transform: .fullscreen))
        document.scenes[0].soundBindings.append(binding)
        let originalScenes = workspace.runtime.sceneStore.document
        let originalAssets = workspace.runtime.dispatcher.assetLibrary.assets
        let rawDocuments = ["stream.scenes.v2.json": try JSONEncoder().encode(document),
            "stream.soundboard.v1.json": try JSONEncoder().encode(SoundboardDocument(pads: [pad], playlists: [.init(name: "Portable playlist", tracks: [track])]))]
        var includedDocuments = rawDocuments
        let included = try workspace.packageAssetContents(includeMedia: true, documents: &includedDocuments)
        includedDocuments["stream.assets.v1.json"] = try JSONEncoder().encode(included.document)
        let package = folder.appendingPathComponent("Included.streamshow", isDirectory: true)
        try ShowPackageIO.export(documents: includedDocuments, media: included.media, name: "Included normal media", includeMedia: true, to: package)
        let preview = try ShowPackageIO.preview(package), imported = folder.appendingPathComponent("Imported", isDirectory: true)
        try ShowPackageIO.importFiles(from: package, to: imported, previewedManifest: preview.manifest)
        let scene = try JSONDecoder().decode(SceneDocument.self, from: Data(contentsOf: imported.appendingPathComponent("stream.scenes.v2.json")))
        let sounds = try JSONDecoder().decode(SoundboardDocument.self, from: Data(contentsOf: imported.appendingPathComponent("stream.soundboard.v1.json")))
        guard let importedSource = scene.sources.first(where: { $0.name == source.name }), case .media(let payload) = importedSource.payload else {
            throw PortableNativeAppDriver.Failure.message("Imported video binding disappeared")
        }
        try require(payload.bookmarkData == nil && payload.assetIdentifier != nil && sounds.pads[0].bookmarkData == nil
            && sounds.pads[0].assetIdentifier != nil && sounds.playlists[0].tracks[0].assetIdentifier != nil
            && scene.scenes[0].soundBindings.last?.assetIdentifier != nil, "Package lost a video/pad/playlist/scene-sound asset reference")
        try require(scene.defaultTransition.stingerBookmarkData == nil && scene.defaultTransition.stingerAssetIdentifier == payload.assetIdentifier,
            "Stinger leaked a machine grant or lost its shared portable media reference")
        var referenceDocuments = rawDocuments
        let references = try workspace.packageAssetContents(includeMedia: false, documents: &referenceDocuments)
        referenceDocuments["stream.assets.v1.json"] = try JSONEncoder().encode(references.document)
        let linkedPackage = folder.appendingPathComponent("Linked.streamshow", isDirectory: true), linkedFolder = folder.appendingPathComponent("LinkedImported", isDirectory: true)
        try ShowPackageIO.export(documents: referenceDocuments, media: [], name: "Relink normal media", includeMedia: false, to: linkedPackage)
        try ShowPackageIO.importFiles(from: linkedPackage, to: linkedFolder)
        let linkedSounds = try JSONDecoder().decode(SoundboardDocument.self, from: Data(contentsOf: linkedFolder.appendingPathComponent("stream.soundboard.v1.json")))
        let repairWave = folder.appendingPathComponent("repair-pad.wav")
        try FileManager.default.copyItem(at: waveURL, to: repairWave)
        try FileManager.default.removeItem(at: movieURL); try FileManager.default.removeItem(at: waveURL)
        let library = AssetLibraryStore(directory: imported), receipt = PortableMediaReceipt()
        stage("decoding imported video with original removed")
        let playback = MediaSourcePlayback(sourceID: importedSource.id, assetAccessProvider: { raw in
            guard let id = UUID(uuidString: raw) else { return nil }; return library.access(for: AssetID(id))
        }) { payload }
        defer { playback.shutdown() }
        playback.onStatus = { _, status in receipt.status(status) }
        playback.load(); playback.play()
        var decoded = false
        for _ in 0..<400 {
            if playback.pullFrame() != nil { decoded = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try require(decoded, "Imported included video did not decode after original source removal: \(receipt.snapshot().0.errorMessage ?? "no frame")")
        guard let padReference = sounds.pads[0].assetIdentifier, let padID = UUID(uuidString: padReference),
              let padAccess = library.access(for: AssetID(padID)) else { throw PortableNativeAppDriver.Failure.message("Copied pad bytes missing") }
        try audioContent(at: padAccess.url)
        if !decodeSoundPad {
            let linkedLibrary = AssetLibraryStore(directory: linkedFolder)
            guard let raw = linkedSounds.pads[0].assetIdentifier, let uuid = UUID(uuidString: raw) else {
                throw PortableNativeAppDriver.Failure.message("References-only pad has no repairable asset identity")
            }
            let id = AssetID(uuid)
            try require(linkedLibrary.access(for: id) == nil, "References-only sound retained access to the original file")
            try require(await linkedLibrary.relink(id, to: repairWave), "Owned reference repair failed")
            guard let access = linkedLibrary.access(for: id) else { throw PortableNativeAppDriver.Failure.message("Repaired reference inaccessible") }
            try audioContent(at: access.url)
            try require(workspace.runtime.sceneStore.document == originalScenes && workspace.runtime.dispatcher.assetLibrary.assets == originalAssets,
                "Snapshot promotion changed the active profile")
            stage("focused content complete; full sound-pad AVAssetReader remains separately unqualified")
            return
        }
        stage("playing imported sound pad with original removed")
        let controller = workspace.runtime.controller, audio = PortableMediaReceipt()
        let oldAudio = controller.capturePool.onMediaAudioSample
        controller.capturePool.onMediaAudioSample = { id, sample in audio.sample(); oldAudio?(id, sample) }
        let board = SoundboardController(store: SoundboardStore(directory: imported), controller: controller)
        controller.capturePool.onMediaAudioSample = oldAudio
        board.bindAssetLibrary(library)
        defer { board.shutdown() }
        board.triggerPad(sounds.pads[0])
        for _ in 0..<300 { if audio.snapshot().1 > 0 { break }; try await Task.sleep(for: .milliseconds(10)) }
        try require(audio.snapshot().1 > 0, "Imported included sound pad supplied no real PCM after original file removal")
        stage("checking missing reference and same-ID Assets repair")
        board.stopAllSoundEffects()
        let linkedLibrary = AssetLibraryStore(directory: linkedFolder), linkedAudio = PortableMediaReceipt()
        controller.capturePool.onMediaAudioSample = { id, sample in linkedAudio.sample(); oldAudio?(id, sample) }
        let linkedBoard = SoundboardController(store: SoundboardStore(directory: linkedFolder), controller: controller)
        controller.capturePool.onMediaAudioSample = oldAudio
        linkedBoard.bindAssetLibrary(linkedLibrary)
        defer { linkedBoard.shutdown() }
        let linkedPad = linkedSounds.pads[0]
        linkedBoard.triggerPad(linkedPad)
        for _ in 0..<200 { if linkedBoard.padStatuses[linkedPad.id]?.phase == .error { break }; try await Task.sleep(for: .milliseconds(10)) }
        try require(linkedBoard.padStatuses[linkedPad.id]?.phase == .error && linkedAudio.snapshot().1 == 0, "References-only media silently used an original machine grant")
        guard let raw = linkedPad.assetIdentifier, let id = UUID(uuidString: raw) else { throw PortableNativeAppDriver.Failure.message("Repairable pad asset missing") }
        try require(await linkedLibrary.relink(AssetID(id), to: repairWave), "Native library repair rejected the owned replacement")
        for _ in 0..<300 { if linkedAudio.snapshot().1 > 0 { break }; try await Task.sleep(for: .milliseconds(10)) }
        try require(linkedAudio.snapshot().1 > 0, "Same-ID Assets repair failed to reload the imported sound pad")
        try require(workspace.runtime.sceneStore.document == originalScenes && workspace.runtime.dispatcher.assetLibrary.assets == originalAssets,
            "Export promotion mutated the active profile instead of its package snapshot")
        stage("complete")
        print("PASS: normal bookmark-backed video/pads/playlists/scene sounds gain portable remapped asset IDs; copied video decodes and sound pad supplies PCM after originals removed; references-only pad stays missing until same-ID Assets relink; active profile unchanged")
    }

    static func audioContent(at url: URL) throws {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1024) else {
            throw PortableNativeAppDriver.Failure.message("Copied WAV PCM buffer missing")
        }
        try file.read(into: buffer)
        guard let samples = buffer.int16ChannelData else { throw PortableNativeAppDriver.Failure.message("Copied WAV did not yield Int16 PCM") }
        try require(file.length == 48_000 && buffer.frameLength == 1024 && samples[0][10] != 0,
            "Copied/repaired sound bytes did not produce the owned WAV content through AVAudioFile")
    }

    static func assetMetadata(_ workspace: StudioWorkspace) throws {
        let folder = PortableNativeAppDriver.folder.appendingPathComponent("Metadata-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("owned.bin")
        try Data("Owned package bytes".utf8).write(to: file)
        let id = AssetID(), path = "Assets/\(id)/owned.bin"
        let asset = LibraryAsset(id: id, name: "Owned", kind: .other, storage: .projectCopy, relativePath: path, fileName: "owned.bin", lastKnownPath: "")
        var escaping = asset; escaping.relativePath = "../../other-profile/private.bin"
        var undeclared = asset; undeclared.relativePath = "Assets/\(id)/absent.bin"
        let invalid = [AssetLibraryDocument(assets: [escaping]), AssetLibraryDocument(assets: [undeclared]),
            AssetLibraryDocument(assets: [asset, asset]), AssetLibraryDocument(version: 99, assets: [asset])]
        for (index, library) in invalid.enumerated() {
            let package = folder.appendingPathComponent("Invalid-\(index).streamshow", isDirectory: true)
            try ShowPackageIO.export(documents: ["stream.scenes.v2.json": JSONEncoder().encode(workspace.runtime.sceneStore.document),
                "stream.assets.v1.json": JSONEncoder().encode(library)],
                media: [.init(access: ResolvedAssetAccess(url: file, needsSecurityScope: false), relativePath: path)],
                name: "Untrusted metadata", includeMedia: true, to: package)
            var previewRejected = false, importRejected = false
            do { _ = try ShowPackageIO.preview(package) } catch { previewRejected = true }
            let destination = folder.appendingPathComponent("Rejected-\(index)")
            do { try ShowPackageIO.importFiles(from: package, to: destination) } catch { importRejected = true }
            try require(previewRejected && importRejected && !FileManager.default.fileExists(atPath: destination.path),
                "Untrusted copied asset metadata passed preview/import or left committed files")
        }
        print("PASS: actual package preview/import reject escaping or undeclared copied assets, duplicate asset IDs and unsupported asset versions without committed files")
    }
}
