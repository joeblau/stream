import Foundation

/// Allowlisted recovery facts: IDs, numeric edits/timing and local basenames.
/// No endpoints, headers, credentials, bookmarks, commands or raw scene payloads.
public struct SessionRecoveryLayer: Codable, Equatable, Sendable {
    public var id: UUID
    public var sourceID: UUID?
    public var x: Double, y: Double, width: Double, height: Double, rotation: Double
    public var anchor: String
    public var isVisible: Bool
    public init(id: UUID, sourceID: UUID?, x: Double, y: Double, width: Double, height: Double, rotation: Double, anchor: String, isVisible: Bool) {
        self.id = id; self.sourceID = sourceID; self.x = x; self.y = y; self.width = width; self.height = height
        self.rotation = rotation; self.anchor = anchor; self.isVisible = isVisible
    }
    public var isValid: Bool { [x, y, width, height, rotation].allSatisfy(\.isFinite) && width >= 0 && height >= 0 && ["topLeft", "topRight", "bottomLeft", "bottomRight", "center"].contains(anchor) }
}
public struct SessionRecoveryMedia: Codable, Equatable, Sendable {
    public var sourceID: UUID
    public var seconds: Double?
    public var page: Int?
    public init(sourceID: UUID, seconds: Double? = nil, page: Int? = nil) { self.sourceID = sourceID; self.seconds = seconds; self.page = page }
}
public struct SessionRecoveryMarker: Codable, Equatable, Sendable {
    public var id: UUID
    public var seconds: Double
    public init(id: UUID, seconds: Double) { self.id = id; self.seconds = seconds }
}
public struct SessionRecoverySegment: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case preparing, recording, paused, finishing, complete, recoverable, partial, unknown }
    public var sessionID: UUID
    public var index: Int
    public var file: String
    public var status: Status
    public var duration: Double
    public var markers: [SessionRecoveryMarker]
    public init(sessionID: UUID, index: Int, file: String, status: Status, duration: Double, markers: [SessionRecoveryMarker] = []) {
        self.sessionID = sessionID; self.index = index; self.file = file; self.status = status; self.duration = duration; self.markers = Array(markers.suffix(2_000))
    }
    public var isValid: Bool {
        index > 0 && file.utf8.count <= 255 && !file.isEmpty && ![".", ".."].contains(file)
        && !file.contains("/") && !file.contains("\\") && !file.contains("\0")
        && duration.isFinite && duration >= 0 && markers.count <= 2_000 && markers.allSatisfy { $0.seconds.isFinite && $0.seconds >= 0 }
    }
}
public struct SessionRecoveryRemoteEvent: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case unknown, ended, reconnectable }
    public var outputID: UUID
    public var eventID: String?
    public var state: State
    public init(outputID: UUID, eventID: String? = nil, state: State = .unknown) { self.outputID = outputID; self.eventID = eventID; self.state = state }
}
public struct SessionRecoverySnapshot: Codable, Equatable, Sendable, Identifiable {
    public var version = 1
    public var id: UUID
    public var updatedAt: Date
    public var projectID: UUID
    public var profileID: UUID
    public var programSceneID: UUID?
    public var stagedSceneID: UUID?
    public var stagedLayers: [SessionRecoveryLayer] = []
    public var hasStagedEdits = false
    public var activeOutputIDs: [UUID] = []
    public var remoteEvents: [SessionRecoveryRemoteEvent] = []
    public var recordings: [SessionRecoverySegment] = []
    public var media: [SessionRecoveryMedia] = []
    public var cleanExit = false
    public var reviewDismissed = false
    public var recordingInventoryVerified = false
    public var recordingWasActive = false
    public init(id: UUID = UUID(), projectID: UUID, profileID: UUID, updatedAt: Date = Date()) {
        self.id = id; self.projectID = projectID; self.profileID = profileID; self.updatedAt = updatedAt
    }
    public var needsReview: Bool { !reviewDismissed && (!cleanExit || hasStagedEdits || recordings.contains { $0.status != .complete }) }
    public var validationError: String? {
        guard version == 1 else { return "Unsupported recovery journal version." }
        guard recordings.reduce(0, { $0 + $1.markers.count }) <= 4_000 && stagedLayers.count <= 2_000 && media.count <= 2_000 && activeOutputIDs.count <= 10 && remoteEvents.count <= 10 && recordings.count <= 200 else { return "Recovery journal exceeds its bounded inventory." }
        guard Set(stagedLayers.map(\.id)).count == stagedLayers.count,
              Set(media.map(\.sourceID)).count == media.count,
              Set(activeOutputIDs).count == activeOutputIDs.count,
              Set(remoteEvents.map(\.outputID)).count == remoteEvents.count else { return "Recovery journal contains duplicate stable IDs." }
        guard stagedLayers.allSatisfy(\.isValid), recordings.allSatisfy(\.isValid), media.allSatisfy({ ($0.seconds.map { $0.isFinite && $0 >= 0 } ?? true) && ($0.page.map { $0 >= 0 } ?? true) }) else { return "Recovery journal contains invalid timing, geometry or local file references." }
        guard remoteEvents.allSatisfy({ item in
            guard let id = item.eventID else { return item.state == .unknown }
            return !id.isEmpty && id.utf8.count <= 200 && id.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "_-".unicodeScalars.contains($0) }
        }) else { return "Remote event identifiers must be verified provider IDs, never URLs or credentials." }
        return nil
    }
}

/// A recovery seek holds autoplay even when loading finishes later. Play is a
/// fresh operator intent; restart also discards the recovered seek position.
public struct PausedMediaRecovery: Sendable {
    public private(set) var isHeld = false
    private var position: Double?
    public init() {}
    public mutating func restore(seconds: Double) {
        guard seconds.isFinite, seconds >= 0 else { return }
        isHeld = true; position = seconds
    }
    public mutating func consumePosition() -> Double? { let value = position; position = nil; return value }
    public mutating func playIntent() { isHeld = false }
    public mutating func restartIntent() { isHeld = false; position = nil }
    public func shouldPlay(autoplay: Bool, requested: Bool) -> Bool { !isHeld && (autoplay || requested) }
}
