import SwiftUI
import UniformTypeIdentifiers

/// A02 (issue #97): the media-source registry + transport UI. Rows for every
/// registered media source show the live playout status (loaded/playing/
/// paused/ended/error, from `CaptureSourcePool.mediaStates`) and carry the
/// transport the issue requires: play/pause/stop/restart, a seek bar with
/// position and remaining-time display, a loop toggle, and — in the Options
/// disclosure — autoplay, the end action, and trim points.
///
/// Every transport action routes through the W05 dispatcher (session state,
/// never undoable); durable playback policy (loop/autoplay/end action/trim)
/// is payload state and writes through the S05 registry (`updateSource`),
/// which keeps every bound layer's inline payload consistent without
/// re-keying the playback engine.
///
/// Embedded at the bottom of the layer panel today; the view is a plain
/// VStack so it can also drop into the Sources inspector's `Form` next to
/// the camera/screen/Syphon sections (a one-line MainWindowView change).
struct MediaSourcesSectionView: View {
    @EnvironmentObject private var sceneStore: SceneStore
    @EnvironmentObject private var capturePool: CaptureSourcePool

    @State private var addPickerPresented = false
    @State private var renameTarget: SourceDefinition?
    @State private var draftName = ""
    @State private var relinkTarget: SourceDefinition?

