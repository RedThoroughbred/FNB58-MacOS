import XCTest
@testable import WattBench

final class SessionDecimatorTests: XCTestCase {
    private typealias S = SessionTestSupport

    func testPreservesGlobalMinAndMax() {
        // 10 000 samples at 1 A with a single-sample dip to 1 mA and a
        // single-sample spike to 3 A: both must survive every zoom level.
        let readings = S.readings(count: 10_000, current: { k in k == 4_321 ? 0.001 : (k == 7_777 ? 3 : 1) })
        for target in [10, 50, 200, 1_500, 9_999, 10_000, 20_000] {
            let points = Decimator.minMaxBuckets(readings[...], metric: .current, targetCount: target)
            XCTAssertEqual(points.map(\.min).min(), 0.001, "target \(target)")
            XCTAssertEqual(points.map(\.max).max(), 3, "target \(target)")
            XCTAssertLessThanOrEqual(points.count, Swift.max(target, 0))
        }
        // A slice keeps the extremes that fall inside it and nothing else.
        let slice = Decimator.minMaxBuckets(readings[5_000..<9_000], metric: .current, targetCount: 40)
        XCTAssertEqual(slice.map(\.max).max(), 3)
        XCTAssertEqual(slice.map(\.min).min(), 1)
        // A window of the mean line never invents values outside the envelope.
        for p in slice {
            XCTAssertGreaterThanOrEqual(p.mean, p.min)
            XCTAssertLessThanOrEqual(p.mean, p.max)
        }
    }

    func testBucketCountAndMonotonicTime() {
        let readings = S.readings(count: 1_000)
        let points = Decimator.minMaxBuckets(readings[...], metric: .voltage, targetCount: 100)
        XCTAssertEqual(points.count, 100)
        for (a, b) in zip(points, points.dropFirst()) {
            XCTAssertLessThan(a.time, b.time)
        }
        XCTAssertEqual(points.first?.time, readings.first?.timestamp)

        // Fewer readings than buckets: one point per reading, in order.
        let few = Decimator.minMaxBuckets(readings[0..<7], metric: .voltage, targetCount: 100)
        XCTAssertEqual(few.count, 7)
        XCTAssertEqual(few.map(\.time), readings[0..<7].map(\.timestamp))

        // Uneven division still yields exactly targetCount non-empty buckets.
        XCTAssertEqual(Decimator.minMaxBuckets(readings[0..<1_000], metric: .power, targetCount: 333).count, 333)
        XCTAssertEqual(Decimator.minMaxBuckets(readings[10..<25], metric: .power, targetCount: 7).count, 7)

        XCTAssertTrue(Decimator.minMaxBuckets(readings[...], metric: .voltage, targetCount: 0).isEmpty)
        XCTAssertTrue(Decimator.minMaxBuckets(readings[0..<0], metric: .voltage, targetCount: 10).isEmpty)

        XCTAssertEqual(Decimator.targetCount(forPixelWidth: 360), 720)
        XCTAssertEqual(Decimator.targetCount(forPixelWidth: 4_000), 1_500)
        XCTAssertEqual(Decimator.targetCount(forPixelWidth: 0), 1)
    }

    func testSingleSampleBucketsHaveNoEnvelope() {
        let readings = S.readings(count: 50, voltage: { 5 + Double($0) * 0.01 })
        let points = Decimator.minMaxBuckets(readings[...], metric: .voltage, targetCount: 200)
        XCTAssertEqual(points.count, 50)
        for (p, r) in zip(points, readings) {
            XCTAssertEqual(p.min, r.voltage)
            XCTAssertEqual(p.max, r.voltage)
            XCTAssertEqual(p.mean, r.voltage)
        }
        // With more readings than buckets the envelope opens up.
        let bucketed = Decimator.minMaxBuckets(readings[...], metric: .voltage, targetCount: 10)
        XCTAssertEqual(bucketed.count, 10)
        XCTAssertTrue(bucketed.allSatisfy { $0.max > $0.min })
    }

    func testYDomainPadding() {
        let points = [
            DecimatedPoint(time: S.t0, min: 1, max: 2, mean: 1.5),
            DecimatedPoint(time: S.t0.addingTimeInterval(1), min: 1.5, max: 3, mean: 2),
        ]
        let domain = Decimator.yDomain(points)
        XCTAssertEqual(domain.lowerBound, 0.9, accuracy: 1e-9)
        XCTAssertEqual(domain.upperBound, 3.1, accuracy: 1e-9)

        let wide = Decimator.yDomain(points, padding: 0.5)
        XCTAssertEqual(wide.lowerBound, 0, accuracy: 1e-9)
        XCTAssertEqual(wide.upperBound, 4, accuracy: 1e-9)

        // Flat data gets a relative pad so the line is not glued to the edge.
        let flat = Decimator.yDomain([DecimatedPoint(time: S.t0, min: 5, max: 5, mean: 5)])
        XCTAssertEqual(flat.lowerBound, 4.75, accuracy: 1e-9)
        XCTAssertEqual(flat.upperBound, 5.25, accuracy: 1e-9)

        // Flat at zero still has a non-empty span.
        let zero = Decimator.yDomain([DecimatedPoint(time: S.t0, min: 0, max: 0, mean: 0)])
        XCTAssertLessThan(zero.lowerBound, zero.upperBound)

        XCTAssertEqual(Decimator.yDomain([]), 0...1)
    }

    func testGapsBetweenReadings() {
        var readings = S.readings(count: 20)
        // 30 s hole after the 10th sample.
        let resumed = S.readings(count: 5, start: S.t0.addingTimeInterval(1.9 + 30))
        readings.append(contentsOf: resumed)
        let gaps = Decimator.gaps(in: readings[...])
        XCTAssertEqual(gaps.count, 1)
        XCTAssertEqual(gaps.first?.start, readings[19].timestamp)
        XCTAssertEqual(gaps.first?.end, resumed[0].timestamp)
        XCTAssertTrue(Decimator.gaps(in: readings[0..<20]).isEmpty)
    }
}
