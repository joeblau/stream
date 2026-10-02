import Foundation
import Testing
@testable import StreamCore

@Suite struct StudioProjectsTests {
    @Test func catalogRejectsFutureDuplicateAndMissingSelections() throws {
        var catalog = StudioProjectCatalog()
        let encoded = try JSONEncoder().encode(catalog)
        #expect(try JSONDecoder().decode(StudioProjectCatalog.self, from: encoded) == catalog)
        catalog.version = 2
        #expect(catalog.validationError != nil)
        catalog.version = 1
        catalog.projects.append(catalog.projects[0])
        #expect(catalog.validationError != nil)
        catalog.projects.removeLast()
        catalog.selectedProfileID = UUID()
        #expect(catalog.validationError != nil)
        #expect(!StudioProjectCatalog.validName("\n"))
        #expect(!StudioProjectCatalog.validName(String(repeating: "x", count: 201)))
    }

    @Test func historyPreservesValidStateAndIgnoresCorruptSnapshots() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("show.json")
        try ProjectDocumentHistory.write(Data("{\"version\":1}".utf8), to: url)
        try ProjectDocumentHistory.write(Data("{\"version\":2}".utf8), to: url)
        let backup = try #require(ProjectDocumentHistory.validBackups(for: url).first)
        #expect(try Data(contentsOf: backup) == Data("{\"version\":1}".utf8))
        try Data("truncated".utf8).write(to: backup)
        #expect(try ProjectDocumentHistory.validBackups(for: url).isEmpty)
        #expect(throws: (any Error).self) { try ProjectDocumentHistory.write(Data("bad".utf8), to: url) }
        #expect(try Data(contentsOf: url) == Data("{\"version\":2}".utf8))
    }

    @Test func historyIsBoundedAndNeverCopiesUnchangedDocuments() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("show.json")
        for n in 0..<30 { try ProjectDocumentHistory.write(Data("{\"n\":\(n)}".utf8), to: url) }
        let newest = try #require(ProjectDocumentHistory.validBackups(for: url).first)
        #expect(try Data(contentsOf: newest) == Data("{\"n\":28}".utf8))
        #expect(try ProjectDocumentHistory.validBackups(for: url).count == ProjectDocumentHistory.limit)
        try ProjectDocumentHistory.write(Data("{\"n\":29}".utf8), to: url)
        #expect(try ProjectDocumentHistory.validBackups(for: url).count == ProjectDocumentHistory.limit)
    }
}
