import Foundation
import Testing
@testable import StreamCore

@Suite struct DestinationTests {
    @Test("Renaming and duplicating retain identity isolation and never enable a copy")
    func identity() {
        var source = StreamDestination(name: "Primary", transport: .srt)
        let id = source.id
        source.name = "Renamed"
        #expect(source.id == id)
        let copy = source.duplicated()
        #expect(copy.id != source.id)
        #expect(!copy.isEnabled)
        #expect(KeychainStore.Item.destination(id, field: .endpoint).account !=
                KeychainStore.Item.destination(copy.id, field: .endpoint).account)
        #expect(KeychainStore.Item.destination(id, field: .streamKey).account ==
                "stream.destination.\(id.uuidString.lowercased()).streamKey")
    }

    @Test("Project destination metadata does not serialize connection credentials")
    func projectRedaction() throws {
        let destination = StreamDestination(name: "Safe", transport: .srt)
        let json = String(decoding: try JSONEncoder().encode(destination), as: UTF8.self)
        #expect(!json.contains("endpoint"))
        #expect(!json.contains("passphrase"))
        #expect(!json.contains("streamKey"))
        #expect(try JSONDecoder().decode(StreamDestination.self, from: Data(json.utf8)) == destination)
    }

    @Test("Protocol fields reject wrong schemes, missing SRT port, short passphrase and listener mode")
    func validation() {
        let srt = StreamDestination(name: "SRT", transport: .srt)
        #expect(DestinationValidator.errors(srt, credentials: .init(endpoint: "rtmp://host/live")).count == 2)
        #expect(DestinationValidator.errors(srt, credentials: .init(endpoint: "srt://host")).contains { $0.contains("port") })
        #expect(DestinationValidator.errors(srt, credentials: .init(endpoint: "srt://host:9000", srtPassphrase: "short")).contains { $0.contains("10–79") })
        #expect(DestinationValidator.errors(srt, credentials: .init(endpoint: "srt://host:9000?mode=listener")).contains { $0.contains("caller") })
        #expect(DestinationValidator.errors(srt, credentials: .init(endpoint: "srt://host:9000", srtPassphrase: "abcdefghij")).isEmpty)
        let whip = StreamDestination(name: "WHIP", transport: .whip)
        #expect(DestinationValidator.errors(whip, credentials: .init(endpoint: "https://host")).contains { $0.contains("path") })
    }

    @Test("SRT explicit secrets are escaped and replace matching query values without losing vendor fields")
    func srtURL() throws {
        let credentials = DestinationCredentials(endpoint: "srt://host:9000?streamid=old&latency=120",
                                                 srtStreamID: "#!::r=show,a+b&c", srtPassphrase: "long&secret=abc")
        let url = try #require(URLComponents(string: credentials.publishingURL(for: .srt)))
        #expect(url.queryItems?.filter { $0.name == "streamid" }.count == 1)
        #expect(url.queryItems?.first { $0.name == "streamid" }?.value == credentials.srtStreamID)
        #expect(url.queryItems?.first { $0.name == "latency" }?.value == "120")
        #expect(url.queryItems?.first { $0.name == "passphrase" }?.value == credentials.srtPassphrase)
    }

    @Test("Unsupported codec blocks start and one profile cannot mutate the program base")
    func independentProfile() {
        var destination = StreamDestination(name: "WHIP", transport: .whip, followsProgramProfile: false,
                                            outputProfile: .init(canvasWidth: 1920, canvasHeight: 1080, frameRate: 30), videoCodec: .hevc)
        let credentials = DestinationCredentials(endpoint: "https://host/whip")
        let hardware = OutputCapabilities(hardwareTier: .uhd4K, hardwareMaxFrameRate: 60)
        #expect(DestinationValidator.startErrors(destination, credentials: credentials, program: .default, capabilities: hardware).contains { $0.contains("does not support") })
        destination.videoCodec = .h264
        let base = StreamSettings.default
        let output = DestinationValidator.settings(destination, credentials: credentials, base: base)
        #expect(output.outputProfile == destination.outputProfile)
        #expect(base.outputProfile == .default)
    }

    @Test("A saved empty list is retained; corrupt metadata is never overwritten during migration")
    func fileIntegrity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("destinations.json")
        let store = DestinationStore(fileURL: url)
        try store.save([], credentials: [:])
        let migrated = try store.migrateLegacyIfNeeded(settings: .default) { _ in ("rtmps://host/live", "secret") }
        #expect(migrated.isEmpty)
        let corrupt = Data("unknown version".utf8)
        try corrupt.write(to: url)
        #expect(throws: (any Error).self) {
            _ = try store.migrateLegacyIfNeeded(settings: .default) { _ in ("", "") }
        }
        #expect(try Data(contentsOf: url) == corrupt)
    }

    @Test("Legacy credentials migrate by stable ID once and removal clears only the removed destination", .enabled(if: KeychainAvailability.isWritable))
    func migration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let keychain = KeychainStore(service: "com.joeblau.Stream.tests.destinations.\(UUID().uuidString)")
        let store = DestinationStore(fileURL: directory.appendingPathComponent("destinations.json"), keychain: keychain)
        defer {
            try? store.save([], credentials: [:])
            try? FileManager.default.removeItem(at: directory)
        }
        let saved = try store.migrateLegacyIfNeeded(settings: .default) { transport in
            transport == .rtmps ? ("rtmps://host/live", "secret") : ("", "")
        }
        #expect(saved.count == 1)
        let original = try #require(saved.first)
        #expect(store.credentials(for: original.id).streamKey == "secret")
        let again = try store.migrateLegacyIfNeeded(settings: .default) { _ in ("new", "new") }
        #expect(again == saved)
        let copy = original.duplicated()
        try store.save([original, copy], credentials: [copy.id: store.credentials(for: original.id)])
        try store.save([copy], credentials: [:])
        #expect(store.credentials(for: original.id).endpoint.isEmpty)
        #expect(store.credentials(for: copy.id).streamKey == "secret")
    }
}
