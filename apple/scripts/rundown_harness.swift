import Foundation
import StreamCore

@main struct RundownHarness {
    @MainActor static func main() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("rundown.json")
        try? FileManager.default.removeItem(at: url)
        var now = 100.0
        let runtime = ShowRundownController(url: url, clock: { now }, automaticallyTicks: false)
        let a = ShowRundownEntry(cue: RundownCue(sceneID: UUID(), durationSeconds: 10, advanceOnMediaEnd: true),
                                 transition: SceneTransition(style: .layerMotion, durationSeconds: 1))
        let b = ShowRundownEntry(cue: RundownCue(sceneID: UUID(), durationSeconds: nil, advanceOnMediaEnd: true))
        runtime.update(ShowRundownDocument(entries: [a,b], loop: false))
        let restored = ShowRundownController(url: url, automaticallyTicks: false)
        precondition(restored.document == runtime.document)
        precondition(restored.playback.phase == .idle, "Launch must not resume automation")
        var emitted: [UUID] = []
        runtime.onCue = { emitted.append($0.id) }
        runtime.play()
        runtime.play()
        precondition(emitted == [a.id], "Repeated Play must not restart cues")
        now = 104
        runtime.tick()
        precondition(runtime.remaining == 6)
        runtime.manualOverride()
        now = 200
        runtime.tick()
        precondition(runtime.playback.phase == .paused && runtime.remaining == 6)
        runtime.play()
        precondition(runtime.remaining == 6)
        now = 206
        runtime.noteMediaEnd(at: 205)
        runtime.tick()
        precondition(runtime.playback.current?.id == b.id && emitted.last == b.id)
        runtime.tick()
        precondition(runtime.playback.current?.id == b.id)
        runtime.noteMediaEnd(at: 205)
        now = 207
        runtime.tick()
        precondition(runtime.playback.current?.id == b.id, "Late prior-cue event must be ignored")
        runtime.noteMediaEnd(at: 207)
        runtime.tick()
        precondition(runtime.playback.phase == .finished)
        runtime.stop()
        runtime.onCue = { _ in runtime.fail("Missing scene") }
        runtime.play()
        precondition(runtime.lastError == "Missing scene" && runtime.playback.phase == .idle,
                     "A rejected cue must keep its error and stop transport")
        let invalid = ShowRundownDocument(entries: [a,a])
        runtime.update(invalid)
        precondition(runtime.document.entries.count == 2 && runtime.document.entries[1].id == b.id)
        print("PASS: controller persistence, safe launch, repeated Play, pause/resume, single timed/media advance, stale events, rejected cue, document validation")
    }
}
