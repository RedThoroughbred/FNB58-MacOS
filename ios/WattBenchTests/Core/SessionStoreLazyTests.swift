import XCTest
@testable import WattBench

/// The folder layout: manifests are the index, samples are read on demand.
@MainActor
final class SessionStoreLazyTests: XCTestCase {
    private var dir: URL!
    private let t0 = Date(timeIntervalSince1970: 1_760_000_000)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func session(name: String = "Bench", samples: Int = 600, start: Date? = nil) -> Session {
        let start = start ?? t0
        var stats = SessionStats()
        var readings: [Reading] = []
        readings.reserveCapacity(samples)
        for k in 0..<samples {
            let r = Reading(timestamp: start.addingTimeInterval(Double(k) * 0.1), voltage: 9, current: 1.5, power: 13.5)
            stats.add(r)
            readings.append(r)
        }
        return Session(id: UUID(), name: name, startTime: start, endTime: start.addingTimeInterval(Double(samples) * 0.1),
                       deviceName: "FNB58", stats: stats, readings: readings,
                       markers: [Marker(timestamp: start.addingTimeInterval(1), label: "m")], tags: ["t"], notes: "n")
    }

    func testLoadDoesNotReadSamples() async throws {
        // 20 one-hour-equivalent sessions (36k samples each would be ~11 MB of
        // journals; 6k each keeps the test quick while still dwarfing the
        // manifests). Load time must be bounded by the manifests alone.
        let store = SessionStore(directory: dir)
        for k in 0..<20 {
            try store.save(session(name: "S\(k)", samples: 6000, start: t0.addingTimeInterval(Double(k) * 3600)))
        }
        let clock = ContinuousClock()
        var loaded: SessionStore?
        let elapsed = clock.measure { loaded = SessionStore(directory: dir) }
        let summaries = try XCTUnwrap(loaded?.summaries)
        XCTAssertEqual(summaries.count, 20)
        XCTAssertEqual(summaries.first?.name, "S19", "newest first")
        XCTAssertEqual(summaries.last?.name, "S0")
        XCTAssertTrue(summaries.allSatisfy { $0.sampleCount == 6000 && $0.sparkline.count == SessionSummary.sparklineCount })
        XCTAssertLessThan(elapsed, .milliseconds(300), "loading 20 manifests took \(elapsed)")

        // Reading samples takes measurably longer than the index load did
        // and returns the full set.
        let samples = try await store.samples(for: try XCTUnwrap(summaries.first).id)
        XCTAssertEqual(samples.count, 6000)
        XCTAssertEqual(samples[1].timestamp.timeIntervalSince(samples[0].timestamp), 0.1, accuracy: 1e-3)
        XCTAssertEqual(samples[0].monotonic, 0, "journal offsets are exposed as monotonic seconds from start")
    }

    func testSaveRenameUpdateDeleteRoundTrip() async throws {
        let store = SessionStore(directory: dir)
        let s = session()
        try store.save(s)
        let folder = SessionFolder.url(for: s.id, in: dir)
        let samplesURL = SessionFolder.samplesURL(in: folder)
        XCTAssertTrue(FileManager.default.fileExists(atPath: SessionFolder.manifestURL(in: folder).path))
        XCTAssertEqual(RecordingJournal.count(url: samplesURL), 600)
        XCTAssertEqual(store.summaries.first?.sparkline.count, SessionSummary.sparklineCount)
        XCTAssertEqual(store.saveCount, 1)
        XCTAssertEqual(store.lastSaved?.id, s.id)

        let samplesBefore = try Data(contentsOf: samplesURL)
        try store.rename(id: s.id, to: "  Charger A  ")
        try store.update(id: s.id, notes: "USB-C", tags: ["charger"])
        XCTAssertEqual(store.summaries.first?.name, "Charger A")
        XCTAssertEqual(store.summaries.first?.notes, "USB-C")
        XCTAssertEqual(store.summaries.first?.tags, ["charger"])
        try store.update(id: s.id, notes: nil, tags: nil)
        XCTAssertEqual(store.summaries.first?.notes, "USB-C")
        XCTAssertEqual(try Data(contentsOf: samplesURL), samplesBefore, "rename/update never touch samples.wbj")
        XCTAssertEqual(store.saveCount, 1, "metadata edits are not saves")

        let reloaded = SessionStore(directory: dir)
        XCTAssertEqual(reloaded.summaries.first?.name, "Charger A")
        XCTAssertEqual(reloaded.summaries.first?.markers.map(\.label), ["m"])
        let full = try await reloaded.session(for: s.id)
        XCTAssertEqual(full.name, "Charger A")
        XCTAssertEqual(full.readings.count, 600)
        XCTAssertEqual(full.stats, s.stats)
        XCTAssertEqual(full.sparkline.count, SessionSummary.sparklineCount)

        // Saving again with samples.wbj present rewrites only the manifest.
        var renamed = full
        renamed.name = "Charger B"
        renamed.readings = []
        try reloaded.save(renamed)
        XCTAssertEqual(reloaded.summaries.first?.name, "Charger B")
        XCTAssertEqual(reloaded.summaries.first?.sampleCount, 600, "sample count comes from the journal")
        XCTAssertEqual(try Data(contentsOf: samplesURL), samplesBefore)

        reloaded.delete(id: s.id)
        XCTAssertTrue(reloaded.summaries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "delete removes the folder")
        XCTAssertThrowsError(try reloaded.rename(id: s.id, to: "x"))
        XCTAssertTrue(SessionStore(directory: dir).summaries.isEmpty)
    }

