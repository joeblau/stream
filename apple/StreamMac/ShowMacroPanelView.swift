import SwiftUI

struct ShowMacroPanelView: View {
    @ObservedObject var macros: ShowMacroController
    @EnvironmentObject private var dispatcher: StudioCommandDispatcher
    @State private var editing: ShowMacro?
    @State private var preview: ShowMacro?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Show Macros").font(.headline)
                Spacer()
                Button("Add") { editing = ShowMacro(name: "New Macro") }.disabled(macros.isRunning)
            }
            if macros.progress.phase != .idle {
                Text(macros.progress.message).font(.callout)
                if macros.isRunning {
                    ProgressView(value: Double(macros.progress.stepIndex), total: Double(max(1, macros.progress.totalSteps)))
                        .accessibilityLabel("Macro progress")
                        .accessibilityValue("Step \(macros.progress.stepIndex + 1) of \(macros.progress.totalSteps)")
                    Button("Cancel Macro") { dispatcher.execute(.cancelMacro) }
                }
                ForEach(Array(macros.progress.notes.enumerated()), id: \.offset) { _, note in Text(note).font(.caption).foregroundStyle(.orange) }
            }
            if let error = macros.lastError { Text(error).font(.caption).foregroundStyle(.orange) }
            List {
                ForEach(macros.document.macros) { macro in
                    VStack(alignment: .leading) {
                        Text(macro.name).font(.headline)
                        Text("\(macro.steps.count) ordered steps").font(.caption)
                        HStack {
                            Button("Preview / Run") { preview = macro }
                            Button("Edit") { editing = macro }.disabled(macros.isRunning)
                            Button("Delete", role: .destructive) {
                                var document = macros.document; document.macros.removeAll { $0.id == macro.id }
                                dispatcher.execute(.setShowMacros(document))
                            }.disabled(macros.isRunning)
                        }
                    }
                }
            }
            Text("One macro runs at a time. Conflicting output actions wait for completion; an emergency Stop cancels the macro. Cancel keeps steps already completed.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(10)
        .sheet(item: $editing) { macro in
            ShowMacroEditor(initial: macro, actions: dispatcher.catalogueActions(includeMacros: false)) { edited in
                var document = macros.document
                if let index = document.macros.firstIndex(where: { $0.id == edited.id }) { document.macros[index] = edited }
                else { document.macros.append(edited) }
                dispatcher.execute(.setShowMacros(document))
            }
        }
        .sheet(item: $preview) { macro in
            VStack(alignment: .leading, spacing: 12) {
                Text("Preview \(macro.name)").font(.title2)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(macro.steps.enumerated()), id: \.element.id) { index, step in
                            let action = dispatcher.catalogueActions(includeMacros: false).first { $0.id == step.commandID }
                            Text("\(index + 1). \(action?.title ?? "Missing target")")
                            Text("Delay: \(step.delaySeconds, format: .number) seconds · \(step.condition.label) · On failure: \(step.failurePolicy.rawValue)").font(.caption)
                            if let error = action?.unavailableReason { Text("Current availability: \(error)").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
                HStack {
                    Button("Close") { preview = nil }
                    Spacer()
                    Button("Run Macro") { preview = nil; dispatcher.execute(.runMacro(macro.id)) }
                        .disabled(macros.availability(for: macro.id) != nil)
                }
                if let reason = macros.availability(for: macro.id) { Text(reason).font(.caption).foregroundStyle(.orange) }
            }.padding(20).frame(minWidth: 480, minHeight: 320)
        }
    }
}
private struct ShowMacroEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ShowMacro
    let actions: [StudioPaletteAction]
    let onSave: (ShowMacro) -> Void
    init(initial: ShowMacro, actions: [StudioPaletteAction], onSave: @escaping (ShowMacro) -> Void) {
        _draft = State(initialValue: initial); self.actions = actions; self.onSave = onSave
    }
    private var choices: [StudioPaletteAction] { actions.filter { $0.command != nil && !$0.id.hasSuffix(".toggle") } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Show Macro").font(.title2)
            TextField("Macro name", text: $draft.name)
            List {
                ForEach($draft.steps) { $step in
                    VStack(alignment: .leading) {
                        Picker("Command", selection: $step.commandID) {
                            if !choices.contains(where: { $0.id == step.commandID }) { Text("Missing target").tag(step.commandID) }
                            ForEach(choices) { Text("\($0.category): \($0.title)").tag($0.id) }
                        }
                        HStack {
                            TextField("Delay (seconds)", value: $step.delaySeconds, format: .number).frame(maxWidth: 160)
                            Picker("Condition", selection: $step.condition) {
                                Text("Always").tag(ShowMacroCondition.always)
                                Text("Command available").tag(ShowMacroCondition.commandAvailable)
                                Text("Stream live").tag(ShowMacroCondition.streamLive)
                                Text("Recording active").tag(ShowMacroCondition.recordingActive)
                                ForEach(actions.filter { $0.category == "Scenes" }) { action in
                                    if let id = UUID(uuidString: String(action.id.dropFirst(6).dropLast(7))) {
                                        Text(action.title + " staged").tag(ShowMacroCondition.sceneStaged(id))
                                    }
                                }
                            }
                            Picker("On failure", selection: $step.failurePolicy) {
                                Text("Stop").tag(ShowMacroFailurePolicy.stop)
                                Text("Continue").tag(ShowMacroFailurePolicy.continue)
                            }
                        }
                        HStack {
                            Button("Move Up") { move(step.id, offset: -1) }
                            Button("Move Down") { move(step.id, offset: 1) }
                            Button("Remove") { draft.steps.removeAll { $0.id == step.id } }
                        }.controlSize(.small)
                    }
                }
            }
            HStack {
                Button("Add Step") { if let first = choices.first { draft.steps.append(ShowMacroStep(commandID: first.id)) } }.disabled(draft.steps.count >= 100)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { onSave(draft); dismiss() }
                    .disabled(ShowMacroDocument(macros: [draft]).validationError != nil)
            }
            if let error = ShowMacroDocument(macros: [draft]).validationError { Text(error).font(.caption).foregroundStyle(.orange) }
        }.padding(20).frame(minWidth: 700, minHeight: 480)
    }
    private func move(_ id: UUID, offset: Int) {
        guard let index = draft.steps.firstIndex(where: { $0.id == id }) else { return }
        let next = min(draft.steps.count - 1, max(0, index + offset))
        guard next != index else { return }
        let step = draft.steps.remove(at: index); draft.steps.insert(step, at: next)
    }
}
