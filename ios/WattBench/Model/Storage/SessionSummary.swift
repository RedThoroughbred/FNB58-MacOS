import Foundation

/// Everything the Sessions list needs without touching samples. Persisted as
/// the per-session manifest (`Documents/sessions/<uuid>/manifest.json`).
struct SessionSummary: Codable, Identifiable, Equatable {
    enum State: String, Codable { case recording, complete, recovered }

    /// Number of points kept in `sparkline`.
    static let sparklineCount = 60

    var schemaVersion: Int = Session.currentSchema
    var id: UUID
    var name: String
    var startTime: Date
    var endTime: Date
    var deviceName: String?
    var stats: SessionStats
    var sampleCount: Int
    var markers: [Marker]
    var tags: [String]
    var notes: String?
    var autoStopReason: String?
    var isDemo: Bool
    var state: State
    /// Mean power per bucket, at most `sparklineCount` values.
    var sparkline: [Float]

    /// Wall-clock span; `stats.durationS` is the active duration.
    var duration: TimeInterval { endTime.timeIntervalSince(startTime) }
}

/// Layout of one session on disk and the shared manifest coding. Every
/// reader and writer of a session folder (store, recorder, migration) goes
/// through here so the format lives in one place.
///
///     Documents/sessions/<uuid>/manifest.json   SessionSummary
///     Documents/sessions/<uuid>/samples.wbj     RecordingJournal
enum SessionFolder {
    static let manifestName = "manifest.json"
    static let samplesName = "samples.wbj"

    static func url(for id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    static func manifestURL(in folder: URL) -> URL {
        folder.appendingPathComponent(manifestName)
    }

    static func samplesURL(in folder: URL) -> URL {
        folder.appendingPathComponent(samplesName)
    }

    /// The session id a folder name encodes, if it is one of ours.
    static func id(of folder: URL) -> UUID? {
        UUID(uuidString: folder.lastPathComponent)
    }

    // Seconds-since-1970 keeps full sub-second precision (ISO8601 truncates
    // to whole seconds). The same strategy reads 1.0 files.
    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }

    /// Writes the manifest atomically (a crash mid-write leaves the old one).
    static func writeManifest(_ summary: SessionSummary, in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try encoder().encode(summary)
        try data.write(to: manifestURL(in: folder), options: .atomic)
    }

    static func readManifest(in folder: URL) throws -> SessionSummary {
        let data = try Data(contentsOf: manifestURL(in: folder))
        return try decoder().decode(SessionSummary.self, from: data)
    }

    /// Writes a complete journal from in-memory readings (imports, tests,
    /// legacy migration). Offsets are taken from the readings' wall-clock
    /// timestamps relative to `startEpoch`, never from monotonic stamps,
    /// which belong to the process that produced them.
    static func writeSamples(_ readings: [Reading], startEpoch: Date, in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try RecordingJournal.write(readings, startEpoch: startEpoch, to: samplesURL(in: folder))
    }
}
