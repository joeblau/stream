import Foundation
@MainActor enum DesktopStorage {
    static var projectDirectory: URL { FileManager.default.temporaryDirectory }
}
@main struct ShowMacrosHarness {
    @MainActor static func waitUntil(_ test: () -> Bool) async {
        for _ in 0..<500 {
            if test() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        preconditionFailure("Macro harness timed out")
    }
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("stream-macro-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("macros.json")
        let runtime = ShowMacroController(url: url)
        var available: Set<String> = ["scene.a.select", "studio.take", "output.record.start"]
        var emitted: [String] = []
        var transitionBusy = false
        runtime.resolve = { available.contains($0) ? nil : "Missing target" }
        runtime.execute = { emitted.append($0); return nil }
        runtime.settle = { _ in
            while transitionBusy { try Task.checkCancellation(); try await Task.sleep(for: .milliseconds(1)) }
        }
        let macro = ShowMacro(name: "Opening", steps: [ShowMacroStep(commandID: "scene.a.select"),
                                                      ShowMacroStep(commandID: "studio.take", delaySeconds: 60),
                                                      ShowMacroStep(commandID: "output.record.start")])
        precondition(runtime.update(ShowMacroDocument(macros: [macro])) == nil)
        let restored = ShowMacroController(url: url)
        precondition(restored.document == runtime.document && restored.progress.phase == .idle, "Launch never resumes old macro runs")
        precondition(runtime.start(macro.id) == nil)
        await waitUntil { emitted.count == 1 }
        precondition(runtime.start(macro.id) != nil, "Only one run owns output transitions")
        precondition(runtime.update(ShowMacroDocument()) != nil, "Running steps cannot be edited")
        runtime.cancel()
        try await Task.sleep(for: .milliseconds(5))
        precondition(emitted == ["scene.a.select"] && runtime.progress.phase == .cancelled, "Cancellation stops delayed steps")
        let sequence = ShowMacro(name: "Ordered", steps: [ShowMacroStep(commandID: "scene.a.select"), ShowMacroStep(commandID: "studio.take")])
        precondition(runtime.update(ShowMacroDocument(macros: [sequence])) == nil)
        emitted.removeAll(); transitionBusy = true
        precondition(runtime.start(sequence.id) == nil)
        try await Task.sleep(for: .milliseconds(5))
        precondition(emitted.isEmpty, "A command must wait for any in-flight transition")
        transitionBusy = false
        await waitUntil { runtime.progress.phase == .finished }
        precondition(emitted == ["scene.a.select", "studio.take"], "Commands execute in order exactly once")
        let conditioned = ShowMacro(name: "Conditional", steps: [ShowMacroStep(commandID: "scene.a.select", condition: .streamLive, failurePolicy: .continue),
                                                                 ShowMacroStep(commandID: "studio.take")])
        runtime.conditionMet = { condition, _ in condition == .always }
        precondition(runtime.update(ShowMacroDocument(macros: [conditioned])) == nil)
        emitted.removeAll(); precondition(runtime.start(conditioned.id) == nil)
        await waitUntil { runtime.progress.phase == .finished }
        precondition(emitted == ["studio.take"] && runtime.progress.notes.count == 1, "Condition failures honor Continue and remain visible")
        let deleted = ShowMacro(name: "Deleted target", steps: [ShowMacroStep(commandID: "scene.a.select"), ShowMacroStep(commandID: "studio.take")])
        runtime.execute = { id in emitted.append(id); available.remove("studio.take"); return nil }
        precondition(runtime.update(ShowMacroDocument(macros: [deleted])) == nil)
        emitted.removeAll(); precondition(runtime.start(deleted.id) == nil)
        await waitUntil { runtime.progress.phase == .failed }
        precondition(emitted == ["scene.a.select"] && runtime.lastError != nil, "Targets are resolved again per step after rename/delete/disconnect")
        available.insert("studio.take")
        precondition(runtime.progress.phase == .failed && emitted.count == 1, "Reconnect never resumes stale steps")
        precondition(ShowMacroDocument(macros: [ShowMacro(name: "Recursive", steps: [ShowMacroStep(commandID: "macro.other.run")])]).validationError != nil)
        precondition(ShowMacroDocument(macros: [ShowMacro(name: "Toggle", steps: [ShowMacroStep(commandID: "output.stream.toggle")])]).validationError != nil)
        precondition(ShowMacroDocument(macros: [ShowMacro(name: "Invalid", steps: [ShowMacroStep(commandID: "studio.take", delaySeconds: .infinity)])]).validationError != nil)
        let future = directory.appendingPathComponent("future.json")
        let bytes = Data("{\"version\":99,\"macros\":[]}".utf8); try bytes.write(to: future)
        let futureRuntime = ShowMacroController(url: future)
        precondition(futureRuntime.update(ShowMacroDocument()) != nil)
        let unchanged = try Data(contentsOf: future)
        precondition(unchanged == bytes)
        print("PASS: macro persistence/no-resume, ordering, cancellation, output serialization, conditions, continue/stop, deleted targets, reconnect, validation and future documents")
    }
}
