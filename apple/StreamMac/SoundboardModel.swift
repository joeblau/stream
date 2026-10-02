import AppKit
import Combine
import Foundation
import StreamCore

/// A03 (issue #98): the embedded soundboard, music playlists, and the
/// persistence behind both.
///
/// **Identity.** Pads and playlists are NOT registry `SourceDefinition`s and
/// never appear as scene layers — they are a project-level performance
/// surface (like the mixer), so they persist in their own additive document
/// beside the scene/browser documents (`stream.soundboard.v1.json` in the
/// shared App Group container, same storage pattern as `SceneStore`). A pad's
/// `id` is a `SourceDefinitionID` purely so its audio can ride the A01 mix
/// engine's existing `.media(sourceID)` channel kind with a stable identity
/// that survives relinks (hot-swapping the clip file changes the bookmark,
/// never the ID — the issue's "hot-swap without breaking identity").
///
/// **Clip ownership.** Each pad/track carries its own security-scoped
/// bookmark (the sandboxed access grant, A02's pattern), so the soundboard is
/// self-contained: deleting a registry media source never breaks a pad, and
/// a missing file degrades to an honest per-item error state with relink
/// instead of a silent skip.

/// What a second trigger does while the pad is still playing.
enum PadTriggerPolicy: String, Codable, CaseIterable, Sendable {
    /// Restart the clip from the beginning (the classic soundboard button).
    case restart
    /// Let the playing instance finish and start a second, overlapping one.
    case overlap

    var displayName: String {
        switch self {
        case .restart: return "Restart"
        case .overlap: return "Overlap"
        }
    }
}

/// One soundboard pad: a named, colored audio clip with a trigger policy,
/// loop flag, and per-pad program volume.
struct SoundPad: Identifiable, Hashable, Codable, Sendable {
    /// Stable identity — also the `.media(id)` mix-channel key.
    var id: SourceDefinitionID
    var name: String
    var colorHex: String
    var systemImage: String
    var triggerPolicy: PadTriggerPolicy
    var loops: Bool
    /// Linear program gain, 0...2 (1 = unity).
    var volume: Double
    /// Security-scoped bookmark for the picked audio file (the access grant).
    var bookmarkData: Data?
    /// The picked file's display name (bookmarks don't round-trip one).
    var fileName: String?

    init(id: SourceDefinitionID = SourceDefinitionID(),
         name: String,
         colorHex: String = "#FF9500",
         systemImage: String = "speaker.wave.2.fill",
         triggerPolicy: PadTriggerPolicy = .restart,
         loops: Bool = false,
         volume: Double = 1,
         bookmarkData: Data? = nil,
         fileName: String? = nil) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.systemImage = systemImage
        self.triggerPolicy = triggerPolicy
        self.loops = loops
        self.volume = volume
        self.bookmarkData = bookmarkData
        self.fileName = fileName
    }

    /// Decode every field with a default so documents written before later
    /// A03 refinements keep loading (the established additive-wire pattern).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(SourceDefinitionID.self, forKey: .id) ?? SourceDefinitionID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Pad"
        colorHex = try container.decodeIfPresent(String.self, forKey: .colorHex) ?? "#FF9500"
        systemImage = try container.decodeIfPresent(String.self, forKey: .systemImage) ?? "speaker.wave.2.fill"
        triggerPolicy = try container.decodeIfPresent(PadTriggerPolicy.self, forKey: .triggerPolicy) ?? .restart
        loops = try container.decodeIfPresent(Bool.self, forKey: .loops) ?? false
        volume = try container.decodeIfPresent(Double.self, forKey: .volume) ?? 1
        bookmarkData = try container.decodeIfPresent(Data.self, forKey: .bookmarkData)
        fileName = try container.decodeIfPresent(String.self, forKey: .fileName)
    }

    /// Builds a pad from a user-picked audio file (bookmark = the persisted
    /// access grant; nil when the bookmark can't be created).
    static func make(pickedFile url: URL) -> SoundPad? {
        guard let payload = MediaSourceFactory.payload(forPickedFile: url) else { return nil }
        return SoundPad(name: url.deletingPathExtension().lastPathComponent,
                        bookmarkData: payload.bookmarkData,
                        fileName: payload.fileName)
    }
}

/// What happens when a playlist reaches the end of a track / the list.
enum PlaylistRepeatMode: String, Codable, CaseIterable, Sendable {
    /// Play the list once; stop after the last track.
    case off
    /// Loop the whole list.
    case all
    /// Loop the current track.
    case one

    var displayName: String {
        switch self {
        case .off: return "No Repeat"
        case .all: return "Repeat All"
        case .one: return "Repeat One"
        }
    }
}

/// One audio file inside a music playlist.
struct MusicTrack: Identifiable, Hashable, Codable, Sendable {
    var id: UUID
    var name: String
    var bookmarkData: Data?
    var fileName: String?

    init(id: UUID = UUID(), name: String, bookmarkData: Data? = nil, fileName: String? = nil) {
        self.id = id
        self.name = name
        self.bookmarkData = bookmarkData
        self.fileName = fileName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Track"
        bookmarkData = try container.decodeIfPresent(Data.self, forKey: .bookmarkData)
        fileName = try container.decodeIfPresent(String.self, forKey: .fileName)
    }

    static func make(pickedFile url: URL) -> MusicTrack? {
        guard let payload = MediaSourceFactory.payload(forPickedFile: url) else { return nil }
        return MusicTrack(name: url.deletingPathExtension().lastPathComponent,
                          bookmarkData: payload.bookmarkData,
                          fileName: payload.fileName)
    }
}

