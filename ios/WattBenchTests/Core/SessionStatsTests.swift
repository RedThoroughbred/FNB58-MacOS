import XCTest
@testable import WattBench

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

    // MARK: 1.1 additions

    func testAvgPowerIsTimeWeighted() {
        var s = SessionStats()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        // 1 s at 10 W, then 3 s at 20 W (rectangle rule on the arriving sample).
        let powers: [Double] = [10, 10, 20, 20, 20]
        for (k, w) in powers.enumerated() {
            s.add(Reading(timestamp: t0.addingTimeInterval(Double(k)), voltage: 10, current: w / 10, power: w))
        }
        XCTAssertEqual(s.durationS, 4, accuracy: 1e-9)
        XCTAssertEqual(s.energyWh, 70.0 / 3600, accuracy: 1e-9)
        XCTAssertEqual(s.avgPower, 17.5, accuracy: 1e-9)          // energy-weighted
        XCTAssertEqual(s.meanPowerSampled, 16, accuracy: 1e-9)    // plain sample mean
        XCTAssertNotEqual(s.avgPower, s.meanPowerSampled)

        // Before any interval was integrated the sample mean is the fallback.
        var single = SessionStats()
        single.add(Reading(timestamp: t0, voltage: 5, current: 1, power: 5))
        XCTAssertEqual(single.avgPower, 5)
    }

    func testGapIsCounted() {
        var s = SessionStats()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        s.add(Reading(timestamp: t0, voltage: 5, current: 1, power: 5))
        s.add(Reading(timestamp: t0.addingTimeInterval(0.1), voltage: 5, current: 1, power: 5))
        s.add(Reading(timestamp: t0.addingTimeInterval(60.1), voltage: 5, current: 1, power: 5))   // 60 s gap
        s.add(Reading(timestamp: t0.addingTimeInterval(60.2), voltage: 5, current: 1, power: 5))
        XCTAssertEqual(s.gapCount, 1)
        XCTAssertEqual(s.gapSeconds, 60, accuracy: 1e-6)
        XCTAssertEqual(s.durationS, 0.2, accuracy: 1e-6)
        XCTAssertEqual(s.energyWh, 5 * 0.2 / 3600, accuracy: 1e-9)
        XCTAssertEqual(s.samples, 4)
    }

    func testMonotonicDtPreferred() {
        var s = SessionStats()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        // Wall clock jumps forward by an hour between samples 1 and 2, but the
        // monotonic clock says they are 100 ms apart.
        s.add(Reading(timestamp: t0, voltage: 5, current: 1, power: 5, monotonic: 100.0))
        s.add(Reading(timestamp: t0.addingTimeInterval(0.1), voltage: 5, current: 1, power: 5, monotonic: 100.1))
        s.add(Reading(timestamp: t0.addingTimeInterval(3600.2), voltage: 5, current: 1, power: 5, monotonic: 100.2))
        XCTAssertEqual(s.gapCount, 0)
        XCTAssertEqual(s.durationS, 0.2, accuracy: 1e-6)

        // Without monotonic stamps the same wall-clock jump is a gap.
        var w = SessionStats()
        w.add(Reading(timestamp: t0, voltage: 5, current: 1, power: 5))
        w.add(Reading(timestamp: t0.addingTimeInterval(0.1), voltage: 5, current: 1, power: 5))
        w.add(Reading(timestamp: t0.addingTimeInterval(3600.2), voltage: 5, current: 1, power: 5))
        XCTAssertEqual(w.gapCount, 1)
        XCTAssertEqual(w.durationS, 0.1, accuracy: 1e-6)
    }

    func testMonotonicDtUsedWhenPresent() {
        var s = SessionStats()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        s.add(Reading(timestamp: t0, voltage: 5, current: 1, power: 5, monotonic: 50))
        // dt(to:) is what the recorder and the pipeline pass around.
        XCTAssertEqual(s.dt(to: Reading(timestamp: t0.addingTimeInterval(7), voltage: 5, current: 1, power: 5, monotonic: 50.1)),
                       0.1, accuracy: 1e-9, "monotonic stamps on both sides win over the wall clock")
        XCTAssertEqual(s.dt(to: Reading(timestamp: t0.addingTimeInterval(0.3), voltage: 5, current: 1, power: 5)),
                       0.3, accuracy: 1e-6, "a reading without a stamp falls back to the wall clock")
        // A mixed pair (stamped after an unstamped one) also uses the wall clock.
        var mixed = SessionStats()
        mixed.add(Reading(timestamp: t0, voltage: 5, current: 1, power: 5))
        XCTAssertEqual(mixed.dt(to: Reading(timestamp: t0.addingTimeInterval(0.2), voltage: 5, current: 1, power: 5, monotonic: 99)),
                       0.2, accuracy: 1e-6)
        // Equality ignores the process-local monotonic cache, so a value that
        // went through JSON compares equal to the live one.
        s.add(Reading(timestamp: t0.addingTimeInterval(0.1), voltage: 5, current: 1, power: 5, monotonic: 50.1))
        let decoded = try? JSONDecoder().decode(SessionStats.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(decoded, s)
    }

    func testDecodesLegacyAvgPowerKey() throws {
        let json = """
        {"samples":3,"minVoltage":5,"maxVoltage":5,"minCurrent":1,"maxCurrent":1,"maxPower":5,
         "avgVoltage":5,"avgCurrent":1,"avgPower":4.5,"energyWh":0.001,"capacityAh":0.0002,"durationS":0.2}
        """
        let s = try JSONDecoder().decode(SessionStats.self, from: Data(json.utf8))
        XCTAssertEqual(s.meanPowerSampled, 4.5)
        XCTAssertEqual(s.gapCount, 0)
        XCTAssertEqual(s.gapSeconds, 0)
        XCTAssertEqual(s.avgPower, 0.001 * 3600 / 0.2, accuracy: 1e-9)
    }
}
