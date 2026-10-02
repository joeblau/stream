import Foundation

enum StudioMIDIKind: String, Codable, Sendable { case note, controlChange }
struct StudioMIDIAddress: Codable, Hashable, Sendable {
    var sourceID: Int32
    var group: UInt8 = 0
    var channel: UInt8
    var kind: StudioMIDIKind
    var number: UInt8
    var valid: Bool { sourceID != 0 && group < 16 && channel < 16 && number < 128 }
}
enum StudioControllerInput: Codable, Hashable, Sendable {
    case midi(StudioMIDIAddress)
    case osc(String)
}
enum StudioControllerTargetKind: String, Codable, Sendable { case command, value }
struct StudioControllerTarget: Identifiable {
    var id: String
    var title: String
    var kind: StudioControllerTargetKind
    /// Numeric targets use linear gain 0…2. Feedback is normalized 0…1.
    var normalizedValue: Double
    var unavailableReason: String?
    var execute: @MainActor (Double?) -> String?
}
struct StudioControllerMapping: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var input: StudioControllerInput
    var targetID: String
    var kind: StudioControllerTargetKind
    var inverted = false
    var label: String {
        switch input {
        case .midi(let address): return "MIDI \(address.kind == .note ? "note" : "CC") \(address.number) · channel \(address.channel + 1) · source \(address.sourceID)"
        case .osc(let address): return address
        }
    }
    var feedbackAddress: String { "/_stream/feedback/\(id.uuidString.lowercased())" }
}
struct StudioControllerMappingDocument: Codable, Equatable, Sendable {
    var version = 1
    var mappings: [StudioControllerMapping] = []
    func validate() throws {
        guard version == 1, mappings.count <= 256 else { throw StudioControllerValidation.invalid("Unsupported mapping version or too many mappings.") }
        var inputs = Set<StudioControllerInput>(), ids = Set<UUID>()
        for mapping in mappings {
            guard ids.insert(mapping.id).inserted, inputs.insert(mapping.input).inserted else { throw StudioControllerValidation.invalid("This controller input is already mapped.") }
            guard !mapping.targetID.isEmpty, mapping.targetID.utf8.count <= 512, !mapping.targetID.hasPrefix("unavailable.") else { throw StudioControllerValidation.invalid("Choose a stable command or value target.") }
            switch mapping.input {
            case .midi(let address):
                guard address.valid, mapping.kind != .value || address.kind == .controlChange else { throw StudioControllerValidation.invalid("Numeric MIDI values require a valid Control Change input.") }
            case .osc(let address):
                guard StudioOSC.validInputAddress(address) else { throw StudioControllerValidation.invalid("Use a literal OSC address outside /_stream/feedback/.") }
            }
        }
    }
}
enum StudioControllerValidation: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

/// OSC 1.0 subset: literal addresses, one i/f/T/F argument, immediate bundles.
/// Parse the whole datagram before accepting any command; reject timed bundles.
enum StudioOSC {
    struct Message: Equatable, Sendable { var address: String; var value: Double }
    static func validAddress(_ value: String) -> Bool {
        value.hasPrefix("/") && value.utf8.count <= 256 && value.utf8.allSatisfy { $0 >= 33 && $0 <= 126 && ![35,42,44,63,91,93,123,125].contains($0) }
    }
    static func validInputAddress(_ value: String) -> Bool { validAddress(value) && !value.hasPrefix("/_stream/") }
    static func decode(_ data: Data) throws -> [Message] {
        guard data.count <= 4096, data.count >= 8, data.count % 4 == 0 else { throw StudioControllerValidation.invalid("Invalid OSC packet size.") }
        var messages: [Message] = []
        try parse(Array(data), depth: 0, messages: &messages)
        return messages
    }
    private static func parse(_ bytes: [UInt8], depth: Int, messages: inout [Message]) throws {
        guard depth <= 4, messages.count < 32 else { throw StudioControllerValidation.invalid("OSC bundle limit exceeded.") }
        var offset = 0
        func word() throws -> UInt32 {
            guard offset + 4 <= bytes.count else { throw StudioControllerValidation.invalid("Truncated OSC value.") }
            defer { offset += 4 }
            return bytes[offset..<offset + 4].reduce(0) { ($0 << 8) | UInt32($1) }
        }
        func string() throws -> String {
            guard let end = bytes[offset...].firstIndex(of: 0), end - offset <= 256,
                  bytes[offset..<end].allSatisfy({ $0 >= 32 && $0 <= 126 }) else { throw StudioControllerValidation.invalid("Invalid OSC string.") }
            let result = String(bytes: bytes[offset..<end], encoding: .ascii)!
            let next = (end + 4) & ~3
            guard next <= bytes.count, bytes[end..<next].allSatisfy({ $0 == 0 }) else { throw StudioControllerValidation.invalid("Invalid OSC padding.") }
            offset = next
            return result
        }
        let address = try string()
        if address == "#bundle" {
            guard try word() == 0, try word() == 1 else { throw StudioControllerValidation.invalid("Only immediate OSC bundles are supported.") }
            while offset < bytes.count {
                let size = Int(try word())
                guard size >= 8, size % 4 == 0, size <= bytes.count - offset else { throw StudioControllerValidation.invalid("Invalid OSC bundle element.") }
                try parse(Array(bytes[offset..<offset + size]), depth: depth + 1, messages: &messages)
                offset += size
            }
            return
        }
        guard validAddress(address) else { throw StudioControllerValidation.invalid("OSC requires a literal address.") }
        let tag = try string()
        let value: Double
        switch tag {
        case ",i": value = Double(Int32(bitPattern: try word()))
        case ",f": value = Double(Float(bitPattern: try word()))
        case ",T": value = 1
        case ",F": value = 0
        default: throw StudioControllerValidation.invalid("OSC requires one i, f, T, or F argument.")
        }
        guard offset == bytes.count, value.isFinite else { throw StudioControllerValidation.invalid("Invalid OSC argument.") }
        messages.append(Message(address: address, value: value))
    }
    static func encode(address: String, value: Double) -> Data {
        func padded(_ value: String) -> [UInt8] { var result = Array(value.utf8) + [0]; while result.count % 4 != 0 { result.append(0) }; return result }
        let word = Float(value).bitPattern.bigEndian
        var data = Data(padded(address) + padded(",f"))
        withUnsafeBytes(of: word) { data.append(contentsOf: $0) }
        return data
    }
}

struct StudioMIDIEvent: Equatable, Sendable {
    var address: StudioMIDIAddress
    var value: UInt8
    static func decode(words: [UInt32], sourceID: Int32) -> [StudioMIDIEvent] {
        // UMP message type fixes its length. Never interpret payload words as events.
        let lengths = [1,1,1,2,2,4,1,1,2,2,2,3,3,4,4,4]
        var index = 0, events: [StudioMIDIEvent] = []
        while index < words.count, events.count < 256 {
            let word = words[index], type = Int(word >> 28)
            guard [0,1,2,3,4,5,13,15].contains(type) else { break }
            let count = lengths[type]
            guard index + count <= words.count else { break }
            index += count
            guard type == 2 else { continue }
            let status = UInt8((word >> 20) & 15)
            guard status == 8 || status == 9 || status == 11, word & 0x8080 == 0 else { continue }
            let address = StudioMIDIAddress(sourceID: sourceID, group: UInt8((word >> 24) & 15), channel: UInt8((word >> 16) & 15), kind: status == 11 ? .controlChange : .note, number: UInt8((word >> 8) & 127))
            events.append(.init(address: address, value: status == 8 ? 0 : UInt8(word & 127)))
        }
        return events
    }
}
