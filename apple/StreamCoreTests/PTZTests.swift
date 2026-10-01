import Foundation
import Testing
@testable import StreamCore

/// Unit tests for the E06 PTZ core (issue #165): the VISCA wire format is
/// pinned byte-for-byte (a silent drift in framing would break every camera
/// in the compatibility matrix), and the document store round-trips through
/// a temp file with the established corrupt-file quarantine behavior.
@Suite struct PTZTests {

    // MARK: - VISCA packet encoding

    @Test("Pan-tilt drive encodes header, speeds, and direction bytes")
    func panTiltDriveEncoding() {
        let up = VISCAPacket.panTiltDrive(address: 1, direction: .up,
                                          panSpeed: 12, tiltSpeed: 10)
        #expect([UInt8](up) == [0x81, 0x01, 0x06, 0x01, 0x0C, 0x0A, 0x03, 0x01, 0xFF])

        let downRight = VISCAPacket.panTiltDrive(address: 2, direction: .downRight,
                                                 panSpeed: 24, tiltSpeed: 20)
        #expect([UInt8](downRight) == [0x82, 0x01, 0x06, 0x01, 0x18, 0x14, 0x02, 0x02, 0xFF])
    }

    @Test("Speeds clamp to the pinned compatibility ranges, never below 1")
    func speedClamping() {
        let fast = VISCAPacket.panTiltDrive(direction: .left, panSpeed: 200, tiltSpeed: 200)
        #expect([UInt8](fast)[4] == 0x18)  // pan clamps to 24
        #expect([UInt8](fast)[5] == 0x14)  // tilt clamps to 20

        let zero = VISCAPacket.panTiltDrive(direction: .right, panSpeed: 0, tiltSpeed: -3)
        #expect([UInt8](zero)[4] == 0x01)
        #expect([UInt8](zero)[5] == 0x01)
    }

    @Test("Camera address clamps into the 1...7 VISCA range in the header byte")
    func addressClamping() {
        #expect([UInt8](VISCAPacket.panTiltStop(address: 1))[0] == 0x81)
        #expect([UInt8](VISCAPacket.panTiltStop(address: 7))[0] == 0x87)
        #expect([UInt8](VISCAPacket.panTiltStop(address: 0))[0] == 0x81)
        #expect([UInt8](VISCAPacket.panTiltStop(address: 200))[0] == 0x87)
    }

