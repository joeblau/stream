import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A03 (issue #98): the embedded sound panel — soundboard pads, music
/// playlists, and the staged scene's bound sounds — hosted in the inspector's
/// Sound tab. Every action routes through the W05 dispatcher: structural
/// edits write the persisted soundboard document (immediate, autosaved),
/// transport fires the ONE shared playback instance per pad/playlist, and
/// scene-sound bindings stage/Take/undo like any scene content.
///
/// Missing files never fail silently: a pad/track/binding whose clip can't be
/// opened shows the engine's error and offers relink (a new bookmark — the
/// item's identity, channel, and level survive).
struct SoundboardPanelView: View {
    @EnvironmentObject private var dispatcher: StudioCommandDispatcher
    @EnvironmentObject private var soundboardStore: SoundboardStore
    @EnvironmentObject private var soundboard: SoundboardController
    @EnvironmentObject private var previewProgram: PreviewProgramModel

    @State private var addPadPresented = false
    @State private var relinkPad: SoundPad?
    @State private var editingPad: SoundPad?
    @State private var addTracksPlaylist: MusicPlaylist?
    @State private var renamePlaylist: MusicPlaylist?
    @State private var draftName = ""
    @State private var addSceneSoundPresented = false
    @State private var newSceneSoundRule: SceneSoundRule = .enter
    @State private var relinkBinding: SceneSoundBinding?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                padsSection
                Divider()
                playlistsSection
                Divider()
                sceneSoundsSection
            }
            .padding(12)
        }
        .fileImporter(isPresented: $addPadPresented,
                      allowedContentTypes: [.audio]) { result in
            guard case .success(let url) = result,
                  let pad = SoundPad.make(pickedFile: url) else { return }
            dispatcher.execute(.addSoundPad(pad))
        }
        .fileImporter(isPresented: relinkPadPresented,
                      allowedContentTypes: [.audio]) { result in
            guard let relinkPad, case .success(let url) = result,
                  let payload = MediaSourceFactory.payload(forPickedFile: url) else { return }
            var pad = relinkPad
            // Hot-swap: only the file identity changes — pad ID, channel,
            // color, policy, and volume all survive.
            pad.bookmarkData = payload.bookmarkData
            pad.fileName = payload.fileName
            dispatcher.execute(.updateSoundPad(pad))
            self.relinkPad = nil
        }
        .fileImporter(isPresented: addTracksPresented,
                      allowedContentTypes: [.audio],
                      allowsMultipleSelection: true) { result in
            guard let addTracksPlaylist, case .success(let urls) = result else { return }
            var playlist = addTracksPlaylist
            playlist.tracks.append(contentsOf: urls.compactMap { MusicTrack.make(pickedFile: $0) })
            dispatcher.execute(.updateMusicPlaylist(playlist))
            self.addTracksPlaylist = nil
        }
        .fileImporter(isPresented: $addSceneSoundPresented,
                      allowedContentTypes: [.audio]) { result in
            guard case .success(let url) = result,
                  let binding = SceneSoundBinding.make(pickedFile: url,
                                                       rule: newSceneSoundRule) else { return }
            updateSceneBindings { $0.append(binding) }
        }
        .fileImporter(isPresented: relinkBindingPresented,
                      allowedContentTypes: [.audio]) { result in
            guard let relinkBinding, case .success(let url) = result,
                  let payload = MediaSourceFactory.payload(forPickedFile: url) else { return }
            updateSceneBindings { bindings in
                guard let index = bindings.firstIndex(where: { $0.id == relinkBinding.id })
                else { return }
                bindings[index].bookmarkData = payload.bookmarkData
                bindings[index].fileName = payload.fileName
            }
            self.relinkBinding = nil
        }
        .alert("Rename Playlist", isPresented: renamePresented) {
            TextField("Name", text: $draftName)
            Button("Rename") {
                if let renamePlaylist {
                    let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        var playlist = renamePlaylist
                        playlist.name = trimmed
                        dispatcher.execute(.updateMusicPlaylist(playlist))
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Soundboard pads

    private var padsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label("Soundboard", systemImage: "square.grid.3x3.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    dispatcher.execute(.stopAllSoundEffects)
                } label: {
                    Image(systemName: "stop.octagon.fill")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .help("Stop all sound effects (pads and scene stingers)")
                Button {
                    addPadPresented = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Add an audio file as a soundboard pad")
            }
            if soundboardStore.pads.isEmpty {
                Text("No pads. Add an audio file — tap a pad to fire it into the program mix.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 8)], spacing: 8) {
                ForEach(soundboardStore.pads) { pad in
                    PadButtonView(pad: pad,
                                  isPlaying: soundboard.playingPadIDs.contains(pad.id),
                                  status: soundboard.padStatuses[pad.id],
                                  onTrigger: { dispatcher.execute(.triggerSoundPad(pad.id)) },
                                  onEdit: { editingPad = pad })
                    .contextMenu {
                        Button("Edit Pad…") { editingPad = pad }
                        Button("Stop") { dispatcher.execute(.stopSoundPad(pad.id)) }
                        Button("Relink Audio File…") { relinkPad = pad }
                        Divider()
                        Button("Remove Pad", role: .destructive) {
                            dispatcher.execute(.removeSoundPad(pad.id))
                        }
                    }
                }
            }
        }
        .popover(item: $editingPad) { pad in
            PadEditorView(pad: pad,
                          onRelink: {
                              relinkPad = pad
                              editingPad = nil
                          })
        }
    }

    // MARK: - Music playlists

    private var playlistsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label("Music", systemImage: "music.note.list")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    let playlist = MusicPlaylist(name: "Playlist \(soundboardStore.playlists.count + 1)")
                    dispatcher.execute(.addMusicPlaylist(playlist))
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Add a music playlist (one mix channel per playlist)")
            }
            if soundboardStore.playlists.isEmpty {
                Text("No playlists. Add one, then drop audio files into its track list.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            ForEach(soundboardStore.playlists) { playlist in
                PlaylistRowView(playlist: playlist,
                                state: soundboard.playlistStates[playlist.id]
                                    ?? SoundboardController.PlaylistPlaybackState(),
                                onAddTracks: { addTracksPlaylist = playlist },
                                onRename: {
                                    draftName = playlist.name
                                    renamePlaylist = playlist
                                })
            }
        }
    }

    // MARK: - Scene sounds

    private var sceneSoundsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Scene Sounds", systemImage: "rectangle.on.rectangle.badge.play")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
            if let scene = previewProgram.stagedScene {
                Text("Staged scene: \(scene.name) — sounds fire when the scene enters or leaves PROGRAM (Take).")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                ForEach(scene.soundBindings) { binding in
                    SceneSoundRowView(binding: binding,
                                      errorMessage: soundboard.sceneSoundErrors[binding.id],
                                      onRelink: { relinkBinding = binding })
                }
                HStack(spacing: 8) {
                    Picker("Rule", selection: $newSceneSoundRule) {
                        ForEach(SceneSoundRule.allCases, id: \.self) { rule in
                            Text(rule.displayName).tag(rule)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    Button {
                        addSceneSoundPresented = true
                    } label: {
                        Label("Add Sound…", systemImage: "plus")
                    }
                    .controlSize(.small)
                }
            } else {
                Text("No scene is staged in preview.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Helpers

    /// Scene-sound edits write the STAGED scene's bindings through the
    /// dispatcher (scene content: staged, Taken, reverted, undoable).
    private func updateSceneBindings(_ edit: (inout [SceneSoundBinding]) -> Void) {
        guard let scene = previewProgram.stagedScene else { return }
        var bindings = scene.soundBindings
        edit(&bindings)
        dispatcher.execute(.setSceneSoundBindings(bindings, in: nil))
    }

    private var relinkPadPresented: Binding<Bool> {
        Binding(get: { relinkPad != nil },
                set: { if !$0 { relinkPad = nil } })
    }

    private var addTracksPresented: Binding<Bool> {
        Binding(get: { addTracksPlaylist != nil },
                set: { if !$0 { addTracksPlaylist = nil } })
    }

    private var renamePresented: Binding<Bool> {
        Binding(get: { renamePlaylist != nil },
                set: { if !$0 { renamePlaylist = nil } })
    }

    private var relinkBindingPresented: Binding<Bool> {
        Binding(get: { relinkBinding != nil },
                set: { if !$0 { relinkBinding = nil } })
    }
}

// MARK: - Pad button + editor

/// One soundboard pad: colored button with icon + name, lit while playing,
/// badged on error. Tap fires the pad into the program mix.
private struct PadButtonView: View {
    let pad: SoundPad
    let isPlaying: Bool
    let status: MediaSourceStatus?
    let onTrigger: () -> Void
    let onEdit: () -> Void

    private var color: Color {
        let components = HexColor.components(pad.colorHex)
        return Color(red: components.red, green: components.green, blue: components.blue)
    }

    var body: some View {
        Button(action: onTrigger) {
            VStack(spacing: 4) {
                Image(systemName: pad.systemImage)
                    .font(.title3)
                Text(pad.name)
                    .font(.caption2.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 64)
            .padding(4)
            .background(color.opacity(isPlaying ? 0.9 : 0.35),
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                if status?.phase == .error {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(4)
                }
            }
        }
        .buttonStyle(.plain)
        .help(status?.phase == .error
              ? (status?.errorMessage ?? "Playback error — relink the audio file")
              : "\(pad.name) — \(pad.triggerPolicy.displayName)\(pad.loops ? ", loops" : "")")
    }
}

/// The pad's edit popover: name, color, icon, trigger policy, loop, and
/// per-pad program volume. Every change dispatches `.updateSoundPad`
/// (persisted in the soundboard document).
private struct PadEditorView: View {
    @EnvironmentObject private var dispatcher: StudioCommandDispatcher

    let pad: SoundPad
    let onRelink: () -> Void

    private static let colorPresets = ["#FF9500", "#FF3B30", "#34C759", "#0A84FF",
                                       "#BF5AF2", "#FFD60A", "#64D2FF", "#FF9F0A"]
    private static let iconChoices = ["speaker.wave.2.fill", "bell.fill", "burst.fill",
                                      "hands.clap.fill", "party.popper.fill", "star.fill",
                                      "music.note", "music.note.list", "mic.fill", "guitars.fill"]

    var body: some View {
        Form {
            TextField("Name", text: binding(\.name))
            LabeledContent("Color") {
                HStack(spacing: 4) {
                    ForEach(Self.colorPresets, id: \.self) { hex in
                        let components = HexColor.components(hex)
                        Circle()
                            .fill(Color(red: components.red, green: components.green,
                                        blue: components.blue))
                            .frame(width: 16, height: 16)
                            .overlay {
                                if hex == pad.colorHex {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                            }
                            .onTapGesture { update { $0.colorHex = hex } }
                    }
                }
            }
            Picker("Icon", selection: binding(\.systemImage)) {
                ForEach(Self.iconChoices, id: \.self) { icon in
                    Image(systemName: icon).tag(icon)
                }
            }
            .pickerStyle(.palette)
            Picker("Retrigger", selection: binding(\.triggerPolicy)) {
                ForEach(PadTriggerPolicy.allCases, id: \.self) { policy in
                    Text(policy.displayName).tag(policy)
                }
            }
            .pickerStyle(.segmented)
            Toggle("Loop", isOn: binding(\.loops))
            LabeledContent("Volume") {
                Slider(value: binding(\.volume), in: 0...2)
            }
            Button("Relink Audio File…", action: onRelink)
        }
        .formStyle(.grouped)
        .frame(width: 300)
        .padding(8)
    }

    private func binding<T>(_ keyPath: WritableKeyPath<SoundPad, T>) -> Binding<T> {
        Binding(get: { pad[keyPath: keyPath] },
                set: { newValue in update { $0[keyPath: keyPath] = newValue } })
    }

    private func update(_ edit: (inout SoundPad) -> Void) {
        var pad = pad
        edit(&pad)
        dispatcher.execute(.updateSoundPad(pad))
    }
}

// MARK: - Playlist row

/// One music playlist: transport (previous/play-pause/stop/next), the current
/// track with position, repeat/shuffle, per-playlist volume, and the
/// disclosure track list. One mix channel per playlist — track changes never
/// re-key it.
private struct PlaylistRowView: View {
    @EnvironmentObject private var dispatcher: StudioCommandDispatcher

    let playlist: MusicPlaylist
    let state: SoundboardController.PlaylistPlaybackState
    let onAddTracks: () -> Void
    let onRename: () -> Void

    private var currentTrack: MusicTrack? {
        playlist.tracks.indices.contains(state.trackIndex) ? playlist.tracks[state.trackIndex] : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button {
                    dispatcher.execute(.playlistPrevious(playlist.id))
                } label: {
                    Image(systemName: "backward.fill")
                }
                .buttonStyle(.borderless)
                .help("Previous track")
                Button {
                    dispatcher.execute(state.isPlaying
                                       ? .playlistPause(playlist.id)
                                       : .playlistPlay(playlist.id))
                } label: {
                    Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.borderless)
                .help(state.isPlaying ? "Pause" : "Play")
                Button {
                    dispatcher.execute(.playlistStop(playlist.id))
                } label: {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(.borderless)
                .help("Stop — rewind to the start of the track")
                Button {
                    dispatcher.execute(.playlistNext(playlist.id))
                } label: {
                    Image(systemName: "forward.fill")
                }
                .buttonStyle(.borderless)
                .help("Next track")
                VStack(alignment: .leading, spacing: 1) {
                    Text(playlist.name)
                        .font(.callout)
                        .lineLimit(1)
                    Text(currentTrack.map { "\($0.name)  \(format(state.positionSeconds)) / \(format(state.durationSeconds))" }
                            ?? "No track")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if state.phase == .error {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help(state.errorMessage ?? "Playback error — relink the track below")
                }
            }
            HStack(spacing: 8) {
                Slider(value: volumeBinding, in: 0...2)
                    .frame(maxWidth: 140)
                Picker("Repeat", selection: repeatBinding) {
                    ForEach(PlaylistRepeatMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 120)
                Toggle("Shuffle", isOn: shuffleBinding)
                    .controlSize(.small)
            }
            DisclosureGroup("Tracks (\(playlist.tracks.count))") {
                ForEach(Array(playlist.tracks.enumerated()), id: \.element.id) { index, track in
                    HStack(spacing: 6) {
                        if index == state.trackIndex, state.phase != .idle {
                            Image(systemName: state.isPlaying ? "play.circle.fill" : "circle.fill")
                                .foregroundStyle(state.isPlaying ? .green : .secondary)
                                .font(.caption2)
                        }
                        Text(track.name)
                            .font(.caption)
                            .lineLimit(1)
                        Spacer()
                        Button {
                            relink(track)
                        } label: {
                            Image(systemName: "link.badge.plus")
                        }
                        .buttonStyle(.borderless)
                        .help("Relink this track's audio file")
                        Button {
                            updatePlaylist { $0.tracks.removeAll { $0.id == track.id } }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove from playlist")
                    }
                }
                Button("Add Tracks…", action: onAddTracks)
                    .controlSize(.small)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .contextMenu {
            Button("Rename…", action: onRename)
            Divider()
            Button("Remove Playlist", role: .destructive) {
                dispatcher.execute(.removeMusicPlaylist(playlist.id))
            }
        }
    }

    /// Relink replaces a track's bookmark in place (the playlist's channel
    /// and the track's position in the list survive).
    private func relink(_ track: MusicTrack) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let replacement = MusicTrack.make(pickedFile: url) else { return }
        updatePlaylist { playlist in
            guard let index = playlist.tracks.firstIndex(where: { $0.id == track.id }) else { return }
            playlist.tracks[index].bookmarkData = replacement.bookmarkData
            playlist.tracks[index].fileName = replacement.fileName
        }
    }

    private var volumeBinding: Binding<Double> {
        Binding(get: { playlist.volume },
                set: { newValue in updatePlaylist { $0.volume = newValue } })
    }

    private var repeatBinding: Binding<PlaylistRepeatMode> {
        Binding(get: { playlist.repeatMode },
                set: { newValue in updatePlaylist { $0.repeatMode = newValue } })
    }

    private var shuffleBinding: Binding<Bool> {
        Binding(get: { playlist.isShuffled },
                set: { newValue in updatePlaylist { $0.isShuffled = newValue } })
    }

    private func updatePlaylist(_ edit: (inout MusicPlaylist) -> Void) {
        var playlist = playlist
        edit(&playlist)
        dispatcher.execute(.updateMusicPlaylist(playlist))
    }

    private func format(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Scene sound row

/// One scene-sound binding on the staged scene: rule picker, clip name,
/// per-binding volume, error state with relink, and remove. Edits write the
/// whole binding list through `.setSceneSoundBindings` (scene content).
private struct SceneSoundRowView: View {
    @EnvironmentObject private var dispatcher: StudioCommandDispatcher
    @EnvironmentObject private var previewProgram: PreviewProgramModel

    let binding: SceneSoundBinding
    let errorMessage: String?
    let onRelink: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Picker("Rule", selection: ruleBinding) {
                    ForEach(SceneSoundRule.allCases, id: \.self) { rule in
                        Text(rule.displayName).tag(rule)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 170)
                Text(binding.name)
                    .font(.callout)
                    .lineLimit(1)
                Spacer()
                if let errorMessage {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help(errorMessage)
                }
                Button(action: onRelink) {
                    Image(systemName: "link.badge.plus")
                }
                .buttonStyle(.borderless)
                .help("Relink this sound's audio file")
                Button {
                    updateBindings { $0.removeAll { $0.id == binding.id } }
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove this scene sound")
            }
            HStack(spacing: 8) {
                Text(binding.fileName ?? "No file linked")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Slider(value: volumeBinding, in: 0...2)
                    .frame(maxWidth: 120)
            }
        }
    }

    private var ruleBinding: Binding<SceneSoundRule> {
        Binding(get: { binding.rule },
                set: { newValue in
                    updateBindings { bindings in
                        guard let index = bindings.firstIndex(where: { $0.id == binding.id })
                        else { return }
                        bindings[index].rule = newValue
                    }
                })
    }

    private var volumeBinding: Binding<Double> {
        Binding(get: { binding.volume },
                set: { newValue in
                    updateBindings { bindings in
                        guard let index = bindings.firstIndex(where: { $0.id == binding.id })
                        else { return }
                        bindings[index].volume = newValue
                    }
                })
    }

    private func updateBindings(_ edit: (inout [SceneSoundBinding]) -> Void) {
        guard let scene = previewProgram.stagedScene else { return }
        var bindings = scene.soundBindings
        edit(&bindings)
        dispatcher.execute(.setSceneSoundBindings(bindings, in: nil))
    }
}
