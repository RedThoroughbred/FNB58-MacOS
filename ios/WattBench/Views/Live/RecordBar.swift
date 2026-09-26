import SwiftUI

/// The Voice-Memos-style bar pinned to the bottom of the Live tab. Idle: one
/// Record button opening the setup sheet. Recording: elapsed time, energy,
/// Mark and Stop. Every stop goes through `MeterManager.stopRecording`; the
/// app's hook saves and `LiveView` shows the Saved toast (keyed on
/// `SessionStore.saveCount`) above this bar.
struct RecordBar: View {
    @Environment(MeterManager.self) private var meter
    @Environment(SessionStore.self) private var store
    @Environment(Preferences.self) private var prefs
    @Environment(AppRouter.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var showSetup = false
    @State private var confirmEmptyStop = false
    @State private var confirmDiscard = false
    @State private var showCustomMarker = false
    @State private var customMarker = ""
    @State private var markCount = 0

    static let quickMarkers = ["Plugged in", "Unplugged", "Cable swapped", "Load changed"]

    var body: some View {
        let recording = meter.recording
        let stats = meter.display.recordingStats
        let formatter = prefs.formatter

        HStack(spacing: 12) {
            if let recording {
                Image(systemName: "record.circle")
                    .font(.title3)
                    .foregroundStyle(.red)
                    .symbolEffect(.pulse, isActive: !reduceMotion)
                    .accessibilityHidden(true)
                Text(timerInterval: recording.startTime...Date.distantFuture, countsDown: false)
                    .font(.title3.monospacedDigit())
                    .lineLimit(1)
                    .accessibilityLabel("Recording time")
                if let rule = recording.autoStop {
                    Image(systemName: "autostartstop")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Stops automatically: \(LiveFormat.ruleSummary(rule, formatter: formatter))")
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(formatter.energy(stats?.energyWh ?? 0).text)
                        .font(.callout.monospacedDigit())
                        .rollingNumber(stats?.energyWh ?? 0)
                    Text(LiveFormat.capacity(stats?.capacityAh ?? 0, unit: prefs.capacityUnit, formatter: formatter).text)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .accessibilityElement(children: .combine)
                markButton
            } else {
                Spacer(minLength: 0)
            }

            primaryButton(recording)

            if recording != nil {
                overflowMenu(recording?.autoStop, formatter: formatter)
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: recording?.id)
        // Home Screen quick action "Start Recording": open the setup sheet once
        // a meter (or demo) is connected and nothing is recording yet.
        .onChange(of: router.pendingQuickAction, initial: true) { _, action in
            guard action == .startRecording, meter.state.isConnected, meter.recording == nil else { return }
            if router.takeQuickAction(.startRecording) { showSetup = true }
        }
        .onChange(of: meter.state.isConnected) { _, connected in
            guard connected, meter.recording == nil, router.takeQuickAction(.startRecording) else { return }
            showSetup = true
        }
        .sheet(isPresented: $showSetup) {
            RecordingSetupSheet(deviceName: meter.state.label,
                                isDemo: meter.isDemo,
                                defaultRule: prefs.defaultAutoStop,
                                recentTags: RecordingSetupModel.recentTags(from: store.summaries)) { model in
                start(model)
            }
        }
        .confirmationDialog("No samples were recorded", isPresented: $confirmEmptyStop, titleVisibility: .visible) {
            Button("Discard Recording", role: .destructive) { meter.stopRecording(discard: true) }
            Button("Keep Recording", role: .cancel) {}
        } message: {
            Text("The meter has not sent any readings since the recording started.")
        }
        .confirmationDialog("Discard this recording?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard Recording", role: .destructive) { meter.stopRecording(discard: true) }
            Button("Keep Recording", role: .cancel) {}
        } message: {
            Text("Its samples and markers are thrown away and nothing is saved.")
        }
        .alert("Marker label", isPresented: $showCustomMarker) {
            TextField("e.g. Screen on", text: $customMarker)
            Button("Add") { addMarker(customMarker) }
            Button("Cancel", role: .cancel) {}
        }
        .onChange(of: recording?.id) { _, id in
            if id != nil { markCount = 0 }
        }
        .recordingFeedback(meter)
        .saveFeedback(store)
        .liveFeedback(.impact(weight: .light), trigger: markCount)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(recording == nil ? "Record bar" : "Recording bar")
    }

    // MARK: Buttons

    /// Record (idle) or Stop (recording); one view so the glyph swap animates.
    private func primaryButton(_ recording: SessionRecorder?) -> some View {
        let isRecording = recording != nil
        return Button {
            if let recording {
                stopTapped(recording)
            } else {
                showSetup = true
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isRecording ? "stop.fill" : "record.circle.fill")
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                if !isRecording {
                    Text("Record")
                }
            }
            .font(.headline)
            .frame(minWidth: isRecording ? 0 : 160)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(isRecording ? .circle : .capsule)
        .controlSize(isRecording ? .regular : .large)
        .tint(.red)
        .disabled(!isRecording && !meter.state.isConnected)
        .accessibilityLabel(isRecording ? "Stop recording" : "Record")
    }

    private var markButton: some View {
        Menu {
            ForEach(Self.quickMarkers, id: \.self) { label in
                Button(label) { addMarker(label) }
            }
            Divider()
            Button("Custom…", systemImage: "pencil") {
                customMarker = ""
                showCustomMarker = true
            }
        } label: {
            Image(systemName: "bookmark")
                .font(.body.weight(.semibold))
        } primaryAction: {
            addMarker("Mark \(markCount + 1)")
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .accessibilityLabel("Add marker")
        .accessibilityHint("Double-tap to add a numbered marker, hold for labels")
    }

    private func overflowMenu(_ rule: AutoStopRule?, formatter: MetricFormatter) -> some View {
        Menu {
            if let rule {
                Text("Stops automatically: \(LiveFormat.ruleSummary(rule, formatter: formatter))")
            }
            Button("Discard Recording…", systemImage: "trash", role: .destructive) { confirmDiscard = true }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.body)
                .frame(width: 32, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("More")
    }

    // MARK: Actions

    private func start(_ model: RecordingSetupModel) {
        meter.startRecording(name: model.trimmedName, tags: model.selectedTags, notes: model.noteOrNil,
                             autoStop: model.rule)
    }

    private func stopTapped(_ recording: SessionRecorder) {
        if recording.stats.samples == 0 {
            confirmEmptyStop = true
        } else {
            meter.stopRecording()
        }
    }

    private func addMarker(_ label: String) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, meter.recording != nil else { return }
        markCount += 1
        meter.addMarker(label: trimmed)
    }
}
