import Foundation
import Observation

/// Persists sessions and publishes their summaries.
///
/// Foundation layout: one `<uuid>.json` file per session (the 1.0 format plus
/// the new optional fields) in the app's Documents/sessions directory, which
/// is visible in the Files app because UIFileSharingEnabled is set. Summaries
/// are derived while loading; WS-A swaps the internals for manifests plus a
/// binary journal without changing this API.
@MainActor
@Observable
final class SessionStore {
    enum StoreError: LocalizedError {
        case notFound
        case corruptSamples
        case io(String)

        var errorDescription: String? {
            switch self {
            case .notFound: return "Session not found"
            case .corruptSamples: return "Samples unavailable"
            case .io(let m): return m
            }
        }
    }

    private(set) var summaries: [SessionSummary] = []
    private(set) var loadError: String?
    private(set) var saveCount = 0
    private(set) var lastSaved: SessionSummary?
    /// A recording that was in progress when the app last quit. Always nil in
    /// the foundation layout (no journal); WS-A fills it from manifests.
    private(set) var interrupted: SessionSummary?
    /// Set by the app when a save requested through the recording hook fails.
    var saveError: String?

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let exportsDirectory: URL

    // Seconds-since-1970 keeps full sub-second precision (ISO8601 truncates to
    // whole seconds, which would break the 100 ms sample spacing on reload).
    nonisolated private static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }

    nonisolated private static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }

    init(directory: URL? = nil) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.directory = directory ?? docs.appendingPathComponent("sessions", isDirectory: true)
        self.exportsDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        // Exports are transient: start every launch with an empty folder.
        try? FileManager.default.removeItem(at: exportsDirectory)
        try? FileManager.default.createDirectory(at: exportsDirectory, withIntermediateDirectories: true)
        load()
    }

    // MARK: - Loading

    func load() {
        do {
            // No property keys requested: sorting uses the stored startTime,
            // so no file-timestamp privacy reason is needed.
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }
            let decoder = Self.makeDecoder()
            var loaded: [SessionSummary] = []
            var undecodable = 0
            for f in files {
                if let data = try? Data(contentsOf: f), let s = try? decoder.decode(Session.self, from: data) {
                    loaded.append(s.summary())
                } else {
                    undecodable += 1
                }
            }
            summaries = loaded.sorted { $0.startTime > $1.startTime }
            loadError = undecodable > 0 ? "\(undecodable) session file(s) could not be read" : nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Reads and decodes one session (including samples) off the main actor.
    func session(for id: UUID) async throws -> Session {
        let url = fileURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { throw StoreError.notFound }
        let task = Task.detached(priority: .userInitiated) { () throws -> Session in
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                throw StoreError.io(error.localizedDescription)
            }
            do {
                return try SessionStore.makeDecoder().decode(Session.self, from: data)
            } catch {
                throw StoreError.corruptSamples
            }
        }
        return try await task.value
    }

    func samples(for id: UUID) async throws -> [Reading] {
        try await session(for: id).readings
    }

    // MARK: - Writing

    func save(_ session: Session) throws {
        var s = session
        s.schemaVersion = Session.currentSchema
        let data: Data
        do {
            data = try Self.makeEncoder().encode(s)
            try data.write(to: fileURL(for: s.id), options: .atomic)
        } catch {
            throw StoreError.io(error.localizedDescription)
        }
        let summary = s.summary()
        replace(summary)
        lastSaved = summary
        saveCount += 1
        saveError = nil
    }

    func delete(id: UUID) {
        try? FileManager.default.removeItem(at: fileURL(for: id))
        summaries.removeAll { $0.id == id }
        if interrupted?.id == id { interrupted = nil }
    }

    func rename(id: UUID, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try modify(id: id) { $0.name = trimmed.isEmpty ? "Session" : trimmed }
    }

    /// Passing nil for a field leaves it unchanged.
    func update(id: UUID, notes: String?, tags: [String]?) throws {
        try modify(id: id) {
            if let notes { $0.notes = notes }
            if let tags { $0.tags = tags }
        }
    }

    /// Writes the CSV to a temporary exports folder (never into Documents)
    /// and returns its URL for `ShareLink`.
    func csvURL(for session: Session) throws -> URL {
        let safe = session.name.replacingOccurrences(of: "[^A-Za-z0-9_-]+", with: "_", options: .regularExpression)
        let base = safe.isEmpty ? "session" : safe
        let url = exportsDirectory.appendingPathComponent("\(base)_\(session.id.uuidString.prefix(8)).csv")
        do {
            try FileManager.default.createDirectory(at: exportsDirectory, withIntermediateDirectories: true)
            try session.csv().write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw StoreError.io(error.localizedDescription)
        }
        return url
    }

    // MARK: - Interrupted recordings

    /// Keeps the interrupted recording as a recovered session.
    func keepInterrupted() throws {
        guard var s = interrupted else { return }
        s.state = .recovered
        if !s.name.hasPrefix("Recovered: ") { s.name = "Recovered: " + s.name }
        try modify(id: s.id) { $0.name = s.name }
        replace(s)
        interrupted = nil
    }

    func discardInterrupted() {
        guard let s = interrupted else { return }
        delete(id: s.id)
        interrupted = nil
    }

    // MARK: - Internals

    private func modify(id: UUID, _ change: (inout Session) -> Void) throws {
        let url = fileURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { throw StoreError.notFound }
        var session: Session
        do {
            session = try Self.makeDecoder().decode(Session.self, from: Data(contentsOf: url))
        } catch {
            throw StoreError.corruptSamples
        }
        change(&session)
        session.schemaVersion = Session.currentSchema
        do {
            try Self.makeEncoder().encode(session).write(to: url, options: .atomic)
        } catch {
            throw StoreError.io(error.localizedDescription)
        }
        replace(session.summary())
    }

    private func replace(_ summary: SessionSummary) {
        summaries.removeAll { $0.id == summary.id }
        summaries.append(summary)
        summaries.sort { $0.startTime > $1.startTime }
    }

    private func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }
}
