import Foundation

public struct StudioProfile: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public init(id: UUID = UUID(), name: String = "Default") { self.id = id; self.name = name }
}

public struct StudioProject: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var isArchived: Bool
    public var profiles: [StudioProfile]
    public init(id: UUID = UUID(), name: String, profiles: [StudioProfile] = [StudioProfile()]) {
        self.id = id; self.name = name; isArchived = false; self.profiles = profiles
    }
}

public struct StudioProjectCatalog: Codable, Equatable, Sendable {
    public var version = 1
    public var projects: [StudioProject]
    public var selectedProjectID: UUID
    public var selectedProfileID: UUID
    public init(project: StudioProject = StudioProject(name: "My Show")) {
        projects = [project]; selectedProjectID = project.id; selectedProfileID = project.profiles[0].id
    }
    public var validationError: String? {
        guard version == 1 else { return "This project catalog needs a different version of Stream." }
        guard !projects.isEmpty, projects.count <= 200,
              Set(projects.map(\.id)).count == projects.count else { return "The project catalog has invalid or duplicate projects." }
        for project in projects {
            guard Self.validName(project.name), !project.profiles.isEmpty, project.profiles.count <= 50,
                  Set(project.profiles.map(\.id)).count == project.profiles.count,
                  project.profiles.allSatisfy({ Self.validName($0.name) }) else { return "A project has invalid profiles or names." }
        }
        guard let selected = projects.first(where: { $0.id == selectedProjectID }),
              selected.profiles.contains(where: { $0.id == selectedProfileID }) else { return "The selected project or profile is missing." }
        return nil
    }
    public static func validName(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= 200 && !value.contains(where: \.isNewline)
    }
    public static func relativeDirectory(project: UUID, profile: UUID) -> String {
        "Projects/\(project.uuidString)/\(profile.uuidString)"
    }
}

/// Atomic local backups retain the last valid bytes before replacing a document.
/// No captured media is included; a missing/corrupt current file stays available
/// for inspection while callers can preview and explicitly restore a valid backup.
public enum ProjectDocumentHistory {
    public static let limit = 20
    public static func write(_ data: Data, to url: URL) throws {
        _ = try JSONSerialization.jsonObject(with: data)
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let backupDirectory = url.deletingLastPathComponent().appendingPathComponent("History/\(url.lastPathComponent)", isDirectory: true)
        if let old = try? Data(contentsOf: url), old != data,
           (try? JSONSerialization.jsonObject(with: old)) != nil {
            try manager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
            let order = String(format: "%020llu", DispatchTime.now().uptimeNanoseconds)
            let name = "\(Int64(Date().timeIntervalSince1970 * 1000))-\(order)-\(UUID().uuidString).json"
            try old.write(to: backupDirectory.appendingPathComponent(name), options: .atomic)
        }
        try data.write(to: url, options: .atomic)
        let backups = try validBackups(for: url)
        for backup in backups.dropFirst(limit) { try manager.removeItem(at: backup) }
    }

    public static func validBackups(for url: URL) throws -> [URL] {
        let directory = url.deletingLastPathComponent().appendingPathComponent("History/\(url.lastPathComponent)", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" && ((try? Data(contentsOf: $0)).flatMap { try? JSONSerialization.jsonObject(with: $0) }) != nil }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
}
