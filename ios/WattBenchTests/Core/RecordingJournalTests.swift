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

    func testAppendReadRoundTrip() throws {
        let journal = try RecordingJournal(url: url, startEpoch: t0, monotonicStart: 50)
        let values: [(Double, Double, Double)] = [(9.0123, 1.2345, 11.1234), (9.0121, 1.2350, 11.1299), (5.0, -0.5, -2.5)]
        for (k, v) in values.enumerated() {
            journal.append(Reading(timestamp: t0.addingTimeInterval(Double(k) * 0.1), voltage: v.0, current: v.1, power: v.2,
                                   monotonic: 50 + Double(k) * 0.1))
        }
        journal.close()

        let size = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        XCTAssertEqual(size, RecordingJournal.headerSize + 3 * RecordingJournal.recordSize)
        XCTAssertEqual(RecordingJournal.count(url: url), 3)

        let (start, readings) = try RecordingJournal.read(url: url)
        XCTAssertEqual(start.timeIntervalSince1970, t0.timeIntervalSince1970, accuracy: 1e-9)
        XCTAssertEqual(readings.count, 3)
        for (k, r) in readings.enumerated() {
            XCTAssertEqual(r.timestamp.timeIntervalSince(t0), Double(k) * 0.1, accuracy: 1e-3)
            XCTAssertEqual(r.monotonic, Double(k) * 0.1, accuracy: 1e-3)
            XCTAssertEqual(r.voltage, Double(Float(values[k].0)))
            XCTAssertEqual(r.current, Double(Float(values[k].1)))
            XCTAssertEqual(r.power, Double(Float(values[k].2)))
        }
        // Header bytes: magic, version, epoch.
        let data = try Data(contentsOf: url)
        XCTAssertEqual(Array(data[0..<4]), Array("WBJ1".utf8))
        XCTAssertEqual(data[4], 1)
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

    func testCountAndTruncatedTrailingRecordIgnored() throws {
        let journal = try RecordingJournal(url: url, startEpoch: t0, flushEvery: 1, monotonicStart: 0)
        for k in 0..<5 {
            journal.append(Reading(timestamp: t0.addingTimeInterval(Double(k)), voltage: 5, current: 1, power: 5, monotonic: 1 + Double(k)))
        }
        journal.close()
        XCTAssertEqual(RecordingJournal.count(url: url), 5)

        // Chop 7 bytes off the last record.
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(RecordingJournal.headerSize + 5 * RecordingJournal.recordSize - 7))
        try handle.close()
        XCTAssertEqual(RecordingJournal.count(url: url), 4)
        XCTAssertEqual(try RecordingJournal.read(url: url).readings.count, 4)

        // Not a journal at all.
        try Data("hello".utf8).write(to: url)
        XCTAssertEqual(RecordingJournal.count(url: url), 0)
        XCTAssertThrowsError(try RecordingJournal.read(url: url))
    }

    func testBufferedRecordsFlushOnCountOrClose() throws {
        let journal = try RecordingJournal(url: url, startEpoch: t0, flushInterval: 3600, flushEvery: 4, monotonicStart: 0)
        for k in 0..<3 {
            journal.append(Reading(timestamp: t0.addingTimeInterval(Double(k)), voltage: 5, current: 1, power: 5, monotonic: 1 + Double(k)))
        }
        XCTAssertEqual(RecordingJournal.count(url: url), 0, "three records are still buffered")
        journal.append(Reading(timestamp: t0.addingTimeInterval(3), voltage: 5, current: 1, power: 5, monotonic: 4))
        XCTAssertEqual(RecordingJournal.count(url: url), 4, "the 4th record triggers a flush")
        journal.append(Reading(timestamp: t0.addingTimeInterval(4), voltage: 5, current: 1, power: 5, monotonic: 5))
        journal.close()
        XCTAssertEqual(RecordingJournal.count(url: url), 5)
        XCTAssertEqual(journal.recordCount, 5)
        XCTAssertEqual(journal.bytesWritten, RecordingJournal.headerSize + 5 * RecordingJournal.recordSize)
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
