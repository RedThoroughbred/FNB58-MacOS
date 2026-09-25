import XCTest
@testable import WattBench

@MainActor
final class SessionStoreTests: XCTestCase {
    private var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func sampleSession() -> Session {
        let rec = SessionRecorder(name: "  Bench test ", deviceName: "FNB58")
        let t0 = Date()
        for k in 0..<10 {
            _ = rec.add(Reading(timestamp: t0.addingTimeInterval(Double(k) * 0.1), voltage: 9, current: 1, power: 9))
        }
        return rec.finish()
    }

    func testSaveLoadDeleteRoundTrip() async throws {
        let store = SessionStore(directory: dir)
        let s = sampleSession()
        XCTAssertEqual(s.name, "Bench test")
        try store.save(s)
        XCTAssertEqual(store.saveCount, 1)
        XCTAssertEqual(store.lastSaved?.id, s.id)

        let reloaded = SessionStore(directory: dir)
        XCTAssertEqual(reloaded.summaries.count, 1)
        let summary = try XCTUnwrap(reloaded.summaries.first)
        XCTAssertEqual(summary.id, s.id)
        XCTAssertEqual(summary.name, s.name)
        XCTAssertEqual(summary.sampleCount, s.readings.count)
        XCTAssertEqual(summary.stats.samples, s.stats.samples)
        XCTAssertEqual(summary.state, .complete)
        XCTAssertEqual(summary.schemaVersion, Session.currentSchema)

        let r = try await reloaded.session(for: s.id)
        XCTAssertEqual(r.readings.count, s.readings.count)
        XCTAssertEqual(r.stats.energyWh, s.stats.energyWh, accuracy: 1e-12)
        // Sub-second timestamps must survive the round trip (100 ms spacing).
        let dt = r.readings[1].timestamp.timeIntervalSince(r.readings[0].timestamp)
        XCTAssertEqual(dt, 0.1, accuracy: 1e-6)
        let samples = try await reloaded.samples(for: s.id)
        XCTAssertEqual(samples.count, 10)

        reloaded.delete(id: s.id)
        XCTAssertTrue(reloaded.summaries.isEmpty)
        XCTAssertTrue(SessionStore(directory: dir).summaries.isEmpty)
    }

    func testMissingSessionThrowsNotFound() async {
        let store = SessionStore(directory: dir)
        do {
            _ = try await store.session(for: UUID())
            XCTFail("expected notFound")
        } catch let e as SessionStore.StoreError {
            guard case .notFound = e else { return XCTFail("wrong error \(e)") }
        } catch {
            XCTFail("wrong error \(error)")
        }
    }

    func testRenameAndUpdate() async throws {
        let store = SessionStore(directory: dir)
        let s = sampleSession()
        try store.save(s)
        try store.rename(id: s.id, to: "  Charger A  ")
        try store.update(id: s.id, notes: "USB-C, 3 A cable", tags: ["charger", "iphone"])
        XCTAssertEqual(store.summaries.first?.name, "Charger A")
        XCTAssertEqual(store.summaries.first?.notes, "USB-C, 3 A cable")
        XCTAssertEqual(store.summaries.first?.tags, ["charger", "iphone"])

        // nil leaves a field untouched
        try store.update(id: s.id, notes: nil, tags: [])
        XCTAssertEqual(store.summaries.first?.notes, "USB-C, 3 A cable")
        XCTAssertEqual(store.summaries.first?.tags, [])

        let reloaded = try await SessionStore(directory: dir).session(for: s.id)
        XCTAssertEqual(reloaded.name, "Charger A")
        XCTAssertEqual(reloaded.readings.count, 10)
    }

    func testCSVExport() throws {
        let store = SessionStore(directory: dir)
        let s = sampleSession()
        let url = try store.csvURL(for: s)
        XCTAssertTrue(url.path.hasPrefix(FileManager.default.temporaryDirectory.path), "exports go to tmp, not Documents")
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(separator: "\n")
        XCTAssertEqual(lines.first, "timestamp,voltage_v,current_a,power_w,elapsed_s,marker_label")
        XCTAssertEqual(lines.count, 11)
        XCTAssertTrue(lines[1].contains(",9.0,1.0,9.0,"), "first four columns unchanged: \(lines[1])")
        XCTAssertTrue(lines[1].hasSuffix(",0.0,"), "elapsed 0 and no marker on the first row: \(lines[1])")
    }

    func testCSVMarkerColumn() throws {
        var s = sampleSession()
        let third = s.readings[2].timestamp
        s.markers = [Marker(timestamp: third, label: "Plugged in, \"phone\"", kind: .user),
                     Marker(timestamp: s.endTime.addingTimeInterval(10), label: "late", kind: .user)]
        let lines = s.csv().split(separator: "\n")
        XCTAssertTrue(lines[3].hasSuffix(",\"Plugged in, \"\"phone\"\"\""), "quoted marker on its row: \(lines[3])")
        XCTAssertTrue(lines[10].hasSuffix(",late"), "a marker after the last sample attaches to the last row: \(lines[10])")
        XCTAssertTrue(lines[2].hasSuffix(",0.1,"), "\(lines[2])")
    }

    func testLoadsLegacyV1File() async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fixture = try XCTUnwrap(Bundle(for: SessionStoreTests.self).url(forResource: "session-v1", withExtension: "json"))
        let id = try XCTUnwrap(UUID(uuidString: "6F9C2A3E-5B1D-4C7A-9E2F-0A1B2C3D4E5F"))
        try FileManager.default.copyItem(at: fixture, to: dir.appendingPathComponent("\(id.uuidString).json"))

        let store = SessionStore(directory: dir)
        XCTAssertNil(store.loadError)
        XCTAssertEqual(store.summaries.count, 1)
        let summary = try XCTUnwrap(store.summaries.first)
        XCTAssertEqual(summary.id, id)
        XCTAssertEqual(summary.sampleCount, 12)
        // The first load migrates the 1.0 file into a folder in the current schema.
        XCTAssertEqual(summary.schemaVersion, Session.currentSchema)
        XCTAssertFalse(summary.sparkline.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(id.uuidString).json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: SessionFolder.samplesURL(in: SessionFolder.url(for: id, in: dir)).path))
        let session = try await store.session(for: id)
        XCTAssertEqual(session.readings.count, 12)

        try store.rename(id: id, to: "Migrated")
        XCTAssertEqual(store.summaries.first?.name, "Migrated")
        XCTAssertEqual(store.summaries.first?.schemaVersion, Session.currentSchema)
    }

    func testInterruptedIsNilWithoutRecordingFolders() throws {
        let store = SessionStore(directory: dir)
        XCTAssertNil(store.interrupted)
        try store.keepInterrupted()
        store.discardInterrupted()
        XCTAssertTrue(store.summaries.isEmpty)
    }
}
