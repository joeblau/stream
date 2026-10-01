import Foundation

/// Pre-apply validation for settings edits (W04, issue #67).
///
/// Pure functions over `StreamSettings`, so the embedded settings area can
/// show inline errors next to a field and block saving INVALID values before
/// they are ever persisted or applied. "Invalid" means MALFORMED — a URL that
/// will not parse, a scheme the selected protocol cannot speak, an
/// out-of-range port, a whitespace-only key. An EMPTY URL or key is not
/// invalid, merely incomplete: `StreamSettings.isPublishable` already guards
/// Go Live for that, and blocking Apply on incompleteness would stop users
/// saving unrelated (video/audio) edits before their destination is set up.
public enum SettingsValidator {

    /// Inline error for the server URL field, or nil when acceptable. Empty
    /// is acceptable here (incomplete, not invalid — see the type docs).
    public static func serverURLError(_ urlString: String,
                                      for proto: StreamProtocol) -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        // URLComponents is stricter than URL: a non-numeric port fails the
        // whole parse instead of being silently dropped.
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty else {
            return "Enter a valid URL like \(proto.urlPlaceholder)."
        }
        guard proto.urlSchemes.contains(scheme) else {
            return "\(proto.displayName) URLs start with \(proto.urlSchemes.joined(separator: ":// or "))://."
        }
        if let port = components.port, !(1...65_535).contains(port) {
            return "The port must be between 1 and 65535."
        }
        return nil
    }

    /// Inline error for the stream-key field, or nil when acceptable. Empty is
    /// acceptable (incomplete); whitespace-only is invalid because it LOOKS
    /// filled but publishes nothing. SRT/WHIP embed credentials in the URL, so
    /// their optional key field is never invalid.
    public static func streamKeyError(_ key: String,
                                      for proto: StreamProtocol) -> String? {
        guard proto.requiresKey else { return nil }
        guard !key.isEmpty, key.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return "The stream key is only whitespace."
    }

    /// Every error that must block Apply for this snapshot (empty = safe to
    /// apply). Completeness (missing URL/key) is deliberately NOT blocking —
    /// it is surfaced in the connection section footer and at Go Live.
    public static func blockingErrors(for settings: StreamSettings) -> [String] {
        [serverURLError(settings.rtmpURL, for: settings.selectedProtocol),
         streamKeyError(settings.streamKey, for: settings.selectedProtocol)]
            .compactMap { $0 }
    }
}
