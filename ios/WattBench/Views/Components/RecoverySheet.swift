import SwiftUI

/// Keep / Discard prompt for a recording that was interrupted by a crash, a
/// force-quit or a system relaunch, modelled on Voice Memos' interrupted
/// recording prompt. `WattBenchApp` presents it once from
/// `SessionStore.interrupted`; `init(summary:)` is frozen.
struct RecoverySheet: View {
    let summary: SessionSummary

    @Environment(SessionStore.self) private var store
    @Environment(Preferences.self) private var prefs
    @State private var confirmDiscard = false
    @State private var keepError: String?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 12) {
                    header
                    statGrid
                    if let keepError {
                        Label(keepError, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    Text("WattBench closed while recording. The samples written so far were kept.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 8)
            }
            buttons
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
        }
        .background(Color(.systemGroupedBackground))
        .presentationDetents([.medium])
        .presentationDragIndicator(.hidden)
        .interactiveDismissDisabled()
        .confirmationDialog("Discard this recording?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard Recording", role: .destructive) { store.discardInterrupted() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The \(summary.sampleCount, format: .number) samples recorded before the interruption will be deleted.")
        }
        .saveFeedback(store)
    }

    // MARK: Sections

    private var header: some View {
        VStack(spacing: 6) {
            Image(systemName: "waveform.badge.exclamationmark")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Recording was interrupted")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(summary.name)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private var statGrid: some View {
        let f = prefs.formatter
        let energy = f.energy(summary.stats.energyWh)
        let capacity = f.capacity(summary.stats.capacityAh)
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            tile("Energy", energy.number, energy.unit, spoken: energy.text)
            tile("Capacity", capacity.number, capacity.unit, spoken: capacity.text)
            tile("Duration", f.duration(summary.stats.durationS), "active",
                 spoken: "\(f.duration(summary.stats.durationS)) active")
            tile("Samples", summary.sampleCount.formatted(.number), summary.sampleCount == 1 ? "sample" : "samples",
                 spoken: "\(summary.sampleCount.formatted(.number)) samples")
        }
    }

    private func tile(_ label: String, _ value: String, _ unit: String, spoken: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .textCase(.uppercase)
                .tracking(0.8)
                .foregroundStyle(.secondary)
            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(.title2, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text(unit)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(spoken)
    }

    private var buttons: some View {
        VStack(spacing: 8) {
            Button(action: keep) {
                Text("Keep Recording")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 24)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Button(role: .destructive) {
                confirmDiscard = true
            } label: {
                Text("Discard")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 24)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }

    private func keep() {
        do {
            try store.keepInterrupted()
        } catch {
            keepError = error.localizedDescription
        }
    }
}

#Preview {
    let store = SessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("preview-sessions"))
    var stats = SessionStats()
    let t0 = Date().addingTimeInterval(-3600)
    for k in 0..<600 {
        stats.add(Reading(timestamp: t0.addingTimeInterval(Double(k) * 0.1), voltage: 9, current: 1.5, power: 13.5))
    }
    let summary = SessionSummary(id: UUID(), name: "Recovered: iPhone charge", startTime: t0, endTime: t0.addingTimeInterval(60),
                                 deviceName: "FNB58", stats: stats, sampleCount: 600, markers: [], tags: [], notes: nil,
                                 autoStopReason: nil, isDemo: false, state: .recovered, sparkline: [])
    return Color.clear.sheet(isPresented: .constant(true)) {
        RecoverySheet(summary: summary)
            .environment(store)
            .environment(Preferences.shared)
    }
}
