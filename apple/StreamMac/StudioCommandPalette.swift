import AppKit
import SwiftUI
import StreamCore

struct StudioPaletteAction: Identifiable {
    let id: String
    let title: String
    let category: String
    let command: StudioCommand?
    var unavailableReason: String?
}

extension StudioCommandDispatcher {
    /// Rebuilt at invocation time: mappings follow UUIDs through rename and
    /// reorder; layer toggles always use the latest staged visibility.
    func paletteActions(scenes: [Scene], sources: [SourceDefinition], stagedScene: Scene?, includeMacros: Bool = true) -> [StudioPaletteAction] {
        var result: [StudioPaletteAction] = []
        func add(_ id: String, _ title: String, _ category: String, _ command: StudioCommand) {
            result.append(StudioPaletteAction(id: id, title: title, category: category,
                                              command: command, unavailableReason: availabilityError(for: command)?.description))
        }
        add("studio.take", "Take Preview to Program", "Studio", .take)
        add("studio.revert", "Revert Preview", "Studio", .revert)
        add("studio.directLive.enable", "Enable Direct Live Editing", "Studio", .setDirectLiveEditing(true))
        add("studio.directLive.disable", "Enable Preview / Program Editing", "Studio", .setDirectLiveEditing(false))
        let selectedID = state.stagedSceneID
        if let index = scenes.firstIndex(where: { $0.id == selectedID }) {
            if index + 1 < scenes.count { add("studio.scene.next", "Select Next Scene", "Scenes", .selectScene(scenes[index + 1].id)) }
            else { result.append(.init(id: "studio.scene.next", title: "Select Next Scene", category: "Scenes", command: nil, unavailableReason: "There is no next scene.")) }
            if index > 0 { add("studio.scene.previous", "Select Previous Scene", "Scenes", .selectScene(scenes[index - 1].id)) }
            else { result.append(.init(id: "studio.scene.previous", title: "Select Previous Scene", category: "Scenes", command: nil, unavailableReason: "There is no previous scene.")) }
        } else {
            result.append(.init(id: "studio.scene.next", title: "Select Next Scene", category: "Scenes", command: nil, unavailableReason: "Select a scene first."))
            result.append(.init(id: "studio.scene.previous", title: "Select Previous Scene", category: "Scenes", command: nil, unavailableReason: "Select a scene first."))
        }
        add("output.stream.toggle", state.stream.isActive ? "End Stream" : "Go Live", "Output", state.stream.isActive ? .stopStream : .startStream)
        add("output.stream.start", "Start Stream", "Output", .startStream)
        add("output.stream.stop", "Stop Stream", "Output", .stopStream)
        add("output.record.start", "Start Recording", "Output", .startRecording)
        add("output.record.stop", "Stop Recording", "Output", .stopRecording)
        add("output.record.pause", "Pause Recording", "Output", .pauseRecording)
        add("output.record.resume", "Resume Recording", "Output", .resumeRecording)
        add("output.record.split", "Start New Recording File", "Output", .startNewRecordingFile)
        add("output.record.marker", "Add Recording Marker", "Output", .addRecordingMarker("Chapter"))
        add("output.rehearsal.start", "Begin Local Rehearsal", "Output", .startRehearsal)
        add("output.rehearsal.stop", "End Local Rehearsal", "Output", .stopRehearsal)
        add("output.preview.start", "Start Preview", "Output", .startPreview)
        add("output.preview.stop", "Stop Preview", "Output", .stopPreview)
        add("settings.open", "Open Settings", "Application", .openSettings(nil))
        add("audio.monitor.toggle", state.monitoringEnabled ? "Disable Monitoring" : "Enable Monitoring", "Audio", .setMonitoringEnabled(!state.monitoringEnabled))
        let mic = AudioChannelID.microphone(deviceUID: nil)
        add("audio.microphone.mute", state.mixer.channelMutes[mic.label] == true ? "Unmute Microphone" : "Mute Microphone", "Audio", .setChannelMuted(mic, state.mixer.channelMutes[mic.label] != true))
        add("audio.microphone.mute.on", "Mute Microphone", "Audio", .setChannelMuted(mic, true))
        add("audio.microphone.mute.off", "Unmute Microphone", "Audio", .setChannelMuted(mic, false))
        func addAudioUnitActions(prefix: String, channel: AudioChannelID, name: String) {
            let current = state.fxChain(forLabel: channel.label)
            for (index, slot) in current.audioUnits.enumerated() {
                var chain = current; chain.audioUnits[index].isEnabled.toggle()
                add("\(prefix).au.\(slot.id.uuidString).bypass", "\(slot.isEnabled ? "Bypass" : "Enable") \(slot.component.displayName) — \(name)", "Audio Effects", .setChannelFXChain(channel, chain))
            }
        }
        addAudioUnitActions(prefix: "audio.microphone", channel: mic, name: "Microphone")
        for overlay in controllerOverlays() {
            let id = overlay.id.rawValue.uuidString
            add("overlay.\(id).visibility", "\(overlay.isVisible ? "Hide" : "Show") Global Overlay \(overlay.name)", "Global Overlays", .setOverlayVisibility(overlay.id, visible: !overlay.isVisible))
            add("overlay.\(id).show", "Show Global Overlay \(overlay.name)", "Global Overlays", .setOverlayVisibility(overlay.id, visible: true))
            add("overlay.\(id).hide", "Hide Global Overlay \(overlay.name)", "Global Overlays", .setOverlayVisibility(overlay.id, visible: false))
        }
        for bus in [AudioBus.program, .monitor, .aux] {
            let muted = state.mixer.mutedBuses.contains(bus.rawValue)
            add("audio.bus.\(bus.rawValue).mute", "\(muted ? "Unmute" : "Mute") \(bus.rawValue.capitalized) Bus", "Audio", .setBusMuted(bus, !muted))
            add("audio.bus.\(bus.rawValue).mute.on", "Mute \(bus.rawValue.capitalized) Bus", "Audio", .setBusMuted(bus, true))
            add("audio.bus.\(bus.rawValue).mute.off", "Unmute \(bus.rawValue.capitalized) Bus", "Audio", .setBusMuted(bus, false))
        }
        for storedScene in scenes {
            let scene = stagedScene?.id == storedScene.id ? stagedScene! : storedScene
            let sceneID = scene.id.rawValue.uuidString
            add("scene.\(sceneID).select", "Select \(scene.name)", "Scenes", .selectScene(scene.id))
            for layer in scene.layers {
                let layerID = layer.id.rawValue.uuidString
                add("scene.\(sceneID).layer.\(layerID).visibility", "\(layer.isVisible ? "Hide" : "Show") \(layer.name) — \(scene.name)",
                    layer.payload.displayName == "Camera" ? "Camera / PIP" : "Layers",
                    .setLayerVisibility(layer.id, visible: !layer.isVisible, in: scene.id))
                add("scene.\(sceneID).layer.\(layerID).show", "Show \(layer.name) — \(scene.name)", "Layers", .setLayerVisibility(layer.id, visible: true, in: scene.id))
                add("scene.\(sceneID).layer.\(layerID).hide", "Hide \(layer.name) — \(scene.name)", "Layers", .setLayerVisibility(layer.id, visible: false, in: scene.id))
                var effects = layer.effectOverrides ?? sources.first(where: { $0.id == layer.sourceID })?.effectDefaults ?? .identity
                effects.isBypassed.toggle()
                add("scene.\(sceneID).layer.\(layerID).effects.bypass", "\(effects.isBypassed ? "Bypass" : "Enable") Visual Effects — \(layer.name)", "Visual Effects", .setLayerSourceEffects(layer.id, effects, in: scene.id))
                if case .text(let text) = layer.payload, text.ticker != nil || text.timer != nil {
                    add("scene.\(sceneID).layer.\(layerID).animation.restart", "Reset Animation — \(layer.name)", "Layers", .setDynamicOverlayTransport(layer.id, .reset, in: scene.id))
                    add("scene.\(sceneID).layer.\(layerID).animation.start", "Start Animation — \(layer.name)", "Layers", .setDynamicOverlayTransport(layer.id, .start, in: scene.id))
                    add("scene.\(sceneID).layer.\(layerID).animation.pause", "Pause Animation — \(layer.name)", "Layers", .setDynamicOverlayTransport(layer.id, .pause, in: scene.id))
                }
                var audio = layer.audio
                audio.isMuted.toggle()
                add("scene.\(sceneID).layer.\(layerID).mute", "\(audio.isMuted ? "Mute" : "Unmute") \(layer.name) — \(scene.name)", "Audio", .setLayerAudio(layer.id, audio, in: scene.id))
            }
            for group in scene.groups {
                let members = scene.layers.filter { $0.groupID == group.id }
                let anyVisible = members.contains { $0.isVisible }
                let prefix = "scene.\(sceneID).group.\(group.id.rawValue.uuidString)"
                add("\(prefix).visibility", "\(anyVisible ? "Hide" : "Show") Group \(group.name) — \(scene.name)", "Layers", .setGroupVisibility(group.id, visible: !anyVisible, in: scene.id))
                add("\(prefix).show", "Show Group \(group.name) — \(scene.name)", "Layers", .setGroupVisibility(group.id, visible: true, in: scene.id))
                add("\(prefix).hide", "Hide Group \(group.name) — \(scene.name)", "Layers", .setGroupVisibility(group.id, visible: false, in: scene.id))
            }
        }
        for source in sources where source.payload.isMedia {
            let id = source.id.rawValue.uuidString
            add("media.\(id).play", "Play \(source.name)", "Media", .mediaPlay(source.id))
            add("media.\(id).pause", "Pause \(source.name)", "Media", .mediaPause(source.id))
            add("media.\(id).stop", "Stop \(source.name)", "Media", .mediaStop(source.id))
            add("media.\(id).restart", "Restart \(source.name)", "Media", .mediaRestart(source.id))
            let channel = AudioChannelID.media(source.id)
            add("media.\(id).mute", "Toggle Mute \(source.name)", "Audio", .setChannelMuted(channel, state.mixer.channelMutes[channel.label] != true))
            add("media.\(id).mute.on", "Mute \(source.name)", "Audio", .setChannelMuted(channel, true))
            add("media.\(id).mute.off", "Unmute \(source.name)", "Audio", .setChannelMuted(channel, false))
            addAudioUnitActions(prefix: "media.\(id)", channel: channel, name: source.name)
        }
        for source in sources where source.payload.isPDF {
            let id = source.id.rawValue.uuidString
            add("pdf.\(id).next", "Next PDF Page — \(source.name)", "PDF", .pdfNextPage(source.id))
            add("pdf.\(id).previous", "Previous PDF Page — \(source.name)", "PDF", .pdfPreviousPage(source.id))
            add("pdf.\(id).first", "First PDF Page — \(source.name)", "PDF", .pdfGoToPage(source.id, page: 0))
            add("pdf.\(id).goto", "Jump to PDF Page — \(source.name)", "PDF", .pdfGoToPage(source.id, page: 0))
        }
        for source in sources {
            if case .camera(let payload) = source.payload, let deviceID = payload.deviceID {
                for reaction in CameraReaction.allCases {
                    add("camera.\(source.id.rawValue.uuidString).reaction.\(reaction.rawValue)", "\(reaction.displayName) — \(source.name)", "Camera Reactions", .triggerCameraReaction(deviceID, reaction))
                }
            }
        }
        for pad in soundboardStore.pads {
            let id = pad.id.rawValue.uuidString
            add("sound.\(id).trigger", "Trigger \(pad.name)", "Sound", .triggerSoundPad(pad.id))
            add("sound.\(id).stop", "Stop \(pad.name)", "Sound", .stopSoundPad(pad.id))
        }
        for playlist in soundboardStore.playlists {
            let id = playlist.id.rawValue.uuidString
            add("playlist.\(id).play", "Play \(playlist.name)", "Sound", .playlistPlay(playlist.id))
            add("playlist.\(id).pause", "Pause \(playlist.name)", "Sound", .playlistPause(playlist.id))
            add("playlist.\(id).stop", "Stop \(playlist.name)", "Sound", .playlistStop(playlist.id))
            add("playlist.\(id).next", "Next Track — \(playlist.name)", "Sound", .playlistNext(playlist.id))
            add("playlist.\(id).previous", "Previous Track — \(playlist.name)", "Sound", .playlistPrevious(playlist.id))
        }
        if includeMacros {
        for macro in macros.document.macros {
            add("macro.\(macro.id.uuidString).run", "Run \(macro.name)", "Macros", .runMacro(macro.id))
        }
        add("macro.cancel", "Cancel Running Macro", "Macros", .cancelMacro)
        }
        // These are discoverability notices, never assignable fake commands.
        add("comments.previous", "Select Previous Queued Comment", "Comments", .selectPreviousComment)
        add("comments.next", "Select Next Queued Comment", "Comments", .selectNextComment)
        add("comments.show", "Show Selected Comment in Preview", "Comments", .showSelectedComment)
        add("comments.hide", "Hide Comment in Preview", "Comments", .hideComment)
        result.append(StudioPaletteAction(id: "unavailable.guests", title: "Control Guest Slot", category: "Guests", command: nil,
                                          unavailableReason: "Guest sessions are not implemented in this studio."))
        return result
    }
}

