import Foundation
import Testing
@testable import StreamCore

@Suite struct PortableShowTests {
    @Test func redactionAndConsistentResourceRemapping() throws {
        let id = UUID().uuidString
        let json = Data("{\"sceneID\":\"\(id)\",\"layers\":[{\"sourceID\":\"\(id)\",\"bookmarkData\":\"grant\",\"configuration\":{\"urlString\":\"https://private.example/?token=secret\"}}],\"rtmpURL\":\"rtmps://secret\",\"streamKey\":\"secret\",\"lastKnownPath\":\"/private/path\"}".utf8)
        var map: [String: String] = [:]
        let redacted = try PortableShow.redact(json, remappingIDs: true, idMap: &map)
        let text = String(decoding: redacted, as: UTF8.self)
        #expect(!text.contains("secret")); #expect(!text.contains("grant")); #expect(!text.contains("private"))
        #expect(!text.contains(id)); #expect(map.count == 1)
        let object = try #require(JSONSerialization.jsonObject(with: redacted) as? [String: Any])
        let layers = try #require(object["layers"] as? [[String: Any]])
        #expect(object["sceneID"] as? String == layers[0]["sourceID"] as? String)
        #expect(PortableShow.remapIDReferences("scene.\(id)", idMap: &map) == "scene.\(map[id]!)")
    }

    @Test func literalUUIDTextSurvivesWhileResourceBindingsRemap() throws {
        let id = UUID().uuidString
        let caption = "Receipt \(id) — keep this exact text 👩🏽‍🚀"
        let data = try JSONSerialization.data(withJSONObject: [
            "sceneID": id, "name": caption, "layers": [["id": id, "text": caption]],
            "commandID": "scene.\(id).select", "slots": [id], "displayName": caption
        ])
        var mapping: [String: String] = [:]
        let result = try PortableShow.redact(data, remappingIDs: true, idMap: &mapping)
        let object = try #require(JSONSerialization.jsonObject(with: result) as? [String: Any])
        let layers = try #require(object["layers"] as? [[String: Any]])
        let mapped = try #require(mapping[id])
        #expect(mapped != id)
        #expect(object["name"] as? String == caption)
        #expect(object["displayName"] as? String == caption)
        #expect(layers[0]["text"] as? String == caption)
        #expect(layers[0]["id"] as? String == mapped)
        #expect(object["slots"] as? [String] == [mapped])
        #expect(object["commandID"] as? String == "scene.\(mapped).select")
    }

    @Test func guestTitleTokensRemapOnlyInsideTypedTextLayers() throws {
        let id = UUID().uuidString
        let token = "{guestslot_\(id.replacingOccurrences(of: "-", with: "").lowercased())_name}"
        let literal = "Keep \(id) and \(token) in public chat"
        let document: [String: Any] = ["guestSlots": [["id": id, "name": literal]],
            "text": literal, "chatPresets": [["text": literal]],
            "layer": ["kind": "text", "payload": ["text": "Hello \(token)! Receipt \(id)"]]]
        var mapping: [String: String] = [:]
        let data = try PortableShow.redact(JSONSerialization.data(withJSONObject: document), remappingIDs: true, idMap: &mapping)
        let result = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let layer = try #require(result["layer"] as? [String: Any])
        let payload = try #require(layer["payload"] as? [String: Any])
        let mapped = try #require(mapping[id])
        let mappedToken = "{guestslot_\(mapped.replacingOccurrences(of: "-", with: "").lowercased())_name}"
        #expect(payload["text"] as? String == "Hello \(mappedToken)! Receipt \(id)")
        #expect(result["text"] as? String == literal)
        #expect((result["chatPresets"] as? [[String: String]])?.first?["text"] == literal)
        #expect((result["guestSlots"] as? [[String: String]])?.first?["name"] == literal)
        #expect((result["guestSlots"] as? [[String: String]])?.first?["id"] == mapped)
    }

