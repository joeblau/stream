import AppKit
import CryptoKit
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
    let manifest: PortableShowManifest
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
            func copyMedia(_ source: URL, path: String) throws {
                let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true else {
                    throw PortableShow.Failure.invalid("Media contains a symbolic link. Replace it with a file copy before exporting.")
                }
                let target = try PortableShow.safeURL(path, under: staging)
                if values.isDirectory == true {
                    let children = try manager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
                    guard !children.isEmpty else {
                        throw PortableShow.Failure.invalid("Empty asset folders cannot be transferred. Use the relink-media policy instead.")
                    }
                    for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                        try copyMedia(child, path: path + "/" + child.lastPathComponent)
                    }
                } else {
                    guard values.isRegularFile == true else { throw PortableShow.Failure.invalid("Media must contain regular files only.") }
                    guard paths.count < 2000 else { throw PortableShow.Failure.invalid("A show package can contain at most 2,000 files.") }
                    try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try manager.copyItem(at: source, to: target)
                    paths.append(path)
                }
            }
            for item in media {
                guard item.access.isAccessible else { throw PortableShow.Failure.invalid("An included asset is no longer accessible. Relink it and export again.") }
                try copyMedia(item.access.url, path: item.relativePath)
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
        guard let sceneFile = manifest.files.first(where: { $0.path == "stream.scenes.v2.json" }) else {
            throw PortableShow.Failure.invalid("The package has no scene document.")
        }
        let sceneData = try readVerifiedDocument(sceneFile, root: url)
        guard case .success(let migrated) = SceneDocumentMigration.migrateToCurrent(sceneData) else {
            throw PortableShow.Failure.invalid("The package scene version is not supported.")
        }
        let document = try JSONDecoder().decode(SceneDocument.self, from: migrated)
        guard !document.scenes.isEmpty, document.scenes.count <= 1000,
              Set(document.scenes.map(\.id)).count == document.scenes.count,
              document.sources.count <= 2000, Set(document.sources.map(\.id)).count == document.sources.count else {
            throw PortableShow.Failure.invalid("The package contains invalid or duplicate scene/source IDs.")
        }
        if let assets = manifest.files.first(where: { $0.path == "stream.assets.v1.json" }) {
            try validateAssetReferences(readVerifiedDocument(assets, root: url), manifest: manifest, root: url)
        }
        return ShowPackagePreview(url: url, name: manifest.name, sceneNames: document.scenes.map(\.name),
            includedMedia: manifest.includesMedia, fileCount: manifest.files.count, manifest: manifest)
    }

    static func importFiles(from source: URL, to destination: URL, previewedManifest: PortableShowManifest? = nil) throws {
        let grant = source.startAccessingSecurityScopedResource()
        defer { if grant { source.stopAccessingSecurityScopedResource() } }
        let manifest = try PortableShow.validate(at: source)
        guard previewedManifest == nil || manifest == previewedManifest else {
            throw PortableShow.Failure.invalid("The package changed after its preview. Open it again before importing.")
        }
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
                let raw = try readVerifiedDocument(file, root: source)
                if file.path == "stream.assets.v1.json" { try validateAssetReferences(raw, manifest: manifest, root: source) }
                let data = try PortableShow.redact(raw, remappingIDs: true, idMap: &mapping)
                try data.write(to: to, options: .atomic)
            } else {
                try manager.copyItem(at: from, to: to)
                let copied = try PortableShow.fileDescription(path: importedPath, root: staging)
                guard copied.bytes == file.bytes, copied.sha256 == file.sha256 else {
                    throw PortableShow.Failure.invalid("The package changed while importing. Open it again before importing.")
                }
            }
        }
        // Every imported destination needs an explicit credentials/enable step.
        let destinations = staging.appendingPathComponent("destinations.json")
        if let data = try? Data(contentsOf: destinations), var entries = try? JSONDecoder().decode([StreamDestination].self, from: data) {
            for i in entries.indices { entries[i].isEnabled = false }
            try JSONEncoder().encode(entries).write(to: destinations, options: .atomic)
        }
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.moveItem(at: staging, to: destination)
    }

    private static func readVerifiedDocument(_ file: PortableShowManifest.File, root: URL) throws -> Data {
        let raw = try PortableShow.readDocument(at: PortableShow.safeURL(file.path, under: root))
        let checksum = SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()
        guard Int64(raw.count) == file.bytes, checksum == file.sha256 else {
            throw PortableShow.Failure.invalid("The package changed while reading. Open it again before importing.")
        }
        return raw
    }

    private static func validateAssetReferences(_ data: Data, manifest: PortableShowManifest, root: URL) throws {
        let library = try JSONDecoder().decode(AssetLibraryDocument.self, from: data)
        guard library.version == AssetLibraryDocument.currentVersion, library.assets.count <= 2000,
              Set(library.assets.map(\.id)).count == library.assets.count else {
            throw PortableShow.Failure.invalid("The package contains an unsupported asset library or duplicate asset IDs.")
        }
        for asset in library.assets where asset.storage == .projectCopy {
            guard manifest.includesMedia, let path = asset.relativePath, path.hasPrefix("Assets/") else {
                throw PortableShow.Failure.invalid("A copied asset must reference included package media.")
            }
            _ = try PortableShow.safeURL(path, under: root)
            guard manifest.files.contains(where: { $0.path == path || (asset.kind == .folder && $0.path.hasPrefix(path + "/")) }) else {
                throw PortableShow.Failure.invalid("A copied asset is missing from the package manifest: \(asset.fileName)")
            }
        }
    }
}
