import Foundation

/// Prose helpers shared by alert and auto-stop text.
enum AlertFormat {
    /// A short, locale-aware duration for prose: "45 sec", "1 min", "1 hr, 30 min".
    static func span(_ seconds: TimeInterval, locale: Locale = .autoupdatingCurrent) -> String {
        let whole = max(0, seconds.isFinite ? seconds.rounded() : 0)
        return Duration.seconds(whole).formatted(
            .units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2)
                .locale(locale))
    }
}

/// Fixed-capacity history of (time, voltage) pairs for drop detection. Never
/// allocates after `init`.
struct VoltageRing: Equatable {
    static let capacity = 32

    private var times = [TimeInterval](repeating: 0, count: VoltageRing.capacity)
    private var volts = [Double](repeating: 0, count: VoltageRing.capacity)
    private var head = 0
    private(set) var count = 0

    mutating func push(time: TimeInterval, voltage: Double) {
        if count == Self.capacity {
            times[head] = time
            volts[head] = voltage
            head = (head + 1) % Self.capacity
        } else {
            let index = (head + count) % Self.capacity
            times[index] = time
            volts[index] = voltage
            count += 1
        }
    }

    /// Highest voltage among the entries stamped at or after `since`
    /// (`-infinity` when there is none).
    func maxVoltage(since: TimeInterval) -> Double {
        var best = -Double.infinity
        for k in 0..<count {
            let i = (head + k) % Self.capacity
            if times[i] >= since { best = max(best, volts[i]) }
        }
        return best
    }

    mutating func removeAll() {
        head = 0
        count = 0
    }
}

/// The pure rule engine behind `AlertCoordinator`.
///
/// A value type with no allocation on the hot path: per-rule state lives in
/// an array parallel to `rules` that is rebuilt only when the rules change,
/// and the voltage history for drop rules is a fixed ring. `evaluate` returns
/// the events that fired for one sample (an empty array allocates nothing).
///
/// Semantics shared by every rule: a rule fires at most once per `cooldown`,
/// and after firing it re-arms only once the value is back `rearmMargin`
/// inside its bound, so a reading hovering around a limit produces one alert,
/// not a stream of them. Sustained rules (`forSeconds > 0`) count only real
/// sample intervals (`dt <= SessionStats.maxGapS`), so a reconnect gap can
/// never satisfy them by itself. The `.disconnected` rule is driven by time,
/// not samples (`tick`), and only while a recording is in progress.
struct ThresholdMonitor {
    /// A rule fires at most once per this interval.
    static let cooldown: TimeInterval = 60
    /// A fired rule re-arms once the value is back this fraction inside its bound.
    static let rearmMargin = 0.02
    /// Window over which a voltage drop is measured.
    static let dropWindow: TimeInterval = 1
    /// Slack for floating-point sums of sample intervals (1 ms), as in `AutoStopRule`.
    static let tolerance: TimeInterval = 0.001

    struct RuleState: Equatable {
        var armed = true
        /// Real-sample seconds spent outside the bound (sustained rules).
        var sustained: TimeInterval = 0
        var lastFired: Date?
    }

    private(set) var rules: [AlertRule] = []
    private var states: [RuleState] = []
    private var ring = VoltageRing()
    private var needsRing = false
    private var lastSampleAt: Date?
    private var disconnectedSince: Date?
    /// Formats the numbers in event messages.
    var formatter: MetricFormatter

    init(rules: [AlertRule] = [], formatter: MetricFormatter = MetricFormatter()) {
        self.formatter = formatter
        setRules(rules)
    }

    /// Replaces the rule set, keeping the state (cooldown, arming) of rules
    /// whose id survives.
    mutating func setRules(_ new: [AlertRule]) {
        var kept: [RuleState] = []
        kept.reserveCapacity(new.count)
        for rule in new {
            if let i = rules.firstIndex(where: { $0.id == rule.id }), i < states.count {
                kept.append(states[i])
            } else {
                kept.append(RuleState())
            }
        }
        rules = new
        states = kept
        needsRing = new.contains { $0.enabled && $0.kind == .voltageDrop }
        if !needsRing { ring.removeAll() }
    }

    /// Current state of one rule (tests, settings screen).
    func state(of id: UUID) -> RuleState? {
        guard let i = rules.firstIndex(where: { $0.id == id }), i < states.count else { return nil }
        return states[i]
    }

    /// True while an enabled `.disconnected` rule exists.
    var hasEnabledDisconnectRule: Bool {
        rules.contains { $0.enabled && $0.kind == .disconnected }
    }

    /// Shortest wait among the enabled `.disconnected` rules that want a
    /// background notification; nil when there is none.
    var disconnectNotifySeconds: TimeInterval? {
        rules.filter { $0.enabled && $0.notify && $0.kind == .disconnected }.map(\.forSeconds).min()
    }

    /// True while an enabled `.disconnected` rule is armed, i.e. `tick` could
    /// still fire something.
    var isWatchingDisconnect: Bool {
        for i in rules.indices where rules[i].enabled && rules[i].kind == .disconnected && states[i].armed {
            return true
        }
        return false
    }

    // MARK: - Sample path

