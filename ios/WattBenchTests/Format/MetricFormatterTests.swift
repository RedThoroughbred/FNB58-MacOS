import XCTest
@testable import WattBench

final class MetricFormatterTests: XCTestCase {
    private let posix = Locale(identifier: "en_US_POSIX")

    private func formatter(precision: Int = 3, autoRange: Bool = true,
                           capacityUnit: Preferences.CapacityUnit = .Ah) -> MetricFormatter {
        MetricFormatter(locale: posix, precision: precision, autoRange: autoRange, capacityUnit: capacityUnit)
    }

    // MARK: Foundation coverage (kept from the foundation commit)

    func testBoundaries() {
        // Hysteresis: down to milli below 0.95, back to base above 1.05.
        XCTAssertEqual(UnitRange.range(for: 0.949, metric: .current, previous: nil), .milli)
        XCTAssertEqual(UnitRange.range(for: 0.951, metric: .current, previous: nil), .base)
        XCTAssertEqual(UnitRange.range(for: 1.0, metric: .current, previous: .milli), .milli)
        XCTAssertEqual(UnitRange.range(for: 1.049, metric: .current, previous: .milli), .milli)
        XCTAssertEqual(UnitRange.range(for: 1.051, metric: .current, previous: .milli), .base)
        XCTAssertEqual(UnitRange.range(for: 0.96, metric: .current, previous: .base), .base)
        XCTAssertEqual(UnitRange.range(for: 0.949, metric: .current, previous: .base), .milli)
        XCTAssertEqual(UnitRange.range(for: -0.5, metric: .power, previous: nil), .milli)
        // Voltage never auto-ranges.
        XCTAssertEqual(UnitRange.range(for: 0.1, metric: .voltage, previous: nil), .base)
        XCTAssertEqual(UnitRange.range(for: 0.1, metric: .voltage, previous: .milli), .base)

        let f = formatter()
        XCTAssertEqual(f.format(0.5, .current), FormattedValue(number: "500", unit: "mA"))
        XCTAssertEqual(f.format(1.2345, .current).text, "1.23 A")
        XCTAssertEqual(f.format(9.0123, .voltage).text, "9.01 V")
        XCTAssertEqual(f.format(0.0123, .power).text, "12.3 mW")
        XCTAssertEqual(f.format(nil, .power).number, "--")
        XCTAssertEqual(f.format(.nan, .power).number, "--")
        XCTAssertEqual(f.format(0.5, .current, range: .base).text, "0.500 A")
        XCTAssertEqual(f.energy(0.5).text, "500 mWh")
        XCTAssertEqual(f.energy(12.3456).text, "12.3 Wh")
        XCTAssertEqual(f.capacity(2.5).text, "2.50 Ah")
        XCTAssertEqual(f.capacity(0.25).text, "250 mAh")
        XCTAssertEqual(f.spoken(0.5, .current), "500 milliamps")
        XCTAssertEqual(f.spoken(9.0123, .voltage), "9.01 volts")
        XCTAssertEqual(f.spoken(nil, .power), "no reading")
        XCTAssertEqual(f.number(9.0123, fractionDigits: 3), "9.012")
        XCTAssertEqual(f.number(nil, fractionDigits: 3), "--")

        let fixed = formatter(precision: 4, autoRange: false)
        XCTAssertEqual(fixed.format(0.5, .current).text, "0.5000 A")
        XCTAssertEqual(fixed.energy(0.5).text, "0.5000 Wh")
    }

    func testDuration() {
        let f = formatter()
        XCTAssertEqual(f.duration(0), "00:00")
        XCTAssertEqual(f.duration(65), "01:05")
        XCTAssertEqual(f.duration(3599.9), "59:59")
        XCTAssertEqual(f.duration(3661), "1:01:01")
        XCTAssertEqual(f.duration(-1), "--")
    }

    // MARK: D1 acceptance

