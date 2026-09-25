import Foundation
import Observation

/// Accumulates statistics, markers and a 1 Hz mean-power series for one
/// recording, evaluates the auto-stop rule and streams every sample into a
/// `RecordingJournal`.
///
/// With a `directory`, the recorder owns `<directory>/<id>/`: it writes
/// `manifest.json` (state `.recording`) BEFORE opening `samples.wbj`, rewrites
/// the manifest atomically every `checkpointInterval` seconds, and keeps no
/// samples in memory (a 4-hour recording holds at most one flush buffer).
/// Without a directory (tests, previews) samples stay in `readings` so
/// `finish()` can still produce a complete session.
@MainActor
@Observable
final class SessionRecorder {
    static let defaultCheckpointInterval: TimeInterval = 10

    let id = UUID()
    let name: String
    let deviceName: String?
    let tags: [String]
    let notes: String?
    let isDemo: Bool
    let startTime = Date()
    /// `MonotonicClock` stamp taken together with `startTime`; journal
    /// offsets are measured from it.
    let monotonicStart = MonotonicClock.now
    private(set) var stats = SessionStats()
    /// In-memory samples; empty whenever a journal is attached.
    private(set) var readings: [Reading] = []
    private(set) var markers: [Marker] = []
    /// Mean power for each second since the first sample (0 for seconds
    /// without samples).
    private(set) var sparkline: [Float] = []
    var autoStop: AutoStopRule?
    /// Set once the auto-stop rule fires.
    private(set) var autoStopReason: AutoStopRule.Reason?

    /// The sample file, when recording into a folder.
    @ObservationIgnored private(set) var journal: RecordingJournal?
    /// The session folder, when recording into one.
    @ObservationIgnored let folder: URL?
    /// Why the journal could not be opened (the recording then stays in memory).
    @ObservationIgnored private(set) var journalError: String?
    /// Seconds between manifest rewrites while recording.
    @ObservationIgnored var checkpointInterval = SessionRecorder.defaultCheckpointInterval
    @ObservationIgnored private(set) var lastCheckpoint: Date
    @ObservationIgnored private(set) var checkpointCount = 0
    @ObservationIgnored private(set) var lastSampleTime: Date?
    @ObservationIgnored private var isFinished = false

    @ObservationIgnored private var firstSampleTime: TimeInterval?
    @ObservationIgnored private var bucketIndex = 0
    @ObservationIgnored private var bucketSum = 0.0
    @ObservationIgnored private var bucketCount = 0

