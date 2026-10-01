import Foundation
import Testing
@testable import StreamCore

/// G06 (issue #113): the presentation page-state math — clamping,
/// next/previous/jump navigation (never wrapping), framing defaults, and the
/// persisted document's additive-wire behavior.
@Suite struct DeckPageStateTests {
    @Test("Pages clamp into the deck bounds")
    func clamping() {
        let state = DeckPageState(page: 7)
        #expect(state.clampedPage(pageCount: 10) == 7)
        #expect(state.clampedPage(pageCount: 5) == 4)
        #expect(state.clampedPage(pageCount: 1) == 0)
        #expect(DeckPageState(page: -3).clampedPage(pageCount: 10) == 0)
    }

    @Test("Unknown or empty page counts clamp only the lower bound")
    func unknownPageCount() {
        #expect(DeckPageState(page: 42).clampedPage(pageCount: nil) == 42)
        #expect(DeckPageState(page: -2).clampedPage(pageCount: nil) == 0)
        #expect(DeckPageState(page: 42).clampedPage(pageCount: 0) == 42)
    }

    @Test("Relative navigation clamps at both ends and never wraps")
    func advanceClamps() {
        let state = DeckPageState(page: 1)
        #expect(state.advanced(by: 1, pageCount: 3).page == 2)
        #expect(state.advanced(by: 1, pageCount: 3).advanced(by: 1, pageCount: 3).page == 2)
        #expect(state.advanced(by: -5, pageCount: 3).page == 0)
        // A second "previous" at the first page stays put (no wrap to last).
        #expect(DeckPageState(page: 0).advanced(by: -1, pageCount: 3).page == 0)
    }

    @Test("Advance without a known page count never goes below zero")
    func advanceUnknownCount() {
        #expect(DeckPageState(page: 2).advanced(by: 1, pageCount: nil).page == 3)
        #expect(DeckPageState(page: 0).advanced(by: -1, pageCount: nil).page == 0)
    }

    @Test("Jump navigation clamps like relative navigation")
    func jumpClamps() {
        let state = DeckPageState(page: 0)
        #expect(state.jumped(to: 4, pageCount: 10).page == 4)
        #expect(state.jumped(to: 99, pageCount: 10).page == 9)
        #expect(state.jumped(to: -1, pageCount: 10).page == 0)
    }

    @Test("Navigation preserves the framing choice")
    func framingPreserved() {
        let state = DeckPageState(page: 0, framing: .fill)
        #expect(state.advanced(by: 1, pageCount: 5).framing == .fill)
        #expect(state.jumped(to: 2, pageCount: 5).framing == .fill)
    }

    @Test("DeckPageState decodes with defaults (additive wire)")
    func additiveDecode() throws {
        let decoded = try JSONDecoder().decode(DeckPageState.self, from: Data("{}".utf8))
        #expect(decoded == DeckPageState(page: 0, framing: .fit))
    }
}

@Suite struct PresentationDeckDocumentTests {
    @Test("Documents decode with defaults and round-trip")
    func roundTrip() throws {
        let empty = try JSONDecoder().decode(PresentationDeckDocument.self,
                                             from: Data("{}".utf8))
        #expect(empty.version == 1)
        #expect(empty.decks.isEmpty)

        let document = PresentationDeckDocument(decks: [
            UUID().uuidString: DeckPageState(page: 3, framing: .fill),
            UUID().uuidString: DeckPageState(page: 0, framing: .fit),
        ])
        let data = try JSONEncoder().encode(document)
        let decoded = try JSONDecoder().decode(PresentationDeckDocument.self, from: data)
        #expect(decoded == document)
    }

    @Test("The document store round-trips through a temp file")
    func storeRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stream.presentations.test.\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = PresentationDeckDocumentStore(fileURL: url)
        #expect(store.load() == nil)
        let document = PresentationDeckDocument(decks: [
            "source-a": DeckPageState(page: 2, framing: .fill),
        ])
        store.save(document)
        #expect(store.load() == document)
    }

    @Test("A corrupt document is quarantined aside, never overwritten")
    func corruptQuarantine() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stream.presentations.test.\(UUID().uuidString).json")
        defer { Self.cleanUpArtifacts(of: url) }
        try Data("not json".utf8).write(to: url)
        let store = PresentationDeckDocumentStore(fileURL: url)
        #expect(store.load() == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    /// Removes the test document and any `.corrupt.*` quarantine siblings.
    private static func cleanUpArtifacts(of url: URL) {
        try? FileManager.default.removeItem(at: url)
        let directory = FileManager.default.temporaryDirectory
        let siblings = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        for sibling in siblings
        where sibling.lastPathComponent.hasPrefix(url.lastPathComponent + ".corrupt") {
            try? FileManager.default.removeItem(at: sibling)
        }
    }
}
