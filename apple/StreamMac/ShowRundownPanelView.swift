import SwiftUI
import StreamCore

/// Embedded in the scene column; all actions use the studio dispatcher.
struct ShowRundownPanelView: View {
    @ObservedObject var runtime: ShowRundownController
    @EnvironmentObject private var dispatcher: StudioCommandDispatcher
    @EnvironmentObject private var sceneStore: SceneStore
    @State private var expanded = false
    @State private var editingID: UUID?

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                transport
                if runtime.playback.current != nil {
                    Text("Now: \(name(runtime.playback.current?.sceneID))")
                    Text("Next: \(name(runtime.playback.next?.sceneID))")
                        .foregroundStyle(.secondary)
                    if let remaining = runtime.remaining {
                        Text(remaining.formatted(.number.precision(.fractionLength(1))) + " seconds remaining")
                            .monospacedDigit()
                    } else { Text("Waiting for media end or Skip").foregroundStyle(.secondary) }
                }
                if let error = runtime.lastError {
                    Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(runtime.document.entries.enumerated()), id: \.element.id) { index, entry in
                            cueRow(entry, index: index)
                        }
                    }
                }.frame(maxHeight: 230)
                HStack {
                    Button("Add Selected Scene", systemImage: "plus") {
                        guard let scene = sceneStore.selected else { return }
                        update { $0.entries.append(ShowRundownEntry(cue: RundownCue(sceneID: scene.id.rawValue))) }
                    }.disabled(runtime.document.entries.count >= 500)
                    Spacer()
                }
                Toggle("Loop", isOn: Binding(get: { runtime.document.loop }, set: { value in update { $0.loop = value } }))
                Text("Editing stops playback. A manual Take pauses the rundown. Staged edits are preserved.")
                    .font(.caption).foregroundStyle(.secondary)
            }.font(.caption)
            .padding(.top, 6)
        } label: {
            HStack {
                Label("Rundown", systemImage: "list.number")
                Spacer()
                Text(runtime.playback.phase == .idle ? "\(runtime.document.entries.count) cues" : runtime.playback.phase.rawValue.capitalized)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(10)
    }

    private var transport: some View {
        HStack(spacing: 8) {
            Button(runtime.playback.phase == .paused ? "Resume" : "Play", systemImage: "play.fill") {
                dispatcher.execute(.rundownPlay)
            }.disabled(runtime.playback.phase == .running || !dispatcher.canExecute(.rundownPlay))
            Button("Pause", systemImage: "pause.fill") { dispatcher.execute(.rundownPause) }
                .disabled(runtime.playback.phase != .running)
            Button("Stop", systemImage: "stop.fill") { dispatcher.execute(.rundownStop) }
                .disabled(runtime.playback.phase == .idle)
            Button("Skip", systemImage: "forward.end.fill") { dispatcher.execute(.rundownSkip) }
                .disabled(runtime.playback.phase != .running && runtime.playback.phase != .paused)
        }.labelStyle(.iconOnly).buttonStyle(.borderless)
    }

    private func cueRow(_ entry: ShowRundownEntry, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Text("\(index + 1).").monospacedDigit()
                Button { editingID = editingID == entry.id ? nil : entry.id } label: {
                    Text(name(entry.cue.sceneID)).lineLimit(1)
                }.buttonStyle(.plain)
                if sceneStore.scenes.allSatisfy({ $0.id.rawValue != entry.cue.sceneID }) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.red)
                }
                Spacer(minLength: 0)
                Button { move(index, by: -1) } label: { Image(systemName: "arrow.up") }.disabled(index == 0)
                Button { move(index, by: 1) } label: { Image(systemName: "arrow.down") }.disabled(index + 1 == runtime.document.entries.count)
                Button { update { $0.entries.removeAll { $0.id == entry.id } } } label: { Image(systemName: "minus.circle") }
            }.buttonStyle(.borderless)
            if editingID == entry.id { editor(entry) }
        }.padding(6).background(runtime.playback.current?.id == entry.id ? Color.accentColor.opacity(0.15) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 5))
    }

    private func editor(_ entry: ShowRundownEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Scene", selection: Binding(get: { entry.cue.sceneID }, set: { value in edit(entry.id) { $0.cue.sceneID = value } })) {
                ForEach(sceneStore.scenes) { scene in Text(scene.name).tag(scene.id.rawValue) }
            }
            Toggle("Timed cue", isOn: Binding(get: { entry.cue.durationSeconds != nil }, set: { value in
                edit(entry.id) { $0.cue.durationSeconds = value ? 60 : nil }
            }))
            if entry.cue.durationSeconds != nil {
                TextField("Seconds", value: Binding(get: { entry.cue.durationSeconds ?? 60 }, set: { value in
                    edit(entry.id) { $0.cue.durationSeconds = value }
                }), format: .number).textFieldStyle(.roundedBorder)
            }
            Toggle("Advance when visible media ends", isOn: Binding(get: { entry.cue.advanceOnMediaEnd }, set: { value in
                edit(entry.id) { $0.cue.advanceOnMediaEnd = value }
            }))
            TextField("Shuffle group (optional)", text: Binding(get: { entry.cue.randomGroup }, set: { value in
                edit(entry.id) { $0.cue.randomGroup = value }
            })).textFieldStyle(.roundedBorder)
            Toggle("Override transition", isOn: Binding(get: { entry.transition != nil }, set: { value in
                edit(entry.id) { $0.transition = value ? (sceneStore.scenes.first { $0.id.rawValue == entry.cue.sceneID }?.transition ?? sceneStore.defaultTransition) : nil }
            }))
            if let transition = entry.transition {
                Picker("Transition", selection: Binding(get: { transition.style }, set: { value in edit(entry.id) { $0.transition?.style = value } })) {
                    ForEach(SceneTransitionStyle.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                if transition.style != .cut {
                    TextField("Transition seconds", value: Binding(get: { transition.durationSeconds }, set: { value in
                        edit(entry.id) { $0.transition?.durationSeconds = value }
                    }), format: .number).textFieldStyle(.roundedBorder)
                }
                if transition.style == .wipe || transition.style == .slide {
                    Picker("Direction", selection: Binding(get: { transition.direction }, set: { value in edit(entry.id) { $0.transition?.direction = value } })) {
                        ForEach(TransitionDirection.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                }
                if transition.style == .layerMotion {
                    Picker("Easing", selection: Binding(get: { transition.motionEasing }, set: { value in edit(entry.id) { $0.transition?.motionEasing = value } })) {
                        ForEach(MotionEasing.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Unmatched layers", selection: Binding(get: { transition.motionFallback }, set: { value in edit(entry.id) { $0.transition?.motionFallback = value } })) {
                        Text("Cut").tag(MotionFallback.cut)
                        Text("Dissolve").tag(MotionFallback.dissolve)
                    }
                }
                if transition.style == .dipToColor {
                    TextField("Dip color (#RRGGBB)", text: Binding(get: { transition.dipColorHex }, set: { value in edit(entry.id) { $0.transition?.dipColorHex = value } }))
                }
                if transition.style == .stinger {
                    Text(transition.stingerFileName.map { "Stinger: \($0)" } ?? "Configure a stinger on the scene or project, then enable this override. Missing media falls back to dissolve.").foregroundStyle(.secondary)
                }
            }
        }
    }

    private func name(_ id: UUID?) -> String {
        guard let id else { return "End of rundown" }
        return sceneStore.scenes.first { $0.id.rawValue == id }?.name ?? "Missing scene"
    }
    private func update(_ action: (inout ShowRundownDocument) -> Void) {
        var document = runtime.document
        action(&document)
        dispatcher.execute(.setRundown(document))
    }
    private func edit(_ id: UUID, _ action: (inout ShowRundownEntry) -> Void) {
        update { doc in
            guard let index = doc.entries.firstIndex(where: { $0.id == id }) else { return }
            action(&doc.entries[index])
        }
    }
    private func move(_ index: Int, by offset: Int) {
        update { $0.entries.swapAt(index, index + offset) }
    }
}