struct StudioCommandPalette: View {
    @ObservedObject var shortcuts: StudioShortcutController
    let actions: [StudioPaletteAction]
    @State private var search = ""
    @State private var selection: String?
    @FocusState private var searchFocused: Bool
    private var matches: [StudioPaletteAction] {
        StudioPaletteValues.matches(actions, search: search)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Command Palette").font(.title2)
                Spacer()
                Button("Shortcuts…") { shortcuts.openEditorAfterPalette = true; shortcuts.palettePresented = false }
                Button("Close") { shortcuts.palettePresented = false }
            }
            TextField("Search studio actions", text: $search)
                .textFieldStyle(.roundedBorder).focused($searchFocused)
                .onSubmit { run(selection ?? matches.first?.id) }
                .onKeyPress(.downArrow) { moveSelection(1); return .handled }
                .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
            List(selection: $selection) {
                ForEach(matches) { action in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(action.title)
                            Text(action.unavailableReason ?? action.category).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(StudioPaletteValues.bindings(shortcuts.document.bindings, commandID: action.id).map { $0.chord.displayName }.joined(separator: " / "))
                            .font(.caption.monospaced())
                        Button("Run") { run(action.id) }.disabled(action.unavailableReason != nil)
                    }
                    .tag(action.id)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("\(action.title), \(action.unavailableReason ?? "available")")
                }
            }
            Text("Return runs the selected action. Escape closes. ↑/↓ navigate results.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(20).frame(minWidth: 460, idealWidth: 580, minHeight: 360, idealHeight: 500)
        .onAppear { searchFocused = true }
        .onChange(of: search) { _, _ in selection = matches.first?.id }
        .onExitCommand { shortcuts.palettePresented = false }
    }
    private func moveSelection(_ offset: Int) {
        guard !matches.isEmpty else { return }
        let current = matches.firstIndex { $0.id == selection } ?? (offset > 0 ? -1 : matches.count)
        selection = matches[min(matches.count - 1, max(0, current + offset))].id
    }
    private func run(_ id: String?) {
        guard let id, let action = actions.first(where: { $0.id == id }), action.unavailableReason == nil else { return }
        shortcuts.palettePresented = false
        shortcuts.execute(id: id)
    }
}

