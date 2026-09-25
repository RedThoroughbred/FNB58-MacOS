import XCTest
@testable import WattBench

final class ChartWindowTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_760_000_000)

    /// 10 Hz readings covering `seconds` seconds.
    private func readings(seconds: Int, power: (Int) -> Double = { _ in 10 }) -> [Reading] {
        (0..<(seconds * 10)).map { k in
            Reading(timestamp: t0.addingTimeInterval(Double(k) * 0.1), voltage: 5, current: 2, power: power(k),
                    monotonic: 100 + Double(k) * 0.1)
        }
    }

    func testNormaliseMapsMinMaxToZeroOne() {
        XCTAssertEqual(ChartWindow.normalise([2, 4, 6]), [0, 0.5, 1])
        XCTAssertEqual(ChartWindow.normalise([-1, 1]), [0, 1])
        XCTAssertEqual(ChartWindow.normalise([3, 3, 3]), [0.5, 0.5, 0.5], "a flat series sits mid-scale")
        XCTAssertEqual(ChartWindow.normalise([]), [])
        XCTAssertEqual(ChartWindow.normalise([7]), [0.5])
    }

    func testWindowSliceIsTimeBounded() {
        let all = readings(seconds: 10)
        let slice = ChartWindow.slice(all, from: t0.addingTimeInterval(2), to: t0.addingTimeInterval(4))
        XCTAssertEqual(slice.count, 21, "2.0 ... 4.0 inclusive at 10 Hz")
        XCTAssertEqual(slice.first?.timestamp, t0.addingTimeInterval(2))
        XCTAssertEqual(slice.last?.timestamp, t0.addingTimeInterval(4))
        XCTAssertTrue(slice.allSatisfy { $0.timestamp >= t0.addingTimeInterval(2) && $0.timestamp <= t0.addingTimeInterval(4) })

        XCTAssertTrue(ChartWindow.slice(all, from: t0.addingTimeInterval(20), to: t0.addingTimeInterval(30)).isEmpty)
        XCTAssertTrue(ChartWindow.slice(all, from: t0.addingTimeInterval(4), to: t0.addingTimeInterval(2)).isEmpty, "inverted range")
        XCTAssertTrue(ChartWindow.slice([], from: t0, to: t0.addingTimeInterval(1)).isEmpty)

        // Edges before the first / after the last reading clamp.
        let head = ChartWindow.slice(all, from: t0.addingTimeInterval(-5), to: t0.addingTimeInterval(0.25))
        XCTAssertEqual(head.count, 3)
        XCTAssertEqual(head.first?.timestamp, t0)

        // The trailing window is measured from the newest reading.
        let trailing = ChartWindow.trailing(all, window: .s10)
        XCTAssertEqual(trailing.count, all.count, "10 s of data fits the 10 s window")
        let sixty = readings(seconds: 60)
        let last30 = ChartWindow.trailing(sixty, window: .s30)
        XCTAssertEqual(last30.first?.timestamp, sixty.last?.timestamp.addingTimeInterval(-30))
        XCTAssertEqual(last30.last?.id, sixty.last?.id)
    }

    func testYDomainPaddingAndFlatLineFallback() {
        let padded = ChartWindow.yDomain([1, 3, 2])
        XCTAssertEqual(padded.lowerBound, 0.9, accuracy: 1e-9)
        XCTAssertEqual(padded.upperBound, 3.1, accuracy: 1e-9)

        // Flat data: 5 percent of the magnitude, never a zero-height domain.
        let flat = ChartWindow.yDomain([5, 5, 5])
        XCTAssertEqual(flat.lowerBound, 4.75, accuracy: 1e-9)
        XCTAssertEqual(flat.upperBound, 5.25, accuracy: 1e-9)
        let zero = ChartWindow.yDomain([0, 0])
        XCTAssertEqual(zero.lowerBound, -0.001, accuracy: 1e-12)
        XCTAssertEqual(zero.upperBound, 0.001, accuracy: 1e-12)
        XCTAssertGreaterThan(zero.upperBound, zero.lowerBound)

        // The peak line is included in the domain when asked for.
        let withPeak = ChartWindow.yDomain([1, 3], including: 10)
        XCTAssertEqual(withPeak.upperBound, 10.45, accuracy: 1e-9)
        XCTAssertEqual(withPeak.lowerBound, 0.55, accuracy: 1e-9)

        XCTAssertEqual(ChartWindow.yDomain([]), 0...1)
        XCTAssertEqual(ChartWindow.yDomain([.nan, .infinity]), 0...1)

        // Same behaviour as the sessions decimator on equivalent input.
        let points = [1.0, 3.0, 2.0].map { DecimatedPoint(time: t0, min: $0, max: $0, mean: $0) }
        XCTAssertEqual(Decimator.yDomain(points), padded)
    }

    func testStabilisedDomainSnapsToNiceGrid() {
        XCTAssertEqual(ChartWindow.niceStep(0.37), 0.2)
        XCTAssertEqual(ChartWindow.niceStep(6), 5)
        XCTAssertEqual(ChartWindow.niceStep(23), 20)
        XCTAssertEqual(ChartWindow.niceStep(100), 100)
        XCTAssertEqual(ChartWindow.niceStep(0), 1)

        let stable = ChartWindow.stabilised(9.012...9.031)
        // span 0.019 / 4 -> step 0.002: outward to the grid.
        XCTAssertEqual(stable.lowerBound, 9.012, accuracy: 1e-9)
        XCTAssertEqual(stable.upperBound, 9.032, accuracy: 1e-9)
        XCTAssertTrue(stable.contains(9.012) && stable.contains(9.031))
        // Small drifts inside the grid cells do not move the domain.
        XCTAssertEqual(ChartWindow.stabilised(9.0125...9.0305), stable)
        XCTAssertEqual(ChartWindow.stabilised(5...5), 5...5, "degenerate input passes through")
    }

    func testNearestWindowAndLabels() {
        XCTAssertEqual(ChartWindow.nearest(to: 30), .s30)
        XCTAssertEqual(ChartWindow.nearest(to: 45), .s30)
        XCTAssertEqual(ChartWindow.nearest(to: 46), .s60)
        XCTAssertEqual(ChartWindow.nearest(to: 1000), .m2)
        XCTAssertEqual(ChartWindow.nearest(to: .nan), .s30)
        XCTAssertEqual(ChartWindow.allCases.map(\.label), ["10 s", "30 s", "60 s", "2 min"])
        XCTAssertEqual(ChartWindow(rawValue: 120), .m2)
        XCTAssertNil(ChartWindow(rawValue: 45))
    }

    func testScaleNormalisesAgainstItsOwnRange() throws {
        let scale = try XCTUnwrap(ChartWindow.Scale([2, 4, 6, .nan]))
        XCTAssertEqual(scale.lo, 2)
        XCTAssertEqual(scale.hi, 6)
        XCTAssertEqual(scale.normalise(2), 0)
        XCTAssertEqual(scale.normalise(5), 0.75)
        XCTAssertEqual(scale.normalise(8), 1.5, "values outside the window clip on the chart, not here")
        XCTAssertEqual(try XCTUnwrap(ChartWindow.Scale([3, 3])).normalise(3), 0.5)
        XCTAssertNil(ChartWindow.Scale([Double]()))
        XCTAssertNil(ChartWindow.Scale([.nan, .infinity]))
    }

    func testFollowingToleranceAndNearestIndex() {
        let last = t0.addingTimeInterval(100)
        let pinned = ChartWindow.pinnedStart(last: last, window: .s30)
        XCTAssertEqual(pinned, t0.addingTimeInterval(70))
        XCTAssertTrue(ChartWindow.isFollowing(scrollX: pinned.addingTimeInterval(0.2), pinnedStart: pinned))
        XCTAssertTrue(ChartWindow.isFollowing(scrollX: pinned.addingTimeInterval(-0.9), pinnedStart: pinned))
        XCTAssertFalse(ChartWindow.isFollowing(scrollX: pinned.addingTimeInterval(-5), pinnedStart: pinned))

        let all = readings(seconds: 5)
        XCTAssertNil(ChartWindow.nearestIndex(in: [], to: t0))
        XCTAssertEqual(ChartWindow.nearestIndex(in: all, to: t0.addingTimeInterval(-1)), 0)
        XCTAssertEqual(ChartWindow.nearestIndex(in: all, to: t0.addingTimeInterval(99)), all.count - 1)
        XCTAssertEqual(ChartWindow.nearestIndex(in: all, to: t0.addingTimeInterval(1.04)), 10)
        XCTAssertEqual(ChartWindow.nearestIndex(in: all, to: t0.addingTimeInterval(1.06)), 11)
    }
}
