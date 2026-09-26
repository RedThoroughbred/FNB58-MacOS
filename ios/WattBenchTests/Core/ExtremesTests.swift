import XCTest
@testable import WattBench

final class ExtremesTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_760_000_000)

    func testTracksMaxMinWithTimestamps() {
        var e = Extremes(since: t0)
        e.update(Reading(timestamp: t0, voltage: 5, current: 1, power: 5))
        e.update(Reading(timestamp: t0.addingTimeInterval(1), voltage: 9, current: 3, power: 27))   // inrush spike
        e.update(Reading(timestamp: t0.addingTimeInterval(2), voltage: 4.8, current: 0.5, power: 2.4))
        e.update(Reading(timestamp: t0.addingTimeInterval(3), voltage: 9, current: 3, power: 27))   // equal, not later
        XCTAssertEqual(e.maxV?.value, 9)
        XCTAssertEqual(e.maxV?.at, t0.addingTimeInterval(1), "the first occurrence of a maximum keeps its time")
        XCTAssertEqual(e.minV?.value, 4.8)
        XCTAssertEqual(e.minV?.at, t0.addingTimeInterval(2))
        XCTAssertEqual(e.maxI?.value, 3)
        XCTAssertEqual(e.minI?.value, 0.5)
        XCTAssertEqual(e.maxW?.value, 27)
        XCTAssertEqual(e.maxW?.at, t0.addingTimeInterval(1))
        XCTAssertEqual(e.since, t0)
    }

    func testResetClearsIndependently() {
        var e = Extremes(since: t0)
        e.update(Reading(timestamp: t0, voltage: 5, current: 1, power: 5))
        e.reset(at: t0.addingTimeInterval(3))
        XCTAssertNil(e.maxW)
        XCTAssertNil(e.minV)
        XCTAssertEqual(e.since, t0.addingTimeInterval(3))
        e.update(Reading(timestamp: t0.addingTimeInterval(4), voltage: 4, current: 0.2, power: 0.8))
        XCTAssertEqual(e.maxW?.value, 0.8, "values after a reset start from scratch")
    }

    func testCodableRoundTrip() throws {
        var e = Extremes(since: t0)
        e.update(Reading(timestamp: t0, voltage: 5, current: 1, power: 5))
        let back = try JSONDecoder().decode(Extremes.self, from: try JSONEncoder().encode(e))
        XCTAssertEqual(back, e)
    }
}
