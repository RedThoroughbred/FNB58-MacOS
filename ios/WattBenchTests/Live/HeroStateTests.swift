import XCTest
@testable import WattBench

final class HeroStateTests: XCTestCase {
    /// 2025-10-09 08:53:20 UTC
    private let t0 = Date(timeIntervalSince1970: 1_760_000_000)
    private let posix = Locale(identifier: "en_US_POSIX")

    func testStaleAfterTwoSeconds() throws {
        XCTAssertFalse(HeroState.isStale(latest: t0, now: t0))
        XCTAssertFalse(HeroState.isStale(latest: t0, now: t0.addingTimeInterval(1.99)))
        XCTAssertFalse(HeroState.isStale(latest: t0, now: t0.addingTimeInterval(2)), "exactly 2 s is still fresh")
        XCTAssertTrue(HeroState.isStale(latest: t0, now: t0.addingTimeInterval(2.01)))
        XCTAssertTrue(HeroState.isStale(latest: nil, now: t0), "no sample yet counts as stale")
        // A sample from the future (clock adjustment) is not stale.
        XCTAssertFalse(HeroState.isStale(latest: t0.addingTimeInterval(10), now: t0))

        XCTAssertEqual(Staleness(latest: t0, now: t0.addingTimeInterval(1)), .fresh)
        XCTAssertEqual(Staleness(latest: t0, now: t0.addingTimeInterval(3)), .stale)
        XCTAssertEqual(Staleness(latest: t0, now: t0.addingTimeInterval(5)), .stale, "paused only beyond the gap guard")
        XCTAssertEqual(Staleness(latest: t0, now: t0.addingTimeInterval(5.5)), .paused)
        XCTAssertEqual(Staleness(latest: nil, now: t0), .paused)
        XCTAssertEqual(HeroState.pausedAfter, SessionStats.maxGapS)
    }

    func testSecondaryOrderForEachHeroMetric() {
        XCTAssertEqual(HeroState.secondaryOrder(for: .power), [.voltage, .current])
        XCTAssertEqual(HeroState.secondaryOrder(for: .voltage), [.current, .power])
        XCTAssertEqual(HeroState.secondaryOrder(for: .current), [.voltage, .power])
        for hero in Metric.allCases {
            let order = HeroState.secondaryOrder(for: hero)
            XCTAssertEqual(order.count, 2)
            XCTAssertFalse(order.contains(hero))
            XCTAssertEqual(Set(order + [hero]), Set(Metric.allCases))
        }
    }

    func testPeakCaptionFormatting() throws {
        let f = MetricFormatter(locale: posix, precision: 3, autoRange: true)
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        var e = Extremes(since: t0)
        XCTAssertNil(HeroState.peakCaption(.power, extremes: e, formatter: f, locale: posix, timeZone: utc))
        XCTAssertNil(HeroState.peakCaption(.voltage, extremes: e, formatter: f, locale: posix, timeZone: utc))

        e.update(Reading(timestamp: t0, voltage: 9.01, current: 1.5, power: 13.5))
        e.update(Reading(timestamp: t0.addingTimeInterval(10), voltage: 9.05, current: 2.03, power: 27.4))
        e.update(Reading(timestamp: t0.addingTimeInterval(20), voltage: 9.02, current: 0.4, power: 3.6))

        XCTAssertEqual(HeroState.peakCaption(.power, extremes: e, formatter: f, locale: posix, timeZone: utc),
                       "PEAK 27.4 W · 08:53:30")
        XCTAssertEqual(HeroState.peakCaption(.current, extremes: e, formatter: f, locale: posix, timeZone: utc),
                       "PEAK 2.03 A · 08:53:30")
        XCTAssertEqual(HeroState.peakCaption(.voltage, extremes: e, formatter: f, locale: posix, timeZone: utc),
                       "9.01–9.05 V")

        // Peaks below one unit auto-range like every other readout.
        var small = Extremes(since: t0)
        small.update(Reading(timestamp: t0.addingTimeInterval(3661), voltage: 5, current: 0.25, power: 1.25))
        XCTAssertEqual(HeroState.peakCaption(.current, extremes: small, formatter: f, locale: posix, timeZone: utc),
                       "PEAK 250 mA · 09:54:21")

        // The clock is always 24-hour, even in a 12-hour locale.
        XCTAssertEqual(HeroState.clock(t0.addingTimeInterval(6 * 3600), locale: Locale(identifier: "en_US"), timeZone: utc),
                       "14:53:20")
        XCTAssertEqual(HeroState.copyText(0.5, metric: .current, formatter: f), "500 mA")
        XCTAssertEqual(HeroState.copyText(nil, metric: .current, formatter: f), "-- A")
    }

    func testFaceStaysDuringReconnectAndHidesWhenIdle() {
        XCTAssertTrue(HeroState.showsFace(.connected("FNB58")))
        XCTAssertTrue(HeroState.showsFace(.demo))
        XCTAssertTrue(HeroState.showsFace(.reconnecting(name: "FNB58", since: t0)))
        XCTAssertTrue(HeroState.showsFace(.unreachable("FNB58")))
        XCTAssertFalse(HeroState.showsFace(.idle))
        XCTAssertFalse(HeroState.showsFace(.scanning))
        XCTAssertFalse(HeroState.showsFace(.connecting("FNB58")))
        XCTAssertFalse(HeroState.showsFace(.bluetoothOff))
        XCTAssertFalse(HeroState.showsFace(.unauthorized))
    }
}