    @Test("Pan-tilt stop drives both axes to the stationary byte")
    func panTiltStopEncoding() {
        #expect([UInt8](VISCAPacket.panTiltStop(address: 3))
            == [0x83, 0x01, 0x06, 0x01, 0x01, 0x01, 0x03, 0x03, 0xFF])
    }

    @Test("Zoom encodes speed in the opcode low nibble; stop is opcode 0x00")
    func zoomEncoding() {
        #expect([UInt8](VISCAPacket.zoom(direction: .tele, speed: 5))
            == [0x81, 0x01, 0x04, 0x07, 0x25, 0xFF])
        #expect([UInt8](VISCAPacket.zoom(direction: .wide, speed: 2))
            == [0x81, 0x01, 0x04, 0x07, 0x32, 0xFF])
        #expect([UInt8](VISCAPacket.zoom(direction: .tele, speed: 99))
            == [0x81, 0x01, 0x04, 0x07, 0x27, 0xFF])  // clamps to speed 7
        #expect([UInt8](VISCAPacket.zoomStop()) == [0x81, 0x01, 0x04, 0x07, 0x00, 0xFF])
    }

    @Test("CAM_Memory set/recall encode the slot, clamped to 0...89")
    func memoryEncoding() {
        #expect([UInt8](VISCAPacket.memorySet(preset: 3))
            == [0x81, 0x01, 0x04, 0x3F, 0x01, 0x03, 0xFF])
        #expect([UInt8](VISCAPacket.memoryRecall(preset: 3))
            == [0x81, 0x01, 0x04, 0x3F, 0x02, 0x03, 0xFF])
        #expect([UInt8](VISCAPacket.memoryRecall(preset: 200))[5] == 89)
    }

    // MARK: - VISCA reply parsing

    @Test("ACK, completion, and error replies parse with their socket")
    func replyParsing() {
        #expect(VISCAResponse.parse(Data([0x90, 0x41, 0xFF])) == .ack(socket: 1))
        #expect(VISCAResponse.parse(Data([0x90, 0x52, 0xFF])) == .completion(socket: 2))
        #expect(VISCAResponse.parse(Data([0x90, 0x61, 0x41, 0xFF])) == .error(socket: 1, code: 0x41))
    }

    @Test("Malformed frames parse as nil instead of misreading")
    func malformedReplies() {
        #expect(VISCAResponse.parse(Data()) == nil)
        #expect(VISCAResponse.parse(Data([0x80, 0x41, 0xFF])) == nil)   // wrong header
        #expect(VISCAResponse.parse(Data([0x90, 0x41, 0x00])) == nil)   // missing terminator
        #expect(VISCAResponse.parse(Data([0x90, 0x41, 0x00, 0xFF])) == nil)  // long ACK
        #expect(VISCAResponse.parse(Data([0x90, 0x61, 0xFF])) == nil)   // short error
        #expect(VISCAResponse.parse(Data([0x90, 0x71, 0xFF])) == nil)   // unknown class
    }

    @Test("Error codes carry plain-language descriptions")
    func errorDescriptions() {
        let error = VISCAResponse.parse(Data([0x90, 0x61, 0x41, 0xFF]))
        #expect(error?.errorDescription == "Command not executable")
        #expect(VISCAResponse.ack(socket: 1).errorDescription == nil)
    }

    // MARK: - Document model

    @Test("The PTZ document Codable round-trips targets, presets, and recall links")
    func documentRoundTrip() throws {
        let target = PTZTarget(name: "Stage Left", host: "192.168.1.50",
                               port: 1259, kind: .viscaOverUDP, cameraAddress: 2,
                               deviceUniqueID: "EAB7A68F-EC2D-4487-BADF-AF8DB187A921")
        let link = PTZSceneRecallLink(sceneID: UUID(), targetID: target.id,
                                      presetNumber: 1, recallOnProgramEntry: true)
        let document = PTZDocument(targets: [target],
                                   presets: [target.id: [PTZPreset(number: 1, name: "Host"),
                                                         PTZPreset(number: 2, name: "Wide")]],
                                   recallLinks: [link])
        let decoded = try JSONDecoder().decode(PTZDocument.self,
                                               from: JSONEncoder().encode(document))
        #expect(decoded == document)
    }

    @Test("Documents written before later fields existed decode with defaults")
    func additiveDecoding() throws {
        let json = #"{"targets":[{"name":"Cam","host":"10.0.0.5"}]}"#.data(using: .utf8)!
        let document = try JSONDecoder().decode(PTZDocument.self, from: json)
        #expect(document.version == 1)
        #expect(document.targets.count == 1)
        #expect(document.targets[0].kind == .viscaOverUDP)
        #expect(document.targets[0].port == PTZProtocolKind.viscaOverUDP.defaultPort)
        #expect(document.targets[0].cameraAddress == 1)
        #expect(document.presets.isEmpty)
        #expect(document.recallLinks.isEmpty)
    }

    // MARK: - Document store

    @Test("The document store saves and loads through a temp file")
    func storeRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ptz-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = PTZDocumentStore(fileURL: url)

        #expect(store.load() == nil)  // absent file loads as nil

        let target = PTZTarget(name: "Cam", host: "10.0.0.9")
        let document = PTZDocument(targets: [target],
                                   presets: [target.id: [PTZPreset(number: 0, name: "Home")]])
        store.save(document)
        #expect(store.load() == document)
    }

    @Test("A corrupt file is quarantined aside, never overwritten or crash-looped")
    func corruptFileQuarantine() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ptz-test-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: url)
            for sibling in (try? FileManager.default.contentsOfDirectory(
                at: FileManager.default.temporaryDirectory,
                includingPropertiesForKeys: nil
            )) ?? [] where sibling.lastPathComponent.hasPrefix(url.lastPathComponent + ".") {
                try? FileManager.default.removeItem(at: sibling)
            }
        }
        try Data("not json".utf8).write(to: url)
        let store = PTZDocumentStore(fileURL: url)
        #expect(store.load() == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path),
                "the unreadable file moved aside instead of being left to fail forever")
    }
}
