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
        add("output.stream.toggle", state.stream.isActive ? "End Stream" : "Go Live", "Output", state.stream.isActive ? .stopStream : .startStream)
        add("output.stream.start", "Start Stream", "Output", .startStream)
        add("output.stream.stop", "Stop Stream", "Output", .stopStream)
        add("output.record.start", "Start Recording", "Output", .startRecording)
        add("output.record.stop", "Stop Recording", "Output", .stopRecording)
        add("output.record.pause", "Pause Recording", "Output", .pauseRecording)
        add("output.record.resume", "Resume Recording", "Output", .resumeRecording)
        add("output.record.split", "Start New Recording File", "Output", .startNewRecordingFile)
        add("output.rehearsal.start", "Begin Local Rehearsal", "Output", .startRehearsal)
        add("output.rehearsal.stop", "End Local Rehearsal", "Output", .stopRehearsal)
        add("output.preview.start", "Start Preview", "Output", .startPreview)
        add("output.preview.stop", "Stop Preview", "Output", .stopPreview)
        add("settings.open", "Open Settings", "Application", .openSettings(nil))
        add("audio.monitor.toggle", state.monitoringEnabled ? "Disable Monitoring" : "Enable Monitoring", "Audio", .setMonitoringEnabled(!state.monitoringEnabled))
        let mic = AudioChannelID.microphone(deviceUID: nil)
        add("audio.microphone.mute", state.mixer.channelMutes[mic.label] == true ? "Unmute Microphone" : "Mute Microphone", "Audio", .setChannelMuted(mic, state.mixer.channelMutes[mic.label] != true))
        for bus in [AudioBus.program, .monitor, .aux] {
            let muted = state.mixer.mutedBuses.contains(bus.rawValue)
            add("audio.bus.\(bus.rawValue).mute", "\(muted ? "Unmute" : "Mute") \(bus.rawValue.capitalized) Bus", "Audio", .setBusMuted(bus, !muted))
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
                var audio = layer.audio
                audio.isMuted.toggle()
                add("scene.\(sceneID).layer.\(layerID).mute", "\(audio.isMuted ? "Mute" : "Unmute") \(layer.name) — \(scene.name)", "Audio", .setLayerAudio(layer.id, audio, in: scene.id))
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
        }
        if includeMacros {
        for macro in macros.document.macros {
            add("macro.\(macro.id.uuidString).run", "Run \(macro.name)", "Macros", .runMacro(macro.id))
        }
        add("macro.cancel", "Cancel Running Macro", "Macros", .cancelMacro)
        }
        // These are discoverability notices, never assignable fake commands.
        result.append(StudioPaletteAction(id: "unavailable.comments", title: "Put Comment on Program", category: "Comments", command: nil,
                                          unavailableReason: "Comment presentation is not implemented in this studio."))
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
        actions.filter { search.isEmpty || "\($0.title) \($0.category)".localizedCaseInsensitiveContains(search) }
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
                        Text(shortcuts.document.bindings.filter { $0.commandID == action.id }.map { $0.chord.displayName }.joined(separator: " / "))
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
        actions.filter { search.isEmpty || "\($0.title) \($0.category)".localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Keyboard Shortcuts").font(.title2)
                Spacer()
                Button("Done") { shortcuts.cancelRecording(); shortcuts.editorPresented = false }
            }
            Toggle("Enable global shortcuts while other apps are active", isOn: Binding(
                get: { shortcuts.document.globalEnabled }, set: shortcuts.setGlobalEnabled))
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
                            ForEach(shortcuts.document.bindings.filter { $0.commandID == action.id }) { binding in
                                bindingRow(binding)
                            }
                        }
                        Divider()
                    }
                    ForEach(shortcuts.document.bindings.filter { binding in !actions.contains { $0.id == binding.commandID } }) { binding in
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
