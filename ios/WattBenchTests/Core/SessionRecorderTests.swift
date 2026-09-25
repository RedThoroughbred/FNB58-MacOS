import XCTest
@testable import WattBench

@MainActor
final class SessionRecorderTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_760_000_000)

    func testGapMarkerAppendedWhenDtExceeds5s() {
        let rec = SessionRecorder(name: "gap", deviceName: "FNB58")
        _ = rec.add(Reading(timestamp: t0, voltage: 5, current: 1, power: 5))
        _ = rec.add(Reading(timestamp: t0.addingTimeInterval(0.1), voltage: 5, current: 1, power: 5))
        _ = rec.add(Reading(timestamp: t0.addingTimeInterval(134.1), voltage: 5, current: 1, power: 5))
        XCTAssertEqual(rec.markers.count, 1)
        XCTAssertEqual(rec.markers.first?.kind, .gap)
        XCTAssertEqual(rec.markers.first?.label, "Gap 2 m 14 s")
        XCTAssertEqual(rec.stats.gapCount, 1)
        XCTAssertEqual(rec.readings.count, 3)
    }

    func testSparklineIsOneMeanPerSecond() {
        let rec = SessionRecorder(name: "spark", deviceName: nil, tags: ["a"], notes: "n")
        // second 0: 10 W, second 1: 20 W, second 2: skipped (gap), second 3: 30 W
        for k in 0..<10 { _ = rec.add(Reading(timestamp: t0.addingTimeInterval(Double(k) * 0.1), voltage: 5, current: 2, power: 10)) }
        for k in 0..<10 { _ = rec.add(Reading(timestamp: t0.addingTimeInterval(1 + Double(k) * 0.1), voltage: 5, current: 4, power: 20)) }
        _ = rec.add(Reading(timestamp: t0.addingTimeInterval(3.0), voltage: 5, current: 6, power: 30))
        let session = rec.finish()
        XCTAssertEqual(session.sparkline, [10, 20, 0, 30])
        XCTAssertEqual(session.tags, ["a"])
        XCTAssertEqual(session.notes, "n")
        XCTAssertEqual(session.summary().sparkline, [10, 20, 0, 30])
        XCTAssertEqual(session.sampleCount, 21)
    }

    func testUserMarkerAndDemoFlag() {
        let rec = SessionRecorder(name: " Demo run ", deviceName: "Demo data", isDemo: true)
        rec.addMarker(label: "Plugged in")
        let s = rec.finish()
        XCTAssertEqual(s.name, "Demo run")
        XCTAssertTrue(s.isDemo)
        XCTAssertEqual(s.markers.map(\.label), ["Plugged in"])
        XCTAssertEqual(s.markers.first?.kind, .user)
        XCTAssertNil(s.autoStopReason)
    }
}