struct StudioShortcutEditor: View {
    @ObservedObject var shortcuts: StudioShortcutController
    let actions: [StudioPaletteAction]
    @State private var search = ""
    private var matches: [StudioPaletteAction] {
        StudioPaletteValues.matches(actions, search: search)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Keyboard Shortcuts").font(.title2)
                Spacer()
                Button("Done") { shortcuts.cancelRecording(); shortcuts.editorPresented = false }
            }
            Toggle("Enable global shortcuts while other apps are active", isOn: Binding(
                get: { shortcuts.document.globalEnabled }, set: { shortcuts.setGlobalEnabled($0) }))
            Text("Each global binding also needs its Global switch enabled and Command + Option or Control. macOS reports shortcuts already owned by another app. Text fields in Stream suppress production shortcuts.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Search actions", text: $search).textFieldStyle(.roundedBorder)
            if let id = shortcuts.recordingCommandID {
                HStack {
                    Text("Press a shortcut for \(actions.first { $0.id == id }?.title ?? id). Escape cancels.")
                    Button("Cancel") { shortcuts.cancelRecording() }
                }.accessibilityLabel("Recording shortcut. Press keys, or Escape to cancel.")
            }
            if let message = shortcuts.message { Text(message).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(matches) { action in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(action.title)
                                Spacer()
                                Button("Add Shortcut") { shortcuts.record(action.id) }.disabled(action.command == nil)
                            }
                            if let reason = action.unavailableReason { Text(reason).font(.caption).foregroundStyle(.secondary) }
                            ForEach(StudioPaletteValues.bindings(shortcuts.document.bindings, commandID: action.id)) { binding in
                                bindingRow(binding)
                            }
                        }
                        Divider()
                    }
                    ForEach(StudioPaletteValues.missingBindings(shortcuts.document.bindings, actions: actions)) { binding in
                        VStack(alignment: .leading) {
                            Text("Missing target — mapping retained").font(.callout)
                            bindingRow(binding)
                        }
                    }
                }
            }
        }
        .padding(20).frame(minWidth: 460, idealWidth: 640, minHeight: 400, idealHeight: 560)
        .onExitCommand { shortcuts.cancelRecording(); shortcuts.editorPresented = false }
        .onDisappear { shortcuts.cancelRecording() }
    }
    private func bindingRow(_ binding: StudioShortcutBinding) -> some View {
        VStack(alignment: .leading) {
            HStack {
                Text(binding.chord.displayName).font(.body.monospaced())
                Toggle("Global", isOn: Binding(get: { binding.global }, set: { shortcuts.setGlobal(binding, enabled: $0) }))
                    .disabled(!binding.chord.supportsGlobal)
                Spacer()
                Button("Remove") { shortcuts.remove(binding) }
            }
            if let error = shortcuts.globalErrors[binding.commandID] { Text(error).font(.caption).foregroundStyle(.orange) }
        }
    }
}