    func testAutoRangeBoundaries() {
        let f = formatter(precision: 3)
        // Standby draw keeps its resolution instead of reading 0.012 A.
        XCTAssertEqual(f.format(0.0123, .current).text, "12.3 mA")
        XCTAssertEqual(f.format(0.000123, .current).text, "0.123 mA")
        // Just under 0.95 is milli, just above is base.
        XCTAssertEqual(f.format(0.949, .current).text, "949 mA")
        XCTAssertEqual(f.format(0.951, .current).text, "0.951 A")
        // 0.9995 A is in the base range and rounds to the unit with 3
        // significant digits; 4 digits keep the full value.
        XCTAssertEqual(f.format(0.9995, .current).text, "1.00 A")
        XCTAssertEqual(formatter(precision: 4).format(0.9995, .current).text, "0.9995 A")
        XCTAssertEqual(formatter(precision: 4).format(0.0123, .current).text, "12.30 mA")
        // Integer digits are never rounded away.
        XCTAssertEqual(f.format(12345, .power).text, "12345 W")
        XCTAssertEqual(f.format(1234.5, .voltage).number, "1234")   // 4 digits, rounded to even
        // Power auto-ranges, voltage never does.
        XCTAssertEqual(f.format(0.5, .power).text, "500 mW")
        XCTAssertEqual(f.format(0.05, .voltage).text, "0.0500 V")
        XCTAssertEqual(f.format(5.0, .voltage).text, "5.00 V")
        // Energy and capacity: milli below 1.
        XCTAssertEqual(f.energy(0.999).text, "999 mWh")
        XCTAssertEqual(f.energy(1.0).text, "1.00 Wh")
        XCTAssertEqual(f.capacity(0.999).text, "999 mAh")
        XCTAssertEqual(f.capacity(1.0).text, "1.00 Ah")
        // Auto-range off: everything in base units.
        let fixed = formatter(precision: 3, autoRange: false)
        XCTAssertEqual(fixed.format(0.0123, .current).text, "0.0123 A")
        XCTAssertEqual(fixed.capacity(0.25).text, "0.250 Ah")
        XCTAssertEqual(fixed.formatLive(0.0123, .current, previous: .milli).value.text, "0.0123 A")
    }

    func testCapacityUnitLock() {
        let locked = formatter(precision: 3, capacityUnit: .mAh)
        XCTAssertEqual(locked.capacity(2.5).text, "2500 mAh")
        XCTAssertEqual(locked.capacity(0.25).text, "250 mAh")
        XCTAssertEqual(locked.capacity(12.345).text, "12345 mAh")
        XCTAssertEqual(locked.capacity(.nan).text, "-- mAh")
        // Locked to mAh even when auto-range is off.
        XCTAssertEqual(formatter(precision: 3, autoRange: false, capacityUnit: .mAh).capacity(2.5).text, "2500 mAh")
        XCTAssertEqual(locked.spokenCapacity(2.5), "2500 milliamp-hours")
        XCTAssertEqual(formatter().spokenCapacity(2.5), "2.50 amp-hours")
    }

    func testHysteresisStateMachine() {
        let f = formatter(precision: 3)
        // A value oscillating around 1 A never flips units between samples:
        // it stays in whichever range it entered until it leaves the band.
        var range: UnitRange?
        var units: Set<String> = []
        for v in [0.98, 1.01, 0.99, 1.03, 0.96, 1.04, 0.97, 1.02] {
            let out = f.formatLive(v, .current, previous: range)
            range = out.range
            units.insert(out.value.unit)
        }
        XCTAssertEqual(units, ["A"], "entered from above 0.95: stays in amps inside the band")

        range = .milli
        units = []
        for v in [0.98, 1.01, 0.99, 1.03, 0.96, 1.04, 0.97, 1.02] {
            let out = f.formatLive(v, .current, previous: range)
            range = out.range
            units.insert(out.value.unit)
        }
        XCTAssertEqual(units, ["mA"], "entered from below: stays in milliamps inside the band")

        // Explicit transitions.
        var r: UnitRange? = nil
        var step = f.formatLive(0.94, .current, previous: r); r = step.range
        XCTAssertEqual(step.value.text, "940 mA")
        step = f.formatLive(1.0, .current, previous: r); r = step.range
        XCTAssertEqual(step.value.text, "1000 mA", "still milli until 1.05")
        step = f.formatLive(1.04, .current, previous: r); r = step.range
        XCTAssertEqual(step.value.text, "1040 mA")
        step = f.formatLive(1.06, .current, previous: r); r = step.range
        XCTAssertEqual(step.value.text, "1.06 A", "above 1.05 goes back to base")
        step = f.formatLive(0.96, .current, previous: r); r = step.range
        XCTAssertEqual(step.value.text, "0.960 A", "still base until 0.95")
        step = f.formatLive(0.94, .current, previous: r); r = step.range
        XCTAssertEqual(step.value.text, "940 mA")
        XCTAssertEqual(r, .milli)

        // A missing reading keeps the previous range and its unit.
        let missing = f.formatLive(nil, .current, previous: .milli)
        XCTAssertEqual(missing.value.text, "-- mA")
        XCTAssertEqual(missing.range, .milli)
        let nan = f.formatLive(.nan, .power, previous: .base)
        XCTAssertEqual(nan.value.text, "-- W")
        XCTAssertEqual(nan.range, .base)

        // Voltage ignores the previous range entirely.
        XCTAssertEqual(f.formatLive(0.5, .voltage, previous: .milli).value.text, "0.500 V")
        XCTAssertEqual(f.formatLive(0.5, .voltage, previous: .milli).range, .base)
    }

