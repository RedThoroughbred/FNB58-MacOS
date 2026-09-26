import SwiftUI

/// One of the two non-hero metrics: label, value, unit and a peak caption
/// from `Extremes`. Tapping promotes it to the hero slot.
struct SecondaryTile: View {
    let metric: Metric
    let formatted: FormattedValue
    let spoken: String
    let caption: String?
    let isStale: Bool
    /// Raw value driving the rolling-digit transition.
    let value: Double
    let onPromote: () -> Void
    let onResetPeaks: () -> Void
    let onCopy: () -> Void

    @Environment(MeterManager.self) private var meter

    var body: some View {
        Button(action: onPromote) {
            VStack(alignment: .leading, spacing: 4) {
                LiveLabel(metric.title)
                HStack(alignment: .lastTextBaseline, spacing: 4) {
                    Text(formatted.number)
                        .font(.system(.title2, design: .rounded).weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .foregroundStyle(isStale ? AnyShapeStyle(.tertiary) : AnyShapeStyle(metric.color))
                        .rollingNumber(value)
                    Text(formatted.unit)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(caption ?? "PEAK —")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .liveCard(padding: 12)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Reset Peaks", systemImage: "arrow.counterclockwise", action: onResetPeaks)
            Button("Copy Value", systemImage: "doc.on.doc", action: onCopy)
            Divider()
            Text("Peak of 100 ms samples")
        }
        .liveFeedback(.impact(weight: .light), trigger: meter.extremes.since)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(metric.title)
        .accessibilityValue(isStale ? "no recent data" : spoken)
        .accessibilityHint("Double-tap to make this the large readout")
        .accessibilityAddTraits(.updatesFrequently)
    }
}
