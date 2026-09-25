import Foundation

/// Statistics between two markers of a session.
struct MarkerSpan: Identifiable, Equatable {
    var id: UUID { from.id }
    let from: Marker
    let to: Marker
    let stats: SessionStats
}

/// Statistics over a time span of a loaded session: the drag selection in
/// the detail chart and the spans between markers. Pure functions over
/// time-ordered readings; every lookup is a binary search so scrubbing a
/// 144k-sample session never walks the array.
enum RangeStats {
    /// Indices of the readings timestamped within `from...to` (both ends
    /// inclusive). Empty when the span holds no reading or `from > to`.
    static func indexRange(in readings: [Reading], from: Date, to: Date) -> Range<Int> {
        guard from <= to, !readings.isEmpty else { return readings.startIndex..<readings.startIndex }
        let lo = firstIndex(in: readings, atOrAfter: from)
        let hi = firstIndex(in: readings, after: to)
        return lo..<Swift.max(lo, hi)
    }

    /// Index of the reading nearest in time to `date`; nil for an empty array.
    static func nearestIndex(in readings: [Reading], to date: Date) -> Int? {
        guard !readings.isEmpty else { return nil }
        let i = firstIndex(in: readings, atOrAfter: date)
        if i >= readings.endIndex { return readings.endIndex - 1 }
        if i == readings.startIndex { return i }
        let before = date.timeIntervalSince(readings[i - 1].timestamp)
        let after = readings[i].timestamp.timeIntervalSince(date)
        return before <= after ? i - 1 : i
    }

    /// Integrates the slice with the rule the recorder uses
    /// (`SessionStats.add`), so the full range reproduces the session's own
    /// statistics. The first reading opens the span and contributes no
    /// interval.
    static func stats(_ slice: ArraySlice<Reading>) -> SessionStats {
        var s = SessionStats()
        for r in slice { s.add(r) }
        return s
    }

    /// Statistics between consecutive markers (sorted by time), one span per
    /// adjacent pair.
    static func spans(in readings: [Reading], between markers: [Marker]) -> [MarkerSpan] {
        let sorted = markers.sorted { $0.timestamp < $1.timestamp }
        guard sorted.count >= 2 else { return [] }
        return zip(sorted, sorted.dropFirst()).map { a, b in
            MarkerSpan(from: a, to: b,
                       stats: stats(readings[indexRange(in: readings, from: a.timestamp, to: b.timestamp)]))
        }
    }

    // MARK: Binary searches

    /// First index whose timestamp is at or after `date` (endIndex when none).
    static func firstIndex(in readings: [Reading], atOrAfter date: Date) -> Int {
        var lo = readings.startIndex, hi = readings.endIndex
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            if readings[mid].timestamp < date { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// First index whose timestamp is after `date` (endIndex when none).
    static func firstIndex(in readings: [Reading], after date: Date) -> Int {
        var lo = readings.startIndex, hi = readings.endIndex
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            if readings[mid].timestamp <= date { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}
