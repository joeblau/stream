import Foundation

/// Per-output session lifecycles (W02, issue #62). Streaming, recording, and
/// preview each own an independent state machine, so one output stopping or
/// failing never tears down another. The controllers fold real signals into
/// these states — publisher `PublisherEvent`s for streaming, writer completion
/// for recording — never optimistic UI flags.

/// Lifecycle of the publishing (Go Live) output.
enum StreamSessionState: Equatable {
    /// No session; the Go Live button is armed.
    case idle
    /// A connect/publish attempt is in flight and not yet acknowledged.
    case connecting
    /// The ingest acknowledged the publish; media is flowing. ONLY here may the
    /// UI show LIVE.
    case live
    /// The acknowledged connection dropped or stalled; the publisher's
    /// supervised reconnect is running (the user still owns the session).
    case reconnecting(reason: String)
    /// The user asked to stop; the publisher is tearing down.
    case stopping
    /// Setup or a non-recoverable error ended the session; retry starts fresh.
    case failed(String)

    /// True only on an acknowledged publishing connection.
    var isLive: Bool { self == .live }

    /// The session owns a publisher (any in-flight state); the render pipeline
    /// must keep feeding it even if the preview is off.
    var isActive: Bool {
        switch self {
        case .idle, .failed: return false
        case .connecting, .live, .reconnecting, .stopping: return true
        }
    }

    /// A new Go Live may start from here.
    var canStart: Bool {
        switch self {
        case .idle, .failed: return true
        case .connecting, .live, .reconnecting, .stopping: return false
        }
    }
}

/// Lifecycle of the local recording output.
enum RecordingSessionState: Equatable {
    case idle
    /// The writer is open and receiving composited frames.
    case recording
    /// Stop requested; the writer is finishing the .mp4.
    case stopping
    /// Start or finish failed (disk space, writer error); retry starts fresh.
    case failed(String)

    var isRecording: Bool { self == .recording }

    /// An output the window-close policy must confirm before teardown.
    var isActive: Bool {
        switch self {
        case .idle, .failed: return false
        case .recording, .stopping: return true
        }
    }
}

/// Lifecycle of the on-screen presentation (preview) output. Independent from
/// streaming/recording: stopping preview never ends an active output, and an
/// active output keeps the render pipeline alive with the preview off.
enum PreviewSessionState: Equatable {
    case idle
    case active
}
