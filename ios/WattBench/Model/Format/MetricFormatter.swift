import Foundation

/// A number and its unit, kept separate so views can style them differently.
struct FormattedValue: Equatable {
    let number: String
    let unit: String
    var text: String { number + " " + unit }
}

/// Which SI prefix a value is shown with. The decision is pure; callers that
/// want hysteresis keep the previous range in `@State` and pass it back
/// (or use `MetricFormatter.formatLive`, which does exactly that).
enum UnitRange: Equatable {
    case base, milli

    /// Switch-down and switch-up thresholds (base units).
    static let toMilliBelow = 0.95
    static let toBaseAbove = 1.05

    /// Current and power auto-range to milli units; voltage never does.
    /// With `previous` supplied: move to milli only below 0.95 and back to
    /// base only above 1.05, so a value hovering around 1 does not flicker.
    static func range(for value: Double, metric: Metric, previous: UnitRange?) -> UnitRange {
        guard metric != .voltage, value.isFinite else { return .base }
        let magnitude = abs(value)
        switch previous {
        case .milli?:
            return magnitude > toBaseAbove ? .base : .milli
        case .base?:
            return magnitude < toMilliBelow ? .milli : .base
        case nil:
            return magnitude < toMilliBelow ? .milli : .base
        }
    }

    /// Prefix for `Metric.symbol` ("m" or nothing).
    var prefix: String { self == .milli ? "m" : "" }

    /// Prefix for `Metric.spokenName` ("milli" or nothing).
    var spokenPrefix: String { self == .milli ? "milli" : "" }
}

/// Locale-aware number formatting for every readout. A value type: create one
/// from `Preferences.formatter` and pass it around; never `String(format:)`
/// in views.
///
/// Numbers are shown with `precision` significant digits, except that digits
/// left of the decimal point are never rounded away (12345 mAh stays 12345,
/// not 12300). Non-finite input formats as `placeholder`. Negative current is
/// shown with its sign: flow direction is displayed, not hidden.
struct MetricFormatter {
    var locale: Locale = .autoupdatingCurrent
    /// Significant digits shown (3 or 4 from Preferences).
    var precision: Int = 3
    /// When true, current, power, energy and capacity drop to milli units
    /// below 0.95 of the base unit.
    var autoRange = true
    /// `.mAh` locks capacity to milliamp-hours whatever its magnitude;
    /// `.Ah` lets it auto-range like the other quantities.
    var capacityUnit: Preferences.CapacityUnit = .Ah

    static let placeholder = "--"

    // MARK: Metrics

    func format(_ v: Double?, _ m: Metric) -> FormattedValue {
        guard let v, v.isFinite else { return FormattedValue(number: Self.placeholder, unit: m.symbol) }
        let range = autoRange ? UnitRange.range(for: v, metric: m, previous: nil) : .base
        return format(v, m, range: range)
    }

    /// Formats with an explicit range (from `UnitRange.range(for:metric:previous:)`).
    func format(_ v: Double, _ m: Metric, range: UnitRange) -> FormattedValue {
        guard v.isFinite else { return FormattedValue(number: Self.placeholder, unit: range.prefix + m.symbol) }
        switch range {
        case .base: return FormattedValue(number: significant(v), unit: m.symbol)
        case .milli: return FormattedValue(number: significant(v * 1000), unit: "m" + m.symbol)
        }
    }

    /// Hysteresis-aware formatting for live readouts. Pass the `range`
    /// returned by the previous call (kept in `@State`); the unit moves to
    /// milli only below 0.95 and back to base only above 1.05, so a value
    /// oscillating around 1 A never flips units between samples. A missing or
    /// non-finite value keeps the previous range.
    func formatLive(_ v: Double?, _ m: Metric, previous: UnitRange?) -> (value: FormattedValue, range: UnitRange?) {
        guard let v, v.isFinite else {
            return (FormattedValue(number: Self.placeholder, unit: (previous?.prefix ?? "") + m.symbol), previous)
        }
        guard autoRange else { return (format(v, m, range: .base), nil) }
        let range = UnitRange.range(for: v, metric: m, previous: previous)
        return (format(v, m, range: range), range)
    }

