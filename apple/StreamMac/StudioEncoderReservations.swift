import Foundation

/// One studio-wide ledger includes countdown/preflight and writer finalization.
/// Reserving does not start capture, create a writer or partially start outputs.
struct StudioEncoderReservations: Sendable {
    var maximum = 4
    private(set) var recordings: [UUID: Int] = [:]
    var recordingCount: Int { recordings.values.reduce(0, +) }
    mutating func reserve(_ id: UUID, encoders: Int, publishing: Int) -> String? {
        let others = recordingCount - (recordings[id] ?? 0)
        guard encoders >= 1, encoders <= maximum, publishing >= 0, publishing <= maximum,
              others + encoders + publishing <= maximum else {
            return "Program, secondary recording, isolated video and publishers exceed the \(maximum)-encoder studio budget. Stop an output or reduce isolated tracks before starting."
        }
        recordings[id] = encoders
        return nil
    }
    mutating func release(_ id: UUID) { recordings[id] = nil }
    func publishingError(current: Int, starting: Int) -> String? {
        guard current >= 0, current <= maximum, starting >= 0, starting <= maximum,
              recordingCount + current + starting <= maximum else {
            return "The selected publishers exceed the encoder budget reserved by all studio recordings. Stop a recording or reduce destinations."
        }
        return nil
    }
}
