import Foundation

/// One chart point summarising a bucket of readings.
struct DecimatedPoint: Equatable {
    let time: Date
    let min: Double
    let max: Double
    let mean: Double
}

/// Reduces sample arrays for charts and sparklines. Used by the Sessions
/// detail screen and for sparklines; the live chart draws raw readings.
/// The three frozen signatures may not change; functions may be added.
enum Decimator {
    /// Splits `readings` into `targetCount` equal buckets (fewer when there
    /// are not enough readings) and reports min/max/mean of `metric` per
    /// bucket, timed at the bucket's first reading.
    static func minMaxBuckets(_ readings: ArraySlice<Reading>, metric: Metric, targetCount: Int) -> [DecimatedPoint] {
        let n = readings.count
        guard n > 0, targetCount > 0 else { return [] }
        if n <= targetCount {
            return readings.map { r in
                let v = metric.value(r)
                return DecimatedPoint(time: r.timestamp, min: v, max: v, mean: v)
            }
        }
        var out: [DecimatedPoint] = []
        out.reserveCapacity(targetCount)
        let start = readings.startIndex
        for b in 0..<targetCount {
            let lo = start + b * n / targetCount
            let hi = start + (b + 1) * n / targetCount
            guard lo < hi else { continue }
            var lowest = Double.infinity, highest = -Double.infinity, sum = 0.0
            for i in lo..<hi {
                let v = metric.value(readings[i])
                lowest = Swift.min(lowest, v)
                highest = Swift.max(highest, v)
                sum += v
            }
            out.append(DecimatedPoint(time: readings[lo].timestamp, min: lowest, max: highest,
                                      mean: sum / Double(hi - lo)))
        }
        return out
    }

    /// Y range covering every bucket's min/max, padded by `padding` of the
    /// span on each side (a small absolute pad when the data is flat).
    static func yDomain(_ points: [DecimatedPoint], padding: Double = 0.05) -> ClosedRange<Double> {
        guard let first = points.first else { return 0...1 }
        var lo = first.min, hi = first.max
        for p in points.dropFirst() {
            lo = Swift.min(lo, p.min)
            hi = Swift.max(hi, p.max)
        }
        let span = hi - lo
        let pad = span > 0 ? span * padding : Swift.max(abs(hi) * padding, 0.001)
        return (lo - pad)...(hi + pad)
    }

    /// The trailing `seconds` of time-ordered readings (measured from the
    /// last reading).
    static func window(_ readings: [Reading], seconds: TimeInterval) -> ArraySlice<Reading> {
        guard let last = readings.last else { return readings[...] }
        let cutoff = last.timestamp.addingTimeInterval(-seconds)
        // Binary search for the first reading inside the window.
        var lo = readings.startIndex, hi = readings.endIndex
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            if readings[mid].timestamp < cutoff { lo = mid + 1 } else { hi = mid }
        }
        return readings[lo...]
    }

    // MARK: Additions (sparklines)

    /// Mean power per bucket, at most `targetCount` values.
    static func meanPower(_ readings: ArraySlice<Reading>, targetCount: Int) -> [Float] {
        minMaxBuckets(readings, metric: .power, targetCount: targetCount).map { Float($0.mean) }
    }

    /// Averages a series down to at most `targetCount` values.
    static func condense(_ values: [Float], targetCount: Int) -> [Float] {
        let n = values.count
        guard n > targetCount, targetCount > 0 else { return values }
        var out: [Float] = []
        out.reserveCapacity(targetCount)
        for b in 0..<targetCount {
            let lo = b * n / targetCount
            let hi = (b + 1) * n / targetCount
            guard lo < hi else { continue }
            var sum: Float = 0
            for i in lo..<hi { sum += values[i] }
            out.append(sum / Float(hi - lo))
        }
        return out
    }
}