    /// Evaluates every enabled rule against one reading. `context.dt` is the
    /// interval since the previous sample. Event times come from the reading.
    mutating func evaluate(_ r: Reading, context: SampleContext) -> [AlertEvent] {
        let now = r.timestamp
        lastSampleAt = now
        disconnectedSince = nil
        var events: [AlertEvent] = []
        if needsRing { ring.push(time: Self.time(of: r), voltage: r.voltage) }
        for i in rules.indices where rules[i].enabled {
            switch rules[i].kind {
            case .threshold:
                evaluateThreshold(at: i, reading: r, dt: context.dt, now: now, into: &events)
            case .voltageDrop:
                evaluateDrop(at: i, reading: r, now: now, into: &events)
            case .disconnected:
                // A sample means the meter is back.
                states[i].armed = true
            }
        }
        return events
    }

    // MARK: - Time path (disconnected rule)

    /// Call periodically while no samples arrive. Fires the `.disconnected`
    /// rules once the meter has been away for their `forSeconds`, only while
    /// recording. Any sample (via `evaluate`) ends the disconnection.
    mutating func tick(now: Date, isRecording: Bool, isConnected: Bool) -> [AlertEvent] {
        guard isRecording, !isConnected else {
            disconnectedSince = nil
            return []
        }
        let since = disconnectedSince ?? lastSampleAt ?? now
        disconnectedSince = since
        let elapsed = now.timeIntervalSince(since)
        var events: [AlertEvent] = []
        for i in rules.indices where rules[i].enabled && rules[i].kind == .disconnected {
            let rule = rules[i]
            guard states[i].armed, elapsed + Self.tolerance >= rule.forSeconds, !inCooldown(i, now: now) else { continue }
            states[i].armed = false
            states[i].lastFired = now
            let span = AlertFormat.span(max(elapsed, rule.forSeconds), locale: formatter.locale)
            events.append(AlertEvent(ruleID: rule.id, title: rule.name,
                                     message: "Meter disconnected for \(span) while recording",
                                     firedAt: now, metric: nil, value: elapsed))
        }
        return events
    }

    // MARK: - Rules

    private mutating func evaluateThreshold(at i: Int, reading r: Reading, dt: TimeInterval, now: Date,
                                            into events: inout [AlertEvent]) {
        let rule = rules[i]
        let v = rule.metric.value(r)
        let crossedAbove = rule.above.map { v > $0 } ?? false
        let crossedBelow = rule.below.map { v < $0 } ?? false
        if crossedAbove || crossedBelow {
            guard states[i].armed else { return }
            if rule.forSeconds > 0, dt > 0, dt <= SessionStats.maxGapS { states[i].sustained += dt }
            let due = rule.forSeconds <= 0 || states[i].sustained + Self.tolerance >= rule.forSeconds
            guard due, !inCooldown(i, now: now) else { return }
            states[i].armed = false
            states[i].sustained = 0
            states[i].lastFired = now
            let bound = crossedAbove ? rule.above : rule.below
            events.append(AlertEvent(ruleID: rule.id, title: rule.name,
                                     message: thresholdMessage(rule, value: v, bound: bound, above: crossedAbove),
                                     firedAt: now, metric: rule.metric, value: v))
        } else {
            let insideAbove = rule.above.map { v <= $0 - Self.rearmMargin * abs($0) } ?? true
            let insideBelow = rule.below.map { v >= $0 + Self.rearmMargin * abs($0) } ?? true
            if insideAbove && insideBelow {
                states[i].armed = true
                states[i].sustained = 0
            }
        }
    }

    private mutating func evaluateDrop(at i: Int, reading r: Reading, now: Date, into events: inout [AlertEvent]) {
        let rule = rules[i]
        guard let delta = rule.above, delta > 0 else { return }
        let peak = ring.maxVoltage(since: Self.time(of: r) - Self.dropWindow)
        let drop = peak - r.voltage
        if drop >= delta {
            guard states[i].armed, !inCooldown(i, now: now) else { return }
            states[i].armed = false
            states[i].lastFired = now
            let window = AlertFormat.span(Self.dropWindow, locale: formatter.locale)
            let message = "Voltage dropped \(formatter.format(drop, .voltage).text) within \(window)"
                + " (from \(formatter.format(peak, .voltage).text) to \(formatter.format(r.voltage, .voltage).text))"
            events.append(AlertEvent(ruleID: rule.id, title: rule.name, message: message,
                                     firedAt: now, metric: .voltage, value: drop))
        } else if drop <= delta * (1 - Self.rearmMargin) {
            states[i].armed = true
        }
    }

    private func thresholdMessage(_ rule: AlertRule, value: Double, bound: Double?, above: Bool) -> String {
        let metric = rule.metric
        let v = formatter.format(value, metric).text
        let b = bound.map { formatter.format($0, metric).text } ?? "the limit"
        let relation = above ? "above" : "below"
        if rule.forSeconds > 0 {
            let span = AlertFormat.span(rule.forSeconds, locale: formatter.locale)
            return "\(metric.title) \(v) has been \(relation) \(b) for \(span)"
        }
        return "\(metric.title) \(v) is \(relation) \(b)"
    }

    private func inCooldown(_ i: Int, now: Date) -> Bool {
        guard let fired = states[i].lastFired else { return false }
        return now.timeIntervalSince(fired) < Self.cooldown
    }

    private static func time(of r: Reading) -> TimeInterval {
        r.monotonic > 0 ? r.monotonic : r.timestamp.timeIntervalSinceReferenceDate
    }
}
