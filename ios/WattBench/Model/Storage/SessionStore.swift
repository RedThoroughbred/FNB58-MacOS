import Foundation
import Observation

/// Persists sessions and publishes their summaries.
///
/// Layout: one folder per session in the app's Documents/sessions directory
/// (visible in the Files app because UIFileSharingEnabled is set):
/// `<uuid>/manifest.json` (a `SessionSummary`) plus `<uuid>/samples.wbj` (a
/// `RecordingJournal`). Loading reads manifests only; samples are decoded on
/// demand off the main actor. 1.0 `<uuid>.json` files are migrated on first
/// load by `LegacyMigration`.
///
/// Robustness rules: a folder without a manifest is rebuilt from its journal;
/// a manifest without a journal is still listed (its samples read as
/// `StoreError.corruptSamples`); unknown files are ignored; a manifest left in
/// state `.recording` by a crash or force-quit is sealed into `interrupted`
/// for the recovery prompt and never auto-resumed.
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
    /// A recording that was in progress when the app last quit, sealed from
    /// its journal. `keepInterrupted()` / `discardInterrupted()` resolve it.
    private(set) var interrupted: SessionSummary?
    /// Legacy files still being migrated in the background (0 when idle).
    private(set) var migrating = 0
    /// Set by the app when a save requested through the recording hook fails.
    var saveError: String?

    /// The sessions directory; recorders create their folders inside it.
    let directory: URL
    @ObservationIgnored private let exportsDirectory: URL
    /// 1.0 files that could not be migrated, still served from their JSON.
    @ObservationIgnored private var legacyFiles: [UUID: URL] = [:]
    @ObservationIgnored private var didScanForInterrupted = false
    @ObservationIgnored private var migrationTask: Task<Void, Never>?

    /// `Documents/sessions`: where the app keeps its recordings (and where
    /// `MeterManager` journals a recording in progress).
    nonisolated static var defaultDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return docs.appendingPathComponent("sessions", isDirectory: true)
    }

    init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory
        self.exportsDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        // Exports are transient: start every launch with an empty folder.
        try? FileManager.default.removeItem(at: exportsDirectory)
        try? FileManager.default.createDirectory(at: exportsDirectory, withIntermediateDirectories: true)
        load()
    }

    // MARK: - Loading

    /// Reads every manifest (never the samples). The first load also seals
    /// interrupted recordings and migrates legacy files.
    func load() {
        let fm = FileManager.default
        let items: [URL]
        do {
            // No property keys requested: sorting uses the stored startTime,
            // so no file-timestamp privacy reason is needed.
            items = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        } catch {
            loadError = error.localizedDescription
            return
        }

        var loaded: [SessionSummary] = []
        var problems: [String] = []
        let firstScan = !didScanForInterrupted
        didScanForInterrupted = true

        for item in items {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: item.path, isDirectory: &isDirectory), isDirectory.boolValue,
                  let id = SessionFolder.id(of: item) else { continue }
            switch Self.loadFolder(item, id: id) {
            case .listed(let s):
                loaded.append(s)
            case .inProgress(let s):
                if firstScan {
                    if let sealed = Self.sealInterrupted(s, folder: item) {
                        if interrupted == nil {
                            interrupted = sealed
                        } else if (try? SessionFolder.writeManifest(sealed, in: item)) != nil {
                            // Only one prompt is shown; any further interrupted
                            // recording is kept as recovered (never dropped).
                            loaded.append(sealed)
                        }
                    } else {
                        // Nothing was written: no samples to keep.
                        try? fm.removeItem(at: item)
                    }
                }
                // Later loads: the folder belongs to the live recorder (or to
                // the pending recovery prompt); it is listed once resolved.
            case .empty:
                try? fm.removeItem(at: item)
            case .failed(let reason):
                problems.append("\(id.uuidString.prefix(8)): \(reason)")
            }
        }

        // Legacy 1.0 files (root <uuid>.json).
        let legacy = LegacyMigration.legacyFiles(in: directory)
        if legacy.count <= LegacyMigration.synchronousLimit {
            for file in legacy {
                let outcome = LegacyMigration.migrate(file, in: directory)
                if let s = outcome.summary { loaded.append(s) }
                if let problem = Self.problem(for: outcome) { problems.append(problem) }
                if case .kept = outcome.status, let s = outcome.summary { legacyFiles[s.id] = file }
            }
        } else if migrationTask == nil {
            startBackgroundMigration(of: legacy)
        }

        summaries = loaded.sorted { $0.startTime > $1.startTime }
        loadError = problems.isEmpty ? nil : problems.joined(separator: "\n")
    }

    /// Reads and decodes one session (including samples) off the main actor.
    func session(for id: UUID) async throws -> Session {
        if let legacy = legacyFiles[id] {
            return try await Self.readLegacy(legacy)
        }
        let folder = SessionFolder.url(for: id, in: directory)
        guard FileManager.default.fileExists(atPath: SessionFolder.manifestURL(in: folder).path) else {
            throw StoreError.notFound
        }
        let task = Task.detached(priority: .userInitiated) { () throws -> Session in
            let manifest: SessionSummary
            do {
                manifest = try SessionFolder.readManifest(in: folder)
            } catch {
                throw StoreError.io(error.localizedDescription)
            }
            let readings = try SessionStore.readSamples(in: folder)
            return SessionStore.session(from: manifest, readings: readings)
        }
        return try await task.value
    }

    /// Decodes just the samples of one session off the main actor.
    func samples(for id: UUID) async throws -> [Reading] {
        if let legacy = legacyFiles[id] {
            return try await Self.readLegacy(legacy).readings
        }
        let folder = SessionFolder.url(for: id, in: directory)
        guard FileManager.default.fileExists(atPath: SessionFolder.manifestURL(in: folder).path) else {
            throw StoreError.notFound
        }
        let task = Task.detached(priority: .userInitiated) { () throws -> [Reading] in
            try SessionStore.readSamples(in: folder)
        }
        return try await task.value
    }

    // MARK: - Writing

    /// Writes the session. When `samples.wbj` already exists (the session came
    /// from a recorder) only the manifest is written; otherwise (imports,
    /// tests, legacy) both files are.
    func save(_ session: Session) throws {
        var s = session
        s.schemaVersion = Session.currentSchema
        let folder = SessionFolder.url(for: s.id, in: directory)
        let fm = FileManager.default
        var summary = s.summary()
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let samplesURL = SessionFolder.samplesURL(in: folder)
            if fm.fileExists(atPath: samplesURL.path) {
                summary.sampleCount = max(summary.sampleCount, RecordingJournal.count(url: samplesURL))
            } else {
                try SessionFolder.writeSamples(s.readings, startEpoch: s.startTime, in: folder)
            }
            try SessionFolder.writeManifest(summary, in: folder)
        } catch {
            throw StoreError.io(error.localizedDescription)
        }
        if let legacy = legacyFiles.removeValue(forKey: s.id) {
            try? fm.removeItem(at: legacy)
        }
        replace(summary)
        if interrupted?.id == s.id { interrupted = nil }
        lastSaved = summary
        saveCount += 1
        saveError = nil
    }

    /// Removes the session's folder (and a legacy file, if that is where it lived).
    func delete(id: UUID) {
        let fm = FileManager.default
        try? fm.removeItem(at: SessionFolder.url(for: id, in: directory))
        if let legacy = legacyFiles.removeValue(forKey: id) {
            try? fm.removeItem(at: legacy)
        }
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
            try session.writeCSV(to: url)
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
        do {
            try SessionFolder.writeManifest(s, in: SessionFolder.url(for: s.id, in: directory))
        } catch {
            throw StoreError.io(error.localizedDescription)
        }
        replace(s)
        interrupted = nil
        lastSaved = s
        saveCount += 1
    }

    func discardInterrupted() {
        guard let s = interrupted else { return }
        delete(id: s.id)
        interrupted = nil
    }

    // MARK: - Folder loading (nonisolated helpers)

    private enum FolderResult {
        case listed(SessionSummary)
        /// Manifest state `.recording`: a live recorder or an interrupted one.
        case inProgress(SessionSummary)
        /// No manifest and no samples.
        case empty
        case failed(String)
    }

    nonisolated private static func loadFolder(_ folder: URL, id: UUID) -> FolderResult {
        let fm = FileManager.default
        let hasManifest = fm.fileExists(atPath: SessionFolder.manifestURL(in: folder).path)
        let samplesURL = SessionFolder.samplesURL(in: folder)
        let hasSamples = fm.fileExists(atPath: samplesURL.path)

        if hasManifest {
            do {
                var s = try SessionFolder.readManifest(in: folder)
                s.id = id
                return s.state == .recording ? .inProgress(s) : .listed(s)
            } catch {
                guard hasSamples else { return .failed("manifest unreadable: \(error.localizedDescription)") }
                // Fall through: rebuild from the journal.
            }
        } else if !hasSamples {
            return .empty
        }

        // Missing or unreadable manifest with a journal: rebuild and persist.
        do {
            let (start, readings) = try RecordingJournal.read(url: samplesURL)
            let placeholder = SessionSummary(id: id, name: "Session", startTime: start, endTime: start,
                                             deviceName: nil, stats: SessionStats(), sampleCount: 0, markers: [],
                                             tags: [], notes: nil, autoStopReason: nil, isDemo: false,
                                             state: .recovered, sparkline: [])
            var rebuilt = seal(placeholder, readings: readings)
            rebuilt.name = "Recovered session"
            try SessionFolder.writeManifest(rebuilt, in: folder)
            return .listed(rebuilt)
        } catch {
            return .failed("no manifest and journal unreadable: \(error.localizedDescription)")
        }
    }

    /// Seals a recording left in progress: statistics, gap markers, end time
    /// and sparkline are replayed from the journal. Nil when the journal
    /// holds no samples (nothing to recover).
    nonisolated private static func sealInterrupted(_ manifest: SessionSummary, folder: URL) -> SessionSummary? {
        guard let (_, readings) = try? RecordingJournal.read(url: SessionFolder.samplesURL(in: folder)),
              !readings.isEmpty else { return nil }
        var sealed = seal(manifest, readings: readings)
        if !sealed.name.hasPrefix("Recovered: ") { sealed.name = "Recovered: " + sealed.name }
        return sealed
    }

    /// Replays `readings` into a copy of `manifest`.
    nonisolated static func seal(_ manifest: SessionSummary, readings: [Reading]) -> SessionSummary {
        var s = manifest
        var stats = SessionStats()
        var gaps: [Marker] = []
        for r in readings {
            let dt = stats.dt(to: r)
            stats.add(r, dt: dt)
            if dt > SessionStats.maxGapS {
                gaps.append(Marker(timestamp: r.timestamp, label: SessionRecorder.gapLabel(dt), kind: .gap))
            }
        }
        s.stats = stats
        s.sampleCount = readings.count
        s.markers = manifest.markers.filter { $0.kind != .gap } + gaps
        s.markers.sort { $0.timestamp < $1.timestamp }
        if let last = readings.last { s.endTime = last.timestamp }
        s.sparkline = Decimator.meanPower(readings[...], targetCount: SessionSummary.sparklineCount)
        s.state = .recovered
        s.schemaVersion = Session.currentSchema
        return s
    }

    nonisolated private static func readSamples(in folder: URL) throws -> [Reading] {
        let url = SessionFolder.samplesURL(in: folder)
        guard FileManager.default.fileExists(atPath: url.path) else { throw StoreError.corruptSamples }
        do {
            return try RecordingJournal.read(url: url).readings
        } catch {
            throw StoreError.corruptSamples
        }
    }

    nonisolated private static func session(from m: SessionSummary, readings: [Reading]) -> Session {
        Session(schemaVersion: m.schemaVersion, id: m.id, name: m.name, startTime: m.startTime, endTime: m.endTime,
                deviceName: m.deviceName, stats: m.stats, readings: readings, markers: m.markers, tags: m.tags,
                notes: m.notes, autoStopReason: m.autoStopReason, isDemo: m.isDemo, sparkline: m.sparkline)
    }

    nonisolated private static func readLegacy(_ url: URL) async throws -> Session {
        let task = Task.detached(priority: .userInitiated) { () throws -> Session in
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                throw StoreError.io(error.localizedDescription)
            }
            do {
                return try SessionFolder.decoder().decode(Session.self, from: data)
            } catch {
                throw StoreError.corruptSamples
            }
        }
        return try await task.value
    }

    nonisolated private static func problem(for outcome: LegacyMigration.Outcome) -> String? {
        let name = outcome.file.lastPathComponent
        switch outcome.status {
        case .migrated: return nil
        case .kept(let reason): return "\(name) could not be migrated (\(reason)); kept as is"
        case .unreadable(let reason): return "\(name) could not be read (\(reason))"
        }
    }

    // MARK: - Background migration (more than a handful of legacy files)

    private func startBackgroundMigration(of files: [URL]) {
        migrating = files.count
        let directory = self.directory
        // The task itself stays on the main actor; each file is migrated on a
        // detached utility task and its outcome applied here.
        migrationTask = Task { [weak self] in
            for file in files {
                let outcome = await Self.migrateDetached(file, in: directory)
                guard let self else { return }
                self.apply(outcome)
            }
            self?.migrationTask = nil
        }
    }

    nonisolated private static func migrateDetached(_ file: URL, in directory: URL) async -> LegacyMigration.Outcome {
        await Task.detached(priority: .utility) {
            LegacyMigration.migrate(file, in: directory)
        }.value
    }

    private func apply(_ outcome: LegacyMigration.Outcome) {
        migrating = max(0, migrating - 1)
        if let s = outcome.summary {
            if case .kept = outcome.status { legacyFiles[s.id] = outcome.file }
            replace(s)
        }
        if let problem = Self.problem(for: outcome) {
            loadError = [loadError, problem].compactMap { $0 }.joined(separator: "\n")
        }
    }

    // MARK: - Internals

    private func modify(id: UUID, _ change: (inout SessionSummary) -> Void) throws {
        if let legacy = legacyFiles[id] {
            try modifyLegacy(legacy, change)
            return
        }
        let folder = SessionFolder.url(for: id, in: directory)
        guard FileManager.default.fileExists(atPath: SessionFolder.manifestURL(in: folder).path) else {
            throw StoreError.notFound
        }
        var summary: SessionSummary
        do {
            summary = try SessionFolder.readManifest(in: folder)
        } catch {
            throw StoreError.io(error.localizedDescription)
        }
        change(&summary)
        summary.schemaVersion = Session.currentSchema
        do {
            try SessionFolder.writeManifest(summary, in: folder)
        } catch {
            throw StoreError.io(error.localizedDescription)
        }
        replace(summary)
    }

    /// An unmigrated 1.0 file is edited in place (its samples stay inline).
    private func modifyLegacy(_ url: URL, _ change: (inout SessionSummary) -> Void) throws {
        var session: Session
        do {
            session = try SessionFolder.decoder().decode(Session.self, from: Data(contentsOf: url))
        } catch {
            throw StoreError.corruptSamples
        }
        var summary = session.summary()
        change(&summary)
        session.name = summary.name
        session.notes = summary.notes
        session.tags = summary.tags
        do {
            try SessionFolder.encoder().encode(session).write(to: url, options: .atomic)
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
}
