import SwiftUI

/// One headline number on a card: uppercase label, rounded monospaced value,
/// unit line with an optional secondary caption ("active", "estimate").
/// Three across in the session detail header.
struct StatTile: View {
    let label: String
    let value: String
    let unit: String
    var caption: String? = nil
    var tint: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .textCase(.uppercase)
                .tracking(0.8)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title2, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundStyle(tint ?? Color.primary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(unit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let caption {
                    Text("· " + caption)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(caption.map { "\(value) \(unit), \($0)" } ?? "\(value) \(unit)")
    }
}

/// A label/value pair for compact grids (highlights, range card, preview card).
struct SessionStatItem: View {
    let label: String
    let value: String
    var caption: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .textCase(.uppercase)
                .tracking(0.8)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(caption.map { "\(value), \($0)" } ?? value)
    }
}

// MARK: - Formatting helpers used by the report surfaces

extension MetricFormatter {
    /// Capacity in the unit chosen in Settings (the auto-ranging `capacity(_:)`
    /// is for places that have no unit preference).
    func capacity(_ ah: Double, unit: Preferences.CapacityUnit) -> FormattedValue {
        guard ah.isFinite else { return FormattedValue(number: Self.placeholder, unit: unit.rawValue) }
        switch unit {
        case .mAh: return FormattedValue(number: format(ah * 1000, .current, range: .base).number, unit: "mAh")
        case .Ah: return FormattedValue(number: format(ah, .current, range: .base).number, unit: "Ah")
        }
    }

    /// "4.98–5.12 V": both ends in the unit chosen for the larger value.
    func span(_ lo: Double?, _ hi: Double?, _ m: Metric) -> String {
        guard let lo, let hi, lo.isFinite, hi.isFinite else { return Self.placeholder + " " + m.symbol }
        let range = autoRange ? UnitRange.range(for: max(abs(lo), abs(hi)), metric: m, previous: nil) : .base
        let low = format(lo, m, range: range)
        let high = format(hi, m, range: range)
        return "\(low.number)–\(high.number) \(high.unit)"
    }

    /// Samples per second with one decimal, or the placeholder.
    func rate(samples: Int, seconds: TimeInterval) -> String {
        guard seconds > 0, samples > 0 else { return Self.placeholder }
        return (Double(samples) / seconds).formatted(.number.precision(.fractionLength(1)).locale(locale))
    }
}
