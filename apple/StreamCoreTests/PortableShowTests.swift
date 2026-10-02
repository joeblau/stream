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
}
