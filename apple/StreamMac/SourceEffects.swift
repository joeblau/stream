import Foundation
import os.lock
import StreamCore

// MARK: - E01 (issue #101): per-source framing and picture adjustment effects
//
// One `SourceEffects` value describes the full effect stack for a rendered
// source: FRAMING (digital zoom/pan, mirror, rotation — they reshape the
// source image before placement), PICTURE ADJUSTMENTS (brightness,
// contrast, saturation, temperature, tint, gamma — color-only, applied after
// placement through the renderer's existing Core Image path), and E03's
// (issue #164) BACKGROUND effect (person-segmentation blur/replacement,
// recompositing the source before framing; camera layers only).
//
// Scope is deliberately two-level, matching the issue's "source defaults
// versus layer overrides":
// - SOURCE DEFAULTS live on the project registry's `SourceDefinition`
//   (`effectDefaults`): project-level, apply immediately to every layer bound
//   to the source in BOTH the staged and program compositions (the S07
//   overlay-edit precedent), and publish to the engines per tick through
//   `SourceEffectsStore`.
// - LAYER OVERRIDES live on `LayerNode` (`effectOverrides`): staged scene
//   content — they stage, Take, revert, and undo exactly like the layer's
//   transform/effects, and reach program only through Take (or direct-live).
// Resolution is override-wins: a layer with an override ignores the source
// defaults entirely (the override is a complete `SourceEffects` value), a
// layer without one renders the source defaults, and an unbound/unconfigured
// layer renders the identity.
//
// `isBypassed` renders the source untouched WITHOUT losing the configured
// values (the A08 per-section bypass precedent): bypass is part of the value,
// so it stages/Takes with everything else.

/// The full framing + picture-adjustment stack for one rendered source.
/// Value semantics, additive wire format (every field decodes with its
/// default, so documents/presets written before a field existed keep
/// loading). `.identity` renders the source untouched.
struct SourceEffects: Hashable, Codable, Sendable {
    // Framing — reshape the source image before placement.
    /// Digital zoom factor, 1...4. The crop is the source shrunk by this
    /// factor, re-fitted to the layer rect by the normal placement path.
    var zoom: Double = 1
    /// Pan within the zoomed crop, -1...1 as a fraction of the available
    /// slack (0 = centered; ±1 = crop pinned to that edge). No-op at zoom 1.
    var panX: Double = 0
    var panY: Double = 0
    /// Horizontal flip (selfie-mirror a screen share, unmirror a camera).
    var isMirrored: Bool = false
    /// Source content rotation in degrees (clockwise in top-left semantics,
    /// like `LayerTransform.rotationDegrees`; 90° steps re-point a sideways
    /// camera). The rotated extent is what placement fits into the rect.
    var rotationDegrees: Double = 0

    // Picture adjustments — color-only, applied after placement.
    /// -0.5...0.5 (CIColorControls inputBrightness).
    var brightness: Double = 0
    /// 0.5...2 (CIColorControls inputContrast; 1 = unchanged).
    var contrast: Double = 1
    /// 0...2 (CIColorControls inputSaturation; 1 = unchanged, 0 = grayscale).
    var saturation: Double = 1
    /// White-balance target temperature in Kelvin, 3000...9000
    /// (CITemperatureAndTint; `neutralTemperature` = unchanged).
    var temperature: Double = SourceEffects.neutralTemperature
    /// White-balance target tint, -100...100 (CITemperatureAndTint; 0 =
    /// unchanged; negative = greener, positive = more magenta).
    var tint: Double = 0
    /// 0.5...2 (CIGammaAdjust inputPower; 1 = unchanged).
    var gamma: Double = 1

    /// E03 (issue #164): the person-segmentation background effect (off /
    /// blur / replacement). Applies to camera layers only; capability-gated
    /// and budget-governed downstream, and a passthrough fallback renders the
    /// source untouched whenever segmentation can't produce a mask.
    var background: BackgroundEffectSettings = BackgroundEffectSettings()

