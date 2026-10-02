import Foundation

/// Prototype-only public commands for the separately identified, shared audio helper.
/// Widget URLs/HTML stay in the private IPC pipe; responses contain no page content.
struct BrowserWidgetAudioCommand: Codable, Sendable {
    enum Action: String, Codable, Sendable { case load, reload, suspend, resume, stop, probe, close, snapshot, interact, evaluate }
    var action: Action
    var widgetID: UUID?
    var html: String?
    var url: URL?
    var options: BrowserWidgetPageOptions?
    var requestID: UUID?
    var generation: UUID?
    var interaction: BrowserWidgetInteraction?
    var expression: String?

    static let maximumLineBytes = 96 * 1_024
    static let maximumWidgets = 8

    func validate() throws {
        if action == .close {
            guard widgetID == nil, html == nil, url == nil, options == nil, interaction == nil, expression == nil else { throw CommandError.invalidContent }
            return
        }
        guard widgetID != nil else { throw CommandError.invalidWidget }
        if action == .interact {
            guard let interaction, html == nil, url == nil, options == nil, expression == nil else { throw CommandError.invalidContent }
            try interaction.validate(); return
        }
        if action == .evaluate {
            guard let expression, expression.utf8.count <= 8_192, requestID != nil,
                  html == nil, url == nil, options == nil, interaction == nil else { throw CommandError.invalidContent }
            return
        }
        guard interaction == nil, expression == nil else { throw CommandError.invalidContent }
        guard action == .load else {
            guard html == nil, url == nil, options == nil else { throw CommandError.invalidContent }
            if action == .snapshot, requestID == nil || generation == nil { throw CommandError.invalidContent }
            return
        }
        try options?.validate()
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
    enum State: String, Codable, Sendable { case ready, loaded, suspended, stopped, probe, failed, evaluated }
    var state: State
    var widgetID: UUID?
    var mediaState: String?
    /// Fixed categories only, never URL/content/framework error descriptions.
    var failure: String?
    var helperPID: Int32
    var requestID: UUID?
    /// Explicit trigger responses only; never persisted or used as diagnostic text.
    var result: String?
    var generation: UUID?
}

enum BrowserWidgetAudioIdentity {
    static let helperBundleID = "com.joeblau.StreamBrowserAudioHelper"
    /// Application audio is shared by all pages owned by this helper. No per-widget tap is claimed.
    static let channelTitle = "Browser Widgets (shared helper)"
    /// Remains false until a shipped signed helper, product lifecycle, and all buses are qualified.
    static let productionRouteQualified = false
}
