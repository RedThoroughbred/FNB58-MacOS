import XCTest
@testable import WattBench

@MainActor
final class SessionRecorderTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_760_000_000)
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: In-memory recorder

    func testGapMarkerAppendedWhenDtExceeds5s() {
        let rec = SessionRecorder(name: "gap", deviceName: "FNB58")
        _ = rec.add(Reading(timestamp: t0, voltage: 5, current: 1, power: 5))
        _ = rec.add(Reading(timestamp: t0.addingTimeInterval(0.1), voltage: 5, current: 1, power: 5))
        _ = rec.add(Reading(timestamp: t0.addingTimeInterval(134.1), voltage: 5, current: 1, power: 5))
        XCTAssertEqual(rec.markers.count, 1)
        XCTAssertEqual(rec.markers.first?.kind, .gap)
        XCTAssertEqual(rec.markers.first?.label, "Gap 2 m 14 s")
        XCTAssertEqual(rec.markers.first?.timestamp, t0.addingTimeInterval(134.1), "placed at the first sample after the gap")
        XCTAssertEqual(rec.stats.gapCount, 1)
        XCTAssertEqual(rec.stats.gapSeconds, 134, accuracy: 1e-6)
        XCTAssertEqual(rec.stats.durationS, 0.1, accuracy: 1e-6, "the gap is not part of the active duration")
        XCTAssertEqual(rec.readings.count, 3)
        XCTAssertEqual(SessionRecorder.gapLabel(30), "Gap 30 s")
        XCTAssertEqual(SessionRecorder.gapLabel(4.6), "Gap 5 s")
    }

    func testSparklineIsOneMeanPerSecond() {
        let rec = SessionRecorder(name: "spark", deviceName: nil, tags: ["a"], notes: "n")
        // second 0: 10 W, second 1: 20 W, second 2: skipped (gap), second 3: 30 W
        for k in 0..<10 { _ = rec.add(Reading(timestamp: t0.addingTimeInterval(Double(k) * 0.1), voltage: 5, current: 2, power: 10)) }
        for k in 0..<10 { _ = rec.add(Reading(timestamp: t0.addingTimeInterval(1 + Double(k) * 0.1), voltage: 5, current: 4, power: 20)) }
        _ = rec.add(Reading(timestamp: t0.addingTimeInterval(3.0), voltage: 5, current: 6, power: 30))
        let session = rec.finish()
        XCTAssertEqual(session.sparkline, [10, 20, 0, 30])
        XCTAssertEqual(session.tags, ["a"])
        XCTAssertEqual(session.notes, "n")
        XCTAssertEqual(session.summary().sparkline, [10, 20, 0, 30])
        XCTAssertEqual(session.sampleCount, 21)
    }

    func testUserMarkerAndDemoFlag() {
        let rec = SessionRecorder(name: " Demo run ", deviceName: "Demo data", isDemo: true)
        rec.addMarker(label: "Plugged in")
        let s = rec.finish()
        XCTAssertEqual(s.name, "Demo run")
        XCTAssertTrue(s.isDemo)
        XCTAssertEqual(s.markers.map(\.label), ["Plugged in"])
        XCTAssertEqual(s.markers.first?.kind, .user)
        XCTAssertNil(s.autoStopReason)
        XCTAssertNil(rec.journal)
        XCTAssertNil(rec.folder)
    }

    // MARK: Journal-backed recorder

    private func journaled(name: String = "Journaled", autoStop: AutoStopRule? = nil) -> SessionRecorder {
        SessionRecorder(name: name, deviceName: "FNB58", tags: ["bench"], notes: "note", autoStop: autoStop,
                        isDemo: false, directory: dir)
    }

    private func reading(of rec: SessionRecorder, at s: TimeInterval, power: Double = 10) -> Reading {
        Reading(timestamp: rec.startTime.addingTimeInterval(s), voltage: 5, current: power / 5, power: power,
                monotonic: rec.monotonicStart + s)
    }

    func testWritesManifestBeforeOpeningJournal() throws {
        let rec = journaled()
        let folder = try XCTUnwrap(rec.folder)
        XCTAssertEqual(folder, SessionFolder.url(for: rec.id, in: dir))
        XCTAssertNotNil(rec.journal)
        XCTAssertNil(rec.journalError)
        let manifest = try SessionFolder.readManifest(in: folder)
        XCTAssertEqual(manifest.state, .recording)
        XCTAssertEqual(manifest.id, rec.id)
        XCTAssertEqual(manifest.name, "Journaled")
        XCTAssertEqual(manifest.sampleCount, 0)
        XCTAssertEqual(manifest.tags, ["bench"])
        XCTAssertEqual(manifest.notes, "note")
        XCTAssertEqual(RecordingJournal.count(url: SessionFolder.samplesURL(in: folder)), 0)
        XCTAssertEqual(try RecordingJournal.startEpoch(url: SessionFolder.samplesURL(in: folder)).timeIntervalSince1970,
                       rec.startTime.timeIntervalSince1970, accuracy: 1e-6)
    }

    /// A 4-hour recording (144,000 samples at 10 Hz) keeps no readings in
    /// memory and produces a journal of exactly 16 + 16 * n bytes.
    func testFourHourRecordingKeepsNoReadingsAndWritesExactFile() throws {
        let rec = journaled(name: "Four hours")
        let n = 4 * 3600 * 10
        for k in 0..<n {
            _ = rec.add(reading(of: rec, at: Double(k) * 0.1))
        }
        XCTAssertTrue(rec.readings.isEmpty, "samples go to the journal, never to an array")
        XCTAssertEqual(rec.sampleCount, n)
        XCTAssertEqual(rec.stats.samples, n)
        XCTAssertEqual(rec.stats.durationS, Double(n - 1) * 0.1, accuracy: 0.01)
        XCTAssertEqual(rec.stats.gapCount, 0)

        let session = rec.finish()
        XCTAssertTrue(session.readings.isEmpty, "finish does not read the file back")
        XCTAssertEqual(session.sampleCount, n, "sampleCount is authoritative")
        XCTAssertEqual(session.sparkline.count, n / 10, "one mean per second")
        XCTAssertEqual(session.summary().sparkline.count, SessionSummary.sparklineCount)

        let folder = try XCTUnwrap(rec.folder)
        let samplesURL = SessionFolder.samplesURL(in: folder)
        let size = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: samplesURL.path)[.size] as? Int)
        XCTAssertEqual(size, RecordingJournal.headerSize + RecordingJournal.recordSize * n)
        XCTAssertEqual(RecordingJournal.count(url: samplesURL), n)
        let manifest = try SessionFolder.readManifest(in: folder)
        XCTAssertEqual(manifest.state, .complete)
        XCTAssertEqual(manifest.sampleCount, n)
        XCTAssertEqual(manifest.sparkline.count, SessionSummary.sparklineCount)
        XCTAssertEqual(manifest.stats, rec.stats)

        // Spot-check the file contents: offsets and values survive.
        let back = try RecordingJournal.read(url: samplesURL).readings
        XCTAssertEqual(back.count, n)
        XCTAssertEqual(back[n - 1].monotonic, Double(n - 1) * 0.1, accuracy: 1e-3)
        XCTAssertEqual(back[n - 1].timestamp.timeIntervalSince(rec.startTime), Double(n - 1) * 0.1, accuracy: 1e-3)
        XCTAssertEqual(back[12_345].power, 10)
    }

    func testCheckpointRewritesManifestWhileRecording() throws {
        let rec = journaled()
        let folder = try XCTUnwrap(rec.folder)
        for k in 0..<30 { _ = rec.add(reading(of: rec, at: Double(k) * 0.1)) }
        rec.addMarker(label: "Mark 1")
        XCTAssertEqual(rec.checkpointCount, 0, "the 10 s cadence has not elapsed")
        XCTAssertEqual(try SessionFolder.readManifest(in: folder).sampleCount, 0)

        rec.checkpoint(synchronize: true)
        rec.journal?.waitForWrites()
        XCTAssertEqual(rec.checkpointCount, 1)
        let manifest = try SessionFolder.readManifest(in: folder)
        XCTAssertEqual(manifest.state, .recording, "still recording")
        XCTAssertEqual(manifest.sampleCount, 30)
        XCTAssertEqual(manifest.stats.samples, 30)
        XCTAssertEqual(manifest.markers.map(\.label), ["Mark 1"])
        XCTAssertEqual(manifest.endTime.timeIntervalSince(rec.startTime), 2.9, accuracy: 1e-3, "end time is the last sample")
        XCTAssertEqual(RecordingJournal.count(url: SessionFolder.samplesURL(in: folder)), 30, "synchronize flushed the buffer")

        // The cadence is driven by wall time between adds.
        rec.checkpointInterval = 0
        _ = rec.add(reading(of: rec, at: 3.0))
        XCTAssertEqual(rec.checkpointCount, 2)
        XCTAssertEqual(try SessionFolder.readManifest(in: folder).sampleCount, 31)
    }

    func testGapSecuresJournalAndAddsMarker() throws {
        let rec = journaled()
        let folder = try XCTUnwrap(rec.folder)
        _ = rec.add(reading(of: rec, at: 0))
        _ = rec.add(reading(of: rec, at: 0.1))
        rec.journal?.waitForWrites()
        XCTAssertEqual(RecordingJournal.count(url: SessionFolder.samplesURL(in: folder)), 0, "still buffered")
        _ = rec.add(reading(of: rec, at: 40.1))   // the meter was off for 40 s
        rec.journal?.waitForWrites()
        XCTAssertEqual(RecordingJournal.count(url: SessionFolder.samplesURL(in: folder)), 3, "a gap flushes and fsyncs")
        XCTAssertEqual(rec.markers.map(\.kind), [.gap])
        XCTAssertEqual(rec.markers.first?.label, "Gap 40 s")
        XCTAssertEqual(rec.stats.gapCount, 1)
        XCTAssertEqual(rec.stats.durationS, 0.1, accuracy: 1e-9)
        XCTAssertEqual(rec.stats.energyWh, 10 * 0.1 / 3600, accuracy: 1e-12, "the gap adds no energy")
    }

    func testAutoStopFiresOnceAndIsRecorded() throws {
        let rec = journaled(autoStop: AutoStopRule(belowCurrentA: 0.5, forSeconds: 0.3))
        var fired: [AutoStopRule.Reason] = []
        for k in 0..<10 {
            if let r = rec.add(reading(of: rec, at: Double(k) * 0.1, power: 0.05)) { fired.append(r) }
        }
        XCTAssertEqual(fired, [.currentBelowThreshold], "reported exactly once")
        XCTAssertEqual(rec.autoStopReason, .currentBelowThreshold)
        XCTAssertEqual(rec.markers.filter { $0.kind == .autoStop }.count, 1)
        let session = rec.finish()
        XCTAssertEqual(session.autoStopReason, "currentBelowThreshold")
        XCTAssertEqual(try SessionFolder.readManifest(in: try XCTUnwrap(rec.folder)).autoStopReason, "currentBelowThreshold")
    }

    func testFinishIsIdempotentAndIgnoresLateSamples() throws {
        let rec = journaled()
        for k in 0..<5 { _ = rec.add(reading(of: rec, at: Double(k) * 0.1)) }
        let first = rec.finish()
        XCTAssertNil(rec.add(reading(of: rec, at: 1)), "samples after finish are dropped")
        XCTAssertEqual(rec.sampleCount, 5)
        let second = rec.finish()
        XCTAssertEqual(second.sampleCount, first.sampleCount)
        XCTAssertEqual(second.id, first.id)
        XCTAssertEqual(RecordingJournal.count(url: SessionFolder.samplesURL(in: try XCTUnwrap(rec.folder))), 5)
    }

    func testDiscardDeletesFolder() throws {
        let rec = journaled()
        let folder = try XCTUnwrap(rec.folder)
        for k in 0..<5 { _ = rec.add(reading(of: rec, at: Double(k) * 0.1)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
        rec.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertNil(rec.journal)
        XCTAssertNil(rec.add(reading(of: rec, at: 1)))
        XCTAssertNil(SessionStore(directory: dir).interrupted, "nothing is left to recover")
    }

    func testJournalDescriptionForDiagnostics() throws {
        let rec = journaled()
        for k in 0..<70 { _ = rec.add(reading(of: rec, at: Double(k) * 0.1)) }
        rec.journal?.waitForWrites()
        let line = try XCTUnwrap(rec.journalDescription)
        XCTAssertTrue(line.hasPrefix("samples.wbj: "), line)
        XCTAssertTrue(line.contains("\(RecordingJournal.headerSize + 64 * RecordingJournal.recordSize) bytes"), line)
        XCTAssertTrue(line.contains("70 records"), line)
        XCTAssertTrue(line.contains("last flush"), line)
        XCTAssertTrue(line.contains("last sync"), line)
    }

    func testUnwritableDirectoryFallsBackToMemory() throws {
        // A plain file where the session folder should go.
        let blocked = dir.appendingPathComponent("blocked")
        try Data("x".utf8).write(to: blocked)
        let rec = SessionRecorder(name: "Fallback", deviceName: nil, directory: blocked)
        XCTAssertNil(rec.journal)
        XCTAssertNotNil(rec.journalError)
        _ = rec.add(reading(of: rec, at: 0))
        XCTAssertEqual(rec.readings.count, 1, "samples stay in memory so the session can still be saved")
        XCTAssertEqual(rec.finish().readings.count, 1)
    }
}
