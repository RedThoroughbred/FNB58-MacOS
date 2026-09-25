import XCTest
@testable import WattBench

/// Interrupted recordings: a manifest left in state `.recording` by a crash or
/// force-quit is sealed from its journal into `SessionStore.interrupted`.
@MainActor
final class RecoveryTests: XCTestCase {
    private var dir: URL!
    private let t0 = Date(timeIntervalSince1970: 1_760_000_000)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Simulates a crash: records into a folder, then abandons the recorder
    /// without `finish()` (the manifest stays in state `.recording`).
    @discardableResult
    private func interruptedRecording(name: String = "Charge test", samples: Int = 50, gapAfter: Int? = nil) -> UUID {
        let rec = SessionRecorder(name: name, deviceName: "FNB58", tags: ["bench"], notes: "n",
                                  isDemo: false, directory: dir)
        rec.addMarker(label: "Plugged in")
        var t = 0.0
        for k in 0..<samples {
            if let gapAfter, k == gapAfter { t += 30 }
            _ = rec.add(Reading(timestamp: t0.addingTimeInterval(t), voltage: 5, current: 2, power: 10, monotonic: 100 + t))
            t += 0.1
        }
        // Force everything buffered onto disk the way a crash would have
        // caught it after the last flush (at most 1 s of samples lost).
        rec.journal?.synchronize()
        rec.journal?.waitForWrites()
        let manifest = try? SessionFolder.readManifest(in: SessionFolder.url(for: rec.id, in: dir))
        XCTAssertEqual(manifest?.state, .recording)
        return rec.id
    }

    func testInterruptedManifestIsSealedAsRecovered() async throws {
        let id = interruptedRecording(gapAfter: 20)
        let store = SessionStore(directory: dir)
        XCTAssertTrue(store.summaries.isEmpty, "an unresolved recording is not listed yet")
        let s = try XCTUnwrap(store.interrupted)
        XCTAssertEqual(s.id, id)
        XCTAssertEqual(s.state, .recovered)
        XCTAssertEqual(s.name, "Recovered: Charge test")
        XCTAssertEqual(s.sampleCount, 50)
        XCTAssertEqual(s.stats.samples, 50)
        XCTAssertEqual(s.stats.gapCount, 1)
        XCTAssertEqual(s.stats.durationS, 4.8, accuracy: 1e-6, "49 intervals of 0.1 s minus the 30 s gap")
        XCTAssertEqual(s.stats.energyWh, 10 * 4.8 / 3600, accuracy: 1e-9)
        XCTAssertEqual(s.endTime.timeIntervalSince(t0), 34.9, accuracy: 1e-3, "end time is the last record")
        XCTAssertEqual(s.markers.filter { $0.kind == .gap }.count, 1)
        XCTAssertEqual(s.markers.first?.label, "Plugged in", "user markers from the manifest survive")
        XCTAssertEqual(s.tags, ["bench"])
        XCTAssertFalse(s.sparkline.isEmpty)

        // Keep: the manifest is rewritten as recovered and the session listed.
        try store.keepInterrupted()
        XCTAssertNil(store.interrupted)
        XCTAssertEqual(store.summaries.map(\.id), [id])
        XCTAssertEqual(store.saveCount, 1)
        XCTAssertEqual(store.lastSaved?.id, id)
        let onDisk = try SessionFolder.readManifest(in: SessionFolder.url(for: id, in: dir))
        XCTAssertEqual(onDisk.state, .recovered)
        XCTAssertEqual(onDisk.name, "Recovered: Charge test")

        // A fresh store lists it normally and never prompts again.
        let reloaded = SessionStore(directory: dir)
        XCTAssertNil(reloaded.interrupted)
        XCTAssertEqual(reloaded.summaries.first?.state, .recovered)
        let session = try await reloaded.session(for: id)
        XCTAssertEqual(session.readings.count, 50)
    }

    func testDiscardRemovesFolder() throws {
        let id = interruptedRecording()
        let folder = SessionFolder.url(for: id, in: dir)
        let store = SessionStore(directory: dir)
        XCTAssertNotNil(store.interrupted)
        store.discardInterrupted()
        XCTAssertNil(store.interrupted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertTrue(store.summaries.isEmpty)
        XCTAssertNil(SessionStore(directory: dir).interrupted)
    }

    func testRecordingWithoutSamplesIsDroppedSilently() throws {
        let id = interruptedRecording(samples: 0)
        let store = SessionStore(directory: dir)
        XCTAssertNil(store.interrupted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: SessionFolder.url(for: id, in: dir).path))
    }

    func testOnlyOnePromptFurtherInterruptedRecordingsAreKept() throws {
        let a = interruptedRecording(name: "A")
        let b = interruptedRecording(name: "B")
        let store = SessionStore(directory: dir)
        let prompted = try XCTUnwrap(store.interrupted)
        let other = try XCTUnwrap(store.summaries.first)
        XCTAssertEqual(Set([prompted.id, other.id]), Set([a, b]))
        XCTAssertEqual(other.state, .recovered)
        XCTAssertTrue(other.name.hasPrefix("Recovered: "))
        XCTAssertEqual(store.summaries.count, 1)
    }

    func testMissingManifestIsRebuiltFromJournal() throws {
        let id = interruptedRecording()
        let folder = SessionFolder.url(for: id, in: dir)
        try FileManager.default.removeItem(at: SessionFolder.manifestURL(in: folder))
        let store = SessionStore(directory: dir)
        XCTAssertNil(store.interrupted)
        let s = try XCTUnwrap(store.summaries.first)
        XCTAssertEqual(s.id, id)
        XCTAssertEqual(s.name, "Recovered session")
        XCTAssertEqual(s.state, .recovered)
        XCTAssertEqual(s.sampleCount, 50)
        XCTAssertEqual(s.startTime.timeIntervalSince1970,
                       try SessionFolder.readManifest(in: folder).startTime.timeIntervalSince1970, accuracy: 1e-6)
        XCTAssertTrue(FileManager.default.fileExists(atPath: SessionFolder.manifestURL(in: folder).path), "rebuilt manifest persisted")
    }

    func testRecorderNeverAutoResumesAfterRelaunch() throws {
        // A relaunch creates a new store; the interrupted recording is offered
        // for recovery and a new recorder gets its own folder.
        let id = interruptedRecording()
        let store = SessionStore(directory: dir)
        XCTAssertEqual(store.interrupted?.id, id)
        let fresh = SessionRecorder(name: "New", deviceName: nil, directory: dir)
        XCTAssertNotEqual(fresh.id, id)
        XCTAssertNotNil(fresh.journal)
        _ = fresh.finish()
        try store.keepInterrupted()
        // Both folders exist and the new one is untouched by recovery.
        XCTAssertTrue(FileManager.default.fileExists(atPath: SessionFolder.url(for: id, in: dir).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: SessionFolder.url(for: fresh.id, in: dir).path))
    }
}
