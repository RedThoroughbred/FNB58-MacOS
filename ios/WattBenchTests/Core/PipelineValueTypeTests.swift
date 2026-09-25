import XCTest
@testable import WattBench

final class TripMeterTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_760_000_000)

    func testGapNotIntegratedAndResetRestartsClock() throws {
        var trip = TripMeter(label: "Trip", startedAt: t0)
        trip.add(Reading(timestamp: t0, voltage: 5, current: 2, power: 10))
        trip.add(Reading(timestamp: t0.addingTimeInterval(1), voltage: 5, current: 2, power: 10))
        trip.add(Reading(timestamp: t0.addingTimeInterval(61), voltage: 5, current: 2, power: 10))
        trip.add(Reading(timestamp: t0.addingTimeInterval(62), voltage: 5, current: 2, power: 10))
        XCTAssertEqual(trip.elapsed, 2, accuracy: 1e-9)
        XCTAssertEqual(trip.stats.energyWh, 20.0 / 3600, accuracy: 1e-12)
        XCTAssertEqual(trip.stats.gapCount, 1)

        let data = try JSONEncoder().encode(trip)
        let back = try JSONDecoder().decode(TripMeter.self, from: data)
        XCTAssertEqual(back.stats.energyWh, trip.stats.energyWh)
        XCTAssertEqual(back.label, "Trip")

        let later = t0.addingTimeInterval(1000)
        trip.reset(at: later)
        XCTAssertEqual(trip.startedAt, later)
        XCTAssertEqual(trip.elapsed, 0)
        XCTAssertEqual(trip.stats, SessionStats())
    }
}

final class ExtremesTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_760_000_000)

    func testTracksMaxMinWithTimestamps() {
        var e = Extremes(since: t0)
        e.update(Reading(timestamp: t0, voltage: 5, current: 1, power: 5))
        e.update(Reading(timestamp: t0.addingTimeInterval(1), voltage: 9, current: 3, power: 27))   // inrush
        e.update(Reading(timestamp: t0.addingTimeInterval(2), voltage: 4.8, current: 0.5, power: 2.4))
        XCTAssertEqual(e.maxV?.value, 9)
        XCTAssertEqual(e.maxV?.at, t0.addingTimeInterval(1))
        XCTAssertEqual(e.minV?.value, 4.8)
        XCTAssertEqual(e.maxI?.value, 3)
        XCTAssertEqual(e.minI?.value, 0.5)
        XCTAssertEqual(e.maxW?.value, 27)
        XCTAssertEqual(e.maxW?.at, t0.addingTimeInterval(1))
        e.reset(at: t0.addingTimeInterval(3))
        XCTAssertNil(e.maxW)
        XCTAssertEqual(e.since, t0.addingTimeInterval(3))
    }
}

final class ReconnectPolicyTests: XCTestCase {
    func testDelaySequenceCapAndGiveUp() {
        var p = ReconnectPolicy()
        let t0 = Date(timeIntervalSince1970: 1_760_000_000)
        var delays: [TimeInterval] = []
        var now = t0
        while let d = p.nextDelay(now: now) {
            delays.append(d)
            now = now.addingTimeInterval(d)
        }
        XCTAssertEqual(Array(delays.prefix(6)), [1, 2, 4, 8, 16, 30])
        XCTAssertTrue(delays.dropFirst(6).allSatisfy { $0 == 30 })
        XCTAssertGreaterThanOrEqual(now.timeIntervalSince(t0), ReconnectPolicy.giveUpAfter)
        XCTAssertEqual(p.firstFailureAt, t0)
        p.reset()
        XCTAssertEqual(p.attempt, 0)
        XCTAssertNil(p.firstFailureAt)
        XCTAssertEqual(p.nextDelay(now: now), 1)
    }
}

final class ConnectionStateTests: XCTestCase {
    func testLabelsSymbolsAndTransientFlags() {
        let since = Date()
        let all: [ConnectionState] = [.bluetoothOff, .unauthorized, .idle, .scanning, .connecting("FNB58"),
                                      .connected("FNB58"), .reconnecting(name: "FNB58", since: since),
                                      .unreachable("FNB58"), .demo]
        for s in all {
            XCTAssertFalse(s.label.isEmpty)
            XCTAssertFalse(s.shortLabel.isEmpty)
            XCTAssertFalse(s.symbolName.isEmpty)
            XCTAssertTrue(["green", "orange", "gray", "purple", "red"].contains(s.tintToken), s.tintToken)
        }
        XCTAssertTrue(ConnectionState.connected("FNB58").isConnected)
        XCTAssertTrue(ConnectionState.demo.isConnected)
        XCTAssertFalse(ConnectionState.reconnecting(name: "FNB58", since: since).isConnected)
        XCTAssertTrue(ConnectionState.reconnecting(name: "FNB58", since: since).isTransient)
        XCTAssertTrue(ConnectionState.scanning.isTransient)
        XCTAssertFalse(ConnectionState.unreachable("FNB58").isTransient)
        XCTAssertEqual(ConnectionState.unreachable("FNB58").tintToken, "red")
        XCTAssertEqual(ConnectionState.demo.tintToken, "purple")
        XCTAssertEqual(ConnectionState.connected("FNB58").label, "FNB58")
        XCTAssertEqual(ConnectionState.reconnecting(name: "FNB58", since: since), .reconnecting(name: "FNB58", since: since))
    }
}

final class DecimatorTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_760_000_000)

    private func readings(_ n: Int) -> [Reading] {
        (0..<n).map { k in
            Reading(timestamp: t0.addingTimeInterval(Double(k) * 0.1), voltage: 5, current: Double(k % 10), power: Double(k))
        }
    }

    func testMinMaxBucketsAndDomain() {
        let r = readings(1000)
        let pts = Decimator.minMaxBuckets(r[...], metric: .current, targetCount: 100)
        XCTAssertEqual(pts.count, 100)
        XCTAssertEqual(pts[0].min, 0)
        XCTAssertEqual(pts[0].max, 9)
        XCTAssertEqual(pts[0].mean, 4.5, accuracy: 1e-9)
        XCTAssertEqual(pts[0].time, t0)
        let dom = Decimator.yDomain(pts)
        XCTAssertEqual(dom.lowerBound, -0.45, accuracy: 1e-9)
        XCTAssertEqual(dom.upperBound, 9.45, accuracy: 1e-9)
        XCTAssertEqual(Decimator.minMaxBuckets(r[0..<5], metric: .power, targetCount: 60).count, 5)
        XCTAssertEqual(Decimator.yDomain([]), 0...1)
    }

    func testWindowAndSparklineHelpers() {
        let r = readings(1000)   // 100 s
        let w = Decimator.window(r, seconds: 10)
        XCTAssertEqual(w.count, 101)
        XCTAssertEqual(w.first?.timestamp, t0.addingTimeInterval(89.9))
        XCTAssertEqual(Decimator.window([], seconds: 10).count, 0)
        XCTAssertEqual(Decimator.meanPower(r[...], targetCount: 60).count, 60)
        XCTAssertEqual(Decimator.condense([1, 2, 3, 4], targetCount: 2), [1.5, 3.5])
        XCTAssertEqual(Decimator.condense([1, 2], targetCount: 60), [1, 2])
    }
}
