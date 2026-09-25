import XCTest
@testable import WattBench

final class ProtocolTests: XCTestCase {
    private func frame(v: Double, i: Double, w: Double, prefix: Int = FNB58Protocol.frameOffset) -> Data {
        var d = Data(repeating: 0, count: prefix)
        for x in [v, i, w] {
            var le = Int32((x * FNB58Protocol.scale).rounded()).littleEndian
            d.append(Data(bytes: &le, count: 4))
        }
        return d
    }

    func testParsesVoltageCurrentPower() throws {
        let r = try XCTUnwrap(FNB58Protocol.parse(frame(v: 9.0123, i: 1.2345, w: 11.1234)))
        XCTAssertEqual(r.voltage, 9.0123, accuracy: 1e-6)
        XCTAssertEqual(r.current, 1.2345, accuracy: 1e-6)
        XCTAssertEqual(r.power, 11.1234, accuracy: 1e-6)
    }

    func testParsesFromSlicedData() throws {
        // Data slices have non-zero startIndex; parser must index relative to it.
        let padded = Data([0xFF, 0xFF]) + frame(v: 5, i: 2, w: 10)
        let slice = padded[2...]
        let r = try XCTUnwrap(FNB58Protocol.parse(slice))
        XCTAssertEqual(r.voltage, 5, accuracy: 1e-9)
    }

    func testRejectsShortFrame() {
        XCTAssertNil(FNB58Protocol.parse(Data(repeating: 0, count: FNB58Protocol.frameOffset + 11)))
    }

    func testRejectsOutOfRangeVoltage() {
        XCTAssertNil(FNB58Protocol.parse(frame(v: -1, i: 0, w: 0)))
        XCTAssertNil(FNB58Protocol.parse(frame(v: 200, i: 0, w: 0)))
    }

    func testNegativeCurrentAllowed() throws {
        let r = try XCTUnwrap(FNB58Protocol.parse(frame(v: 5, i: -0.5, w: -2.5)))
        XCTAssertEqual(r.current, -0.5, accuracy: 1e-9)
    }

    func testInitCommands() {
        XCTAssertEqual(FNB58Protocol.initCommands, [Data([0xAA, 0x81, 0x00, 0xF4]), Data([0xAA, 0x82, 0x00, 0xA7])])
    }
}

final class SessionStatsTests: XCTestCase {
    func testIntegratesEnergyFromTimestamps() {
        var s = SessionStats()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        // 101 samples, 10 ms apart -> 1.0 s at 5 V / 2 A = 10 W
        for k in 0..<101 {
            s.add(Reading(timestamp: t0.addingTimeInterval(Double(k) * 0.01), voltage: 5, current: 2, power: 10))
        }
        XCTAssertEqual(s.samples, 101)
        XCTAssertEqual(s.durationS, 1.0, accuracy: 1e-6)
        XCTAssertEqual(s.energyWh, 10.0 / 3600, accuracy: 1e-9)
        XCTAssertEqual(s.capacityAh, 2.0 / 3600, accuracy: 1e-9)
        XCTAssertEqual(s.avgVoltage, 5, accuracy: 1e-9)
        XCTAssertEqual(s.minVoltage, 5)
        XCTAssertEqual(s.maxCurrent, 2)
    }

    func testLargeGapIsNotIntegrated() {
        var s = SessionStats()
        let t0 = Date()
        s.add(Reading(timestamp: t0, voltage: 5, current: 1, power: 5))
        s.add(Reading(timestamp: t0.addingTimeInterval(60), voltage: 5, current: 1, power: 5))
        XCTAssertEqual(s.durationS, 0)
        XCTAssertEqual(s.energyWh, 0)
    }

    func testEmptyStatsHaveNoMinMax() {
        let s = SessionStats()
        XCTAssertNil(s.minVoltage)
        XCTAssertNil(s.maxVoltage)
    }
}

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
            rec.add(Reading(timestamp: t0.addingTimeInterval(Double(k) * 0.1), voltage: 9, current: 1, power: 9))
        }
        return rec.finish()
    }

    func testSaveLoadDeleteRoundTrip() throws {
        let store = SessionStore(directory: dir)
        let s = sampleSession()
        XCTAssertEqual(s.name, "Bench test")
        try store.save(s)

        let reloaded = SessionStore(directory: dir)
        XCTAssertEqual(reloaded.sessions.count, 1)
        let r = try XCTUnwrap(reloaded.sessions.first)
        XCTAssertEqual(r.id, s.id)
        XCTAssertEqual(r.name, s.name)
        XCTAssertEqual(r.readings.count, s.readings.count)
        XCTAssertEqual(r.stats.samples, s.stats.samples)
        XCTAssertEqual(r.stats.energyWh, s.stats.energyWh, accuracy: 1e-12)
        // Sub-second timestamps must survive the round trip (10 ms spacing).
        let dt = r.readings[1].timestamp.timeIntervalSince(r.readings[0].timestamp)
        XCTAssertEqual(dt, 0.1, accuracy: 1e-6)

        reloaded.delete(s)
        XCTAssertTrue(reloaded.sessions.isEmpty)
        XCTAssertTrue(SessionStore(directory: dir).sessions.isEmpty)
    }

    func testCSVExport() throws {
        let store = SessionStore(directory: dir)
        let s = sampleSession()
        let url = try store.csvURL(for: s)
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(separator: "\n")
        XCTAssertEqual(lines.first, "timestamp,voltage_v,current_a,power_w")
        XCTAssertEqual(lines.count, 11)
        XCTAssertTrue(lines[1].hasSuffix(",9.0,1.0,9.0"))
    }
}