    func energy(_ wh: Double) -> FormattedValue {
        guard wh.isFinite else { return FormattedValue(number: Self.placeholder, unit: "Wh") }
        if autoRange, abs(wh) < 1 { return FormattedValue(number: significant(wh * 1000), unit: "mWh") }
        return FormattedValue(number: significant(wh), unit: "Wh")
    }

    func capacity(_ ah: Double) -> FormattedValue {
        guard ah.isFinite else { return FormattedValue(number: Self.placeholder, unit: capacityUnit == .mAh ? "mAh" : "Ah") }
        if capacityUnit == .mAh || (autoRange && abs(ah) < 1) {
            return FormattedValue(number: significant(ah * 1000), unit: "mAh")
        }
        return FormattedValue(number: significant(ah), unit: "Ah")
    }

    /// "mm:ss" below one hour, "h:mm:ss" above.
    func duration(_ s: TimeInterval) -> String {
        guard s.isFinite, s >= 0 else { return Self.placeholder }
        let d = Duration.seconds(s.rounded(.down))
        if s >= 3600 {
            return d.formatted(.time(pattern: .hourMinuteSecond).locale(locale))
        }
        return d.formatted(.time(pattern: .minuteSecond(padMinuteToLength: 2)).locale(locale))
    }

    /// A span in words for settings and rule descriptions: "30 sec",
    /// "2 min", "1 hr, 30 min".
    func interval(_ s: TimeInterval) -> String {
        guard s.isFinite, s >= 0 else { return Self.placeholder }
        return Duration.seconds(s.rounded())
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2).locale(locale))
    }

    /// One line describing an auto-stop rule, e.g.
    /// "Current below 100 mA for 1 min · Max 2 hr"; "Off" for an empty rule.
    func describe(_ rule: AutoStopRule?) -> String {
        guard let rule else { return "Off" }
        var parts: [String] = []
        if let a = rule.belowCurrentA {
            parts.append("Current below \(format(a, .current).text) for \(interval(rule.forSeconds))")
        }
        if let d = rule.maxDuration { parts.append("Max \(interval(d))") }
        if let e = rule.maxEnergyWh { parts.append("Max \(energy(e).text)") }
        return parts.isEmpty ? "Off" : parts.joined(separator: " · ")
    }

    /// Storage sizes ("42 MB"), locale-aware.
    func byteCount(_ bytes: Int) -> String {
        Int64(bytes).formatted(.byteCount(style: .file, spellsOutZero: false).locale(locale))
    }

    // MARK: VoiceOver

    /// VoiceOver text, e.g. "9.01 volts" or "12.3 milliamps".
    func spoken(_ v: Double?, _ m: Metric) -> String {
        guard let v, v.isFinite else { return "no reading" }
        let range = autoRange ? UnitRange.range(for: v, metric: m, previous: nil) : .base
        let f = format(v, m, range: range)
        return f.number + " " + range.spokenPrefix + m.spokenName
    }

    /// "500 milliwatt-hours" / "12.3 watt-hours".
    func spokenEnergy(_ wh: Double) -> String {
        guard wh.isFinite else { return "no reading" }
        let f = energy(wh)
        return f.number + " " + (f.unit == "mWh" ? "milliwatt-hours" : "watt-hours")
    }

    /// "250 milliamp-hours" / "2.50 amp-hours".
    func spokenCapacity(_ ah: Double) -> String {
        guard ah.isFinite else { return "no reading" }
        let f = capacity(ah)
        return f.number + " " + (f.unit == "mAh" ? "milliamp-hours" : "amp-hours")
    }

    // MARK: Plain numbers

    /// Fixed number of fraction digits (used by the legacy `Fmt` shim).
    func number(_ v: Double?, fractionDigits: Int) -> String {
        guard let v, v.isFinite else { return Self.placeholder }
        return v.formatted(.number.precision(.fractionLength(fractionDigits)).grouping(.never).locale(locale))
    }

    private func significant(_ v: Double) -> String {
        // Fold negative zero into zero so "-0.00 mA" never appears.
        let value = v == 0 ? 0 : v
        let magnitude = abs(value)
        let integerDigits = magnitude >= 1 ? Int(log10(magnitude)) + 1 : 0
        let digits = max(1, precision, integerDigits)
        return value.formatted(.number.precision(.significantDigits(digits)).grouping(.never).locale(locale))
    }
}
