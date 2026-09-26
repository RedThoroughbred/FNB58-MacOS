import XCTest
@testable import WattBench

final class TripMeterTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_760_000_000)

    private func reading(at s: TimeInterval, power: Double = 10) -> Reading {
        Reading(timestamp: t0.addingTimeInterval(s), voltage: 5, current: power / 5, power: power)
    }

    func testGapNotIntegrated() {
        var trip = TripMeter(label: "Trip", startedAt: t0)
        trip.add(reading(at: 0))
        trip.add(reading(at: 1))
        trip.add(reading(at: 61))    // 60 s reconnect pause
        trip.add(reading(at: 62))
        XCTAssertEqual(trip.elapsed, 2, accuracy: 1e-9, "the pause is not part of the active time")
        XCTAssertEqual(trip.stats.energyWh, 20.0 / 3600, accuracy: 1e-12, "and adds no energy")
        XCTAssertEqual(trip.stats.capacityAh, 4.0 / 3600, accuracy: 1e-12)
        XCTAssertEqual(trip.stats.gapCount, 1)
        XCTAssertEqual(trip.stats.gapSeconds, 60, accuracy: 1e-9)
    }

    func testPersistsAndRestores() throws {
        var trip = TripMeter(label: "Trip", startedAt: t0)
        for k in 0..<20 { trip.add(reading(at: Double(k) * 0.1)) }
        let data = try JSONEncoder().encode(trip)
        let back = try JSONDecoder().decode(TripMeter.self, from: data)
        XCTAssertEqual(back, trip)
        XCTAssertEqual(back.stats.energyWh, trip.stats.energyWh)
        XCTAssertEqual(back.stats.samples, 20)
        XCTAssertEqual(back.label, "Trip")
        XCTAssertEqual(back.startedAt, t0)
        // Integration continues seamlessly after a restore (the last sample
        // time survives, so the next reading adds exactly one interval).
        var resumed = back
        resumed.add(reading(at: 2.0))
        XCTAssertEqual(resumed.elapsed, 2.0, accuracy: 1e-9)
    }

    func testResetRestartsClock() {
        var trip = TripMeter(label: "Trip", startedAt: t0)
        trip.add(reading(at: 0))
        trip.add(reading(at: 1))
        XCTAssertEqual(trip.elapsed, 1, accuracy: 1e-9)
        let later = t0.addingTimeInterval(1000)
        trip.reset(at: later)
        XCTAssertEqual(trip.startedAt, later)
        XCTAssertEqual(trip.elapsed, 0)
        XCTAssertEqual(trip.stats, SessionStats())
        // The first reading after a reset starts a fresh interval chain.
        trip.add(reading(at: 1000))
        trip.add(reading(at: 1000.5))
        XCTAssertEqual(trip.elapsed, 0.5, accuracy: 1e-9)
    }
}
