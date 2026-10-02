import Foundation

/// Prototype-only public commands for the separately identified, shared audio helper.
/// Widget URLs/HTML stay in the private IPC pipe; responses contain no page content.
struct BrowserWidgetAudioCommand: Codable, Sendable {
    enum Action: String, Codable, Sendable { case load, reload, suspend, resume, stop, probe, close }
    var action: Action
    var widgetID: UUID?
    var html: String?
    var url: URL?

    static let maximumLineBytes = 96 * 1_024
    static let maximumWidgets = 8

    func validate() throws {
        if action == .close { return }
        guard widgetID != nil else { throw CommandError.invalidWidget }
        guard action == .load else {
            guard html == nil, url == nil else { throw CommandError.invalidContent }
            return
        }
        guard (html == nil) != (url == nil) else { throw CommandError.invalidContent }
        if let html, html.utf8.count > 64 * 1_024 { throw CommandError.contentTooLarge }
        if let url {
            guard url.absoluteString.utf8.count <= 8 * 1_024,
                  url.scheme?.lowercased() == "https", url.host != nil,
                  url.user == nil, url.password == nil else { throw CommandError.invalidContent }
        }
    }
    func encodedLine() throws -> Data {
        try validate()
        var bytes = try JSONEncoder().encode(self); bytes.append(10)
        guard bytes.count <= Self.maximumLineBytes else { throw CommandError.contentTooLarge }
        return bytes
    }

    enum CommandError: Error { case invalidWidget, invalidContent, contentTooLarge }
}

struct BrowserWidgetAudioReply: Codable, Sendable {
    enum State: String, Codable, Sendable { case ready, loaded, suspended, stopped, probe, failed }
    var state: State
    var widgetID: UUID?
    var mediaState: String?
    /// Fixed categories only, never URL/content/framework error descriptions.
    var failure: String?
    var helperPID: Int32
}

enum BrowserWidgetAudioIdentity {
    static let helperBundleID = "com.joeblau.StreamBrowserAudioHelper"
    /// Application audio is shared by all pages owned by this helper. No per-widget tap is claimed.
    static let channelTitle = "Browser Widgets (shared helper)"
    /// Remains false until a shipped signed helper, product lifecycle, and all buses are qualified.
    static let productionRouteQualified = false
}
