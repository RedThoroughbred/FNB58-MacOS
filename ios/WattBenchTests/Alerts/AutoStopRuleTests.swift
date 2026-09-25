import XCTest
@testable import WattBench

final class AutoStopRuleTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_760_000_000)

    private func r(_ current: Double, at s: TimeInterval) -> Reading {
        Reading(timestamp: t0.addingTimeInterval(s), voltage: 5, current: current, power: 5 * current)
    }

    func testCountsOnlyRealSamples() {
        var rule = AutoStopRule(belowCurrentA: 0.1, forSeconds: 1)
        var stats = SessionStats()
        // 6 samples 100 ms apart = 0.5 s of real samples below threshold
        // (the first sample has dt 0).
        for k in 0...5 {
            let reading = r(0.05, at: Double(k) * 0.1)
            let dt = stats.dt(to: reading)
            stats.add(reading, dt: dt)
            XCTAssertNil(rule.evaluate(reading, dt: dt, stats: stats))
        }
        // A 60 s gap must not count as "below for 60 s".
        let afterGap = r(0.05, at: 60.5)
        let gapDt = stats.dt(to: afterGap)
        XCTAssertGreaterThan(gapDt, SessionStats.maxGapS)
        stats.add(afterGap, dt: gapDt)
        XCTAssertNil(rule.evaluate(afterGap, dt: gapDt, stats: stats))
        // 0.4 s more is still short of 1 s ...
        for k in 1...4 {
            let reading = r(0.05, at: 60.5 + Double(k) * 0.1)
            let dt = stats.dt(to: reading)
            stats.add(reading, dt: dt)
            XCTAssertNil(rule.evaluate(reading, dt: dt, stats: stats), "sample \(k) after the gap")
        }
        // ... and the sample that completes 1.0 s of real samples stops.
        let last = r(0.05, at: 61.0)
        let lastDt = stats.dt(to: last)
        stats.add(last, dt: lastDt)
        XCTAssertEqual(rule.evaluate(last, dt: lastDt, stats: stats), .currentBelowThreshold)
    }

    func testHysteresisResetsOnlyAboveThresholdPlusTwoPercent() {
        var rule = AutoStopRule(belowCurrentA: 1.0, forSeconds: 0.3)
        let stats = SessionStats()
        XCTAssertNil(rule.evaluate(r(0.5, at: 0), dt: 0.2, stats: stats))
        XCTAssertNil(rule.evaluate(r(1.01, at: 0.2), dt: 0.2, stats: stats))   // inside the band: no reset
        XCTAssertEqual(rule.evaluate(r(0.5, at: 0.4), dt: 0.2, stats: stats), .currentBelowThreshold)

        var reset = AutoStopRule(belowCurrentA: 1.0, forSeconds: 0.3)
        XCTAssertNil(reset.evaluate(r(0.5, at: 0), dt: 0.2, stats: stats))
        XCTAssertNil(reset.evaluate(r(1.03, at: 0.2), dt: 0.2, stats: stats))   // above 1.02 -> reset
        XCTAssertNil(reset.evaluate(r(0.5, at: 0.4), dt: 0.2, stats: stats))
    }

    func testDurationAndEnergyLimits() {
        var byDuration = AutoStopRule(maxDuration: 10)
        var stats = SessionStats()
        stats.add(r(1, at: 0))
        stats.add(r(1, at: 5))
        XCTAssertNil(byDuration.evaluate(r(1, at: 5), dt: 5, stats: stats))
        stats.add(r(1, at: 10))
        XCTAssertEqual(byDuration.evaluate(r(1, at: 10), dt: 5, stats: stats), .duration)

        var byEnergy = AutoStopRule(maxEnergyWh: 0.01)
        var e = SessionStats()
        e.add(r(1, at: 0))
        e.add(r(1, at: 5))    // 5 W * 5 s = 25 Ws = 0.0069 Wh
        XCTAssertNil(byEnergy.evaluate(r(1, at: 5), dt: 5, stats: e))
        e.add(r(1, at: 10))   // 0.0139 Wh
        XCTAssertEqual(byEnergy.evaluate(r(1, at: 10), dt: 5, stats: e), .energy)
    }

    func testCodableRoundTrip() throws {
        let rule = AutoStopRule(belowCurrentA: 0.1, forSeconds: 30, maxDuration: 3600, maxEnergyWh: nil)
        let back = try JSONDecoder().decode(AutoStopRule.self, from: try JSONEncoder().encode(rule))
        XCTAssertEqual(back, rule)
    }
}
