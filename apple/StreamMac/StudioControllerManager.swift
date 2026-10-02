import Combine
import Foundation

struct StudioControllerTarget: Identifiable {
    var id: String
    var title: String
    var kind: StudioControllerTargetKind
    /// Numeric targets use linear gain 0…2. Feedback is normalized 0…1.
    var normalizedValue: Double
    var unavailableReason: String?
    var execute: @MainActor (Double?) -> String?
}

@MainActor final class StudioControllerManager: ObservableObject {
    @Published private(set) var document = StudioControllerMappingDocument()
    @Published private(set) var midiEnabled = false
    @Published private(set) var oscEnabled = false
    @Published private(set) var midiStatus = "Disabled"
    @Published private(set) var oscStatus = "Disabled"
    @Published private(set) var sources: [StudioMIDITransport.Endpoint] = []
    @Published private(set) var destinations: [StudioMIDITransport.Endpoint] = []
    @Published private(set) var sourceID: Int32 = 0
    @Published private(set) var destinationID: Int32 = 0
    @Published private(set) var feedbackChannel: UInt8 = 15
    @Published private(set) var oscPort: UInt16 = 32146
    @Published private(set) var oscFeedbackPort: UInt16 = 0
    @Published private(set) var learningTarget: String?
    @Published var message: String?
    var targets: @MainActor () -> [StudioControllerTarget] = { [] }
    var interactionBlocked: @MainActor () -> Bool = { false }
    var scopeIsCurrent: @MainActor () -> Bool = { true }
    var currentRunID: @MainActor () -> UUID? = { nil }
    var cancelRun: @MainActor (UUID) -> Void = { _ in }
    private var ownedRun: UUID?
    private var activeFeedbackDestination: Int32 = 0
    private let midi = StudioMIDITransport()
    let osc = StudioOSCTransport()
    private let defaults: UserDefaults
    private let url: URL
    private(set) var persistenceBlocked = false
    private var timer: Task<Void, Never>?
    private var held = Set<UUID>()
    private var values: [UUID: Double] = [:]
    private var feedbackValues: [UUID: Double] = [:]
    private var learningKind: StudioControllerTargetKind?
    private var learningInverted = false
    private var refreshCounter = 0
    init(url: URL? = nil, defaults: UserDefaults = .standard) {
        self.url = url ?? DesktopStorage.projectDirectory.appendingPathComponent("stream.controllers.v1.json")
        self.defaults = defaults
        sourceID = Int32(clamping: defaults.integer(forKey: "studio.controllers.midiSource"))
        destinationID = Int32(clamping: defaults.integer(forKey: "studio.controllers.midiFeedback"))
        feedbackChannel = UInt8(max(0, min(15, defaults.object(forKey: "studio.controllers.feedbackChannel") as? Int ?? 15)))
        oscPort = UInt16(clamping: defaults.object(forKey: "studio.controllers.oscPort") as? Int ?? 32146)
        oscFeedbackPort = UInt16(clamping: defaults.integer(forKey: "studio.controllers.oscFeedbackPort"))
        if FileManager.default.fileExists(atPath: self.url.path) {
            do {
                let data = try Data(contentsOf: self.url)
                guard data.count <= 256_000 else { throw StudioControllerValidation.invalid("The mapping file exceeds the size limit.") }
                let restored = try JSONDecoder().decode(StudioControllerMappingDocument.self, from: data)
                try restored.validate(); document = restored
            } catch { persistenceBlocked = true; message = "The mapping file was left unchanged: \(error.localizedDescription)" }
        }
        midi.receive = { [weak self] events in self?.receiveMIDI(events) }
        osc.receive = { [weak self] messages in self?.receiveOSC(messages) }
        osc.rejected = { [weak self] error in self?.message = error }
        // Input flags are machine-scoped and never imported with a project.
        midiEnabled = defaults.bool(forKey: "studio.controllers.midiEnabled") && sourceID != 0 && !persistenceBlocked
        oscEnabled = defaults.bool(forKey: "studio.controllers.oscEnabled") && !persistenceBlocked
    }
    func start() {
        guard timer == nil else { return }
        refreshEndpoints(); restartInputs()
        timer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled, let self else { return }
                self.tick()
            }
        }
    }
    func shutdown() {
        timer?.cancel(); timer = nil
        midi.stop(); osc.stop(); learningTarget = nil; learningKind = nil
        resetInputState(); midiStatus = "Disabled"; oscStatus = "Disabled"
    }
    func setMIDIEnabled(_ enabled: Bool) {
        guard !enabled || !persistenceBlocked else { return }
        guard !enabled || sourceID != 0 else { message = "Choose and apply a MIDI source before enabling input."; return }
        midiEnabled = enabled; defaults.set(enabled, forKey: "studio.controllers.midiEnabled")
        cancelLearning(); restartInputs()
    }
    func setOSCEnabled(_ enabled: Bool) {
        guard !enabled || !persistenceBlocked else { return }
        oscEnabled = enabled; defaults.set(enabled, forKey: "studio.controllers.oscEnabled")
        restartInputs()
    }
    func configureMIDI(source: Int32, destination: Int32, feedbackChannel: UInt8) {
        guard feedbackChannel < 16, destination == 0 || destination != source else { message = "Choose a separate MIDI feedback destination."; return }
        for mapping in document.mappings {
            if case .midi(let address) = mapping.input, destination != 0, address.channel == feedbackChannel {
                message = "MIDI feedback must use a channel without input mappings to prevent loops."; return
            }
        }
        sourceID = source; destinationID = destination; self.feedbackChannel = feedbackChannel
        defaults.set(source, forKey: "studio.controllers.midiSource"); defaults.set(destination, forKey: "studio.controllers.midiFeedback")
        defaults.set(Int(feedbackChannel), forKey: "studio.controllers.feedbackChannel")
        cancelLearning(); restartInputs()
    }
    func configureOSC(port: UInt16, feedbackPort: UInt16) {
        guard port != 0, feedbackPort == 0 || feedbackPort != port else { message = "Choose distinct OSC input and feedback ports from 1 to 65535."; return }
        oscPort = port; oscFeedbackPort = feedbackPort
        defaults.set(Int(port), forKey: "studio.controllers.oscPort"); defaults.set(Int(feedbackPort), forKey: "studio.controllers.oscFeedbackPort")
        restartInputs()
    }
    func learn(targetID: String, kind: StudioControllerTargetKind, inverted: Bool = false) {
        guard !persistenceBlocked, sourceID != 0 else { message = "Choose a MIDI source before learning."; return }
        guard targets().contains(where: { $0.id == targetID && $0.kind == kind }) else { message = "This stable target is unavailable."; return }
        learningTarget = targetID; learningKind = kind; learningInverted = inverted; message = "Move a CC fader or press a note on the selected source. Learning captures one input without running a command."
        resetInputState(); midi.start(sourceID: sourceID)
    }
    func cancelLearning() {
        learningTarget = nil; learningKind = nil
        if !midiEnabled { midi.stop() }
    }
    @discardableResult func add(_ mapping: StudioControllerMapping) -> Bool {
        guard !persistenceBlocked else { return false }
        if case .midi(let address) = mapping.input, destinationID != 0, address.channel == feedbackChannel {
            message = "This channel is reserved for MIDI feedback."; return false
        }
        var candidate = document; candidate.mappings.append(mapping)
        do { try candidate.validate(); try save(candidate); document = candidate; message = nil; resetInputState(); return true }
        catch { message = error.localizedDescription; return false }
    }
    func remove(_ id: UUID) {
        guard !persistenceBlocked else { return }
        var candidate = document; candidate.mappings.removeAll { $0.id == id }
        do { try save(candidate); document = candidate; restartInputs() }
        catch { message = error.localizedDescription }
    }
    private func save(_ candidate: StudioControllerMappingDocument) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(candidate).write(to: url, options: .atomic)
    }
    private func restartInputs() {
        resetInputState()
        var safeDestination = destinationID
        for mapping in document.mappings {
            if case .midi(let address) = mapping.input, address.channel == feedbackChannel { safeDestination = 0 }
        }
        if safeDestination != destinationID { message = "MIDI feedback is disabled because this project's inputs use its feedback channel." }
        activeFeedbackDestination = safeDestination
        if midiEnabled, sourceID != 0, !persistenceBlocked { midi.start(sourceID: sourceID, destinationID: safeDestination) } else { midi.stop() }
        if oscEnabled, oscPort != 0, !persistenceBlocked { osc.start(port: oscPort, feedbackPort: oscFeedbackPort) } else { osc.stop() }
        midiStatus = midi.status; oscStatus = osc.status
    }
    private func resetInputState() {
        held.removeAll(); values.removeAll(); feedbackValues.removeAll()
        if let ownedRun { cancelRun(ownedRun) }; ownedRun = nil
    }
    func refreshEndpoints() {
        let newSources = StudioMIDITransport.endpoints(), newDestinations = StudioMIDITransport.endpoints(destinations: true)
        if newDestinations != destinations { feedbackValues.removeAll() }
        sources = newSources; destinations = newDestinations
        if midi.refresh() { resetInputState() }
        var status = midi.status
        if learningTarget != nil { status = "Learning · \(status)" }
        if midiEnabled, destinationID != 0, learningTarget == nil {
            let selectedDestination = destinationID
            if activeFeedbackDestination == 0 { status += " · feedback disabled (channel conflict)" }
            else { status += newDestinations.contains(where: { $0.id == selectedDestination }) ? " · feedback connected" : " · feedback disconnected" }
        }
        if midiStatus != status { midiStatus = status }
    }
    func receiveMIDI(_ events: [StudioMIDIEvent]) {
        guard scopeIsCurrent(), !persistenceBlocked else { return }
        if let target = learningTarget, let kind = learningKind {
            for event in events where event.address.sourceID == sourceID && event.value > 0 {
                guard kind != .value || event.address.kind == .controlChange else { continue }
                _ = add(.init(input: .midi(event.address), targetID: target, kind: kind, inverted: learningInverted))
                cancelLearning(); if midiEnabled { restartInputs() }; return
            }
            return
        }
        guard midiEnabled else { return }
        for event in events {
            guard event.address.sourceID == sourceID else { continue }
            if let mapping = document.mappings.first(where: { $0.input == .midi(event.address) }) { receive(mapping, value: Double(event.value) / 127) }
        }
    }
    func receiveOSC(_ messages: [StudioOSC.Message]) {
        guard oscEnabled, scopeIsCurrent(), !persistenceBlocked else { return }
        for event in messages where !event.address.hasPrefix("/_stream/") {
            guard event.value >= 0, event.value <= 1 else { message = "OSC input values must be finite and normalized from 0 to 1."; return }
        }
        for event in messages {
            guard StudioOSC.validInputAddress(event.address) else { continue }
            if let mapping = document.mappings.first(where: { $0.input == .osc(event.address) }) { receive(mapping, value: event.value) }
        }
    }
    private func receive(_ mapping: StudioControllerMapping, value: Double) {
        if mapping.kind == .value {
            guard !interactionBlocked() else { return }
            values[mapping.id] = mapping.inverted ? 1 - value : value
        } else {
            if value == 0 { held.remove(mapping.id); return }
            // Press edges only; repeated note-on or held CC does not toggle twice.
            guard held.insert(mapping.id).inserted, !interactionBlocked() else { return }
            execute(mapping, normalized: nil)
        }
    }
    private func execute(_ mapping: StudioControllerMapping, normalized: Double?) {
        guard scopeIsCurrent(), !interactionBlocked() else { return }
        guard let target = targets().first(where: { $0.id == mapping.targetID && $0.kind == mapping.kind }) else { message = "The stable target \(mapping.targetID) no longer exists. Its mapping was retained."; return }
        if let error = target.unavailableReason { message = error; return }
        if let normalized, abs(target.normalizedValue - normalized) < 1.0 / 254 { return }
        let before = currentRunID()
        message = target.execute(normalized)
        if message == nil, let after = currentRunID(), after != before { ownedRun = after }
    }
    func tick() {
        guard scopeIsCurrent() else { shutdown(); return }
        let pending = values; values.removeAll()
        for mapping in document.mappings { if let value = pending[mapping.id] { execute(mapping, normalized: value) } }
        refreshCounter += 1
        if refreshCounter % 20 == 0 {
            refreshEndpoints(); osc.refresh()
            // UDP has no session handshake: periodically publish a complete
            // snapshot so a feedback application can reconnect independently.
            for mapping in document.mappings { if case .osc = mapping.input { feedbackValues.removeValue(forKey: mapping.id) } }
        }
        if oscStatus != osc.status { oscStatus = osc.status }
        guard midiEnabled || oscEnabled else { return }
        let catalogue = targets()
        for mapping in document.mappings {
            let target = catalogue.first(where: { $0.id == mapping.targetID && $0.kind == mapping.kind })
            var value = max(0, min(1, target?.normalizedValue ?? 0))
            if mapping.kind == .value && mapping.inverted { value = 1 - value }
            guard feedbackValues[mapping.id] != value else { continue }
            switch mapping.input {
            case .midi(let address):
                if midiEnabled, destinationID != 0, feedbackChannel != address.channel { midi.send(address: address, channel: feedbackChannel, value: UInt8((value * 127).rounded())) }
                feedbackValues[mapping.id] = value
            case .osc:
                if oscEnabled, oscFeedbackPort != 0, osc.send(address: mapping.feedbackAddress, value: value) { feedbackValues[mapping.id] = value }
            }
        }
    }
}
