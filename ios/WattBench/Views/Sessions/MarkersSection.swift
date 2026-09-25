import SwiftUI

/// The Markers section of the session report: every marker with its elapsed
/// time and the readings at that instant, plus the energy integrated between
/// consecutive markers. Tapping a row reveals it on the chart; user markers
/// can be swiped away once the session is loaded.
struct MarkersSection: View {
    let markers: [Marker]
    let readings: [Reading]
    let sessionStart: Date
    /// False until the full session is loaded (deleting rewrites the session).
    var canDelete = true
    let onSelect: (Marker) -> Void
    let onDelete: (Marker) -> Void

    @Environment(Preferences.self) private var prefs

    private var sorted: [Marker] { markers.sorted { $0.timestamp < $1.timestamp } }

    /// Span statistics keyed by the marker that opens each span.
    private var spans: [UUID: MarkerSpan] {
        guard !readings.isEmpty else { return [:] }
        return Dictionary(RangeStats.spans(in: readings, between: markers).map { ($0.from.id, $0) },
                          uniquingKeysWith: { first, _ in first })
    }

    var body: some View {
        let f = prefs.formatter
        let spans = spans
        Section {
            if sorted.isEmpty {
                Text("No markers. Tap Mark while recording to flag a moment.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(sorted) { marker in
                    Button { onSelect(marker) } label: {
                        row(marker, span: spans[marker.id], formatter: f)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .deleteDisabled(!(canDelete && marker.kind == .user))
                }
                .onDelete { offsets in
                    let targets = offsets.map { sorted[$0] }
                    targets.forEach(onDelete)
                }
            }
        } header: {
            Text("Markers")
        } footer: {
            if sorted.count >= 2 {
                Text("Energy is integrated between consecutive markers.")
            }
        }
    }

    private func row(_ marker: Marker, span: MarkerSpan?, formatter f: MetricFormatter) -> some View {
        let tint = SessionChart.tint(for: marker)
        let elapsed = f.duration(marker.timestamp.timeIntervalSince(sessionStart))
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: Self.symbol(for: marker))
                .font(.subheadline)
                .foregroundStyle(tint)
                .frame(width: 22, alignment: .center)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(marker.label)
                    .font(.body)
                    .lineLimit(2)
                Text("at \(elapsed)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if let span {
                    Text("\(f.energy(span.stats.energyWh).text) over \(f.duration(span.stats.durationS)) to next")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            if let r = RangeStats.nearestIndex(in: readings, to: marker.timestamp).map({ readings[$0] }) {
                VStack(alignment: .trailing, spacing: 2) {
                    ForEach(Metric.allCases) { m in
                        Text(f.format(m.value(r), m).text)
                    }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel(Metric.allCases.map { f.spoken($0.value(r), $0) }.joined(separator: ", "))
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows this moment on the chart")
    }

    static func symbol(for marker: Marker) -> String {
        switch marker.kind {
        case .user: return "flag.fill"
        case .gap: return "bolt.slash"
        case .autoStop: return "stop.circle.fill"
        case .alert: return "bell.badge.fill"
        }
    }
}