    var chromaKey = ChromaKeySettings()
    var lut = LUTSettings()

    /// Skip the whole stack without losing the configured values.
    var isBypassed: Bool = false

    init() {}

    /// The value CITemperatureAndTint treats as neutral (no white-balance
    /// shift).
    static let neutralTemperature = 6500.0

    /// The untouched-source value.
    static let identity = SourceEffects()

    /// Additive wire format: every field decodes with its default so older
    /// documents and presets keep loading (the established LayerGraph
    /// pattern).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        zoom = try container.decodeIfPresent(Double.self, forKey: .zoom) ?? 1
        panX = try container.decodeIfPresent(Double.self, forKey: .panX) ?? 0
        panY = try container.decodeIfPresent(Double.self, forKey: .panY) ?? 0
        isMirrored = try container.decodeIfPresent(Bool.self, forKey: .isMirrored) ?? false
        rotationDegrees = try container.decodeIfPresent(Double.self, forKey: .rotationDegrees) ?? 0
        brightness = try container.decodeIfPresent(Double.self, forKey: .brightness) ?? 0
        contrast = try container.decodeIfPresent(Double.self, forKey: .contrast) ?? 1
        saturation = try container.decodeIfPresent(Double.self, forKey: .saturation) ?? 1
        temperature = try container.decodeIfPresent(Double.self, forKey: .temperature)
            ?? SourceEffects.neutralTemperature
        tint = try container.decodeIfPresent(Double.self, forKey: .tint) ?? 0
        gamma = try container.decodeIfPresent(Double.self, forKey: .gamma) ?? 1
        background = try container.decodeIfPresent(BackgroundEffectSettings.self, forKey: .background)
            ?? BackgroundEffectSettings()
        chromaKey = try container.decodeIfPresent(ChromaKeySettings.self, forKey: .chromaKey) ?? ChromaKeySettings()
        lut = try container.decodeIfPresent(LUTSettings.self, forKey: .lut) ?? LUTSettings()
        isBypassed = try container.decodeIfPresent(Bool.self, forKey: .isBypassed) ?? false
    }

    /// True when any framing field deviates from identity. Bypass does not
    /// clear this — the configuration is still there, just skipped.
    var hasFraming: Bool {
        zoom != 1 || panX != 0 || panY != 0 || isMirrored || rotationDegrees != 0
    }

    /// True when any picture adjustment deviates from identity.
    var hasPictureAdjustments: Bool {
        brightness != 0 || contrast != 1 || saturation != 1
            || temperature != SourceEffects.neutralTemperature || tint != 0 || gamma != 1
    }

    /// True when the background effect is configured (mode ≠ off).
    var hasBackgroundEffect: Bool {
        background.isEnabled
    }

    /// True when rendering this value costs nothing (identity or bypassed).
    var isRenderNoOp: Bool {
        isBypassed || (!hasFraming && !hasPictureAdjustments && !hasBackgroundEffect && !(chromaKey.isEnabled && !chromaKey.isBypassed) && !lut.isEnabled)
    }

    /// The value with every field clamped to its documented range (the
    /// dispatcher rejects out-of-range input via `validationError`; the UI
    /// clamps its sliders to the same ranges).
    func clamped() -> SourceEffects {
        var copy = self
        copy.zoom = min(4, max(1, zoom))
        copy.panX = min(1, max(-1, panX))
        copy.panY = min(1, max(-1, panY))
        copy.brightness = min(0.5, max(-0.5, brightness))
        copy.contrast = min(2, max(0.5, contrast))
        copy.saturation = min(2, max(0, saturation))
        copy.temperature = min(9000, max(3000, temperature))
        copy.tint = min(100, max(-100, tint))
        copy.gamma = min(2, max(0.5, gamma))
        copy.background = background.clamped()
        return copy
    }

    /// The rejection reason for an out-of-range value, or nil (guards
    /// automation input, like `ChannelFXChain.validationError`).
    var validationError: String? {
        func finite(_ value: Double, _ name: String) -> String? {
            value.isFinite ? nil : "\(name) must be a finite number."
        }
        if let error = finite(zoom, "Zoom") ?? finite(panX, "Pan X") ?? finite(panY, "Pan Y")
            ?? finite(rotationDegrees, "Rotation") ?? finite(brightness, "Brightness")
            ?? finite(contrast, "Contrast") ?? finite(saturation, "Saturation")
            ?? finite(temperature, "Temperature") ?? finite(tint, "Tint")
            ?? finite(gamma, "Gamma") {
            return error
        }
        if !(1...4).contains(zoom) { return "Zoom must be between 1 and 4." }
        if !(-1...1).contains(panX) || !(-1...1).contains(panY) {
            return "Pan must be between -1 and 1."
        }
        if !(-0.5...0.5).contains(brightness) { return "Brightness must be between -0.5 and 0.5." }
        if !(0.5...2).contains(contrast) { return "Contrast must be between 0.5 and 2." }
        if !(0...2).contains(saturation) { return "Saturation must be between 0 and 2." }
        if !(3000...9000).contains(temperature) {
            return "Temperature must be between 3000 and 9000 K."
        }
        if !(-100...100).contains(tint) { return "Tint must be between -100 and 100." }
        if !(0.5...2).contains(gamma) { return "Gamma must be between 0.5 and 2." }
        if let error = background.validationError ?? chromaKey.validationError ?? lut.validationError { return error }
        return nil
    }
}

