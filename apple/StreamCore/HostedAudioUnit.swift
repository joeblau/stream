import AVFAudio
import AudioToolbox
import Foundation

/// A11 (issue #123): a persisted reference to one installed Audio Unit effect
/// component — the `AudioComponentDescription` triple (type/subtype/
/// manufacturer) plus a display-name snapshot. The triple is what a chain
/// stores and what instantiation uses; the name snapshot lets the FX rack
/// show an HONEST placeholder ("Plugin not installed") when the component is
/// no longer registered on this Mac, instead of an anonymous dead slot.
///
/// Only `kAudioUnitType_Effect` ('aufx') components are hosted — generators
/// and instruments have no input bus to sit on a channel insert.
public struct AudioUnitComponentID: Hashable, Codable, Sendable {
    /// `AudioComponentDescription.componentType` ('aufx').
    public var componentType: UInt32
    /// `AudioComponentDescription.componentSubType` (e.g. 'dely').
    public var componentSubType: UInt32
    /// `AudioComponentDescription.componentManufacturer`.
    public var manufacturer: UInt32
    /// Display name captured at add time (the component's
    /// "Manufacturer: Name" string), for the placeholder state.
    public var displayName: String

    public init(componentType: UInt32, componentSubType: UInt32,
                manufacturer: UInt32, displayName: String) {
        self.componentType = componentType
        self.componentSubType = componentSubType
        self.manufacturer = manufacturer
        self.displayName = displayName
    }

    public init(description: AudioComponentDescription, displayName: String) {
        self.init(componentType: description.componentType,
                  componentSubType: description.componentSubType,
                  manufacturer: description.componentManufacturer,
                  displayName: displayName)
    }

    /// The description used to instantiate the component
    /// (`AVAudioUnitEffect(audioComponentDescription:)`).
    public var componentDescription: AudioComponentDescription {
        AudioComponentDescription(componentType: componentType,
                                  componentSubType: componentSubType,
                                  componentManufacturer: manufacturer,
                                  componentFlags: 0,
                                  componentFlagsMask: 0)
    }

    /// True when a component with this exact triple is registered with the
    /// system right now. Checked before instantiation so a missing plugin
    /// never reaches the (non-failable) `AVAudioUnitEffect` initializer —
    /// the slot renders as a bypassed placeholder and the chain still runs.
    public var isAvailable: Bool {
        var description = componentDescription
        return AudioComponentFindNext(nil, &description) != nil
    }
}

/// A11 (issue #123): one hosted Audio Unit in a channel's effect chain —
/// ordered (array position = signal position, between the compressor and the
/// limiter), individually bypassable, persisted by component identity plus a
/// best-effort state blob.
///
/// **What is persisted:** the component triple + name (`component`), the
/// bypass flag, and `state` — the AU's `fullState` property list (for v2
/// components AVFAudio synthesizes it from `classData`; for v3 it is the
/// extension's own document) encoded as a BINARY property list. State is
/// captured when the parameter editor closes — parameter edits are live the
/// moment they are made, but only become part of the persisted chain at that
/// point (documented in the rack UI). A plugin whose state is not
/// property-list-safe simply persists no blob and reopens at defaults.
public struct HostedAudioUnitSlot: Hashable, Codable, Sendable, Identifiable {
    /// Slots per channel, capped: every hosted unit is one more node on the
    /// capture thread's offline render, and 4 covers every realistic
    /// voice-processing rack (the Ecamm inspiration exposes 2).
    public static let maxSlotsPerChannel = 4
    /// State blobs above this size are rejected by chain validation — a
    /// runaway plugin must not bloat the settings document.
    public static let maxStateBytes = 1_048_576

    public var id: UUID
    public var component: AudioUnitComponentID
    public var isEnabled: Bool
    /// Binary-plist-encoded `AUAudioUnit.fullState`, or nil.
    public var state: Data?

    public init(id: UUID = UUID(), component: AudioUnitComponentID,
                isEnabled: Bool = true, state: Data? = nil) {
        self.id = id
        self.component = component
        self.isEnabled = isEnabled
        self.state = state
    }

    /// Encodes an AU's `fullState` dictionary as a binary property list;
    /// nil when the AU published no state or the state is not plist-safe
    /// (then nothing is persisted — the slot reopens at plugin defaults).
    public static func encodeState(_ fullState: [String: Any]?) -> Data? {
        guard let fullState, PropertyListSerialization.propertyList(
            fullState, isValidFor: .binary) else { return nil }
        return try? PropertyListSerialization.data(
            fromPropertyList: fullState, format: .binary, options: 0)
    }

    /// Decodes a persisted state blob back into a `fullState` dictionary.
    /// Corrupt/foreign blobs decode to nil — the plugin then opens at its
    /// own defaults (never a crash, never a failed chain).
    public static func decodeState(_ data: Data?) -> [String: Any]? {
        guard let data else { return nil }
        return try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil) as? [String: Any]
    }
}

/// A11 (issue #123): the UI-facing handle to a hosted unit RUNNING inside a
/// channel's offline-render graph. The unit lives on the capture thread, but
/// `AUAudioUnit`'s parameter tree and `fullState` are explicitly thread-safe
/// entry points — the same in-place write path A08 uses for the native
/// sections — so the rack's generic parameter editor binds straight to it.
/// `@unchecked Sendable` is sound on exactly those two entry points; nothing
/// else on the object is touched off the audio graph.
public final class HostedAudioUnitHandle: @unchecked Sendable {
    /// The slot this unit was instantiated for.
    public let slotID: UUID
    /// The live unit (parameter tree + fullState are the thread-safe surface).
    public let audioUnit: AUAudioUnit
    /// The plugin's reported processing latency in seconds, read at build
    /// time. NOT compensated (the offline render preserves frame counts, so
    /// a latent plugin shifts content by this amount); surfaced in the rack
    /// so the user can counter it with the A10 channel delay if it matters.
    public let latencySeconds: Double

    public init(slotID: UUID, audioUnit: AUAudioUnit, latencySeconds: Double) {
        self.slotID = slotID
        self.audioUnit = audioUnit
        self.latencySeconds = latencySeconds
    }
}
