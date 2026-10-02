import AppKit
import Foundation
import StreamCore
import UniformTypeIdentifiers

extension UTType {
    static let streamShow = UTType(exportedAs: "com.joeblau.stream.show", conformingTo: .package)
}

struct ShowPackagePreview: Identifiable, Sendable {
    var id = UUID()
    let url: URL
    let name: String
    let sceneNames: [String]
    let includedMedia: Bool
    let fileCount: Int
}

enum ShowPackageIO {
    struct Media: Sendable {
        let access: ResolvedAssetAccess
        let relativePath: String
    }

    static func export(documents: [String: Data], media: [Media], name: String,
                       includeMedia: Bool, to destination: URL) throws {
        let grant = destination.startAccessingSecurityScopedResource()
        defer { if grant { destination.stopAccessingSecurityScopedResource() } }
        let manager = FileManager.default
        guard !manager.fileExists(atPath: destination.path) else { throw PortableShow.Failure.invalid("Choose a new package name; an existing package is preserved.") }
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".stream-export-\(UUID().uuidString)", isDirectory: true)
        defer { try? manager.removeItem(at: staging) }
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        var paths: [String] = []
        for (name, data) in documents {
            guard PortableShow.documentNames.contains(name) else { continue }
            var map: [String: String] = [:]
            let cleaned = try PortableShow.redact(data, idMap: &map)
            try cleaned.write(to: PortableShow.safeURL(name, under: staging), options: .atomic)
            paths.append(name)
        }
        if includeMedia {
            for item in media {
                guard item.access.isAccessible else { continue }
                let target = try PortableShow.safeURL(item.relativePath, under: staging)
                try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard (try item.access.url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { continue }
                try manager.copyItem(at: item.access.url, to: target)
                paths.append(item.relativePath)
                withExtendedLifetime(item.access) {}
            }
        }
        let files = try paths.sorted().map { try PortableShow.fileDescription(path: $0, root: staging) }
        let manifest = PortableShowManifest(name: name, includesMedia: includeMedia, files: files)
        try JSONEncoder().encode(manifest).write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)
        _ = try PortableShow.validate(at: staging)
        try manager.moveItem(at: staging, to: destination)
    }

    static func preview(_ url: URL) throws -> ShowPackagePreview {
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        let manifest = try PortableShow.validate(at: url)
        let sceneData = try Data(contentsOf: url.appendingPathComponent("stream.scenes.v2.json"))
        guard case .success(let migrated) = SceneDocumentMigration.migrateToCurrent(sceneData) else {
            throw PortableShow.Failure.invalid("The package scene version is not supported.")
        }
        let document = try JSONDecoder().decode(SceneDocument.self, from: migrated)
        guard !document.scenes.isEmpty, document.scenes.count <= 1000,
              Set(document.scenes.map(\.id)).count == document.scenes.count,
              document.sources.count <= 2000, Set(document.sources.map(\.id)).count == document.sources.count else {
            throw PortableShow.Failure.invalid("The package contains invalid or duplicate scene/source IDs.")
        }
        return ShowPackagePreview(url: url, name: manifest.name, sceneNames: document.scenes.map(\.name),
            includedMedia: manifest.includesMedia, fileCount: manifest.files.count)
    }

    static func importFiles(from source: URL, to destination: URL) throws {
        let grant = source.startAccessingSecurityScopedResource()
        defer { if grant { source.stopAccessingSecurityScopedResource() } }
        let manifest = try PortableShow.validate(at: source)
        let manager = FileManager.default
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".stream-import-\(UUID().uuidString)", isDirectory: true)
        defer { try? manager.removeItem(at: staging) }
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        var mapping: [String: String] = [:]
        for file in manifest.files.sorted(by: { $0.path < $1.path }) {
            let from = try PortableShow.safeURL(file.path, under: source)
            let importedPath = PortableShow.remapIDReferences(file.path, idMap: &mapping)
            let to = try PortableShow.safeURL(importedPath, under: staging)
            try manager.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            if PortableShow.documentNames.contains(file.path) {
                let data = try PortableShow.redact(Data(contentsOf: from), remappingIDs: true, idMap: &mapping)
                try data.write(to: to, options: .atomic)
            } else { try manager.copyItem(at: from, to: to) }
        }
        // Every imported destination needs an explicit credentials/enable step.
        let destinations = staging.appendingPathComponent("destinations.json")
        if let data = try? Data(contentsOf: destinations), var object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           var entries = object["destinations"] as? [[String: Any]] {
            for i in entries.indices { entries[i]["isEnabled"] = false; entries[i]["enabled"] = false }
            object["destinations"] = entries
            try JSONSerialization.data(withJSONObject: object).write(to: destinations, options: .atomic)
        }
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.moveItem(at: staging, to: destination)
    }
}
