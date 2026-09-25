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
    /// The counter resets once the current is back above threshold by this fraction.
    static let rearmMargin = 0.02

    init(belowCurrentA: Double? = nil, forSeconds: TimeInterval = 60,
         maxDuration: TimeInterval? = nil, maxEnergyWh: Double? = nil) {
        self.belowCurrentA = belowCurrentA
        self.forSeconds = forSeconds
        self.maxDuration = maxDuration
        self.maxEnergyWh = maxEnergyWh
    }

    /// `belowSince` is progress, not configuration: it is never persisted, so
    /// a rule remembered in Preferences always starts from zero.
    private enum CodingKeys: String, CodingKey {
        case belowCurrentA, forSeconds, maxDuration, maxEnergyWh
    }

    /// True when no condition is set (the rule can never fire).
    var isEmpty: Bool {
        belowCurrentA == nil && maxDuration == nil && maxEnergyWh == nil
    }

    /// `dt` is the interval since the previous sample. Time below the
    /// threshold accumulates only from real samples (`dt <= maxGapS`), so a
    /// gap can never trigger a stop by itself; the counter resets once the
    /// current is back above threshold plus 2 percent hysteresis. Duration
    /// and energy limits are checked first, against the recorder's stats.
    mutating func evaluate(_ r: Reading, dt: TimeInterval, stats: SessionStats) -> Reason? {
        if let maxDuration, stats.durationS + Self.tolerance >= maxDuration { return .duration }
        if let maxEnergyWh, stats.energyWh >= maxEnergyWh { return .energy }
        if let threshold = belowCurrentA {
            if r.current < threshold {
                if dt > 0, dt <= SessionStats.maxGapS { belowSince += dt }
                if belowSince + Self.tolerance >= forSeconds { return .currentBelowThreshold }
            } else if r.current >= threshold + Self.rearmMargin * abs(threshold) {
                belowSince = 0
            }
        }
        return nil
    }

    // MARK: - Text

    /// The configured conditions in words, "·"-joined: "current below 100 mA
    /// for 1 min · after 1 hr · at 10 Wh". Empty for an empty rule.
    func summary(formatter: MetricFormatter = MetricFormatter()) -> String {
        var parts: [String] = []
        if belowCurrentA != nil { parts.append(description(of: .currentBelowThreshold, formatter: formatter)) }
        if maxDuration != nil { parts.append(description(of: .duration, formatter: formatter)) }
        if maxEnergyWh != nil { parts.append(description(of: .energy, formatter: formatter)) }
        return parts.joined(separator: " · ")
    }

    /// Why the recording stopped, with this rule's numbers: "current below
    /// 100 mA for 1 min", "after 1 hr", "at 10 Wh". Falls back to the
    /// generic label when the matching condition is not set.
    func description(of reason: Reason, formatter: MetricFormatter = MetricFormatter()) -> String {
        switch reason {
        case .currentBelowThreshold:
            guard let a = belowCurrentA else { return reason.label }
            return "current below \(AlertFormat.value(a, .current, formatter: formatter)) for \(AlertFormat.span(forSeconds, locale: formatter.locale))"
        case .duration:
            guard let d = maxDuration else { return reason.label }
            return "after \(AlertFormat.span(d, locale: formatter.locale))"
        case .energy:
            guard let wh = maxEnergyWh else { return reason.label }
            return "at \(AlertFormat.energy(wh, formatter: formatter))"
        }
    }
}