/// Captures the one studio's NSWindow instead of resolving whichever app
/// window happens to be key when a global shortcut is pressed.
struct StudioShortcutWindowAttachment: NSViewRepresentable {
    let shortcuts: StudioShortcutController
    final class Attachment: NSView {
        var attach: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); attach?(window) }
    }
    func makeNSView(context: Context) -> Attachment {
        let view = Attachment(); view.attach = { shortcuts.install(window: $0) }; return view
    }
    func updateNSView(_ nsView: Attachment, context: Context) { shortcuts.install(window: nsView.window) }
}

/// Keep pure sequence predicates outside SwiftUI's actor-isolated body. Older
/// supported Swift compilers crash while emitting an isolated Bool thunk for
/// nested predicates that implicitly capture the view.
private enum StudioPaletteValues {
    static func matches(_ actions: [StudioPaletteAction], search: String) -> [StudioPaletteAction] {
        actions.filter { search.isEmpty || "\($0.title) \($0.category)".localizedCaseInsensitiveContains(search) }
    }
    static func bindings(_ values: [StudioShortcutBinding], commandID: String) -> [StudioShortcutBinding] {
        values.filter { $0.commandID == commandID }
    }
    static func missingBindings(_ values: [StudioShortcutBinding], actions: [StudioPaletteAction]) -> [StudioShortcutBinding] {
        let ids = Set(actions.map(\.id))
        return values.filter { !ids.contains($0.commandID) }
    }
}
