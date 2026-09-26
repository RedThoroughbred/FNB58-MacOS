import XCTest
@testable import WattBench

final class SessionDecodeTests: XCTestCase {
    private func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }

    private func fixtureData() throws -> Data {
        let url = try XCTUnwrap(Bundle(for: SessionDecodeTests.self).url(forResource: "session-v1", withExtension: "json"))
        return try Data(contentsOf: url)
    }

    func testDecodesV1FixtureWithoutNewFields() throws {
        let data = try fixtureData()
        // Sanity: the fixture really is a 1.0 file.
        let raw = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(raw["schemaVersion"])
        XCTAssertNil(raw["markers"])
        let rawStats = try XCTUnwrap(raw["stats"] as? [String: Any])
        XCTAssertNotNil(rawStats["avgPower"])
        XCTAssertNil(rawStats["meanPowerSampled"])

        let s = try decoder().decode(Session.self, from: data)
        XCTAssertEqual(s.schemaVersion, 1)
        XCTAssertEqual(s.name, "Bench test (1.0 fixture)")
        XCTAssertEqual(s.deviceName, "FNB58")
        XCTAssertEqual(s.readings.count, 12)
        XCTAssertEqual(s.sampleCount, 12)
        XCTAssertTrue(s.markers.isEmpty)
        XCTAssertTrue(s.tags.isEmpty)
        XCTAssertNil(s.notes)
        XCTAssertNil(s.autoStopReason)
        XCTAssertFalse(s.isDemo)
        XCTAssertTrue(s.sparkline.isEmpty)
        XCTAssertEqual(s.readings[0].monotonic, 0)
        XCTAssertEqual(s.readings[0].voltage, 9.0123)
        XCTAssertEqual(s.readings[1].timestamp.timeIntervalSince(s.readings[0].timestamp), 0.1, accuracy: 1e-6)

        // Legacy avgPower is the sample mean; the new avgPower is time weighted.
        let legacyAvg = try XCTUnwrap(rawStats["avgPower"] as? Double)
        XCTAssertEqual(s.stats.meanPowerSampled, legacyAvg, accuracy: 1e-12)
        XCTAssertEqual(s.stats.avgPower, s.stats.energyWh * 3600 / s.stats.durationS, accuracy: 1e-9)
        XCTAssertEqual(s.stats.gapCount, 0)
        XCTAssertEqual(s.stats.samples, 12)

        let summary = s.summary()
        XCTAssertEqual(summary.sampleCount, 12)
        XCTAssertEqual(summary.state, .complete)
        XCTAssertEqual(summary.sparkline.count, 12)   // fewer readings than buckets -> one per reading
        XCTAssertEqual(summary.duration, 1.1, accuracy: 1e-6)
    }

    func testV2RoundTripKeepsNewFields() throws {
        var s = try decoder().decode(Session.self, from: fixtureData())
        s.schemaVersion = Session.currentSchema
        s.markers = [Marker(timestamp: s.startTime.addingTimeInterval(0.5), label: "Load on", kind: .user)]
        s.tags = ["bench"]
        s.notes = "note"
        s.autoStopReason = AutoStopRule.Reason.duration.rawValue
        s.isDemo = true
        s.sparkline = [1, 2, 3]
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        let back = try decoder().decode(Session.self, from: try e.encode(s))
        XCTAssertEqual(back, s)
        XCTAssertEqual(back.stats.meanPowerSampled, s.stats.meanPowerSampled)
    }

    func testReadingEncodesWithoutMonotonic() throws {
        let r = Reading(timestamp: Date(timeIntervalSince1970: 1), voltage: 1, current: 2, power: 2, monotonic: 42)
        let data = try JSONEncoder().encode(r)
        let keys = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any]).keys.sorted()
        XCTAssertEqual(keys, ["current", "power", "timestamp", "voltage"])
        let back = try JSONDecoder().decode(Reading.self, from: data)
        XCTAssertEqual(back.monotonic, 0)
        XCTAssertNotEqual(back.id, r.id)
    }
}