/// A03: an ordered list of audio files played through ONE music mix channel
/// (`.media(playlist.id)` — the stable identity A10's ducking keys on).
struct MusicPlaylist: Identifiable, Hashable, Codable, Sendable {
    /// Stable identity — also the `.media(id)` mix-channel key (one channel
    /// per playlist; track changes never re-key it).
    var id: SourceDefinitionID
    var name: String
    var tracks: [MusicTrack]
    var repeatMode: PlaylistRepeatMode
    var isShuffled: Bool
    /// Linear program gain, 0...2 (1 = unity).
    var volume: Double

    init(id: SourceDefinitionID = SourceDefinitionID(),
         name: String,
         tracks: [MusicTrack] = [],
         repeatMode: PlaylistRepeatMode = .off,
         isShuffled: Bool = false,
         volume: Double = 1) {
        self.id = id
        self.name = name
        self.tracks = tracks
        self.repeatMode = repeatMode
        self.isShuffled = isShuffled
        self.volume = volume
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(SourceDefinitionID.self, forKey: .id) ?? SourceDefinitionID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Playlist"
        tracks = try container.decodeIfPresent([MusicTrack].self, forKey: .tracks) ?? []
        repeatMode = try container.decodeIfPresent(PlaylistRepeatMode.self, forKey: .repeatMode) ?? .off
        isShuffled = try container.decodeIfPresent(Bool.self, forKey: .isShuffled) ?? false
        volume = try container.decodeIfPresent(Double.self, forKey: .volume) ?? 1
    }
}

/// The persisted soundboard document (v1). Every field decodes with a default
/// so older/partial files keep loading.
struct SoundboardDocument: Hashable, Codable, Sendable {
    static let currentVersion = 1

    var version: Int
    var pads: [SoundPad]
    var playlists: [MusicPlaylist]

    init(version: Int = SoundboardDocument.currentVersion,
         pads: [SoundPad] = [],
         playlists: [MusicPlaylist] = []) {
        self.version = version
        self.pads = pads
        self.playlists = playlists
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version)
            ?? SoundboardDocument.currentVersion
        pads = try container.decodeIfPresent([SoundPad].self, forKey: .pads) ?? []
        playlists = try container.decodeIfPresent([MusicPlaylist].self, forKey: .playlists) ?? []
    }
}

/// The soundboard's persisted model: pads and playlists, debounced-autosaved
/// to the shared App Group container exactly like `SceneStore`'s documents
/// (atomic writes, quarantine-on-corrupt, flush on termination). Mutations
/// are immediate — this is a live performance surface, not a draft/Apply
/// editor — and the playback runtime (`SoundboardController`) observes the
/// published lists to hot-swap clip payloads and gains in place.
@MainActor
final class SoundboardStore: ObservableObject {
    @Published private(set) var pads: [SoundPad] {
        didSet { scheduleAutosave() }
    }
    @Published private(set) var playlists: [MusicPlaylist] {
        didSet { scheduleAutosave() }
    }

    private static let fileName = "stream.soundboard.v1.json"
    private static let autosaveDelay: TimeInterval = 0.75

    private var autosaveTask: Task<Void, Never>?
    /// `nonisolated(unsafe)` so `deinit` can unregister it (the store lives
    /// for the app's lifetime; this is belt-and-braces).
    nonisolated(unsafe) private var terminationObserver: NSObjectProtocol?

    private let storageURL: URL

    init(directory: URL = DesktopStorage.projectDirectory) {
        storageURL = directory.appendingPathComponent(Self.fileName)
        let document = Self.loadDocument(url: storageURL) ?? SoundboardDocument()
        pads = document.pads
        playlists = document.playlists
        writeDocument()
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushPendingWrites() }
        }
    }

    deinit {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
    }

    // MARK: - Lookups

    func pad(withID id: SourceDefinitionID) -> SoundPad? {
        pads.first(where: { $0.id == id })
    }

    func playlist(withID id: SourceDefinitionID) -> MusicPlaylist? {
        playlists.first(where: { $0.id == id })
    }

    // MARK: - Mutations (immediate, autosaved)

    @discardableResult
    func addPad(_ pad: SoundPad) -> SoundPad {
        pads.append(pad)
        return pad
    }

    func updatePad(_ pad: SoundPad) {
        guard let index = pads.firstIndex(where: { $0.id == pad.id }) else { return }
        pads[index] = pad
    }

    func removePad(_ id: SourceDefinitionID) {
        pads.removeAll { $0.id == id }
    }

    @discardableResult
    func addPlaylist(_ playlist: MusicPlaylist) -> MusicPlaylist {
        playlists.append(playlist)
        return playlist
    }

    func updatePlaylist(_ playlist: MusicPlaylist) {
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        playlists[index] = playlist
    }

    func removePlaylist(_ id: SourceDefinitionID) {
        playlists.removeAll { $0.id == id }
    }

    // MARK: - Persistence

    /// Loads the document, quarantining an unreadable/newer file aside (never
    /// crash-loop, never overwrite data that couldn't be read — the S12 rule).
    private static func loadDocument(url: URL) -> SoundboardDocument? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let document = try? JSONDecoder().decode(SoundboardDocument.self, from: data) else {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            try? FileManager.default.moveItem(
                at: url,
                to: url.appendingPathExtension("corrupt.\(formatter.string(from: Date())).bak"))
            return nil
        }
        return document
    }

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.autosaveDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.writeDocument()
        }
    }

    /// Writes any pending debounced autosave NOW (app termination).
    func flushPendingWrites() {
        autosaveTask?.cancel()
        writeDocument()
    }

    private func writeDocument() {
        let document = SoundboardDocument(pads: pads, playlists: playlists)
        let url = storageURL
        guard let data = try? JSONEncoder().encode(document) else { return }
        try? ProjectDocumentHistory.write(data, to: url)
    }
}
