import XCTest
@testable import WattBench

@MainActor
final class FixtureSourceTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_760_000_000)

    private func fixture(_ n: Int, dt: TimeInterval = 0.1) -> [Reading] {
        (0..<n).map { k in
            Reading(timestamp: t0.addingTimeInterval(Double(k) * dt), voltage: 5, current: 1, power: 5)
        }
    }

    /// Collects readings until `count` have arrived or `timeout` passes.
    private func collect(from source: FixtureSource, count: Int, timeout: TimeInterval = 5) async throws -> [Reading] {
        var out: [Reading] = []
        source.onReading = { out.append($0) }
        source.start()
        let deadline = Date().addingTimeInterval(timeout)
        while out.count < count, Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        return out
    }

    func testReplaysWithOriginalSpacing() async throws {
        let source = FixtureSource(readings: fixture(6), timeScale: 1, restamp: true)
        let clock = ContinuousClock()
        let start = clock.now
        let out = try await collect(from: source, count: 6)
        let elapsed = clock.now - start
        XCTAssertEqual(out.count, 6)
        XCTAssertEqual(source.emitted, 6)
        // Five 100 ms intervals replayed in real time.
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(480))
        XCTAssertLessThan(elapsed, .milliseconds(1500))
        for k in 1..<out.count {
            XCTAssertEqual(out[k].monotonic - out[k - 1].monotonic, 0.1, accuracy: 0.06, "interval \(k)")
            XCTAssertEqual(out[k].timestamp.timeIntervalSince(out[k - 1].timestamp), 0.1, accuracy: 0.06)
        }
        // Restamped readings look live: monotonic stamps and today's wall clock.
        XCTAssertGreaterThan(out[0].monotonic, 0)
        XCTAssertLessThan(abs(out[0].timestamp.timeIntervalSinceNow), 10)
        XCTAssertEqual(out.map(\.voltage), Array(repeating: 5, count: 6))
        // The run ends by itself once the fixture is exhausted.
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(source.isRunning)
    }

    func testTimeScaleSpeedsUpAndNoRestampKeepsOriginals() async throws {
        let readings = fixture(20)
        let source = FixtureSource(readings: readings, timeScale: 20, restamp: false)
        let clock = ContinuousClock()
        let start = clock.now
        let out = try await collect(from: source, count: 20)
        XCTAssertLessThan(clock.now - start, .milliseconds(800), "1.9 s of fixture at 20x")
        XCTAssertEqual(out, readings, "without restamping the fixture is emitted verbatim")
    }

    func testStopCancelsReplay() async throws {
        let source = FixtureSource(readings: fixture(50), timeScale: 1)
        var count = 0
        source.onReading = { _ in count += 1 }
        source.start()
        try await Task.sleep(for: .milliseconds(150))
        source.stop()
        let stoppedAt = count
        XCTAssertFalse(source.isRunning)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(count, stoppedAt, "nothing is emitted after stop")
        XCTAssertLessThan(stoppedAt, 50)
    }

    func testIntervalRuleMatchesSessionStats() {
        let a = Reading(timestamp: t0, voltage: 5, current: 1, power: 5, monotonic: 100)
        let b = Reading(timestamp: t0.addingTimeInterval(3600), voltage: 5, current: 1, power: 5, monotonic: 100.1)
        XCTAssertEqual(FixtureSource.interval(from: a, to: b), 0.1, accuracy: 1e-9, "monotonic wins over a wall-clock jump")
        let c = Reading(timestamp: t0.addingTimeInterval(0.2), voltage: 5, current: 1, power: 5)
        XCTAssertEqual(FixtureSource.interval(from: a, to: c), 0.2, accuracy: 1e-6, "wall clock when a stamp is missing")
        XCTAssertEqual(FixtureSource.interval(from: c, to: a), 0, "unsorted fixtures never sleep negative")
    }

    func testSyntheticFixtureIsQuantisedAndEvenlySpaced() {
        let s = FixtureSource.synthetic(seconds: 2, hz: 10)
        XCTAssertEqual(s.count, 20)
        for k in 1..<s.count {
            XCTAssertEqual(s[k].timestamp.timeIntervalSince(s[k - 1].timestamp), 0.1, accuracy: 1e-6)
            XCTAssertEqual(s[k].monotonic - s[k - 1].monotonic, 0.1, accuracy: 1e-6)
        }
        for r in s {
            XCTAssertEqual(r.voltage, FixtureSource.quantise(r.voltage), "1/10000 grid, as the meter reports")
            XCTAssertEqual(r.current, FixtureSource.quantise(r.current))
            XCTAssertEqual(r.power, FixtureSource.quantise(r.power))
            XCTAssertEqual(r.voltage, 9, accuracy: 0.06)
        }
        XCTAssertEqual(FixtureSource.quantise(9.01234567), 9.0123)
        XCTAssertTrue(FixtureSource.synthetic(seconds: 0).isEmpty)
    }
}
