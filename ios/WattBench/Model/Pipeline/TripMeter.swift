import Foundation

/// An always-on accumulator ("how many mAh went into that") that does not
/// need a named session. Persisted by `MeterManager`; a reconnect pause is
/// not integrated thanks to the gap guard in `SessionStats`.
struct TripMeter: Codable, Equatable {
    var label: String
    var startedAt: Date
    var stats = SessionStats()

    init(label: String, startedAt: Date = Date(), stats: SessionStats = SessionStats()) {
        self.label = label
        self.startedAt = startedAt
        self.stats = stats
    }

    mutating func add(_ r: Reading) {
        stats.add(r)
    }

    mutating func reset(at date: Date = Date()) {
        stats = SessionStats()
        startedAt = date
    }

    /// Active (integrated) seconds since the last reset.
    var elapsed: TimeInterval { stats.durationS }
}
