import XCTest
@testable import WattBench

final class RecordingJournalTests: XCTestCase {
    private var url: URL!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("samples.wbj")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    private let t0 = Date(timeIntervalSince1970: 1_760_000_000)

    private func reading(_ k: Int, v: Double = 5, i: Double = 1, w: Double = 5, dt: Double = 0.1,
                         monotonicBase: Double = 100) -> Reading {
        Reading(timestamp: t0.addingTimeInterval(Double(k) * dt), voltage: v, current: i, power: w,
                monotonic: monotonicBase + Double(k) * dt)
    }

    func testAppendReadRoundTripIsBitExact() throws {
        let journal = try RecordingJournal(url: url, startEpoch: t0, monotonicStart: 50)
        // Meter-native values (1/10000 units), including the largest the
        // meter can report and a negative current.
        let values: [(Double, Double, Double)] = [(9.0123, 1.2345, 11.1234), (9.0121, 1.2350, 11.1299),
                                                  (5.0, -0.5, -2.5), (149.9999, 6.9999, 999.9999), (0, 0, 0)]
        for (k, v) in values.enumerated() {
            journal.append(Reading(timestamp: t0.addingTimeInterval(Double(k) * 0.1), voltage: v.0, current: v.1, power: v.2,
                                   monotonic: 50 + Double(k) * 0.1))
        }
        journal.close()

        let size = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        XCTAssertEqual(size, RecordingJournal.headerSize + values.count * RecordingJournal.recordSize)
        XCTAssertEqual(RecordingJournal.count(url: url), values.count)
        XCTAssertEqual(try RecordingJournal.startEpoch(url: url).timeIntervalSince1970, t0.timeIntervalSince1970, accuracy: 1e-9)

        let (start, readings) = try RecordingJournal.read(url: url)
        XCTAssertEqual(start.timeIntervalSince1970, t0.timeIntervalSince1970, accuracy: 1e-9)
        XCTAssertEqual(readings.count, values.count)
        for (k, r) in readings.enumerated() {
            XCTAssertEqual(r.timestamp.timeIntervalSince(t0), Double(k) * 0.1, accuracy: 1e-3)
            XCTAssertEqual(r.monotonic, Double(k) * 0.1, accuracy: 1e-3)
            XCTAssertEqual(r.voltage, values[k].0, "voltage \(k)")
            XCTAssertEqual(r.current, values[k].1, "current \(k)")
            XCTAssertEqual(r.power, values[k].2, "power \(k)")
        }
        // Header bytes: magic, version, epoch.
        let data = try Data(contentsOf: url)
        XCTAssertEqual(Array(data[0..<4]), Array("WBJ1".utf8))
        XCTAssertEqual(Array(data[4..<8]), [1, 0, 0, 0])
        XCTAssertEqual(Double(bitPattern: data[8..<16].withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }),
                       t0.timeIntervalSince1970)
    }

    func testMonotonicOffsetsSurviveWallClockJump() throws {
        let journal = try RecordingJournal(url: url, startEpoch: t0, monotonicStart: 100)
        // The wall clock jumps forward an hour (NTP) between samples; the
        // monotonic stamps stay 100 ms apart.
        journal.append(Reading(timestamp: t0, voltage: 5, current: 1, power: 5, monotonic: 100.0))
        journal.append(Reading(timestamp: t0.addingTimeInterval(3600.1), voltage: 5, current: 1, power: 5, monotonic: 100.1))
        journal.append(Reading(timestamp: t0.addingTimeInterval(-500), voltage: 5, current: 1, power: 5, monotonic: 100.2))
        journal.close()

        let readings = try RecordingJournal.read(url: url).readings
        XCTAssertEqual(readings.map { $0.timestamp.timeIntervalSince(t0) }, [0, 0.1, 0.2].map { $0 }, accuracy: 1e-3)
        XCTAssertEqual(readings.map(\.monotonic), [0, 0.1, 0.2], accuracy: 1e-3)
        var stats = SessionStats()
        readings.forEach { stats.add($0) }
        XCTAssertEqual(stats.gapCount, 0)
        XCTAssertEqual(stats.durationS, 0.2, accuracy: 1e-3)
    }

    func testReadingsWithoutMonotonicUseWallOffset() throws {
        let journal = try RecordingJournal(url: url, startEpoch: t0, monotonicStart: 100)
        journal.append(Reading(timestamp: t0.addingTimeInterval(2.5), voltage: 5, current: 1, power: 5))
        journal.close()
        let r = try XCTUnwrap(try RecordingJournal.read(url: url).readings.first)
        XCTAssertEqual(r.timestamp.timeIntervalSince(t0), 2.5, accuracy: 1e-3)
    }

    func testTruncatedTrailingRecordIgnored() throws {
        let journal = try RecordingJournal(url: url, startEpoch: t0, flushEvery: 1, monotonicStart: 0)
        for k in 0..<5 { journal.append(reading(k, dt: 1, monotonicBase: 1)) }
        journal.close()
        XCTAssertEqual(RecordingJournal.count(url: url), 5)

        // Chop 7 bytes off the last record.
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(RecordingJournal.headerSize + 5 * RecordingJournal.recordSize - 7))
        try handle.close()
        XCTAssertEqual(RecordingJournal.count(url: url), 4)
        XCTAssertEqual(try RecordingJournal.read(url: url).readings.count, 4)

        // Only a header, or a header plus a few bytes: no records, no error.
        try handle(truncateTo: RecordingJournal.headerSize + 3)
        XCTAssertEqual(try RecordingJournal.read(url: url).readings.count, 0)
        XCTAssertEqual(RecordingJournal.count(url: url), 0)

        // Not a journal at all.
        try Data("hello".utf8).write(to: url)
        XCTAssertEqual(RecordingJournal.count(url: url), 0)
        XCTAssertThrowsError(try RecordingJournal.read(url: url))
        XCTAssertThrowsError(try RecordingJournal.startEpoch(url: url))
        XCTAssertEqual(RecordingJournal.count(url: url.appendingPathExtension("missing")), 0)
    }

    private func handle(truncateTo length: Int) throws {
        let h = try FileHandle(forWritingTo: url)
        try h.truncate(atOffset: UInt64(length))
        try h.close()
    }

    func testFlushEvery64RecordsOr1Second() throws {
        var clock = t0
        let journal = try RecordingJournal(url: url, startEpoch: t0, monotonicStart: 0, now: { clock })

        // 63 records inside the same second stay buffered.
        for k in 0..<63 { journal.append(reading(k, monotonicBase: 1)) }
        journal.waitForWrites()
        XCTAssertEqual(RecordingJournal.count(url: url), 0, "63 records stay in the buffer")
        XCTAssertEqual(journal.recordCount, 63)

        // The 64th record flushes the whole batch.
        journal.append(reading(63, monotonicBase: 1))
        journal.waitForWrites()
        XCTAssertEqual(RecordingJournal.count(url: url), 64)
        XCTAssertEqual(journal.bytesWritten, RecordingJournal.headerSize + 64 * RecordingJournal.recordSize)

        // A few more records, then the clock passes 1 s: time-based flush.
        for k in 64..<70 { journal.append(reading(k, monotonicBase: 1)) }
        journal.waitForWrites()
        XCTAssertEqual(RecordingJournal.count(url: url), 64, "6 records buffered while the second is young")
        clock = t0.addingTimeInterval(1.01)
        journal.append(reading(70, monotonicBase: 1))
        journal.waitForWrites()
        XCTAssertEqual(RecordingJournal.count(url: url), 71, "the first append after 1 s flushes")
        XCTAssertEqual(journal.lastFlush.timeIntervalSince(t0), 0, accuracy: 120,
                       "lastFlush is a real wall-clock stamp of the completed write")

        // synchronize() flushes too and stamps lastSync.
        journal.append(reading(71, monotonicBase: 1))
        journal.synchronize()
        journal.waitForWrites()
        XCTAssertEqual(RecordingJournal.count(url: url), 72)
        XCTAssertNil(journal.lastError)

        journal.close()
        XCTAssertEqual(RecordingJournal.count(url: url), 72)
        // Appends after close are ignored.
        journal.append(reading(72, monotonicBase: 1))
        XCTAssertEqual(journal.recordCount, 72)
    }

    func testCloseWritesBufferedRecords() throws {
        let journal = try RecordingJournal(url: url, startEpoch: t0, flushInterval: 3600, flushEvery: 1000, monotonicStart: 0)
        for k in 0..<10 { journal.append(reading(k, monotonicBase: 1)) }
        XCTAssertEqual(RecordingJournal.count(url: url), 0)
        journal.close()
        XCTAssertEqual(RecordingJournal.count(url: url), 10)
        XCTAssertEqual(journal.bytesWritten, RecordingJournal.headerSize + 10 * RecordingJournal.recordSize)
    }

    func testWriteWholeJournalFromReadings() throws {
        let readings = (0..<25).map { reading($0, v: 9.0123, i: 1.2345, w: 11.1257, monotonicBase: 0) }
        try RecordingJournal.write(readings, startEpoch: t0, to: url)
        XCTAssertEqual(RecordingJournal.count(url: url), 25)
        let back = try RecordingJournal.read(url: url).readings
        XCTAssertEqual(back.map(\.voltage), readings.map(\.voltage))
        XCTAssertEqual(back[24].timestamp.timeIntervalSince(t0), 2.4, accuracy: 1e-3)
    }

    func testFileProtectionAttribute() throws {
        let journal = try RecordingJournal(url: url, startEpoch: t0)
        journal.close()
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let protection = attrs[.protectionKey] as? FileProtectionType
        #if targetEnvironment(simulator)
        // The Simulator's host file system may not carry the attribute.
        if let protection { XCTAssertEqual(protection, .completeUntilFirstUserAuthentication) }
        #else
        XCTAssertEqual(protection, .completeUntilFirstUserAuthentication)
        #endif
    }
}

private func XCTAssertEqual(_ a: [Double], _ b: [Double], accuracy: Double, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a.count, b.count, file: file, line: line)
    for (x, y) in zip(a, b) { XCTAssertEqual(x, y, accuracy: accuracy, file: file, line: line) }
}
