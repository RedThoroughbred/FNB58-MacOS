import SwiftUI

/// Floating card with the statistics of the chart's range selection. Slides
/// in from the bottom while a range is selected; the close button clears the
/// selection.
struct RangeStatsCard: View {
    let range: ClosedRange<Date>
    let stats: SessionStats
    let sessionStart: Date
    let sessionEnergyWh: Double
    /// False until the session is fully loaded (markers are saved with it).
    var canSaveMarkers = true
    let onSaveMarkers: () -> Void
    let onClose: () -> Void

    @Environment(Preferences.self) private var prefs

    private static let columns = [GridItem(.flexible(), alignment: .topLeading),
                                  GridItem(.flexible(), alignment: .topLeading),
                                  GridItem(.flexible(), alignment: .topLeading)]

    var body: some View {
        let f = prefs.formatter
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Selection")
                        .font(.caption2.weight(.semibold))
                        .textCase(.uppercase)
                        .tracking(0.8)
                        .foregroundStyle(.secondary)
                    Text("\(f.duration(range.lowerBound.timeIntervalSince(sessionStart))) – \(f.duration(range.upperBound.timeIntervalSince(sessionStart)))")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear selection")
            }

            let energy = f.energy(stats.energyWh)
            let capacity = f.capacity(stats.capacityAh, unit: prefs.capacityUnit)
            LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 12) {
                SessionStatItem(label: "Duration", value: f.duration(stats.durationS), caption: "active")
                SessionStatItem(label: "Energy", value: energy.text, caption: fractionCaption)
                SessionStatItem(label: "Capacity", value: capacity.text)
                SessionStatItem(label: "Avg V", value: f.format(stats.avgVoltage, .voltage).text)
                SessionStatItem(label: "Avg A", value: f.format(stats.avgCurrent, .current).text)
                SessionStatItem(label: "Avg W", value: f.format(stats.avgPower, .power).text, caption: "time-weighted")
                SessionStatItem(label: "V range", value: f.span(stats.minVoltage, stats.maxVoltage, .voltage))
                SessionStatItem(label: "A range", value: f.span(stats.minCurrent, stats.maxCurrent, .current))
                SessionStatItem(label: "Peak W", value: f.format(stats.maxPower, .power).text)
            }

            Button(action: onSaveMarkers) {
                Label("Save as Marker Pair", systemImage: "flag.2.crossed")
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .disabled(!canSaveMarkers)
        }
        .padding(16)
        .floatingChrome(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Range selection")
    }

    /// "12% of session" when the session integrated any energy.
    private var fractionCaption: String? {
        guard sessionEnergyWh > 0, stats.energyWh.isFinite else { return nil }
        let fraction = min(max(stats.energyWh / sessionEnergyWh, 0), 1)
        let percent = fraction.formatted(.percent.precision(.fractionLength(0)).locale(prefs.formatter.locale))
        return "\(percent) of session"
    }
}
