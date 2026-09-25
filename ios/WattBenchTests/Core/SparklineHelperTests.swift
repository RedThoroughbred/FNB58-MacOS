import XCTest
@testable import WattBench

/// The `Decimator` additions the storage layer relies on for sparklines and
/// chart windows (the frozen bucket functions themselves are WS-C's).
final class SparklineHelperTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_760_000_000)

    private func readings(_ n: Int) -> [Reading] {
        (0..<n).map { k in
            Reading(timestamp: t0.addingTimeInterval(Double(k) * 0.1), voltage: 5, current: Double(k % 10), power: Double(k))
        }
    }

    func testWindowKeepsTrailingSeconds() {
        let r = readings(1000)   // 100 s
        let w = Decimator.window(r, seconds: 10)
        XCTAssertEqual(w.count, 101)
        XCTAssertEqual(w.first?.timestamp, t0.addingTimeInterval(89.9))
        XCTAssertEqual(w.last?.timestamp, r.last?.timestamp)
        XCTAssertEqual(Decimator.window([], seconds: 10).count, 0)
        XCTAssertEqual(Decimator.window(r, seconds: 1000).count, 1000, "a window wider than the data keeps everything")
    }

    func testMeanPowerSparkline() {
        let r = readings(1000)
        let spark = Decimator.meanPower(r[...], targetCount: 60)
        XCTAssertEqual(spark.count, 60)
        XCTAssertEqual(spark.first ?? -1, 7.5, accuracy: 1e-6, "mean of 0..<16 for the first bucket of 1000/60 readings")
        XCTAssertLessThan(spark[0], spark[59])
        XCTAssertEqual(Decimator.meanPower(r[0..<5], targetCount: 60).count, 5, "fewer readings than buckets: one per reading")
        XCTAssertTrue(Decimator.meanPower([][...], targetCount: 60).isEmpty)
    }

    func testCondense() {
        XCTAssertEqual(Decimator.condense([1, 2, 3, 4], targetCount: 2), [1.5, 3.5])
        XCTAssertEqual(Decimator.condense([1, 2], targetCount: 60), [1, 2], "short series are returned as is")
        XCTAssertEqual(Decimator.condense([], targetCount: 60), [])
        let long = (0..<14_400).map { Float($0) }   // 4 h at 1 Hz
        let out = Decimator.condense(long, targetCount: 60)
        XCTAssertEqual(out.count, 60)
        XCTAssertEqual(out[0], 119.5, accuracy: 1e-3)
    }
}
