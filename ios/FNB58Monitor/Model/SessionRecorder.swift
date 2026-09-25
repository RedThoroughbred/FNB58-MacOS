import Foundation
import Observation

/// Accumulates readings for one recording session.
@Observable
final class SessionRecorder {
    let id = UUID()
    let name: String
    let deviceName: String?
    let startTime = Date()
    private(set) var stats = SessionStats()
    private(set) var readings: [Reading] = []

    init(name: String, deviceName: String?) {
        self.name = name.trimmingCharacters(in: .whitespaces)
        self.deviceName = deviceName
    }

    var elapsed: TimeInterval { Date().timeIntervalSince(startTime) }

    func add(_ r: Reading) {
        readings.append(r)
        stats.add(r)
    }

    func finish() -> Session {
        Session(id: id,
                name: name.isEmpty ? "Session" : name,
                startTime: startTime,
                endTime: Date(),
                deviceName: deviceName,
                stats: stats,
                readings: readings)
    }
}

/// Persists sessions as JSON files in the app's Documents directory (visible in
/// the Files app because UIFileSharingEnabled is set).
@Observable
final class SessionStore {
    private(set) var sessions: [Session] = []
    private(set) var loadError: String?

    private let directory: URL
    // Seconds-since-1970 keeps full sub-second precision (ISO8601 truncates to
    // whole seconds, which would break the 10 ms sample spacing on reload).
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    init(directory: URL? = nil) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.directory = directory ?? docs.appendingPathComponent("sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        load()
    }

    func load() {
        do {
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }
            var loaded: [Session] = []
            for f in files {
                if let s = try? decoder.decode(Session.self, from: Data(contentsOf: f)) {
                    loaded.append(s)
                }
            }
            sessions = loaded.sorted { $0.startTime > $1.startTime }
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    func save(_ session: Session) throws {
        let data = try encoder.encode(session)
        try data.write(to: url(for: session), options: .atomic)
        sessions.removeAll { $0.id == session.id }
        sessions.insert(session, at: 0)
        sessions.sort { $0.startTime > $1.startTime }
    }

    func delete(_ session: Session) {
        try? FileManager.default.removeItem(at: url(for: session))
        sessions.removeAll { $0.id == session.id }
    }

    /// Writes a CSV next to the JSON and returns its URL for the share sheet.
    func csvURL(for session: Session) throws -> URL {
        let safe = session.name.replacingOccurrences(of: "[^A-Za-z0-9_-]+", with: "_", options: .regularExpression)
        let url = directory.appendingPathComponent("\(safe)_\(session.id.uuidString.prefix(8)).csv")
        try session.csv().write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func url(for session: Session) -> URL {
        directory.appendingPathComponent("\(session.id.uuidString).json")
    }
}
