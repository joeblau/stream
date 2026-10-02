import SwiftUI

/// Recording controls stay attached to the main studio transport. Folder access
/// uses the standard macOS picker and persists a security-scoped bookmark.
struct RecordingOptionsView: View {
    @EnvironmentObject private var controller: StreamController
    @State private var audioSources: [RecordingAudioSource] = []
    @State private var videoSources: [RecordingVideoSource] = []
    @ObservedObject var recorder: RecordingController
    @State private var presented = false

    var body: some View {
        Button("Recording Options", systemImage: "slider.horizontal.3") { presented.toggle() }
            .labelStyle(.iconOnly)
            .help("Recording options and folder")
            .popover(isPresented: $presented, arrowEdge: .bottom) {
                ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Recording").font(.headline)
                    Group {
                        Picker("Container", selection: $recorder.preferences.container) {
                            ForEach(RecordingContainer.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        Picker("Codec", selection: $recorder.preferences.codec) {
                            ForEach(RecordingCodec.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        Picker("Quality", selection: $recorder.preferences.quality) {
                            ForEach(RecordingQuality.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        TextField("File prefix", text: $recorder.preferences.filenamePrefix)
                        Stepper("Record-only countdown: \(recorder.preferences.countdownSeconds)s", value: $recorder.preferences.countdownSeconds, in: 0...60)
                        Stepper("Split duration: \(recorder.preferences.splitAfterMinutes == 0 ? "Off" : "\(recorder.preferences.splitAfterMinutes) minutes")", value: $recorder.preferences.splitAfterMinutes, in: 0...240)
                        Stepper("Split size: \(recorder.preferences.splitAfterMegabytes == 0 ? "Off" : "\(recorder.preferences.splitAfterMegabytes) MB")", value: $recorder.preferences.splitAfterMegabytes, in: 0...20_000, step: 100)
                        Text(recorder.folderLabel).font(.caption).lineLimit(2).textSelection(.enabled)
                        HStack {
                            Button("Choose Folder…") { recorder.chooseFolder() }
                            Button("Default Folder") { recorder.useDefaultFolder() }
                        }
                    }
                    .disabled(recorder.state.isActive)
                    Toggle("Auto-record on Go Live", isOn: $recorder.preferences.autoRecordOnGoLive)
                    Divider()
                    Text("Isolated audio (up to 8 tracks)").font(.subheadline.bold())
                    Text("Widget audio follows its System Mix route. Independent widget audio taps are unavailable.")
                        .font(.caption).foregroundStyle(.secondary)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(audioSources) { source in
                                isolatedSource(source)
                            }
                            ForEach(recorder.preferences.isolatedTracks.filter { selection in !audioSources.contains(where: { $0.id == selection.targetID }) }) { selection in
                                HStack {
                                    Text("\(selection.name) — unavailable").foregroundStyle(.orange)
                                    Button("Remove") { recorder.preferences.isolatedTracks.removeAll { $0.targetID == selection.targetID } }
                                }
                            }
                        }
                    }.frame(maxHeight: 170).disabled(recorder.state.isActive)
                    ForEach(recorder.isolatedProgress) { track in
                        Text("\(track.name): \(track.status)\(track.missingSourceFrames > 0 ? " · source gaps" : "")\(track.error.map { " · " + $0 } ?? "")")
                            .font(.caption).foregroundStyle(track.error == nil ? Color.secondary : Color.orange)
                    }
                    Divider()
                    Text("Isolated video (up to 2 sources)").font(.subheadline.bold())
                    Text("Measured on 16-core Apple M3 Max (Mac15,8): up to two 1080p30 sources, with up to four program/publisher/ISO encoders in total. Other Mac classes await native qualification. The selected folder is write-tested before start.")
                        .font(.caption).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(videoSources) { source in isolatedVideoSource(source) }
                        ForEach(recorder.preferences.isolatedVideoTracks.filter { selected in !videoSources.contains { $0.id == selected.targetID } }) { selection in
                            HStack { Text("\(selection.name) — unavailable").foregroundStyle(.orange)
                                Button("Remove") { recorder.preferences.isolatedVideoTracks.removeAll { $0.targetID == selection.targetID } } }
                        }
                    }.disabled(recorder.state.isActive)
                    if let budget = recorder.videoBudget {
                        Text("Folder: \(Int(budget.measuredDiskMegabytesPerSecond ?? 0)) MB/s · estimated recording writes: \(budget.estimatedDiskMegabytesPerSecond, specifier: "%.1f") MB/s")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(recorder.isolatedVideoProgress) { track in
                        Text("\(track.name): \(track.status) · \(track.missingVideoFrames) missing frames\(track.error.map { " · " + $0 } ?? track.warning.map { " · " + $0 } ?? "")")
                            .font(.caption).foregroundStyle(track.error == nil ? Color.secondary : Color.orange)
                    }
                    Text("Recording uses its own encoder at the program canvas size and frame rate. High quality uses more disk space; HEVC may add encoder load. File changes and pause keep network streaming active.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Done") { presented = false }
                }
                .padding(16)
                .frame(width: 420)
                }.frame(maxHeight: 580)
                .task {
                    while !Task.isCancelled {
                        audioSources = await controller.recordingAudioSources()
                        videoSources = controller.recordingVideoSources()
                        try? await Task.sleep(for: .seconds(1))
                    }
                }
            }
    }

    @ViewBuilder private func isolatedVideoSource(_ source: RecordingVideoSource) -> some View {
        let index = recorder.preferences.isolatedVideoTracks.firstIndex { $0.targetID == source.id }
        VStack(alignment: .leading, spacing: 4) {
            Toggle(source.name + (source.isAvailable ? "" : " (no frame received)"), isOn: Binding(
                get: { recorder.preferences.isolatedVideoTracks.contains { $0.targetID == source.id } },
                set: { selected in
                    if selected, source.unsupportedReason == nil, recorder.preferences.isolatedVideoTracks.count < 2 {
                        recorder.preferences.isolatedVideoTracks.append(.init(targetID: source.id, name: source.name))
                    } else if !selected { recorder.preferences.isolatedVideoTracks.removeAll { $0.targetID == source.id } }
                })).disabled(source.unsupportedReason != nil && index == nil)
            if let reason = source.unsupportedReason { Text(reason).font(.caption).foregroundStyle(.orange) }
            if let index {
                let selected = recorder.preferences.isolatedVideoTracks[index]
                Picker("Processing", selection: videoBinding(source.id, \.processing, fallback: selected.processing)) {
                    ForEach(IsolatedVideoProcessing.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                HStack {
                    Picker("Size", selection: videoBinding(source.id, \.resolution, fallback: selected.resolution)) {
                        ForEach(IsolatedVideoResolution.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Picker("Rate", selection: videoBinding(source.id, \.frameRate, fallback: selected.frameRate)) {
                        Text("15 fps").tag(15); Text("30 fps").tag(30)
                    }
                }
                HStack {
                    Picker("Codec", selection: videoBinding(source.id, \.codec, fallback: selected.codec)) {
                        ForEach(RecordingCodec.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Picker("Quality", selection: videoBinding(source.id, \.quality, fallback: selected.quality)) {
                        ForEach(RecordingQuality.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                }
                Picker("Associated audio", selection: videoBinding(source.id, \.audioTargetID, fallback: selected.audioTargetID)) {
                    Text("Video Only").tag(String?.none)
                    ForEach(audioSources) { audio in Text(audio.name).tag(String?.some(audio.id)) }
                }.onChange(of: selected.audioTargetID) { _, newValue in
                    guard let current = recorder.preferences.isolatedVideoTracks.firstIndex(where: { $0.targetID == source.id }) else { return }
                    recorder.preferences.isolatedVideoTracks[current].audioName = audioSources.first { $0.id == newValue }?.name
                }
            }
        }
    }

    /// Resolve the stable source ID for each edit; removing another row can
    /// change indices while SwiftUI still retains that row's picker binding.
    private func videoBinding<Value>(_ id: String, _ keyPath: WritableKeyPath<IsolatedVideoSelection, Value>, fallback: Value) -> Binding<Value> {
        Binding(get: {
            recorder.preferences.isolatedVideoTracks.first { $0.targetID == id }?[keyPath: keyPath] ?? fallback
        }, set: { value in
            guard let index = recorder.preferences.isolatedVideoTracks.firstIndex(where: { $0.targetID == id }) else { return }
            recorder.preferences.isolatedVideoTracks[index][keyPath: keyPath] = value
        })
    }

    @ViewBuilder private func isolatedSource(_ source: RecordingAudioSource) -> some View {
        let index = recorder.preferences.isolatedTracks.firstIndex { $0.targetID == source.id }
        VStack(alignment: .leading, spacing: 4) {
            Toggle(source.name + (source.isAvailable ? "" : " (no audio received)"), isOn: Binding(
                get: { recorder.preferences.isolatedTracks.contains { $0.targetID == source.id } },
                set: { selected in
                    if selected, recorder.preferences.isolatedTracks.count < 8 {
                        recorder.preferences.isolatedTracks.append(IsolatedRecordingSelection(targetID: source.id, name: source.name))
                    } else if !selected { recorder.preferences.isolatedTracks.removeAll { $0.targetID == source.id } }
                }))
            if let index {
                HStack {
                    Picker("Format", selection: $recorder.preferences.isolatedTracks[index].format) {
                        ForEach(IsolatedAudioFormat.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    if !source.isBus {
                        Picker("Processing", selection: $recorder.preferences.isolatedTracks[index].processing) {
                            ForEach(IsolatedAudioProcessing.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                    } else { Text("Mixed bus").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }
}
