import CoreMedia
import Foundation

private struct PaintFailure: Error, CustomStringConvertible { let description: String }
private func check(_ value: @autoclosure () throws -> Bool, _ reason: String) throws {
    if try !value() { throw PaintFailure(description: reason) }
}
private var paintKey: CFString { "com.joeblau.Stream.recording.publicChatPaint.v1" as CFString }

private func sample() throws -> CMSampleBuffer {
    var result: CMSampleBuffer?
    let status = CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: true,
        makeDataReadyCallback: nil, refcon: nil, formatDescription: nil, sampleCount: 0,
        sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 0,
        sampleSizeArray: nil, sampleBufferOut: &result)
    guard status == noErr, let result else { throw PaintFailure(description: "Owned sample creation failed: \(status)") }
    return result
}
private func attachment(_ sample: CMSampleBuffer) -> (Data?, CMAttachmentMode) {
    var mode = kCMAttachmentMode_ShouldPropagate
    let data = CMGetAttachment(sample, key: paintKey, attachmentModeOut: &mode) as? Data
    return (data, mode)
}
private func paint(_ id: String) -> RecordingChatPaint {
    .init(slotID: "owned-slot", messageID: id, fingerprint: RecordingChatPaint.fingerprint("Owned public text"))
}

@main private enum RecordingChatPaintHarness {
    static func main() {
        do {
            let valid = paint("owned-message")
            let empty = try sample()
            RecordingChatPaint.attach([], to: empty)
            try check(attachment(empty).0 == nil && RecordingChatPaint.read(empty).isEmpty,
                "Empty input added an attachment to a blank sample")

            let retained = try sample()
            RecordingChatPaint.attach([valid], to: retained)
            let original = attachment(retained)
            try check(original.0 != nil && original.1 == kCMAttachmentMode_ShouldNotPropagate,
                "Valid paint attachment or propagation mode missing")
            RecordingChatPaint.attach([], to: retained)
            try check(attachment(retained).0 == original.0 && attachment(retained).1 == original.1
                && RecordingChatPaint.read(retained) == [valid], "Empty input changed existing paint")

            var paged = paint("owned-page")
            paged.bodyUTF16Start = 2; paged.bodyUTF16Length = 7; paged.pageIndex = 1; paged.pageCount = 3
            RecordingChatPaint.attach([paged, valid, paged], to: retained)
            try check(RecordingChatPaint.read(retained) == [paged, valid, paged],
                "Valid fields, order or duplicates changed")

            let invalid = RecordingChatPaint(slotID: "", messageID: "owned-invalid", fingerprint: valid.fingerprint)
            try check(!invalid.isValid && valid.isValid && paged.isValid, "Validity contract changed")
            RecordingChatPaint.attach([invalid], to: retained)
            let cleared = attachment(retained)
            try check(cleared.0 != nil && cleared.1 == kCMAttachmentMode_ShouldNotPropagate
                && RecordingChatPaint.read(retained).isEmpty, "Nonempty all-invalid input did not overwrite prior paint")
            try check(try JSONDecoder().decode([RecordingChatPaint].self, from: cleared.0!) == [],
                "All-invalid input did not retain the existing encoded-empty-array behavior")

            let many = (0..<40).map { paint("owned-\($0)") }
            let mixed = [invalid] + many.flatMap { [$0, invalid] }
            RecordingChatPaint.attach(mixed, to: retained)
            try check(RecordingChatPaint.read(retained) == Array(many.prefix(32)),
                "Valid-first bounded prefix changed")

            let result: [String: Any] = ["result": "PASS", "checks": [
                "empty blank sample has no attachment", "empty preserves existing bytes and propagation mode",
                "valid optional fields/order/duplicates preserved", "nonempty all-invalid overwrites prior paint with encoded []",
                "validity behavior retained", "filter-valid then prefix32 retained"],
                "samples": 2, "boundedPrefixCount": RecordingChatPaint.read(retained).count,
                "scope": "Owned zero-sample CMSampleBuffers and actual whole RecordingChatPaint source only; no image/device/audio/renderer/network operation or measured performance claim."]
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            if CommandLine.arguments.count == 2 { try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1])) }
            print(String(decoding: data, as: UTF8.self))
        } catch {
            print("FAIL recording chat paint: \(error)")
            exit(1)
        }
    }
}
