import XCTest
@testable import WattBench

final class ReconnectPolicyTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_760_000_000)

    func testDelaySequenceAndCap() {
        var p = ReconnectPolicy()
        var delays: [TimeInterval] = []
        var now = t0
        for _ in 0..<9 {
            guard let d = p.nextDelay(now: now) else { return XCTFail("gave up too early") }
            delays.append(d)
            now = now.addingTimeInterval(min(d, 5))   // keep the total well under the horizon
        }
        XCTAssertEqual(delays, [1, 2, 4, 8, 16, 30, 30, 30, 30], "1, 2, 4, 8, 16 then capped at 30 s")
        XCTAssertEqual(p.attempt, 9)
        XCTAssertEqual(p.firstFailureAt, t0, "the first call records the first failure")
    }

    func testGivesUpAfter120Seconds() {
        var p = ReconnectPolicy()
        XCTAssertEqual(ReconnectPolicy.giveUpAfter, 120)
        XCTAssertNotNil(p.nextDelay(now: t0))
        XCTAssertNotNil(p.nextDelay(now: t0.addingTimeInterval(119.9)), "still inside the window")
        XCTAssertNil(p.nextDelay(now: t0.addingTimeInterval(120)), "nil at the horizon means give up")
        XCTAssertNil(p.nextDelay(now: t0.addingTimeInterval(500)))

        // Walking the schedule in real time reaches the horizon.
        var walk = ReconnectPolicy()
        var now = t0
        var total: TimeInterval = 0
        while let d = walk.nextDelay(now: now) {
            total += d
            now = now.addingTimeInterval(d)
            XCTAssertLessThan(total, 400, "the schedule must terminate")
        }
        XCTAssertGreaterThanOrEqual(total, ReconnectPolicy.giveUpAfter)
    }

    func testResetOnSuccess() {
        var p = ReconnectPolicy()
        _ = p.nextDelay(now: t0)
        _ = p.nextDelay(now: t0.addingTimeInterval(1))
        XCTAssertEqual(p.attempt, 2)
        p.reset()
        XCTAssertEqual(p.attempt, 0)
        XCTAssertNil(p.firstFailureAt)
        XCTAssertEqual(p, ReconnectPolicy())
        // A later failure starts a fresh window from the shortest delay.
        let later = t0.addingTimeInterval(1000)
        XCTAssertEqual(p.nextDelay(now: later), 1)
        XCTAssertEqual(p.firstFailureAt, later)
    }
}
