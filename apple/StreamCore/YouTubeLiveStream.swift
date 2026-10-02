import Foundation

/// Deliberately excludes cdn.ingestionInfo and closed-caption URLs. Credentials
/// may pass through the existing private ingest importer, never this metadata.
public struct YouTubeLiveStream: Equatable, Sendable, Identifiable {
    public enum State: String, Sendable { case unknown, created, ready, inactive, active, error }
    public var id: String
    public var channelID: String?
    public var title: String
    public var state: State
    public var ingestionType: String?
    public var resolution: String?
    public var frameRate: String?
    public var reusable: Bool?
    public var verifiedAt: Date
    public init(id: String, channelID: String? = nil, title: String, state: State = .unknown,
                ingestionType: String? = nil, resolution: String? = nil, frameRate: String? = nil,
                reusable: Bool? = nil, verifiedAt: Date = Date()) {
        self.id = id; self.channelID = channelID; self.title = String(title.prefix(128)); self.state = state
        self.ingestionType = ingestionType; self.resolution = resolution; self.frameRate = frameRate
        self.reusable = reusable; self.verifiedAt = verifiedAt
    }
}

public struct YouTubeStreamDraft: Equatable, Sendable {
    public enum Resolution: String, CaseIterable, Sendable {
        case variable, p240 = "240p", p360 = "360p", p480 = "480p", p720 = "720p"
        case p1080 = "1080p", p1440 = "1440p", p2160 = "2160p"
    }
    public enum FrameRate: String, CaseIterable, Sendable { case variable, fps30 = "30fps", fps60 = "60fps" }
    public var title: String
    public var resolution: Resolution
    public var frameRate: FrameRate
    public var reusable: Bool
    public init(title: String = "", resolution: Resolution = .variable, frameRate: FrameRate = .variable, reusable: Bool = false) {
        self.title = title; self.resolution = resolution; self.frameRate = frameRate; self.reusable = reusable
    }
    public func validate() throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 128,
              title.utf8.count <= 1024, (resolution == .variable) == (frameRate == .variable) else {
            throw ProviderFailure(.invalidRequest)
        }
    }
}

public struct YouTubeBindingReview: Equatable, Sendable {
    public let event: ProviderEvent
    public let stream: YouTubeLiveStream
    public init(event: ProviderEvent, stream: YouTubeLiveStream) { self.event = event; self.stream = stream }
    public var replacesExisting: Bool { event.boundStreamID != nil && event.boundStreamID != stream.id }
}
