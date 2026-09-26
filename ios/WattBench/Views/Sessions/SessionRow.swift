import SwiftUI

/// One session in the list: name, start time · active duration · energy,
/// tag capsules, state badges and a trailing sparkline.
struct SessionRow: View {
    @Environment(Preferences.self) private var prefs
    let summary: SessionSummary

    var body: some View {
        let f = prefs.formatter
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(summary.name)
                        .font(.headline)
                        .lineLimit(1)
                    if summary.state == .recovered { SessionRecoveredBadge() }
                    if summary.isDemo { SessionDemoBadge() }
                }
                HStack(spacing: 5) {
                    Text(summary.startTime, format: .dateTime.hour().minute())
                    Text("·").foregroundStyle(.tertiary)
                    Text(f.duration(summary.stats.durationS))
                    Text("·").foregroundStyle(.tertiary)
                    Text(f.energy(summary.stats.energyWh).text)
                }
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                if !summary.tags.isEmpty {
                    SessionTagCapsules(tags: summary.tags)
                }
            }
            Spacer(minLength: 8)
            SessionSparkline(values: summary.sparkline)
                .frame(width: 72, height: 32)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// Larger card shown as the context-menu preview of a row. A context-menu
/// preview is rendered outside the row's view hierarchy, so it takes the
/// formatter as a value instead of reading `Preferences` from the
/// environment (which is missing there and would trap).
struct SessionPreviewCard: View {
    let summary: SessionSummary
    let formatter: MetricFormatter

    var body: some View {
        let f = formatter
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(summary.name).font(.headline).lineLimit(1)
                    if summary.state == .recovered { SessionRecoveredBadge() }
                    if summary.isDemo { SessionDemoBadge() }
                }
                Text(summary.startTime, format: .dateTime.weekday(.abbreviated).month().day().hour().minute())
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            SessionSparkline(values: summary.sparkline, lineWidth: 2, fill: true)
                .frame(height: 96)
            HStack(alignment: .top, spacing: 12) {
                SessionStatItem(label: "Energy", value: f.energy(summary.stats.energyWh).text)
                SessionStatItem(label: "Duration", value: f.duration(summary.stats.durationS), caption: "active")
                SessionStatItem(label: "Peak", value: f.format(summary.stats.maxPower, .power).text)
            }
            if !summary.tags.isEmpty {
                SessionTagCapsules(tags: summary.tags)
            }
        }
        .padding(16)
        .frame(width: 320)
        .background(Color(.secondarySystemGroupedBackground))
    }
}

/// Wrapping row of tag capsules.
struct SessionTagCapsules: View {
    let tags: [String]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(tags, id: \.self) { SessionTagCapsule(text: $0) }
            }
        }
        .scrollClipDisabled()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tags: " + tags.joined(separator: ", "))
    }
}

struct SessionTagCapsule: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(.secondary)
            .background(Color(.tertiarySystemFill), in: Capsule())
    }
}

/// Purple is reserved for demo data so App Review can never mistake it.
struct SessionDemoBadge: View {
    var body: some View {
        Text("Demo")
            .font(.caption2.weight(.semibold))
            .textCase(.uppercase)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(.purple)
            .background(Color.purple.opacity(0.12), in: Capsule())
            .accessibilityLabel("Demo data")
    }
}

/// Passive marker for a recording recovered after a crash or force quit.
struct SessionRecoveredBadge: View {
    var body: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
            .accessibilityLabel("Recovered recording")
    }
}
