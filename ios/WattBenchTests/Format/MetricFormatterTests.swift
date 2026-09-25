import XCTest
@testable import WattBench

final class MetricFormatterTests: XCTestCase {
    private let posix = Locale(identifier: "en_US_POSIX")

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

        let f = MetricFormatter(locale: posix, precision: 3, autoRange: true)
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

        let fixed = MetricFormatter(locale: posix, precision: 4, autoRange: false)
        XCTAssertEqual(fixed.format(0.5, .current).text, "0.5000 A")
        XCTAssertEqual(fixed.energy(0.5).text, "0.5000 Wh")
    }

    func testDuration() {
        let f = MetricFormatter(locale: posix)
        XCTAssertEqual(f.duration(0), "00:00")
        XCTAssertEqual(f.duration(65), "01:05")
        XCTAssertEqual(f.duration(3599.9), "59:59")
        XCTAssertEqual(f.duration(3661), "1:01:01")
        XCTAssertEqual(f.duration(-1), "--")
    }

    func testLocaleDecimalSeparator() {
        let de = MetricFormatter(locale: Locale(identifier: "de_DE"), precision: 3)
        XCTAssertEqual(de.format(9.0123, .voltage).number, "9,01")
    }
}
