import Foundation

public enum LUTColorSpace: String, Codable, CaseIterable, Sendable { case sRGB, linearSRGB }
public struct LUTSettings: Hashable, Codable, Sendable {
    public var assetID: AssetID?
    public var intensity = 1.0
    public var isBypassed = false
    public var colorSpace: LUTColorSpace = .sRGB
    public init() {}
    public var validationError: String? {
        intensity.isFinite && (0...1).contains(intensity) ? nil : "LUT intensity must be between 0 and 1."
    }
    public var isEnabled: Bool { assetID != nil && !isBypassed && intensity > 0 }
}

public struct CubeLUT: Sendable {
    public let dimension: Int
    public let title: String?
    /// RGB triples, red changes fastest, then green, then blue.
    public let values: [SIMD3<Float>]
    public static let maxFileBytes = 16 * 1024 * 1024
    public enum Failure: Error, CustomStringConvertible, Sendable {
        case invalid(String)
        public var description: String { switch self { case .invalid(let message): return message } }
    }
    /// Bounded SDR 3D .cube subset. Unsupported shapers/ranges fail rather
    /// than silently changing the creator's intended color transform.
    public static func parse(_ data: Data) throws -> CubeLUT {
        guard data.count <= maxFileBytes, var text = String(data: data, encoding: .utf8) else {
            throw Failure.invalid("Use a UTF-8 .cube file of 16 MiB or less.")
        }
        if text.first == "\u{FEFF}" { text.removeFirst() }
        var dimension: Int?, title: String?, values: [SIMD3<Float>] = []
        var seen = Set<String>()
        for (lineNumber,line) in text.split(whereSeparator: \.isNewline).enumerated() {
            var quoted = false
            let comment = line.firstIndex { character in
                if character == "\"" { quoted.toggle() }
                return character == "#" && !quoted
            }
            let clean = line[..<(comment ?? line.endIndex)].trimmingCharacters(in: .whitespaces)
            guard !clean.isEmpty else { continue }
            let tokens = clean.split(whereSeparator: \.isWhitespace)
            let name = String(tokens[0])
            func fail(_ message: String) -> Failure { .invalid("Line \(lineNumber+1): \(message)") }
            if name == "TITLE" {
                guard values.isEmpty, seen.insert(name).inserted,
                      let first = clean.firstIndex(of: "\""), let last = clean.lastIndex(of: "\""), first < last,
                      clean[..<first].trimmingCharacters(in: .whitespaces) == "TITLE",
                      clean[clean.index(after:last)...].trimmingCharacters(in: .whitespaces).isEmpty else {
                    throw fail("TITLE must be a quoted string in the header.")
                }
                title = String(clean[clean.index(after:first)..<last])
                guard title!.utf8.count <= 1024 else { throw fail("LUT title is too long.") }
            } else if name == "LUT_3D_SIZE" {
                guard values.isEmpty, seen.insert(name).inserted, tokens.count == 2,
                      let n = Int(tokens[1]), (2...64).contains(n) else {
                    throw fail("Supported 3D LUT sizes are 2–64; re-export a smaller 3D .cube.")
                }
                dimension = n; values.reserveCapacity(n*n*n)
            } else if name == "DOMAIN_MIN" || name == "DOMAIN_MAX" {
                let expected: Float = name == "DOMAIN_MIN" ? 0 : 1
                guard values.isEmpty, seen.insert(name).inserted, tokens.count == 4,
                      tokens.dropFirst().allSatisfy({ Float($0) == expected }) else {
                    throw fail("Only DOMAIN_MIN 0 0 0 / DOMAIN_MAX 1 1 1 are supported.")
                }
            } else {
                guard let n = dimension, tokens.count == 3, let r = Float(tokens[0]), let g = Float(tokens[1]),
                      let b = Float(tokens[2]), [r,g,b].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
                    throw fail("Expected an SDR RGB row in 0–1 after LUT_3D_SIZE. 1D/shaper/log-range files are unsupported.")
                }
                guard values.count < n*n*n else { throw fail("Too many LUT rows.") }
                values.append(SIMD3(r,g,b))
            }
        }
        guard let n = dimension, values.count == n*n*n else {
            throw Failure.invalid("The LUT must contain exactly size³ RGB rows.")
        }
        return CubeLUT(dimension: n, title: title, values: values)
    }

    /// Blend identity into the LUT once when intensity changes, rather than
    /// compositing two video frames. Alpha remains one in the table.
    public func rgbaData(intensity: Double) -> Data? {
        guard intensity.isFinite, (0...1).contains(intensity) else { return nil }
        var output = [Float](); output.reserveCapacity(values.count*4)
        let t = Float(intensity), scale = Float(dimension-1)
        for (index,value) in values.enumerated() {
            let identity = SIMD3(Float(index % dimension),Float((index/dimension) % dimension),Float(index/(dimension*dimension)))/scale
            let color = identity*(1-t)+value*t
            output += [color.x,color.y,color.z,1]
        }
        return output.withUnsafeBytes { Data($0) }
    }
}