    private var mediaSources: [SourceDefinition] {
        sceneStore.sources.filter { $0.payload.isMedia }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label("Media Playout", systemImage: "film")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    addPickerPresented = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Add a video file (MP4/MOV/ProRes) as a media source")
            }
            if mediaSources.isEmpty {
                Text("No media sources. Add a video file, then bind it to a layer from the Add Layer menu.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            ForEach(mediaSources) { source in
                MediaSourceRowView(source: source,
                                   status: capturePool.mediaStatus(for: source.id),
                                   onRename: {
                                       draftName = source.name
                                       renameTarget = source
                                   },
                                   onRelink: { relinkTarget = source },
                                   onRemove: { sceneStore.removeSource(source.id) },
                                   updatePayload: { edit in
                                       updatePayload(of: source, edit)
                                   })
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .fileImporter(isPresented: $addPickerPresented,
                      allowedContentTypes: [.movie, .mpeg4Movie, .quickTimeMovie]) { result in
            guard case .success(let url) = result,
                  let payload = MediaSourceFactory.payload(forPickedFile: url) else { return }
            sceneStore.addSource(SourceDefinition(
                name: url.deletingPathExtension().lastPathComponent,
                payload: .media(payload)))
        }
        .fileImporter(isPresented: relinkPresented,
                      allowedContentTypes: [.movie, .mpeg4Movie, .quickTimeMovie]) { result in
            guard let relinkTarget, case .success(let url) = result,
                  let picked = MediaSourceFactory.payload(forPickedFile: url),
                  case .media(var payload) = relinkTarget.payload else { return }
            // Relink keeps the source's playback policy (loop/autoplay/end
            // action/trim) and replaces only the file identity.
            payload.bookmarkData = picked.bookmarkData
            payload.fileName = picked.fileName
            sceneStore.relinkSource(relinkTarget.id, to: .media(payload))
            self.relinkTarget = nil
        }
        .alert("Rename Source", isPresented: renamePresented) {
            TextField("Name", text: $draftName)
            Button("Rename") {
                if let renameTarget {
                    let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        sceneStore.renameSource(renameTarget.id, to: trimmed)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// Durable playback-policy edits write through the S05 registry update
    /// path (immediate, like relinks) — the media key is the source ID, so
    /// the playback engine keeps running and picks the new policy up live.
    private func updatePayload(of source: SourceDefinition,
                               _ edit: (inout MediaSourcePayload) -> Void) {
        guard case .media(var payload) = source.payload else { return }
        edit(&payload)
        var updated = source
        updated.payload = .media(payload)
        sceneStore.updateSource(updated)
    }

    private var relinkPresented: Binding<Bool> {
        Binding(
            get: { relinkTarget != nil },
            set: { if !$0 { relinkTarget = nil } })
    }

    private var renamePresented: Binding<Bool> {
        Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } })
    }
}

/// One media source row: status, transport controls, seek bar, and the
/// Options disclosure (loop, autoplay, end action, trim points).
private struct MediaSourceRowView: View {
    @EnvironmentObject private var dispatcher: StudioCommandDispatcher

    let source: SourceDefinition
    let status: MediaSourceStatus
    let onRename: () -> Void
    let onRelink: () -> Void
    let onRemove: () -> Void
    let updatePayload: (@escaping (inout MediaSourcePayload) -> Void) -> Void

    /// Live scrub position while the seek slider is dragged (the committed
    /// seek fires on drag end — frame-accurate seeks per pixel of drag
    /// would thrash the decoder).
    @State private var scrubPosition: Double?

    private var payload: MediaSourcePayload? {
        guard case .media(let payload) = source.payload else { return nil }
        return payload
    }

    private var isPlaying: Bool { status.phase == .playing }
    private var position: Double { scrubPosition ?? status.positionSeconds }
    private var remaining: Double { max(0, status.durationSeconds - position) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                statusBadge
                VStack(alignment: .leading, spacing: 1) {
                    Text(source.name)
                        .font(.callout)
                        .lineLimit(1)
                    Text(payload?.fileName ?? "No file linked")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                transportButtons
            }
            HStack(spacing: 8) {
                Slider(value: scrubBinding, in: 0...max(status.durationSeconds, 1)) { editing in
                    if !editing, let scrubPosition {
                        dispatcher.execute(.mediaSeek(source.id, to: scrubPosition))
                        self.scrubPosition = nil
                    }
                }
                .disabled(status.durationSeconds <= 0)
                Text("\(format(position))  −\(format(remaining))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            DisclosureGroup("Options") {
                if let payload {
                    Toggle("Loop", isOn: payloadBinding(\.loops, in: payload))
                    Toggle("Autoplay", isOn: payloadBinding(\.autoplay, in: payload))
                    Picker("When playback ends", selection: payloadBinding(\.endAction, in: payload)) {
                        ForEach(MediaEndAction.allCases, id: \.self) { action in
                            Text(action.displayName).tag(action)
                        }
                    }
                    .pickerStyle(.menu)
                    LabeledContent("Trim In") {
                        Text(format(payload.trimInSeconds ?? 0))
                    }
                    Slider(value: trimInBinding(payload),
                           in: 0...max(status.durationSeconds, 1))
                    LabeledContent("Trim Out") {
                        Text(format(payload.trimOutSeconds ?? status.durationSeconds))
                    }
                    Slider(value: trimOutBinding(payload),
                           in: 0...max(status.durationSeconds, 1))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .contextMenu {
            Button("Rename…", action: onRename)
            Button("Relink Media File…", action: onRelink)
            Divider()
            Button("Remove Source", role: .destructive, action: onRemove)
        }
    }

    // MARK: - Transport

    @ViewBuilder
    private var transportButtons: some View {
        Button {
            dispatcher.execute(isPlaying ? .mediaPause(source.id) : .mediaPlay(source.id))
        } label: {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
        }
        .buttonStyle(.borderless)
        .help(isPlaying ? "Pause" : "Play")
        Button {
            dispatcher.execute(.mediaStop(source.id))
        } label: {
            Image(systemName: "stop.fill")
        }
        .buttonStyle(.borderless)
        .help("Stop — rewind and clear the frame")
        Button {
            dispatcher.execute(.mediaRestart(source.id))
        } label: {
            Image(systemName: "backward.end.fill")
        }
        .buttonStyle(.borderless)
        .help("Restart from the beginning")
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch status.phase {
        case .idle:
            Image(systemName: "circle")
                .foregroundStyle(.tertiary)
                .help("Idle — playback starts when a visible layer uses this source")
        case .loading:
            ProgressView()
                .controlSize(.small)
                .help("Loading…")
        case .ready:
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
                .help("Loaded — parked at the start")
        case .playing:
            Image(systemName: "circle.fill")
                .foregroundStyle(.green)
                .help("Playing")
        case .paused:
            Image(systemName: "pause.circle")
                .foregroundStyle(.secondary)
                .help("Paused")
        case .ended:
            Image(systemName: "checkmark.circle")
                .foregroundStyle(.orange)
                .help("Ended — holding the last frame")
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .help(status.errorMessage ?? "Playback error")
        }
    }

    // MARK: - Bindings

    private var scrubBinding: Binding<Double> {
        Binding(
            get: { position },
            set: { scrubPosition = $0 })
    }

    private func payloadBinding<T>(_ keyPath: WritableKeyPath<MediaSourcePayload, T>,
                                   in payload: MediaSourcePayload) -> Binding<T> {
        Binding(
            get: { payload[keyPath: keyPath] },
            set: { newValue in
                updatePayload { $0[keyPath: keyPath] = newValue }
            })
    }

    /// Trim-in: 0…trim-out (a trim edit applies on the next loop/restart —
    /// the playback engine reads trim points at load time).
    private func trimInBinding(_ payload: MediaSourcePayload) -> Binding<Double> {
        Binding(
            get: { payload.trimInSeconds ?? 0 },
            set: { newValue in
                updatePayload {
                    let upper = $0.trimOutSeconds ?? status.durationSeconds
                    $0.trimInSeconds = min(max(0, newValue), upper)
                }
            })
    }

    /// Trim-out: trim-in…duration (nil = natural end).
    private func trimOutBinding(_ payload: MediaSourcePayload) -> Binding<Double> {
        Binding(
            get: { payload.trimOutSeconds ?? status.durationSeconds },
            set: { newValue in
                updatePayload {
                    let lower = $0.trimInSeconds ?? 0
                    $0.trimOutSeconds = max(min(newValue, status.durationSeconds), lower)
                }
            })
    }

    // MARK: - Time display

    private func format(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let minutes = total / 60
        let rest = total % 60
        return String(format: "%d:%02d", minutes, rest)
    }
}
