import XCTest
@testable import WattBench

@MainActor
final class LegacyMigrationTests: XCTestCase {
    private var dir: URL!
    private let fixtureID = UUID(uuidString: "6F9C2A3E-5B1D-4C7A-9E2F-0A1B2C3D4E5F")!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func fixtureURL() throws -> URL {
        try XCTUnwrap(Bundle(for: LegacyMigrationTests.self).url(forResource: "session-v1", withExtension: "json"))
    }

    @discardableResult
    private func placeFixture(named name: String? = nil) throws -> URL {
        let target = dir.appendingPathComponent(name ?? "\(fixtureID.uuidString).json")
        try FileManager.default.copyItem(at: try fixtureURL(), to: target)
        return target
    }

    private func decodeFixture() throws -> Session {
        try SessionFolder.decoder().decode(Session.self, from: try Data(contentsOf: try fixtureURL()))
    }

    func testV1FixtureMigratesLosslessly() throws {
        let legacy = try placeFixture()
        let original = try decodeFixture()

        let outcome = LegacyMigration.migrate(legacy, in: dir)
        XCTAssertEqual(outcome.status, .migrated)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path), "legacy file deleted after verification")

        let folder = SessionFolder.url(for: fixtureID, in: dir)
        let manifest = try SessionFolder.readManifest(in: folder)
        XCTAssertEqual(outcome.summary, manifest)
        XCTAssertEqual(manifest.id, original.id)
        XCTAssertEqual(manifest.name, original.name)
        XCTAssertEqual(manifest.deviceName, original.deviceName)
        XCTAssertEqual(manifest.startTime.timeIntervalSince1970, original.startTime.timeIntervalSince1970, accuracy: 1e-6)
        XCTAssertEqual(manifest.endTime.timeIntervalSince1970, original.endTime.timeIntervalSince1970, accuracy: 1e-6)
        XCTAssertEqual(manifest.stats, original.stats, "stored statistics are carried over unchanged")
        XCTAssertEqual(manifest.sampleCount, 12)
        XCTAssertEqual(manifest.schemaVersion, Session.currentSchema)
        XCTAssertEqual(manifest.state, .complete)
        XCTAssertFalse(manifest.isDemo)
        XCTAssertEqual(manifest.sparkline.count, 12)

        let (start, readings) = try RecordingJournal.read(url: SessionFolder.samplesURL(in: folder))
        XCTAssertEqual(start.timeIntervalSince1970, original.startTime.timeIntervalSince1970, accuracy: 1e-6)
        XCTAssertEqual(readings.count, original.readings.count)
        for (a, b) in zip(readings, original.readings) {
            XCTAssertEqual(a.voltage, b.voltage)
            XCTAssertEqual(a.current, b.current)
            XCTAssertEqual(a.power, b.power)
            XCTAssertEqual(a.timestamp.timeIntervalSince1970, b.timestamp.timeIntervalSince1970, accuracy: 1e-3)
        }
        // Sub-second spacing survives.
        XCTAssertEqual(readings[1].timestamp.timeIntervalSince(readings[0].timestamp), 0.1, accuracy: 1e-3)
    }

    func testStoreMigratesOnFirstLoadAndListsIt() async throws {
        let legacy = try placeFixture()
        let store = SessionStore(directory: dir)
        XCTAssertNil(store.loadError)
        XCTAssertEqual(store.migrating, 0)
        XCTAssertEqual(store.summaries.map(\.id), [fixtureID])
        XCTAssertEqual(store.summaries.first?.sampleCount, 12)
        XCTAssertEqual(store.summaries.first?.schemaVersion, Session.currentSchema)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        let session = try await store.session(for: fixtureID)
        XCTAssertEqual(session.readings.count, 12)
        XCTAssertEqual(session.readings[0].voltage, 9.0123)
        // Second launch: nothing left to migrate, same listing.
        XCTAssertEqual(SessionStore(directory: dir).summaries.map(\.id), [fixtureID])
    }

    func testCorruptLegacyFileIsKeptAndReported() throws {
        let corrupt = dir.appendingPathComponent("\(UUID().uuidString).json")
        try Data("{\"id\": \"not-a-session\"".utf8).write(to: corrupt)
        let outcome = LegacyMigration.migrate(corrupt, in: dir)
        guard case .unreadable = outcome.status else { return XCTFail("expected unreadable, got \(outcome.status)") }
        XCTAssertNil(outcome.summary)
        XCTAssertTrue(FileManager.default.fileExists(atPath: corrupt.path), "unreadable files are left in place")

        let store = SessionStore(directory: dir)
        XCTAssertTrue(store.summaries.isEmpty)
        let error = try XCTUnwrap(store.loadError)
        XCTAssertTrue(error.contains(corrupt.lastPathComponent), error)
        XCTAssertTrue(FileManager.default.fileExists(atPath: corrupt.path))
    }

    func testUnwritableFolderKeepsLegacyFileAndStillListsIt() async throws {
        let legacy = try placeFixture()
        // Occupy the folder path with a plain file so the folder cannot be created.
        let folderPath = SessionFolder.url(for: fixtureID, in: dir)
        try Data("blocker".utf8).write(to: folderPath)
        let outcome = LegacyMigration.migrate(legacy, in: dir)
        guard case .kept = outcome.status else { return XCTFail("expected kept, got \(outcome.status)") }
        XCTAssertNotNil(outcome.summary, "a decodable file is still listed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))

        let store = SessionStore(directory: dir)
        XCTAssertEqual(store.summaries.map(\.id), [fixtureID])
        XCTAssertNotNil(store.loadError)
        // Served lazily from the JSON.
        let session = try await store.session(for: fixtureID)
        XCTAssertEqual(session.readings.count, 12)
        try store.rename(id: fixtureID, to: "Renamed")
        XCTAssertEqual(store.summaries.first?.name, "Renamed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
    }

    func testLegacyFileListingIgnoresUnrelatedFiles() throws {
        try placeFixture()
        try Data("x".utf8).write(to: dir.appendingPathComponent("notes.json"))
        try Data("x".utf8).write(to: dir.appendingPathComponent("\(UUID().uuidString).csv"))
        XCTAssertEqual(LegacyMigration.legacyFiles(in: dir).map(\.lastPathComponent), ["\(fixtureID.uuidString).json"])
    }

    func testManyLegacyFilesMigrateInBackgroundWithProgress() async throws {
        let session = try decodeFixture()
        var ids: [UUID] = []
        for k in 0..<(LegacyMigration.synchronousLimit + 2) {
            var copy = session
            copy.id = UUID()
            copy.name = "Legacy \(k)"
            ids.append(copy.id)
            try SessionFolder.encoder().encode(copy).write(to: dir.appendingPathComponent("\(copy.id.uuidString).json"))
        }
        let store = SessionStore(directory: dir)
        XCTAssertEqual(store.migrating, ids.count, "progress count while the background task runs")
        let deadline = Date().addingTimeInterval(20)
        while store.migrating > 0, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(store.migrating, 0)
        XCTAssertEqual(Set(store.summaries.map(\.id)), Set(ids))
        XCTAssertNil(store.loadError)
        XCTAssertTrue(LegacyMigration.legacyFiles(in: dir).isEmpty)
        XCTAssertEqual(SessionStore(directory: dir).summaries.count, ids.count)
    }
}
