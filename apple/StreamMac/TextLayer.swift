import Foundation
import StreamCore
import os.lock

// MARK: - G02 (issue #110): text layers — presets and the live token store
//
// The StreamMac-side companions to StreamCore's `TextLayout.swift` (the
// testable value model): the project-level named title-style presets and the
// process-wide hand-off of live `{host}`/`{guest}` token values into the
// render engines.
//
// INTEGRATION SEAMS left for follow-up work:
// - GUEST WORKSTREAM (guest sessions, the inspector's Guests tab):
//   `TitleTokenStore.shared.publish(_:)` is the write path for automatic
//   host/guest names — publish token keys (`host`, `guest`, `guest1`…`guest8`)
//   to display names whenever the session roster changes; every text layer
//   carrying `{token}` templates re-resolves on the next tick. Until a
//   publisher exists the tokens render literally (the documented honest
//   preview).
// - G04 (countdown/clock, issue #111) and G05 (ticker): both are dynamic
//   TEXT on top of `TextSourcePayload`, not new layer kinds — a per-tick
//   text provider keyed by playback ID (this store's pattern) feeds the
//   resolved string, and the renderer's content-keyed raster cache already
//   re-renders only when the string changes. Timed/fly-in visibility and
//   the fixed/auto box semantics come free from the G02 render path.

/// G02 (issue #110): a named, reusable `TextTitleStyle` value. Presets are
/// PROJECT-level (persisted once in the scene document, the E01
/// `SourceEffectPreset` / G03 `LayerStylePreset` precedent) and hold a
/// complete style: applying one WRITES its value onto the layer's payload,
/// so later preset edits never re-point existing users.
enum TextStylePresetTag {}
typealias TextStylePresetID = GraphID<TextStylePresetTag>

struct TextStylePreset: Identifiable, Hashable, Codable, Sendable {
    var id: TextStylePresetID
    var name: String
    var style: TextTitleStyle

    init(id: TextStylePresetID = TextStylePresetID(), name: String, style: TextTitleStyle) {
        self.id = id
        self.name = name
        self.style = style
    }
}

/// The process-wide hand-off of live title-token values (host/guest display
/// names) from whoever publishes them (main actor, on roster changes) to
/// every `SceneRenderer` (engine actor, reads per tick) — the
/// `ProjectOverlayStore` / `SourceEffectsStore` pattern: lock-protected value
/// snapshots, so a mid-tick publish can never tear a frame. Keys are token
/// names WITHOUT braces, lowercased (`host`, `guest`, `guest1`…`guest8`).
final class TitleTokenStore: @unchecked Sendable {
    static let shared = TitleTokenStore()

    private var lock = os_unfair_lock_s()
    private var names: [String: String] = [:]

    /// Replaces the whole token context (nil/empty values clear their token,
    /// which renders the token literally again — the honest fallback).
    func publish(_ names: [String: String]) {
        let normalized = Dictionary(uniqueKeysWithValues: names.map {
            ($0.key.lowercased(), $0.value)
        })
        os_unfair_lock_lock(&lock)
        self.names = normalized
        os_unfair_lock_unlock(&lock)
    }

    /// Convenience for the common case: one host name and an ordered guest
    /// roster. `guests[0]` publishes both `guest` and `guest1`.
    func publish(host: String?, guests: [String]) {
        var names: [String: String] = [:]
        if let host, !host.isEmpty {
            names[TitleTemplate.hostToken] = host
        }
        for (index, guest) in guests.enumerated() where !guest.isEmpty {
            names["guest\(index + 1)"] = guest
            if index == 0 { names[TitleTemplate.guestToken] = guest }
        }
        publish(names)
    }

    func snapshot() -> [String: String] {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return names
    }
}
