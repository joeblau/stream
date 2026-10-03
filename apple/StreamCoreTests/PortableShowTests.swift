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

    @Test func existingTemporaryAliasesPreserveURLsAndRejectOwnedChildEscapes() throws {
        #if os(macOS)
        let name = "stream-package-alias-\(UUID().uuidString)"
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(name, isDirectory: true)
        let outside = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(name + "-outside", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let bytes = Data("{\"owned\":true}".utf8)
        try bytes.write(to: root.appendingPathComponent("stream.scenes.v2.json"))
        try bytes.write(to: outside.appendingPathComponent("outside.json"))
        for prefix in ["/private/tmp", "/tmp"] {
            let spelling = URL(fileURLWithPath: prefix, isDirectory: true).appendingPathComponent(name, isDirectory: true)
            let original = spelling.absoluteString
            let expected = spelling.appendingPathComponent("stream.scenes.v2.json").standardizedFileURL
            let returned = try PortableShow.safeURL("stream.scenes.v2.json", under: spelling)
            #expect(returned.absoluteString == expected.absoluteString)
            #expect(spelling.absoluteString == original)
            #expect(try Data(contentsOf: returned) == bytes)
            let missing = try PortableShow.safeURL("Assets/new-file", under: spelling)
            #expect(missing.absoluteString == spelling.appendingPathComponent("Assets/new-file").standardizedFileURL.absoluteString)
            let entry = try PortableShow.fileDescription(path: "stream.scenes.v2.json", root: spelling)
            try JSONEncoder().encode(PortableShowManifest(name: "Alias Show", includesMedia: false, files: [entry]))
                .write(to: spelling.appendingPathComponent("manifest.json"))
            let validated = try PortableShow.validate(at: spelling)
            #expect(validated.files.count == 1)
            #expect(validated.files.first?.path == entry.path)
            #expect(validated.files.first?.bytes == entry.bytes)
            #expect(validated.files.first?.sha256 == entry.sha256)
        }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Escape"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("InternalLink"),
            withDestinationURL: root.appendingPathComponent("stream.scenes.v2.json"))
        for prefix in ["/private/tmp", "/tmp"] {
            let spelling = URL(fileURLWithPath: prefix, isDirectory: true).appendingPathComponent(name, isDirectory: true)
            #expect(throws: (any Error).self) { try PortableShow.safeURL("Escape/outside.json", under: spelling) }
            #expect(throws: (any Error).self) { try PortableShow.safeURL("InternalLink", under: spelling) }
            #expect(throws: (any Error).self) { try PortableShow.safeURL("../" + outside.lastPathComponent + "/outside.json", under: spelling) }
        }
        #endif
    }
}