    func testNaNAndNegativeCurrent() {
        let f = formatter(precision: 3)
        XCTAssertEqual(f.format(.nan, .current).text, "-- A")
        XCTAssertEqual(f.format(.infinity, .power).text, "-- W")
        XCTAssertEqual(f.format(-.infinity, .voltage).text, "-- V")
        XCTAssertEqual(f.format(.nan, .current, range: .milli).text, "-- mA")
        XCTAssertEqual(f.energy(.nan).text, "-- Wh")
        XCTAssertEqual(f.capacity(.infinity).text, "-- Ah")
        XCTAssertEqual(f.duration(.nan), "--")
        XCTAssertEqual(f.spoken(.nan, .current), "no reading")
        XCTAssertEqual(f.spokenEnergy(.nan), "no reading")

        // Flow direction is displayed, not hidden.
        XCTAssertEqual(f.format(-0.5, .current).text, "-500 mA")
        XCTAssertEqual(f.format(-1.5, .current).text, "-1.50 A")
        XCTAssertEqual(f.format(-0.0123, .current).text, "-12.3 mA")
        XCTAssertEqual(f.spoken(-0.5, .current), "-500 milliamps")
        XCTAssertEqual(f.capacity(-0.25).text, "-250 mAh")
        XCTAssertEqual(f.energy(-2).text, "-2.00 Wh")
        // Negative zero never shows a sign.
        XCTAssertEqual(f.format(-0.0, .current).text, "0.00 mA")
        XCTAssertEqual(f.format(0, .current).text, "0.00 mA")
    }

    func testLocaleDecimalSeparator() {
        let de = MetricFormatter(locale: Locale(identifier: "de_DE"), precision: 3, capacityUnit: .mAh)
        XCTAssertEqual(de.format(9.0123, .voltage).number, "9,01")
        XCTAssertEqual(de.format(0.0123, .current).text, "12,3 mA")
        XCTAssertEqual(de.energy(12.3456).text, "12,3 Wh")
        XCTAssertEqual(de.number(9.0123, fractionDigits: 2), "9,01")
        // No grouping separator, whatever the locale would normally insert.
        XCTAssertEqual(de.capacity(12.345).text, "12345 mAh")
        XCTAssertEqual(de.format(12345, .power).number, "12345")
        XCTAssertEqual(de.spoken(9.0123, .voltage), "9,01 volts")

        let fr = MetricFormatter(locale: Locale(identifier: "fr_FR"), precision: 4)
        XCTAssertEqual(fr.format(1.2345, .current).number, "1,234")
    }

    func testSpokenUnits() {
        let f = formatter(precision: 3)
        XCTAssertEqual(f.spoken(0.0123, .current), "12.3 milliamps")
        XCTAssertEqual(f.spoken(1.5, .current), "1.50 amps")
        XCTAssertEqual(f.spoken(0.5, .power), "500 milliwatts")
        XCTAssertEqual(f.spoken(20.123, .power), "20.1 watts")
        XCTAssertEqual(f.spoken(9.0123, .voltage), "9.01 volts")
        XCTAssertEqual(f.spoken(0.5, .voltage), "0.500 volts")
        XCTAssertEqual(f.spoken(nil, .power), "no reading")
        XCTAssertEqual(f.spokenEnergy(0.5), "500 milliwatt-hours")
        XCTAssertEqual(f.spokenEnergy(12.3456), "12.3 watt-hours")
        XCTAssertEqual(f.spokenCapacity(0.25), "250 milliamp-hours")
        XCTAssertEqual(f.spokenCapacity(2.5), "2.50 amp-hours")
        // Auto-range off: base units only.
        XCTAssertEqual(formatter(precision: 3, autoRange: false).spoken(0.0123, .current), "0.0123 amps")
    }

    func testIntervalAndAutoStopDescription() {
        let f = MetricFormatter(locale: Locale(identifier: "en_US"), precision: 3)
        XCTAssertEqual(f.interval(30), "30 sec")
        XCTAssertEqual(f.interval(60), "1 min")
        XCTAssertEqual(f.interval(90), "1 min, 30 sec")
        XCTAssertEqual(f.interval(7200), "2 hr")
        XCTAssertEqual(f.interval(5400), "1 hr, 30 min")
        XCTAssertEqual(f.interval(-1), "--")

        XCTAssertEqual(f.describe(nil), "Off")
        XCTAssertEqual(f.describe(AutoStopRule()), "Off")
        XCTAssertEqual(f.describe(AutoStopRule(belowCurrentA: 0.1, forSeconds: 60)), "Current below 100 mA for 1 min")
        XCTAssertEqual(f.describe(AutoStopRule(belowCurrentA: 0.1, forSeconds: 60, maxDuration: 7200, maxEnergyWh: 20)),
                       "Current below 100 mA for 1 min · Max 2 hr · Max 20.0 Wh")
        XCTAssertEqual(f.describe(AutoStopRule(maxDuration: 3600)), "Max 1 hr")
    }

    func testByteCount() {
        let f = MetricFormatter(locale: Locale(identifier: "en_US"))
        XCTAssertEqual(f.byteCount(0), "Zero KB")
        XCTAssertTrue(f.byteCount(42_000_000).hasSuffix("MB"), f.byteCount(42_000_000))
        XCTAssertTrue(f.byteCount(1_500).hasSuffix("KB"), f.byteCount(1_500))
    }
}
