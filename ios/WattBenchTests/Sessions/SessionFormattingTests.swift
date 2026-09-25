import XCTest
@testable import WattBench

/// The report-only formatting helpers (`MetricFormatter` extensions in
/// `StatTile.swift`).
final class SessionFormattingTests: XCTestCase {
    private let f = MetricFormatter(locale: Locale(identifier: "en_US_POSIX"), precision: 4)

    func testSpanUsesTheLargerEndsDigitsForBoth() {
        XCTAssertEqual(f.span(0.003, 4.5012, .current), "0.003–4.501 A")
        XCTAssertEqual(f.span(8.8963, 9.0741, .voltage), "8.896–9.074 V")
        // Both ends in milli units when the larger one is below 0.95.
        XCTAssertEqual(f.span(0.012, 0.0162, .current), "12.00–16.20 mA")
        // Voltage never auto-ranges.
        XCTAssertEqual(f.span(0.5, 0.6, .voltage), "0.5000–0.6000 V")
        // Whole numbers carry no fraction digits.
        XCTAssertEqual(f.span(10, 1234, .power), "10–1234 W")
        XCTAssertEqual(f.span(nil, 1, .current), "-- A")
        XCTAssertEqual(f.span(1, .nan, .power), "-- W")
    }

    func testSpanFollowsLocale() {
        let de = MetricFormatter(locale: Locale(identifier: "de_DE"), precision: 4)
        XCTAssertEqual(de.span(0.003, 4.5012, .current), "0,003–4,501 A")
    }

    func testCapacityUnitAndRate() {
        XCTAssertEqual(f.capacity(0.8487, unit: .mAh).text, "848.7 mAh")
        XCTAssertEqual(f.capacity(0.8487, unit: .Ah).text, "0.8487 Ah")
        XCTAssertEqual(f.rate(samples: 15_000, seconds: 1_499), "10.0")
        XCTAssertEqual(f.rate(samples: 0, seconds: 10), "--")
        XCTAssertEqual(f.rate(samples: 10, seconds: 0), "--")
    }
}
