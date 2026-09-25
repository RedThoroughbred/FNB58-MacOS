import SwiftUI

/// The always-on odometer: energy since the last reset, with capacity and
/// active time as secondaries. Reads `meter.trips[0]` (published at 5 Hz).
struct TripCard: View {
    /// From the parent's 1 Hz staleness check: the stream stopped for longer
    /// than the gap guard, so integration is paused.
    let isPaused: Bool

    @Environment(MeterManager.self) private var meter
    @Environment(Preferences.self) private var prefs
    @State private var confirmReset = false

    /// Below this the trip is cleared without asking.
    static let confirmAboveWh = 0.01

    var body: some View {
        let trip = meter.trips.first ?? TripMeter(label: "Trip")
        let stats = trip.stats
        let formatter = prefs.formatter
        let energy = formatter.energy(stats.energyWh)
        let capacity = LiveFormat.capacity(stats.capacityAh, unit: prefs.capacityUnit, formatter: formatter)
        let elapsed = formatter.duration(stats.durationS)
        let paused = isPaused || !meter.state.isConnected
        let demoExcluded = meter.isDemo && prefs.excludeDemoFromTrips

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                LiveLabel("Trip")
                Text("since \(trip.startedAt, format: .dateTime.hour().minute())")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                if paused {
                    Image(systemName: "pause.circle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Paused")
                }
                Spacer(minLength: 8)
                Button("Reset", systemImage: "arrow.counterclockwise") { requestReset(stats) }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .disabled(stats.samples == 0 && stats.energyWh == 0)
            }
            HStack(alignment: .center, spacing: 12) {
                HStack(alignment: .lastTextBaseline, spacing: 4) {
                    Text(energy.number)
                        .font(.system(.title, design: .rounded).weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .rollingNumber(stats.energyWh)
                    Text(energy.unit)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(capacity.text).rollingNumber(stats.capacityAh)
                        Text("·")
                        Text(elapsed).monospacedDigit()
                        Text("active").foregroundStyle(.tertiary)
                    }
                    .font(.subheadline)
                    Text(peakLine(stats, formatter: formatter))
                        .font(.caption2.monospacedDigit())
                }
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }
            if demoExcluded {
                Text("Demo readings are not counted")
                    .font(.caption2)
                    .foregroundStyle(.purple)
            }
        }
        .liveCard()
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 20, style: .continuous))
        .contextMenu {
            Button("Reset Trip", systemImage: "arrow.counterclockwise") { requestReset(stats) }
            Button("Copy Values", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = "\(energy.text) · \(capacity.text) · \(elapsed)"
            }
        }
        .confirmationDialog("Reset the trip counter?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset Trip", role: .destructive) { meter.resetTrip(0) }
            Button("Keep Counting", role: .cancel) {}
        } message: {
            Text("\(energy.text) and \(capacity.text) since \(trip.startedAt.formatted(date: .omitted, time: .shortened)) will be cleared.")
        }
        .liveFeedback(.impact(weight: .light), trigger: meter.tripResetCount)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Trip counter\(paused ? ", paused" : "")")
        .accessibilityValue("\(energy.text), \(capacity.text), \(elapsed) active")
    }

    private func requestReset(_ stats: SessionStats) {
        if stats.energyWh > Self.confirmAboveWh {
            confirmReset = true
        } else {
            meter.resetTrip(0)
        }
    }

    private func peakLine(_ stats: SessionStats, formatter: MetricFormatter) -> String {
        guard stats.samples > 0 else { return "No samples yet" }
        let peak = formatter.format(stats.maxPower, .power).text
        let avg = formatter.format(stats.avgPower, .power).text
        return "Peak \(peak) · avg \(avg)"
    }
}
