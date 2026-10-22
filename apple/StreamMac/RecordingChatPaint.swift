import CoreMedia
import CryptoKit
import Foundation

struct RecordingChatPaint: Codable, Hashable, Sendable {
    let slotID: String
    let messageID: String
    let fingerprint: String
    var bodyUTF16Start: Int? = nil
    var bodyUTF16Length: Int? = nil
    var pageIndex: Int? = nil
    var pageCount: Int? = nil
    var bindingKey: Self { .init(slotID: slotID, messageID: messageID, fingerprint: fingerprint) }
    static func fingerprint(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    var isValid: Bool {
        slotID.utf8.count <= 64 && !slotID.isEmpty && messageID.utf8.count <= 128 && !messageID.isEmpty && fingerprint.count == 64
            && ((bodyUTF16Start == nil) == (bodyUTF16Length == nil))
            && ((pageIndex == nil) == (pageCount == nil))
            && (pageIndex == nil || pageIndex! < pageCount!)
            && (bodyUTF16Start.map { $0 >= 0 && $0 <= 20_000 } ?? true)
            && (bodyUTF16Length.map { $0 >= 0 && $0 <= 20_000 } ?? true)
            && (pageIndex.map { $0 >= 0 && $0 < 256 } ?? true)
            && (pageCount.map { $0 > 0 && $0 <= 256 } ?? true)
    }
    private static var key: CFString { "com.joeblau.Stream.recording.publicChatPaint.v1" as CFString }
    static func attach(_ value: [Self], to sample: CMSampleBuffer) {
        guard let data = try? JSONEncoder().encode(Array(value.filter(\.isValid).prefix(32))), !value.isEmpty else { return }
        CMSetAttachment(sample, key: key, value: data as CFData, attachmentMode: kCMAttachmentMode_ShouldNotPropagate)
    }
    static func read(_ sample: CMSampleBuffer) -> [Self] {
        guard let data = CMGetAttachment(sample, key: key, attachmentModeOut: nil) as? Data,
              data.count <= 16_384, let values = try? JSONDecoder().decode([Self].self, from: data), values.count <= 32 else { return [] }
        return values.filter(\.isValid)
    }
}

