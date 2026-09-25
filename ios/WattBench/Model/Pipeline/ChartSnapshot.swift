import Foundation

/// What the live chart draws: the raw readings of the visible window (at most
/// the 2-minute ring, 1200 points at 10 Hz), time ordered, plus the intervals
/// where consecutive samples are further apart than `SessionStats.maxGapS`.
/// Published by `SamplePipeline` at most 5 times per second.
struct ChartSnapshot: Equatable {
    /// Longest span kept in a snapshot.
    static let windowSeconds: TimeInterval = 120

    var points: [Reading]
    var publishedAt: Date
    var gaps: [DateInterval]

    static let empty = ChartSnapshot(points: [], publishedAt: .distantPast, gaps: [])

    /// Builds a snapshot from time-ordered readings, windowing to the last
    /// `windowSeconds` and detecting gaps.
    static func make(from readings: [Reading], at publishedAt: Date) -> ChartSnapshot {
        let window = Array(Decimator.window(readings, seconds: windowSeconds))
        var gaps: [DateInterval] = []
        var previous: Reading?
        for r in window {
            if let p = previous {
                let dt = r.monotonic > 0 && p.monotonic > 0
                    ? r.monotonic - p.monotonic
                    : r.timestamp.timeIntervalSince(p.timestamp)
                if dt > SessionStats.maxGapS, r.timestamp > p.timestamp {
                    gaps.append(DateInterval(start: p.timestamp, end: r.timestamp))
                }
            }
            previous = r
        }
        return ChartSnapshot(points: window, publishedAt: publishedAt, gaps: gaps)
    }
}
