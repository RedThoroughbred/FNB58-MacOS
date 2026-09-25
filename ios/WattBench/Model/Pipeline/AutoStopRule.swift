import Foundation

/// Conditions that end a recording by themselves. Evaluated by
/// `SessionRecorder.add(_:)` on every sample. Fields and `evaluate` are
/// frozen; WS-E owns the behaviour and tests.
struct AutoStopRule: Codable, Equatable {
    enum Reason: String, Codable {
        case currentBelowThreshold, duration, energy

        var label: String {
            switch self {
            case .currentBelowThreshold: return "current below threshold"
            case .duration: return "duration reached"
            case .energy: return "energy reached"
            }
        }
    }

    /// Stop once the current has stayed below this (A) for `forSeconds`.
    var belowCurrentA: Double?
    var forSeconds: TimeInterval = 60
    /// Stop once the active duration (s) reaches this.
    var maxDuration: TimeInterval?
    /// Stop once the integrated energy (Wh) reaches this.
    var maxEnergyWh: Double?

    /// Seconds of real samples accumulated below the current threshold.
    private var belowSince: TimeInterval = 0

    /// Slack for floating-point sums of sample intervals (1 ms).
    static let tolerance: TimeInterval = 0.001

    init(belowCurrentA: Double? = nil, forSeconds: TimeInterval = 60,
         maxDuration: TimeInterval? = nil, maxEnergyWh: Double? = nil) {
        self.belowCurrentA = belowCurrentA
        self.forSeconds = forSeconds
        self.maxDuration = maxDuration
        self.maxEnergyWh = maxEnergyWh
    }

    /// `dt` is the interval since the previous sample. Time below the
    /// threshold accumulates only from real samples (`dt <= maxGapS`), so a
    /// gap can never trigger a stop by itself; the counter resets once the
    /// current is back above threshold plus 2 percent hysteresis.
    mutating func evaluate(_ r: Reading, dt: TimeInterval, stats: SessionStats) -> Reason? {
        if let maxDuration, stats.durationS >= maxDuration { return .duration }
        if let maxEnergyWh, stats.energyWh >= maxEnergyWh { return .energy }
        if let threshold = belowCurrentA {
            if r.current < threshold {
                if dt > 0, dt <= SessionStats.maxGapS { belowSince += dt }
                if belowSince + Self.tolerance >= forSeconds { return .currentBelowThreshold }
            } else if r.current >= threshold * 1.02 {
                belowSince = 0
            }
        }
        return nil
    }
}