    @Test func guestTitleRemappingMatchesResolverAndPreservesRecordedPublicChat() throws {
        let id = UUID().uuidString
        let compact = id.replacingOccurrences(of: "-", with: "").lowercased()
        let name = "{guestslot_\(compact)_name}"
        let variant = "{ \tGUESTSLOT_\(compact.uppercased())_TITLE\t }"
        let unknown = "{guestslot_00000000000000000000000000000000_name}"
        let malformed = "{{guestslot_\(compact)_name}}"
        let caption = "👩🏽‍🚀 \(name) / \(variant) / \(unknown) / \(malformed) / receipt \(id)"
        let document: [String: Any] = ["guestSlots": [["id": id]],
            "title": ["kind": "text", "payload": ["text": caption]],
            "chat": ["kind": "text", "payload": ["text": caption, "recordingChatMessageID": "public-comment"]],
            "nullChat": ["kind": "text", "payload": ["text": variant, "recordingChatMessageID": NSNull()]]]
        var mapping: [String: String] = [:]
        let data = try PortableShow.redact(JSONSerialization.data(withJSONObject: document), remappingIDs: true, idMap: &mapping)
        let result = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        func text(_ field: String) -> String? { ((result[field] as? [String: Any])?["payload"] as? [String: Any])?["text"] as? String }
        let mapped = try #require(mapping[id]).replacingOccurrences(of: "-", with: "").lowercased()
        let mappedName = "{guestslot_\(mapped)_name}", mappedTitle = "{guestslot_\(mapped)_title}"
        #expect(text("title") == "👩🏽‍🚀 \(mappedName) / \(mappedTitle) / \(unknown) / \(malformed) / receipt \(id)")
        #expect(text("chat") == caption)
        #expect(text("nullChat") == mappedTitle)
    }

    @Test func packageRejectsTraversalSymlinksAndChangedBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for path in ["../escape", "/absolute", "Assets//bad", "Assets/./bad", "Assets/../bad", "Assets\\bad"] {
            #expect(throws: (any Error).self) { try PortableShow.safeURL(path, under: root) }
        }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Assets"), withDestinationURL: root.deletingLastPathComponent())
        #expect(throws: (any Error).self) { try PortableShow.safeURL("Assets/file", under: root) }
        try Data("{}".utf8).write(to: root.appendingPathComponent("stream.scenes.v2.json"))
        let entry = try PortableShow.fileDescription(path: "stream.scenes.v2.json", root: root)
        let manifest = PortableShowManifest(name: "Test Show", includesMedia: false, files: [entry])
        try JSONEncoder().encode(manifest).write(to: root.appendingPathComponent("manifest.json"))
        #expect(try PortableShow.validate(at: root).files.count == 1)
        try Data("{\"changed\":true}".utf8).write(to: root.appendingPathComponent("stream.scenes.v2.json"))
        #expect(throws: (any Error).self) { try PortableShow.validate(at: root) }
    }

    @Test func packageRequiresRegularEntriesAndHonorsRelinkPolicy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Assets/folder"), withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try PortableShow.fileDescription(path: "Assets/folder", root: root) }
        try Data("{}".utf8).write(to: root.appendingPathComponent("stream.scenes.v2.json"))
        try Data("media".utf8).write(to: root.appendingPathComponent("Assets/file"))
        let files = try ["stream.scenes.v2.json", "Assets/file"].map { try PortableShow.fileDescription(path: $0, root: root) }
        let manifest = PortableShowManifest(name: "Relink only", includesMedia: false, files: files)
        try JSONEncoder().encode(manifest).write(to: root.appendingPathComponent("manifest.json"))
        #expect(throws: (any Error).self) { try PortableShow.validate(at: root) }
        // Never read a multi-gigabyte untrusted manifest into memory first.
        try Data(repeating: 0x20, count: 1024 * 1024 + 1).write(to: root.appendingPathComponent("manifest.json"))
        #expect(throws: (any Error).self) { try PortableShow.validate(at: root) }
    }
}
