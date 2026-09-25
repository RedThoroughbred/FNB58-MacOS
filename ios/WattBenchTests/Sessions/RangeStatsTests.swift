import XCTest
@testable import WattBench

@MainActor
final class RangeStatsTests: XCTestCase {
    private typealias S = SessionTestSupport

    func testIndexRangeBinarySearchBoundaries() {
        let readings = S.readings(count: 100)   // t0 + 0.0 ... t0 + 9.9
        func t(_ k: Int, _ offset: TimeInterval = 0) -> Date { readings[k].timestamp.addingTimeInterval(offset) }

        // Both ends inclusive when they land exactly on samples.
        XCTAssertEqual(RangeStats.indexRange(in: readings, from: t(10), to: t(20)), 10..<21)
        // Between samples: only the samples strictly inside.
        XCTAssertEqual(RangeStats.indexRange(in: readings, from: t(10, 0.05), to: t(19, 0.05)), 11..<20)
        // Clamped to the array at both ends.
        XCTAssertEqual(RangeStats.indexRange(in: readings, from: t(0, -100), to: t(99, 100)), 0..<100)
        XCTAssertEqual(RangeStats.indexRange(in: readings, from: t(99), to: t(99, 1)), 99..<100)
        XCTAssertEqual(RangeStats.indexRange(in: readings, from: t(0), to: t(0)), 0..<1)
        // Nothing inside, inverted, or empty input.
        XCTAssertTrue(RangeStats.indexRange(in: readings, from: t(10, 0.01), to: t(10, 0.09)).isEmpty)
        XCTAssertTrue(RangeStats.indexRange(in: readings, from: t(20), to: t(10)).isEmpty)
        XCTAssertTrue(RangeStats.indexRange(in: readings, from: t(99, 200), to: t(99, 300)).isEmpty)
        XCTAssertTrue(RangeStats.indexRange(in: [], from: t(0), to: t(10)).isEmpty)

        // Nearest-sample lookup used by the scrub cursor.
        XCTAssertEqual(RangeStats.nearestIndex(in: readings, to: t(10, 0.04)), 10)
        XCTAssertEqual(RangeStats.nearestIndex(in: readings, to: t(10, 0.06)), 11)
        XCTAssertEqual(RangeStats.nearestIndex(in: readings, to: t(50)), 50)
        XCTAssertEqual(RangeStats.nearestIndex(in: readings, to: t(0, -5)), 0)
        XCTAssertEqual(RangeStats.nearestIndex(in: readings, to: t(99, 500)), 99)
        XCTAssertNil(RangeStats.nearestIndex(in: [], to: t(0)))
    }

    func testFullRangeEqualsSessionStats() throws {
        // A recorded session with a varying load and a 20 s gap in the middle.
        let rec = SessionRecorder(name: "Full", deviceName: "FNB58")
        var readings = S.readings(count: 300, voltage: { 9 + 0.001 * Double($0 % 7) },
                                  current: { 0.5 + 0.01 * Double($0 % 13) })
        readings.append(contentsOf: S.readings(count: 300, start: S.t0.addingTimeInterval(29.9 + 20),
                                               voltage: { _ in 5 }, current: { 1.5 + 0.002 * Double($0 % 5) }))
        for r in readings { _ = rec.add(r) }
        let session = rec.finish()
        XCTAssertEqual(session.stats.gapCount, 1)

        // (The recorder stamps startTime with the wall clock; the span of the
        // samples themselves is what the detail screen selects.)
        let first = try XCTUnwrap(session.readings.first?.timestamp)
        let last = try XCTUnwrap(session.readings.last?.timestamp)
        let range = RangeStats.indexRange(in: session.readings, from: first, to: last)
        XCTAssertEqual(range, 0..<600)
        let full = RangeStats.stats(session.readings[range])
        let expected = session.stats
        XCTAssertEqual(full.samples, expected.samples)
        XCTAssertEqual(full.energyWh, expected.energyWh, accuracy: 1e-12)
        XCTAssertEqual(full.capacityAh, expected.capacityAh, accuracy: 1e-12)
        XCTAssertEqual(full.durationS, expected.durationS, accuracy: 1e-9)
        XCTAssertEqual(full.avgPower, expected.avgPower, accuracy: 1e-9)
        XCTAssertEqual(full.avgVoltage, expected.avgVoltage, accuracy: 1e-9)
        XCTAssertEqual(full.avgCurrent, expected.avgCurrent, accuracy: 1e-9)
        XCTAssertEqual(full.minVoltage, expected.minVoltage)
        XCTAssertEqual(full.maxVoltage, expected.maxVoltage)
        XCTAssertEqual(full.minCurrent, expected.minCurrent)
        XCTAssertEqual(full.maxCurrent, expected.maxCurrent)
        XCTAssertEqual(full.maxPower, expected.maxPower)
        XCTAssertEqual(full.gapCount, expected.gapCount)
        XCTAssertEqual(full.gapSeconds, expected.gapSeconds, accuracy: 1e-9)

        // A slice reports only its own span.
        let half = RangeStats.stats(session.readings[RangeStats.indexRange(in: session.readings,
                                                                           from: first, to: session.readings[299].timestamp)])
        XCTAssertEqual(half.samples, 300)
        XCTAssertEqual(half.gapCount, 0)
        XCTAssertEqual(half.durationS, 29.9, accuracy: 1e-6)
        XCTAssertLessThan(half.energyWh, full.energyWh)
    }

    func testEnergyBetweenMarkers() {
        // Constant 10 W (5 V x 2 A) for 10 s at 10 Hz.
        let readings = S.readings(count: 101, voltage: { _ in 5 }, current: { _ in 2 })
        let markers = [
            Marker(timestamp: readings[80].timestamp, label: "C"),
            Marker(timestamp: readings[20].timestamp, label: "A"),
            Marker(timestamp: readings[50].timestamp, label: "B"),
        ]
        let spans = RangeStats.spans(in: readings, between: markers)
        XCTAssertEqual(spans.count, 2)
        XCTAssertEqual(spans.map(\.from.label), ["A", "B"])
        XCTAssertEqual(spans.map(\.to.label), ["B", "C"])
        // 3 s at 10 W = 30 Ws = 1/120 Wh in each span.
        for span in spans {
            XCTAssertEqual(span.stats.durationS, 3, accuracy: 1e-9)
            XCTAssertEqual(span.stats.energyWh, 30.0 / 3600, accuracy: 1e-12)
            XCTAssertEqual(span.stats.capacityAh, 6.0 / 3600, accuracy: 1e-12)
            XCTAssertEqual(span.stats.samples, 31)
        }
        XCTAssertTrue(RangeStats.spans(in: readings, between: Array(markers.prefix(1))).isEmpty)
        XCTAssertTrue(RangeStats.spans(in: readings, between: []).isEmpty)
    }
}
