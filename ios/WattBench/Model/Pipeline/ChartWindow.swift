import Foundation

/// The span of the live chart's visible window. Raw values are seconds so
/// `Preferences.defaultWindow` (a plain Double) round-trips through it.
///
/// The static helpers are the pure parts of the live chart (windowing,
/// normalisation for the "All" mode, y-domain and pin-to-live logic) so they
/// can be unit tested without SwiftUI.
enum ChartWindow: Double, CaseIterable, Identifiable, Codable {
    case s10 = 10
    case s30 = 30
    case s60 = 60
    case m2 = 120

    var id: Double { rawValue }
    var seconds: TimeInterval { rawValue }

    var label: String {
        switch self {
        case .s10: return "10 s"
        case .s30: return "30 s"
        case .s60: return "60 s"
        case .m2: return "2 min"
        }
    }

    /// Spoken form for VoiceOver ("10 seconds", "2 minutes").
    var spokenLabel: String {
        switch self {
        case .s10: return "10 seconds"
        case .s30: return "30 seconds"
        case .s60: return "60 seconds"
        case .m2: return "2 minutes"
        }
    }

    /// The case nearest to `seconds`, for a persisted preference that may hold
    /// any value.
    static func nearest(to seconds: Double) -> ChartWindow {
        guard seconds.isFinite else { return .s30 }
        return allCases.min { abs($0.rawValue - seconds) < abs($1.rawValue - seconds) } ?? .s30
    }

    // MARK: - Windowing

    /// Readings whose timestamps fall inside `from...to` (inclusive), for
    /// time-ordered input. Binary searches both edges.
    static func slice(_ readings: [Reading], from: Date, to: Date) -> ArraySlice<Reading> {
        guard from <= to, !readings.isEmpty else { return readings[readings.endIndex...] }
        let lower = firstIndex(in: readings) { $0.timestamp >= from }
        let upper = firstIndex(in: readings) { $0.timestamp > to }
        guard lower < upper else { return readings[readings.endIndex...] }
        return readings[lower..<upper]
    }

    /// The last `window.seconds` of time-ordered readings, measured from the
    /// newest one.
    static func trailing(_ readings: [Reading], window: ChartWindow) -> ArraySlice<Reading> {
        Decimator.window(readings, seconds: window.seconds)
    }

    /// Index of the reading closest in time to `date`, or nil when empty.
    static func nearestIndex(in readings: [Reading], to date: Date) -> Int? {
        guard !readings.isEmpty else { return nil }
        let i = firstIndex(in: readings) { $0.timestamp >= date }
        if i == readings.startIndex { return i }
        if i == readings.endIndex { return readings.endIndex - 1 }
        let before = readings[i - 1], after = readings[i]
        return date.timeIntervalSince(before.timestamp) <= after.timestamp.timeIntervalSince(date) ? i - 1 : i
    }

    /// First index whose element satisfies `predicate`, assuming the predicate
    /// is false then true along the array (endIndex when never true).
    private static func firstIndex(in readings: [Reading], where predicate: (Reading) -> Bool) -> Int {
        var lo = readings.startIndex, hi = readings.endIndex
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            if predicate(readings[mid]) { hi = mid } else { lo = mid + 1 }
        }
        return lo
    }

    // MARK: - Scales

    /// A linear map of one metric's min–max onto 0...1, so the "All" mode can
    /// draw three series on one axis. A flat series maps to 0.5 everywhere.
    struct Scale: Equatable {
        let lo: Double
        let hi: Double

        /// Nil when `values` holds no finite number.
        init?(_ values: some Sequence<Double>) {
            var lo = Double.infinity, hi = -Double.infinity
            for v in values where v.isFinite {
                lo = Swift.min(lo, v)
                hi = Swift.max(hi, v)
            }
            guard lo.isFinite, hi.isFinite else { return nil }
            self.lo = lo
            self.hi = hi
        }

        func normalise(_ v: Double) -> Double {
            let span = hi - lo
            return span > 0 ? (v - lo) / span : 0.5
        }
    }

    /// Maps values onto 0...1 by their own min-max ("All" mode draws three
    /// series on one axis). A flat series maps to 0.5 everywhere.
    static func normalise(_ values: [Double]) -> [Double] {
        guard let scale = Scale(values) else { return [] }
        return values.map(scale.normalise)
    }

    /// Y range covering `values` (and `extra`, e.g. the peak line, when given)
    /// padded by `padding` of the span on each side. A flat line gets a small
    /// absolute pad so the chart never has a zero-height domain. Mirrors
    /// `Decimator.yDomain` for raw readings.
    static func yDomain(_ values: [Double], including extra: Double? = nil, padding: Double = 0.05) -> ClosedRange<Double> {
        var lo = Double.infinity, hi = -Double.infinity
        for v in values where v.isFinite {
            lo = min(lo, v)
            hi = max(hi, v)
        }
        if let extra, extra.isFinite {
            lo = min(lo, extra)
            hi = max(hi, extra)
        }
        guard lo.isFinite, hi.isFinite else { return 0...1 }
        let span = hi - lo
        let pad = span > 0 ? span * padding : max(abs(hi) * padding, 0.001)
        return (lo - pad)...(hi + pad)
    }

    /// Snaps a domain outwards to a "nice" grid (1, 2 or 5 times a power of
    /// ten, about `steps` divisions) so the scale does not jitter with every
    /// 200 ms snapshot; it only moves when the data crosses a grid line.
    static func stabilised(_ domain: ClosedRange<Double>, steps: Int = 4) -> ClosedRange<Double> {
        let span = domain.upperBound - domain.lowerBound
        guard span > 0, span.isFinite, steps > 0 else { return domain }
        let step = niceStep(span / Double(steps))
        let lo = (domain.lowerBound / step).rounded(.down) * step
        let hi = (domain.upperBound / step).rounded(.up) * step
        return lo < hi ? lo...hi : domain
    }

    /// The largest of 1, 2, 5 × 10^k that is at most `raw`.
    static func niceStep(_ raw: Double) -> Double {
        guard raw > 0, raw.isFinite else { return 1 }
        let magnitude = pow(10, (log10(raw)).rounded(.down))
        let residual = raw / magnitude
        let factor: Double = residual >= 5 ? 5 : residual >= 2 ? 2 : 1
        return factor * magnitude
    }

    // MARK: - Pin to live

    /// The leading edge that keeps the newest sample on the trailing edge.
    static func pinnedStart(last: Date, window: ChartWindow) -> Date {
        last.addingTimeInterval(-window.seconds)
    }

    /// The chart's scrollable x-domain: the readings' span, extended
    /// backwards to at least one window so the newest sample can sit on the
    /// trailing edge even while fewer than `window` seconds of data exist
    /// (Swift Charts otherwise clamps the scroll position to the data).
    static func xDomain(first: Date, last: Date, window: ChartWindow) -> ClosedRange<Date> {
        let start = min(first, pinnedStart(last: last, window: window))
        return start...max(last, start)
    }

    /// True while the scroll position is within `tolerance` of the pinned
    /// start, i.e. the user has not scrolled back into history. One snapshot
    /// step is 200 ms, so the default tolerance of 1 s never trips by itself.
    static func isFollowing(scrollX: Date, pinnedStart: Date, tolerance: TimeInterval = 1) -> Bool {
        abs(scrollX.timeIntervalSince(pinnedStart)) <= tolerance
    }
}
