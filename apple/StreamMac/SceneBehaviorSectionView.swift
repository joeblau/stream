import SwiftUI

/// S08 (issue #99): the staged scene's program-entry behavior — the media
/// entry/exit policy and the opt-in audio snapshot ("the scene restores its
/// audio" vs "audio persists globally"), hosted in the Sources inspector's
/// staged-scene section. Every edit dispatches a scene-content command, so
/// the behavior stages, Takes, reverts, and undoes like layer edits; the
/// behavior itself fires only when the scene becomes PROGRAM (Take) —
/// previewing a scene never fires it.
struct SceneBehaviorSectionView: View {
    @EnvironmentObject private var dispatcher: StudioCommandDispatcher
    @EnvironmentObject private var previewProgram: PreviewProgramModel

    var body: some View {
        if let scene = previewProgram.stagedScene {
            Section("Scene Behavior (on Program)") {
                Picker("Media on Enter", selection: mediaEntryBinding(for: scene)) {
                    ForEach(SceneMediaEntryBehavior.allCases, id: \.self) { behavior in
                        Text(behavior.displayName).tag(behavior)
                    }
                }
                Picker("Media on Exit", selection: mediaExitBinding(for: scene)) {
                    ForEach(SceneMediaExitBehavior.allCases, id: \.self) { behavior in
                        Text(behavior.displayName).tag(behavior)
                    }
                }
                Toggle("Restore Audio Snapshot on Take",
                       isOn: audioSnapshotBinding(for: scene))
                if let snapshot = scene.audioSnapshot {
                    Button("Re-capture Current Mix") {
                        dispatcher.execute(.captureSceneAudioSnapshot(in: nil))
                    }
                    Text("\(snapshot.channelGains.count) channel override(s). Applied when this scene becomes program; channels the snapshot doesn't name keep their live levels.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func mediaEntryBinding(for scene: Scene) -> Binding<SceneMediaEntryBehavior> {
        Binding(
            get: { scene.mediaBehavior.entry },
            set: { entry in
                var behavior = scene.mediaBehavior
                behavior.entry = entry
                dispatcher.execute(.setSceneMediaBehavior(behavior, in: nil))
            })
    }

    private func mediaExitBinding(for scene: Scene) -> Binding<SceneMediaExitBehavior> {
        Binding(
            get: { scene.mediaBehavior.exit },
            set: { exit in
                var behavior = scene.mediaBehavior
                behavior.exit = exit
                dispatcher.execute(.setSceneMediaBehavior(behavior, in: nil))
            })
    }

    /// Enabling captures the CURRENT mix as the scene's snapshot; disabling
    /// clears it (the explicit inherit-current option).
    private func audioSnapshotBinding(for scene: Scene) -> Binding<Bool> {
        Binding(
            get: { scene.audioSnapshot != nil },
            set: { enabled in
                if enabled {
                    dispatcher.execute(.captureSceneAudioSnapshot(in: nil))
                } else {
                    dispatcher.execute(.setSceneAudioSnapshot(nil, in: nil))
                }
            })
    }
}
