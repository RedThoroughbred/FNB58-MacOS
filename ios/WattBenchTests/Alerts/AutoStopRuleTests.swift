import XCTest
@testable import WattBench

final class AutoStopRuleTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_760_000_000)
    private let formatter = MetricFormatter(locale: Locale(identifier: "en_US"), precision: 3)

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

    func testBelowThresholdResetsAbove102Percent() {
        let stats = SessionStats()

        // 1.01 A is inside the 2 % band: the time already spent below is kept.
        var kept = AutoStopRule(belowCurrentA: 1.0, forSeconds: 0.3)
        XCTAssertNil(kept.evaluate(r(0.5, at: 0), dt: 0.2, stats: stats))
        XCTAssertNil(kept.evaluate(r(1.01, at: 0.2), dt: 0.2, stats: stats))
        XCTAssertEqual(kept.evaluate(r(0.5, at: 0.4), dt: 0.2, stats: stats), .currentBelowThreshold)

        // 1.03 A is above threshold + 2 %: the counter starts over.
        var reset = AutoStopRule(belowCurrentA: 1.0, forSeconds: 0.3)
        XCTAssertNil(reset.evaluate(r(0.5, at: 0), dt: 0.2, stats: stats))
        XCTAssertNil(reset.evaluate(r(1.03, at: 0.2), dt: 0.2, stats: stats))
        XCTAssertNil(reset.evaluate(r(0.5, at: 0.4), dt: 0.2, stats: stats))
        XCTAssertEqual(reset.evaluate(r(0.5, at: 0.6), dt: 0.2, stats: stats), .currentBelowThreshold)

        // Exactly 1.02 A resets too (the boundary belongs to "re-armed").
        var edge = AutoStopRule(belowCurrentA: 1.0, forSeconds: 0.3)
        XCTAssertNil(edge.evaluate(r(0.5, at: 0), dt: 0.2, stats: stats))
        XCTAssertNil(edge.evaluate(r(1.02, at: 0.2), dt: 0.2, stats: stats))
        XCTAssertNil(edge.evaluate(r(0.5, at: 0.4), dt: 0.2, stats: stats))
    }

    func testDurationAndEnergyReasons() {
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

        // Gaps are not active time: 10 s of duration takes real samples.
        var gapped = AutoStopRule(maxDuration: 10)
        var g = SessionStats()
        g.add(r(1, at: 0))
        g.add(r(1, at: 100))   // one 100 s gap, durationS still 0
        XCTAssertNil(gapped.evaluate(r(1, at: 100), dt: 100, stats: g))
        XCTAssertEqual(g.durationS, 0)

        // When several limits are hit on the same sample, duration wins over
        // energy, which wins over the current threshold.
        var all = AutoStopRule(belowCurrentA: 5, forSeconds: 0, maxDuration: 10, maxEnergyWh: 0.001)
        XCTAssertEqual(all.evaluate(r(1, at: 10), dt: 5, stats: stats), .duration)
        var two = AutoStopRule(belowCurrentA: 5, forSeconds: 0, maxEnergyWh: 0.001)
        XCTAssertEqual(two.evaluate(r(1, at: 10), dt: 5, stats: stats), .energy)
        XCTAssertEqual(AutoStopRule.Reason.duration.label, "duration reached")
        XCTAssertEqual(AutoStopRule.Reason.energy.label, "energy reached")
        XCTAssertEqual(AutoStopRule.Reason.currentBelowThreshold.label, "current below threshold")
    }

    func testCodableRoundTrip() throws {
        let rule = AutoStopRule(belowCurrentA: 0.1, forSeconds: 30, maxDuration: 3600, maxEnergyWh: nil)
        let back = try JSONDecoder().decode(AutoStopRule.self, from: try JSONEncoder().encode(rule))
        XCTAssertEqual(back, rule)
    }

    func testProgressBelowThresholdIsNotPersisted() throws {
        var rule = AutoStopRule(belowCurrentA: 0.1, forSeconds: 1)
        let stats = SessionStats()
        for k in 0...4 {
            XCTAssertNil(rule.evaluate(r(0.05, at: Double(k) * 0.1), dt: k == 0 ? 0 : 0.1, stats: stats))
        }
        // 0.4 s accumulated; a copy stored in Preferences starts from zero.
        var restored = try JSONDecoder().decode(AutoStopRule.self, from: try JSONEncoder().encode(rule))
        for k in 5...10 {
            let reading = r(0.05, at: Double(k) * 0.1)
            let original = rule.evaluate(reading, dt: 0.1, stats: stats)
            let fresh = restored.evaluate(reading, dt: 0.1, stats: stats)
            XCTAssertNil(fresh, "a restored rule needs the full second again (sample \(k))")
            if k < 10 {
                XCTAssertNil(original, "sample \(k)")
            } else {
                XCTAssertEqual(original, .currentBelowThreshold)
            }
        }
    }

    func testSummaryAndReasonDescriptions() {
        let rule = AutoStopRule(belowCurrentA: 0.1, forSeconds: 60, maxDuration: 3600, maxEnergyWh: 10)
        XCTAssertFalse(rule.isEmpty)
        XCTAssertEqual(rule.summary(formatter: formatter), "current below 100 mA for 1 min · after 1 hr · at 10 Wh")
        XCTAssertEqual(rule.description(of: .currentBelowThreshold, formatter: formatter), "current below 100 mA for 1 min")
        XCTAssertEqual(rule.description(of: .duration, formatter: formatter), "after 1 hr")
        XCTAssertEqual(rule.description(of: .energy, formatter: formatter), "at 10 Wh")

        let empty = AutoStopRule()
        XCTAssertTrue(empty.isEmpty)
        XCTAssertEqual(empty.summary(formatter: formatter), "")
        XCTAssertEqual(empty.description(of: .energy, formatter: formatter), AutoStopRule.Reason.energy.label)
        XCTAssertEqual(AutoStopRule(maxEnergyWh: 0.25).summary(formatter: formatter), "at 250 mWh")
    }
}
