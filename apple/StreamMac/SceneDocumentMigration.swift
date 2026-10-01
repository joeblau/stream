import Foundation

// MARK: - Scene document migration pipeline (S12, issue #75)
//
// The version ladder as DATA: `steps` holds one closure per version hop, each
// turning JSON of version N into JSON of version N+1. Adding v3 is mechanical:
// decode the new fields with `decodeIfPresent` defaults (the established
// additive pattern), bump `SceneDocument.currentVersion`, and append ONE step
// here — `migrateToCurrent` walks whatever ladder a file needs.
//
// Steps work at the JSON-data level so an old file is upgraded without the
// current decoder ever touching old bytes: each hop decodes the legacy type
// for that version (kept frozen in SceneMigration.swift) and re-encodes at
// the next version.
//
// NEWER versions are refused, never guessed at: a file written by a future
// app comes back as `.newerThanSupported` and the caller (SceneStore)
// quarantines it aside unread rather than decoding a partial document and
// autosaving destruction over the user's data.
enum SceneDocumentMigration {
    /// One hop on the ladder: JSON of `fromVersion` → JSON of
    /// `fromVersion + 1`.
    struct Step: Sendable {
        let fromVersion: Int
        let migrate: @Sendable (Data) throws -> Data
    }

    enum MigrationError: Error, Equatable {
        /// The file was written by a NEWER app version than this build
        /// understands. Refusing preserves the data; decoding would not.
        case newerThanSupported(found: Int, supported: Int)
        /// The data is not decodable at the version it claims (corrupt or
        /// truncated write). `version` is nil when not even JSON.
        case unreadable(version: Int?)
    }

    /// The version this build writes and migrates up to.
    static var currentVersion: Int { SceneDocument.currentVersion }

    /// The ladder, in order. v1 → v2: the fixed-layout document becomes a
    /// layer graph (see SceneMigration.swift, which keeps the frozen v1
    /// types).
    static let steps: [Step] = [
        Step(fromVersion: 1, migrate: migrateV1toV2)
    ]

    /// Reads just the `version` field. Documents with no `version` key are
    /// v1 — the original format pre-dates versioning. Nil when the data is
    /// not a JSON object at all (corrupt/truncated).
    static func detectedVersion(of data: Data) -> Int? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else { return nil }
        guard let version = dictionary["version"] as? Int else { return 1 }
        return version
    }

    /// Brings JSON of ANY older supported version up to `currentVersion`,
    /// hop by hop. Current-version data passes through unchanged (the caller
    /// still validates it with a real decode). Older-than-v1 or
    /// newer-than-current versions fail without touching the data.
    static func migrateToCurrent(_ data: Data) -> Result<Data, MigrationError> {
        guard let version = detectedVersion(of: data) else {
            return .failure(.unreadable(version: nil))
        }
        guard version >= 1 else {
            return .failure(.unreadable(version: version))
        }
        guard version <= currentVersion else {
            return .failure(.newerThanSupported(found: version, supported: currentVersion))
        }
        var migrated = data
        var stepVersion = version
        while stepVersion < currentVersion {
            guard let step = steps.first(where: { $0.fromVersion == stepVersion }) else {
                // A hole in the ladder: refuse rather than skip a version.
                return .failure(.unreadable(version: stepVersion))
            }
            do {
                migrated = try step.migrate(migrated)
            } catch {
                return .failure(.unreadable(version: stepVersion))
            }
            stepVersion += 1
        }
        return .success(migrated)
    }

    /// v1 → v2: decode the frozen v1 wire type, build the equivalent layer
    /// graph (scene IDs, names, PIP corner/scale, and selection preserved —
    /// see `SceneDocument.init(migratingV1:)`), re-encode as v2 JSON.
    private static func migrateV1toV2(_ data: Data) throws -> Data {
        let legacy = try JSONDecoder().decode(LegacySceneDocumentV1.self, from: data)
        return try JSONEncoder().encode(SceneDocument(migratingV1: legacy))
    }
}