    /// `directory` is the sessions directory (`SessionStore.directory`); the
    /// recorder creates its own folder inside it.
    init(name: String, deviceName: String?, tags: [String] = [], notes: String? = nil,
         autoStop: AutoStopRule? = nil, isDemo: Bool = false, directory: URL? = nil) {
        self.name = name.trimmingCharacters(in: .whitespaces)
        self.deviceName = deviceName
        self.tags = tags
        self.notes = notes
        self.autoStop = autoStop
        self.isDemo = isDemo
        self.lastCheckpoint = startTime

        guard let directory else {
            folder = nil
            return
        }
        let folder = SessionFolder.url(for: id, in: directory)
        self.folder = folder
        do {
            // Manifest first: a crash between the two writes leaves a folder
            // the store can still recognise.
            try SessionFolder.writeManifest(makeSummary(state: .recording), in: folder)
            journal = try RecordingJournal(url: SessionFolder.samplesURL(in: folder), startEpoch: startTime,
                                           monotonicStart: monotonicStart)
        } catch {
            journal = nil
            journalError = error.localizedDescription
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// Wall-clock seconds since the recording started.
    var elapsed: TimeInterval { Date().timeIntervalSince(startTime) }

    /// Samples recorded so far (journal or memory).
    var sampleCount: Int { stats.samples }

    func addMarker(label: String, kind: Marker.Kind = .user) {
        markers.append(Marker(timestamp: Date(), label: label, kind: kind))
    }

    /// Adds one sample. Returns the auto-stop reason when the rule fired on
    /// this sample (the caller stops the recording).
    func add(_ r: Reading) -> AutoStopRule.Reason? {
        guard !isFinished else { return nil }
        let dt = stats.dt(to: r)
        stats.add(r, dt: dt)
        lastSampleTime = r.timestamp
        if let journal {
            journal.append(r)
        } else {
            readings.append(r)
        }
        if dt > SessionStats.maxGapS {
            markers.append(Marker(timestamp: r.timestamp, label: Self.gapLabel(dt), kind: .gap))
            // A gap means the link dropped: make sure what we had is on disk.
            journal?.synchronize()
        }
        accumulateSparkline(r)
        var fired: AutoStopRule.Reason?
        if autoStop != nil, autoStopReason == nil, let reason = autoStop?.evaluate(r, dt: dt, stats: stats) {
            autoStopReason = reason
            markers.append(Marker(timestamp: r.timestamp, label: "Auto-stop: \(reason.label)", kind: .autoStop))
            fired = reason
        }
        if folder != nil, Date().timeIntervalSince(lastCheckpoint) >= checkpointInterval {
            checkpoint()
        }
        return fired
    }

    /// Rewrites the manifest with the current statistics, markers and
    /// sparkline (state `.recording`). With `synchronize`, also fsyncs the
    /// journal (backgrounding, disconnects).
    func checkpoint(synchronize: Bool = false) {
        lastCheckpoint = Date()
        if synchronize { journal?.synchronize() }
        guard let folder, !isFinished else { return }
        do {
            try SessionFolder.writeManifest(makeSummary(state: .recording), in: folder)
            checkpointCount += 1
        } catch {
            journalError = error.localizedDescription
        }
    }

    /// Closes the journal, writes the final manifest and returns the session.
    /// `readings` is empty when a journal exists (`sampleCount` is
    /// authoritative); the store reads samples from the file on demand.
    func finish() -> Session {
        flushSparklineBucket()
        if !isFinished {
            isFinished = true
            journal?.close()
            if let folder {
                do {
                    try SessionFolder.writeManifest(makeSummary(state: .complete), in: folder)
                } catch {
                    journalError = error.localizedDescription
                }
            }
        }
        return Session(id: id,
                       name: displayName,
                       startTime: startTime,
                       endTime: endTime,
                       deviceName: deviceName,
                       stats: stats,
                       readings: readings,
                       markers: markers,
                       tags: tags,
                       notes: notes,
                       autoStopReason: autoStopReason?.rawValue,
                       isDemo: isDemo,
                       sparkline: sparkline)
    }

    /// Closes the journal and deletes the folder (nothing is kept).
    func discard() {
        isFinished = true
        journal?.close()
        journal = nil
        readings.removeAll()
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    /// Diagnostics: journal path, bytes and last flush/sync.
    var journalDescription: String? {
        guard let journal else { return journalError.map { "Journal unavailable: \($0)" } }
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        var line = "\(journal.url.lastPathComponent): \(journal.bytesWritten) bytes, \(journal.recordCount) records, "
        line += "last flush \(f.string(from: journal.lastFlush)), last sync \(f.string(from: journal.lastSync)), "
        line += "\(checkpointCount) checkpoints"
        if let e = journal.lastError { line += ", error: \(e)" }
        return line
    }

    // MARK: - Manifest

    private var displayName: String { name.isEmpty ? "Session" : name }

    private var endTime: Date {
        isFinished ? Date() : (lastSampleTime ?? Date())
    }

    private func makeSummary(state: SessionSummary.State) -> SessionSummary {
        let spark = Decimator.condense(sparkline, targetCount: SessionSummary.sparklineCount)
        return SessionSummary(schemaVersion: Session.currentSchema, id: id, name: displayName,
                              startTime: startTime, endTime: state == .recording ? (lastSampleTime ?? startTime) : Date(),
                              deviceName: deviceName, stats: stats, sampleCount: stats.samples, markers: markers,
                              tags: tags, notes: notes, autoStopReason: autoStopReason?.rawValue, isDemo: isDemo,
                              state: state, sparkline: spark)
    }

    // MARK: - Sparkline (1 Hz mean power)

    private func accumulateSparkline(_ r: Reading) {
        let t = r.monotonic > 0 ? r.monotonic : r.timestamp.timeIntervalSinceReferenceDate
        guard let first = firstSampleTime else {
            firstSampleTime = t
            bucketIndex = 0
            bucketSum = r.power
            bucketCount = 1
            return
        }
        let second = Int(max(0, t - first))
        if second > bucketIndex {
            flushSparklineBucket()
            // Seconds with no samples (gaps) read as 0 W.
            let missing = second - bucketIndex - 1
            if missing > 0 { sparkline.append(contentsOf: repeatElement(0, count: missing)) }
            bucketIndex = second
        }
        bucketSum += r.power
        bucketCount += 1
    }

    private func flushSparklineBucket() {
        guard bucketCount > 0 else { return }
        sparkline.append(Float(bucketSum / Double(bucketCount)))
        bucketSum = 0
        bucketCount = 0
    }

    nonisolated static func gapLabel(_ dt: TimeInterval) -> String {
        let s = Int(dt.rounded())
        return s >= 60 ? "Gap \(s / 60) m \(s % 60) s" : "Gap \(s) s"
    }
}
