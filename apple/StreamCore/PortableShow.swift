import CryptoKit
import Foundation

public struct PortableShowManifest: Codable, Sendable {
    public var version = 1
    public var name: String
    public var createdAt = Date()
    public var includesMedia: Bool
    public var files: [File]
    public struct File: Codable, Sendable {
        public var path: String
        public var bytes: Int64
        public var sha256: String
        public init(path: String, bytes: Int64, sha256: String) { self.path = path; self.bytes = bytes; self.sha256 = sha256 }
    }
    public init(name: String, includesMedia: Bool, files: [File]) {
        self.name = name; self.includesMedia = includesMedia; self.files = files
    }
}

public enum PortableShow {
    public enum Failure: Error, CustomStringConvertible {
        case invalid(String)
        public var description: String { switch self { case .invalid(let message): return message } }
    }
    public static let documentNames: Set<String> = [
        "stream.scenes.v2.json", "stream.sceneBrowser.v1.json", "stream.assets.v1.json",
        "stream.soundboard.v1.json", "stream.annotations.v1.json", "stream.presentations.v1.json", "studio-rundown.json",
        "stream.shortcuts.v1.json", "stream.macros.v1.json", "destinations.json", "desktop.settings.v1.json"
    ]
    private static let privateKeys: Set<String> = [
        "bookmarkdata", "lastknownpath", "rtmpurl", "streamkey", "token", "bearertoken", "passphrase", "password",
        "deviceuniqueid", "deviceuid", "deviceid", "targetidentifier", "displayid", "windowid", "preferredaudioinputuid", "monitoroutputdeviceuid",
        "cameracontrols", "audioinputs", "url", "urlstring", "endpoint", "hostname", "host", "address", "applicationbundleidentifier"
    ]

    /// Explicit configuration redaction, applied again on import. Unknown prose
    /// remains editable content; connection credentials and machine grants do not.
    public static func redact(_ data: Data, remappingIDs: Bool = false, idMap: inout [String: String]) throws -> Data {
        guard data.count <= 16 * 1024 * 1024 else { throw Failure.invalid("A show document exceeds 16 MiB.") }
        func visit(_ value: Any) -> Any {
            if let dictionary = value as? [String: Any] {
                var result: [String: Any] = [:]
                for (key, item) in dictionary where !privateKeys.contains(key.lowercased()) {
                    let mappedKey = remappingIDs ? remapIDReferences(key, idMap: &idMap) : key
                    result[mappedKey] = visit(item)
                }
                // A linked asset without its bookmark must remain repairable.
                if dictionary["lastKnownPath"] != nil { result["lastKnownPath"] = "" }
                if dictionary["rtmpURL"] != nil { result["rtmpURL"] = "" }
                if dictionary["streamKey"] != nil { result["streamKey"] = "" }
                return result
            }
            if let array = value as? [Any] { return array.map(visit) }
            if let string = value as? String, remappingIDs { return remapIDReferences(string, idMap: &idMap) }
            return value
        }
        return try JSONSerialization.data(withJSONObject: visit(JSONSerialization.jsonObject(with: data)), options: [.sortedKeys])
    }

    public static func remapIDReferences(_ value: String, idMap: inout [String: String]) -> String {
        let pattern = "(?i)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
        let regex = try! NSRegularExpression(pattern: pattern)
        var result = value
        for match in regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let key = String(result[range]).uppercased()
            let mapped = idMap[key] ?? UUID().uuidString
            idMap[key] = mapped
            result.replaceSubrange(range, with: mapped)
        }
        return result
    }

    public static func safeURL(_ path: String, under root: URL) throws -> URL {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, path.utf8.count <= 1024, !path.contains("\\"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw Failure.invalid("Unsafe package path.") }
        let url = root.appendingPathComponent(path).standardizedFileURL
        guard url.path.hasPrefix(root.standardizedFileURL.path + "/") else { throw Failure.invalid("Package path escapes its folder.") }
        var current = root
        for component in components {
            current.appendPathComponent(String(component))
            if let values = try? current.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true {
                throw Failure.invalid("Show packages cannot contain symbolic links.")
            }
        }
        return url
    }

    public static func fileDescription(path: String, root: URL) throws -> PortableShowManifest.File {
        let url = try safeURL(path, under: root)
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256(); var bytes: Int64 = 0
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data); bytes += Int64(data.count) }
        return .init(path: path, bytes: bytes, sha256: hash.finalize().map { String(format: "%02x", $0) }.joined())
    }

    public static func validate(at root: URL) throws -> PortableShowManifest {
        let values = try root.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw Failure.invalid("Choose a .streamshow package folder.") }
        let manifestURL = try safeURL("manifest.json", under: root)
        let data = try Data(contentsOf: manifestURL)
        guard data.count <= 1024 * 1024 else { throw Failure.invalid("The package manifest is too large.") }
        let manifest = try JSONDecoder().decode(PortableShowManifest.self, from: data)
        guard manifest.version == 1, StudioProjectCatalog.validName(manifest.name), manifest.files.count <= 2000,
              Set(manifest.files.map(\.path)).count == manifest.files.count,
              manifest.files.contains(where: { $0.path == "stream.scenes.v2.json" }) else { throw Failure.invalid("Unsupported or incomplete show manifest.") }
        for file in manifest.files {
            guard documentNames.contains(file.path) || file.path.hasPrefix("Assets/"), file.bytes >= 0 else { throw Failure.invalid("Unexpected show file.") }
            let actual = try fileDescription(path: file.path, root: root)
            guard actual.bytes == file.bytes, actual.sha256 == file.sha256 else { throw Failure.invalid("A package file is missing or has changed: \(file.path)") }
        }
        return manifest
    }
}