extension LayerNode {
    /// E01 (issue #101): the effects this layer renders with — its own
    /// OVERRIDE when set (a complete value: overrides replace, not merge),
    /// else the bound registry source's defaults from `sourceDefaults`, else
    /// nil (identity). The bypass flag is part of the returned value.
    func effectiveSourceEffects(defaults: [SourceDefinitionID: SourceEffects]) -> SourceEffects? {
        effectOverrides ?? sourceID.flatMap { defaults[$0] }
    }
}

// MARK: - Reusable presets

/// E01 (issue #101): a named, reusable `SourceEffects` value. Presets are
/// PROJECT-level (persisted once in the scene document, like overlays) and
/// hold a complete effect stack: applying one writes its value as a layer's
/// override or a source's defaults, so later preset edits never re-point
/// existing users.
struct SourceEffectPreset: Identifiable, Hashable, Codable, Sendable {
    var id: EffectPresetID
    var name: String
    var effects: SourceEffects

    init(id: EffectPresetID = EffectPresetID(), name: String, effects: SourceEffects) {
        self.id = id
        self.name = name
        self.effects = effects
    }
}

// MARK: - Engine hand-off

/// The process-wide hand-off of per-source effect DEFAULTS from `SceneStore`
/// (main actor, publishes on every mutation) to every `CompositionEngine`'s
/// renderer (reads per layer per frame). Same lock-protected value-snapshot
/// pattern as `SourcePayloadStore`: source defaults are project-level and
/// apply immediately to staged AND program compositions, so a mid-tick edit
/// can never tear a frame. Layer OVERRIDES never pass through here — they are
/// staged scene content and ride the scene snapshot the engine already holds.
final class SourceEffectsStore: @unchecked Sendable {
    static let shared = SourceEffectsStore()

    private var lock = os_unfair_lock_s()
    private var effects: [SourceDefinitionID: SourceEffects] = [:]

    /// Publishes the registry's non-identity source defaults (nil defaults
    /// drop out of the index entirely — absence IS identity).
    func publish(_ sources: [SourceDefinition]) {
        var index: [SourceDefinitionID: SourceEffects] = [:]
        for source in sources {
            if let defaults = source.effectDefaults {
                index[source.id] = defaults
            }
        }
        os_unfair_lock_lock(&lock)
        self.effects = index
        os_unfair_lock_unlock(&lock)
    }

    func snapshot() -> [SourceDefinitionID: SourceEffects] {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return effects
    }
}