    func testMissingSamplesFileYieldsCorruptSamplesButSummaryListed() async throws {
        let store = SessionStore(directory: dir)
        let s = session()
        try store.save(s)
        try FileManager.default.removeItem(at: SessionFolder.samplesURL(in: SessionFolder.url(for: s.id, in: dir)))

        let reloaded = SessionStore(directory: dir)
        XCTAssertEqual(reloaded.summaries.map(\.id), [s.id], "the manifest alone keeps the session listed")
        XCTAssertNil(reloaded.loadError)
        for attempt in 0..<2 {
            do {
                _ = attempt == 0 ? try await reloaded.samples(for: s.id) : try await reloaded.session(for: s.id).readings
                XCTFail("expected corruptSamples")
            } catch let e as SessionStore.StoreError {
                guard case .corruptSamples = e else { return XCTFail("wrong error \(e)") }
                XCTAssertEqual(e.errorDescription, "Samples unavailable")
            }
        }
        // Metadata still works without samples.
        try reloaded.rename(id: s.id, to: "No samples")
        XCTAssertEqual(reloaded.summaries.first?.name, "No samples")
    }

    func testUnknownFilesAreIgnoredAndEmptyFoldersRemoved() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: dir.appendingPathComponent(".DS_Store"))
        try Data("x".utf8).write(to: dir.appendingPathComponent("readme.txt"))
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("not-a-uuid"), withIntermediateDirectories: true)
        let empty = SessionFolder.url(for: UUID(), in: dir)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let store = SessionStore(directory: dir)
        XCTAssertNil(store.loadError)
        XCTAssertTrue(store.summaries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: empty.path), "an empty session folder is cleaned up")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("readme.txt").path))
    }

    func testCorruptManifestWithoutJournalIsReported() throws {
        let store = SessionStore(directory: dir)
        let s = session()
        try store.save(s)
        let folder = SessionFolder.url(for: s.id, in: dir)
        try Data("{not json".utf8).write(to: SessionFolder.manifestURL(in: folder))
        try FileManager.default.removeItem(at: SessionFolder.samplesURL(in: folder))
        let reloaded = SessionStore(directory: dir)
        XCTAssertTrue(reloaded.summaries.isEmpty)
        XCTAssertNotNil(reloaded.loadError)
    }

    func testCSVExportGoesToTemporaryDirectory() throws {
        let store = SessionStore(directory: dir)
        let s = session(name: "Charger / A")
        try store.save(s)
        let url = try store.csvURL(for: s)
        XCTAssertTrue(url.path.hasPrefix(FileManager.default.temporaryDirectory.path), url.path)
        XCTAssertEqual(url.pathExtension, "csv")
        XCTAssertTrue(url.lastPathComponent.hasPrefix("Charger_A_"))
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 601)
        let inDocuments = try FileManager.default.subpathsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".csv") }
        XCTAssertTrue(inDocuments.isEmpty, "no CSV inside the sessions directory")
    }

    func testDemoSessionsCarryFlag() async throws {
        let store = SessionStore(directory: dir)
        var s = session(name: "Demo")
        s.isDemo = true
        try store.save(s)
        XCTAssertEqual(SessionStore(directory: dir).summaries.first?.isDemo, true)
        let loaded = try await store.session(for: s.id)
        XCTAssertTrue(loaded.isDemo)
    }
}
