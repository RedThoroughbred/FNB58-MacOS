import Foundation

/// A number and its unit, kept separate so views can style them differently.
struct FormattedValue: Equatable {
    let number: String
    let unit: String
    var text: String { number + " " + unit }
}

/// Which SI prefix a value is shown with. The decision is pure; callers that
/// want hysteresis keep the previous range in `@State` and pass it back.
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
}

/// Locale-aware number formatting for every readout. A value type: create one
/// from `Preferences` and pass it around; never `String(format:)` in views.
struct MetricFormatter {
    var locale: Locale = .autoupdatingCurrent
    /// Significant digits shown.
    var precision: Int = 3
    var autoRange = true

    static let placeholder = "--"

    // MARK: Metrics

    func format(_ v: Double?, _ m: Metric) -> FormattedValue {
        guard let v, v.isFinite else { return FormattedValue(number: Self.placeholder, unit: m.symbol) }
        let range = autoRange ? UnitRange.range(for: v, metric: m, previous: nil) : .base
        return format(v, m, range: range)
    }

    /// Formats with an explicit range (from `UnitRange.range(for:metric:previous:)`).
    func format(_ v: Double, _ m: Metric, range: UnitRange) -> FormattedValue {
        switch range {
        case .base: return FormattedValue(number: significant(v), unit: m.symbol)
        case .milli: return FormattedValue(number: significant(v * 1000), unit: "m" + m.symbol)
        }
    }

    func energy(_ wh: Double) -> FormattedValue {
        guard wh.isFinite else { return FormattedValue(number: Self.placeholder, unit: "Wh") }
        if autoRange, abs(wh) < 1 { return FormattedValue(number: significant(wh * 1000), unit: "mWh") }
        return FormattedValue(number: significant(wh), unit: "Wh")
    }

    func capacity(_ ah: Double) -> FormattedValue {
        guard ah.isFinite else { return FormattedValue(number: Self.placeholder, unit: "Ah") }
        if autoRange, abs(ah) < 1 { return FormattedValue(number: significant(ah * 1000), unit: "mAh") }
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

    /// VoiceOver text, e.g. "9.01 volts" or "500 milliamps".
    func spoken(_ v: Double?, _ m: Metric) -> String {
        guard let v, v.isFinite else { return "no reading" }
        let range = autoRange ? UnitRange.range(for: v, metric: m, previous: nil) : .base
        let f = format(v, m, range: range)
        return f.number + " " + (range == .milli ? "milli" + m.spokenName : m.spokenName)
    }

    // MARK: Plain numbers

    /// Fixed number of fraction digits (used by the legacy `Fmt` shim).
    func number(_ v: Double?, fractionDigits: Int) -> String {
        guard let v, v.isFinite else { return Self.placeholder }
        return v.formatted(.number.precision(.fractionLength(fractionDigits)).grouping(.never).locale(locale))
    }

    private func significant(_ v: Double) -> String {
        v.formatted(.number.precision(.significantDigits(max(1, precision))).grouping(.never).locale(locale))
    }
}
