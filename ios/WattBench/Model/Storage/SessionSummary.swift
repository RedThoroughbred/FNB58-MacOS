import Foundation

/// Everything the Sessions list needs without touching samples. Persisted as
/// the per-session manifest once WS-A lands the journal layout; derived from
/// the full session in the foundation store.
struct SessionSummary: Codable, Identifiable, Equatable {
    enum State: String, Codable { case recording, complete, recovered }

    /// Number of points kept in `sparkline`.
    static let sparklineCount = 60

    var schemaVersion: Int = Session.currentSchema
    var id: UUID
    var name: String
    var startTime: Date
    var endTime: Date
    var deviceName: String?
    var stats: SessionStats
    var sampleCount: Int
    var markers: [Marker]
    var tags: [String]
    var notes: String?
    var autoStopReason: String?
    var isDemo: Bool
    var state: State
    /// Mean power per bucket, at most `sparklineCount` values.
    var sparkline: [Float]

    /// Wall-clock span; `stats.durationS` is the active duration.
    var duration: TimeInterval { endTime.timeIntervalSince(startTime) }
}
