import Foundation

public struct ChromaKeySettings: Hashable, Codable, Sendable {
    public var isEnabled = false
    public var isBypassed = false
    public var keyColorHex = "#00FF00"
    public var tolerance = 0.12
    public var softness = 0.10
    public var spill = 0.5
    /// Normalized source-space garbage mask, top-left coordinates.
    public var left = 0.0
    public var right = 0.0
    public var top = 0.0
    public var bottom = 0.0
    public var maskFeather = 0.0
    public init() {}
    public var validationError: String? {
        guard keyColorHex.count == 7, keyColorHex.first == "#",
              UInt32(keyColorHex.dropFirst(), radix: 16) != nil else { return "Key color must be #RRGGBB." }
        guard [tolerance,softness,spill,left,right,top,bottom,maskFeather].allSatisfy(\.isFinite) else {
            return "Chroma key controls must be finite numbers."
        }
        guard (0...1).contains(tolerance), (0.001...1).contains(softness), (0...1).contains(spill) else {
            return "Tolerance/spill must be 0–1 and softness 0.001–1."
        }
        guard [left,right,top,bottom].allSatisfy({ (0...0.99).contains($0) }),
              left + right < 1, top + bottom < 1, (0...32).contains(maskFeather) else {
            return "Garbage mask must leave a visible region; feather must be 0–32 pixels."
        }
        return nil
    }
    public var color: SIMD3<Double> {
        let value = UInt32(keyColorHex.dropFirst(), radix: 16) ?? 0x00ff00
        return SIMD3(Double((value >> 16) & 255), Double((value >> 8) & 255), Double(value & 255)) / 255
    }
}

/// Encoded-sRGB chroma-distance key. Cube texels are premultiplied RGBA.
/// Luminance is ignored when finding the key, preserving differently lit
/// screen areas; softness retains fractional-alpha edge colors.
public enum ChromaKeyTransform {
    public static func rgba(_ rgb: SIMD3<Double>, inputAlpha: Double = 1,
                            settings: ChromaKeySettings) -> SIMD4<Double> {
        guard [rgb.x,rgb.y,rgb.z].allSatisfy(\.isFinite) else { return .zero }
        let alpha = inputAlpha.isFinite ? min(1,max(0,inputAlpha)) : 0
        guard settings.isEnabled, !settings.isBypassed, settings.validationError == nil else {
            return SIMD4(rgb.x * alpha, rgb.y * alpha, rgb.z * alpha, alpha)
        }
        return pixel(rgb, alpha: alpha, key: settings.color, settings: settings)
    }

    private static func pixel(_ rgb: SIMD3<Double>, alpha: Double, key: SIMD3<Double>,
                              settings: ChromaKeySettings) -> SIMD4<Double> {
        func chroma(_ c: SIMD3<Double>) -> SIMD2<Double> {
            SIMD2(-0.168736*c.x - 0.331264*c.y + 0.5*c.z,
                   0.5*c.x - 0.418688*c.y - 0.081312*c.z)
        }
        let kc = chroma(key), rc = chroma(rgb)
        let keyLength = sqrt(kc.x*kc.x+kc.y*kc.y)
        let rgbLength = sqrt(rc.x*rc.x+rc.y*rc.y)
        let delta = rgb-key
        let distance: Double
        if keyLength < 0.02 {
            distance = sqrt((delta.x*delta.x+delta.y*delta.y+delta.z*delta.z)/3)
        } else if rgbLength < 0.001 {
            distance = 1
        } else {
            let hue = rc/rgbLength-kc/keyLength
            func saturation(_ c: SIMD3<Double>) -> Double {
                let maximum = max(c.x,max(c.y,c.z)), minimum = min(c.x,min(c.y,c.z))
                return maximum > 0 ? (maximum-minimum)/maximum : 0
            }
            // Chroma direction removes lighting variation; saturation keeps
            // pale neutrals with the same hue from disappearing entirely.
            distance = max(sqrt(hue.x*hue.x+hue.y*hue.y)/2,
                           abs(saturation(rgb)-saturation(key))*0.25)
        }
        let t = min(1,max(0,(distance-settings.tolerance)/settings.softness))
        let matte = t*t*(3-2*t)
        let keyChroma = chroma(key)
        let length = sqrt(keyChroma.x*keyChroma.x + keyChroma.y*keyChroma.y)
        // Desaturate key-aligned spill close to edges, retaining luminance.
        let alignment = length > 0.001 ? max(0,(chroma(rgb).x*keyChroma.x + chroma(rgb).y*keyChroma.y)/(length*length)) : 0
        let strength = settings.spill * min(1,alignment)
        let luma = 0.299*rgb.x + 0.587*rgb.y + 0.114*rgb.z
        let cleaned = rgb * (1-strength) + SIMD3(repeating: luma) * strength
        let a = alpha * matte
        return SIMD4(cleaned.x*a,cleaned.y*a,cleaned.z*a,a)
    }

    public static func cubeData(settings: ChromaKeySettings, dimension: Int = 64) -> Data? {
        guard settings.validationError == nil, (2...64).contains(dimension) else { return nil }
        var values = [Float](); values.reserveCapacity(dimension*dimension*dimension*4)
        let key = settings.color
        for b in 0..<dimension { for g in 0..<dimension { for r in 0..<dimension {
            let rgb = SIMD3(Double(r),Double(g),Double(b))/Double(dimension-1)
            let pixel = settings.isEnabled && !settings.isBypassed
                ? pixel(rgb, alpha: 1, key: key, settings: settings) : SIMD4(rgb.x,rgb.y,rgb.z,1)
            values.append(Float(pixel.x)); values.append(Float(pixel.y))
            values.append(Float(pixel.z)); values.append(Float(pixel.w))
        } } }
        return values.withUnsafeBytes { Data($0) }
    }
}
