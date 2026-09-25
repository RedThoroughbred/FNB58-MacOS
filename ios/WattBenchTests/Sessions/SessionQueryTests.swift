import XCTest
@testable import WattBench

final class SessionQueryTests: XCTestCase {
    private typealias S = SessionTestSupport

    private var newYork: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        return c
    }

    private func date(_ calendar: Calendar, _ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi)) ?? .distantPast
    }

    func testGroupsAcrossMidnightAndDST() {
        let cal = newYork
        // US DST starts 2026-03-08 at 02:00 local (clocks jump to 03:00).
        let a = S.summary(name: "A", start: date(cal, 2026, 3, 7, 23, 50))
        let b = S.summary(name: "B", start: date(cal, 2026, 3, 8, 0, 10))
        let c = S.summary(name: "C", start: date(cal, 2026, 3, 8, 1, 30))
        let d = S.summary(name: "D", start: date(cal, 2026, 3, 8, 3, 30))
        let e = S.summary(name: "E", start: date(cal, 2026, 3, 9, 0, 0))
        // 23 h day (DST) still groups as one day; A and B straddle midnight.
        XCTAssertEqual(d.startTime.timeIntervalSince(c.startTime), 3600, "DST jump: 01:30 -> 03:30 is one real hour")

        let groups = SessionQuery.group([e, d, c, b, a], calendar: cal)
        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(groups.map { $0.sessions.map(\.name) }, [["E"], ["D", "C", "B"], ["A"]])
        XCTAssertEqual(groups.map(\.day), [cal.startOfDay(for: e.startTime), cal.startOfDay(for: b.startTime),
                                           cal.startOfDay(for: a.startTime)])
        XCTAssertTrue(groups.allSatisfy { cal.startOfDay(for: $0.day) == $0.day })

        // Order inside a day follows the input order; days are newest first.
        let reordered = SessionQuery.group([b, c, d], calendar: cal)
        XCTAssertEqual(reordered.first?.sessions.map(\.name), ["B", "C", "D"])
        XCTAssertTrue(SessionQuery.group([], calendar: cal).isEmpty)

        // Relative names for the two most recent days.
        let now = date(cal, 2026, 3, 9, 12, 0)
        XCTAssertEqual(SessionQuery.relativeDayName(for: cal.startOfDay(for: e.startTime), now: now, calendar: cal), "Today")
        XCTAssertEqual(SessionQuery.relativeDayName(for: cal.startOfDay(for: b.startTime), now: now, calendar: cal), "Yesterday")
        XCTAssertNil(SessionQuery.relativeDayName(for: cal.startOfDay(for: a.startTime), now: now, calendar: cal))
    }

    func testFilterMatchesTagsAndNotesCaseInsensitive() {
        let anker = S.summary(name: "Anker 65W", start: S.t0, deviceName: "FNB58",
                              tags: ["Charger", "USB-C"], notes: "Braided cable, 2 m")
        let bank = S.summary(name: "Power bank drain", start: S.t0.addingTimeInterval(60), deviceName: "FNB58",
                             tags: ["powerbank"], notes: nil)
        let cafe = S.summary(name: "Café", start: S.t0.addingTimeInterval(120), deviceName: nil, tags: [], notes: nil)
        let all = [anker, bank, cafe]

        XCTAssertEqual(SessionQuery.filter(all, query: "CHARGER").map(\.name), ["Anker 65W"])
        XCTAssertEqual(SessionQuery.filter(all, query: "usb-c").map(\.name), ["Anker 65W"])
        XCTAssertEqual(SessionQuery.filter(all, query: "#USB-C").map(\.name), ["Anker 65W"])
        XCTAssertEqual(SessionQuery.filter(all, query: "braided").map(\.name), ["Anker 65W"])
        XCTAssertEqual(SessionQuery.filter(all, query: "anker").map(\.name), ["Anker 65W"])
        XCTAssertEqual(SessionQuery.filter(all, query: "fnb").map(\.name), ["Anker 65W", "Power bank drain"])
        XCTAssertEqual(SessionQuery.filter(all, query: "cafe").map(\.name), ["Café"])
        XCTAssertEqual(SessionQuery.filter(all, query: "anker cable").map(\.name), ["Anker 65W"])
        XCTAssertTrue(SessionQuery.filter(all, query: "anker zzz").isEmpty)
        XCTAssertTrue(SessionQuery.filter(all, query: "zzz").isEmpty)
        XCTAssertEqual(SessionQuery.filter(all, query: "").count, 3)
        XCTAssertEqual(SessionQuery.filter(all, query: "   ").count, 3)
        XCTAssertEqual(SessionQuery.filter(all, query: "#").count, 3)

        XCTAssertEqual(SessionQuery.recentTags(all), ["powerbank", "Charger", "USB-C"])
        XCTAssertEqual(SessionQuery.recentTags(all, limit: 2), ["powerbank", "Charger"])
    }

    func testSortOrders() {
        let a = S.summary(name: "A", start: S.t0.addingTimeInterval(300), durationS: 60, energyWh: 5)
        let b = S.summary(name: "B", start: S.t0.addingTimeInterval(200), durationS: 600, energyWh: 1)
        let c = S.summary(name: "C", start: S.t0.addingTimeInterval(100), durationS: 6, energyWh: 50)
        let d = S.summary(name: "D", start: S.t0.addingTimeInterval(0), durationS: 60, energyWh: 5)
        let input = [c, d, a, b]

        XCTAssertEqual(SessionQuery.sorted(input, by: .newest).map(\.name), ["A", "B", "C", "D"])
        XCTAssertEqual(SessionQuery.sorted(input, by: .longest).map(\.name), ["B", "A", "D", "C"])
        XCTAssertEqual(SessionQuery.sorted(input, by: .mostEnergy).map(\.name), ["C", "A", "D", "B"])

        // Stable: the same input in any order sorts identically.
        for order in SortOrder.allCases {
            let once = SessionQuery.sorted(input, by: order).map(\.id)
            XCTAssertEqual(SessionQuery.sorted(input.reversed(), by: order).map(\.id), once, "\(order)")
            XCTAssertEqual(SessionQuery.sorted(SessionQuery.sorted(input, by: order), by: order).map(\.id), once, "\(order)")
        }
        XCTAssertEqual(SortOrder(rawValue: "mostEnergy"), .mostEnergy)
    }
}
