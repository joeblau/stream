import Combine
import Foundation

enum ShowMacroCondition: Codable, Hashable, Sendable {
    case always, commandAvailable, streamLive, recordingActive
    case sceneStaged(UUID)
    var label: String {
        switch self {
        case .always: return "Always"
        case .commandAvailable: return "Command available"
        case .streamLive: return "Stream live"
        case .recordingActive: return "Recording active"
        case .sceneStaged(let id): return "Staged scene \(id)"
        }
    }
}
enum ShowMacroFailurePolicy: String, Codable, CaseIterable, Sendable { case stop, `continue` }
struct ShowMacroStep: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var commandID: String
    var delaySeconds = 0.0
    var condition: ShowMacroCondition = .always
    var failurePolicy: ShowMacroFailurePolicy = .stop
}
struct ShowMacro: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var steps: [ShowMacroStep] = []
}
struct ShowMacroDocument: Codable, Equatable, Sendable {
    var version = 1
    var macros: [ShowMacro] = []
    var validationError: String? {
        guard version == 1 else { return "Unsupported macro document version." }
        guard macros.count <= 100, Set(macros.map(\.id)).count == macros.count else { return "Use at most 100 macros with unique IDs." }
        for macro in macros {
            guard !macro.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, macro.name.count <= 128 else { return "Macro names must contain 1–128 characters." }
            guard macro.steps.count <= 100, Set(macro.steps.map(\.id)).count == macro.steps.count else { return "Use at most 100 steps with unique IDs per macro." }
            for step in macro.steps {
                guard !step.commandID.isEmpty, step.commandID.count <= 512, !step.commandID.hasPrefix("macro.") else { return "Choose a command for every step. Macros cannot call macros." }
                guard !step.commandID.hasSuffix(".toggle") else { return "Use explicit start/stop commands in macros." }
                guard step.delaySeconds.isFinite, (0...3600).contains(step.delaySeconds) else { return "Step delays must be between 0 and 3600 seconds." }
            }
        }
        return nil
    }
}
struct ShowMacroProgress: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable { case idle, running, finished, cancelled, failed }
    var phase: Phase = .idle
    var macroID: UUID?
    var runID: UUID?
    var stepIndex = 0
    var totalSteps = 0
    var message = ""
    var notes: [String] = []
}
struct ShowMacroRunError: Error, CustomStringConvertible {
    let description: String
}

@MainActor final class ShowMacroController: ObservableObject {
    @Published private(set) var document: ShowMacroDocument
    @Published private(set) var progress = ShowMacroProgress()
    @Published private(set) var lastError: String?
    var resolve: (String) -> String? = { _ in "The studio command layer is unavailable." }
    var conditionMet: (ShowMacroCondition, String) -> Bool = { condition, _ in condition == .always }
    var execute: (String) -> String? = { _ in "The studio command layer is unavailable." }
    var settle: (String) async throws -> Void = { _ in }
    private let url: URL
    private let sleep: (Double) async throws -> Void
    private var task: Task<Void, Never>?
    private var persistenceBlocked = false
    var isRunning: Bool { progress.phase == .running }

    init(url: URL? = nil, sleep: @escaping (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.url = url ?? DesktopStorage.projectDirectory.appendingPathComponent("stream.macros.v1.json")
        self.sleep = sleep
        document = ShowMacroDocument()
        if FileManager.default.fileExists(atPath: self.url.path) {
            do {
                let restored = try JSONDecoder().decode(ShowMacroDocument.self, from: Data(contentsOf: self.url))
                guard restored.validationError == nil else {
                    persistenceBlocked = true; lastError = restored.validationError; return
                }
                document = restored
            } catch { persistenceBlocked = true; lastError = "Could not read macros: \(error.localizedDescription)" }
        }
    }
    deinit { task?.cancel() }
    @discardableResult func update(_ document: ShowMacroDocument) -> String? {
        guard !isRunning else { return "Cancel the running macro before editing macros." }
        guard !persistenceBlocked else { return lastError ?? "The macro file cannot be overwritten." }
        guard document.validationError == nil else { return document.validationError }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(document).write(to: url, options: .atomic)
            self.document = document; lastError = nil
            return nil
        } catch { lastError = "Could not save macros: \(error.localizedDescription)"; return lastError }
    }
    func availability(for id: UUID) -> String? {
        guard !isRunning else { return "A macro is already running. Cancel it before starting another." }
        guard let macro = document.macros.first(where: { $0.id == id }) else { return "The macro no longer exists." }
        guard !macro.steps.isEmpty else { return "Add at least one step to the macro." }
        // Preflight validates identities, not future output availability.
        return macro.steps.compactMap { resolve($0.commandID) }.first
    }
    @discardableResult func start(_ id: UUID) -> String? {
        if let error = availability(for: id) { lastError = error; return error }
        guard let macro = document.macros.first(where: { $0.id == id }) else { return "The macro no longer exists." }
        let runID = UUID()
        progress = ShowMacroProgress(phase: .running, macroID: id, runID: runID, totalSteps: macro.steps.count,
                                     message: "Starting \(macro.name)")
        lastError = nil
        task = Task { [weak self] in
            guard let self else { return }
            for (index, step) in macro.steps.enumerated() {
                do {
                    try Task.checkCancellation()
                    guard self.progress.runID == runID && self.isRunning else { return }
                    self.progress.stepIndex = index
                    self.progress.message = step.delaySeconds > 0 ? "Waiting \(step.delaySeconds) seconds before step \(index + 1)" : "Step \(index + 1)"
                    if step.delaySeconds > 0 { try await self.sleep(step.delaySeconds) }
                    try Task.checkCancellation()
                    guard self.progress.runID == runID && self.isRunning else { return }
                    try await self.settle("")
                    try Task.checkCancellation()
                    guard self.progress.runID == runID && self.isRunning else { return }
                    if let error = self.resolve(step.commandID) { throw ShowMacroRunError(description: error) }
                    guard self.conditionMet(step.condition, step.commandID) else {
                        throw ShowMacroRunError(description: "Condition not met: \(step.condition.label)")
                    }
                    if let error = self.execute(step.commandID) { throw ShowMacroRunError(description: error) }
                    try await self.settle(step.commandID)
                } catch is CancellationError { return }
                catch {
                    let message = "Step \(index + 1): \(error)"
                    self.progress.notes.append(message)
                    if step.failurePolicy == .stop {
                        self.lastError = message; self.progress.phase = .failed; self.progress.message = message; self.task = nil; return
                    }
                }
            }
            guard self.progress.runID == runID && self.isRunning else { return }
            self.progress.phase = .finished; self.progress.message = "Finished \(macro.name)"; self.task = nil
        }
        return nil
    }
    func cancel() {
        task?.cancel(); task = nil
        guard isRunning else { return }
        progress.phase = .cancelled; progress.message = "Cancelled; commands already completed remain applied."
    }
}
