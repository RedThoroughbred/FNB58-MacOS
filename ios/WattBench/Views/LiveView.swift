import SwiftUI

/// The instrument face: status pill and gear in the toolbar, hero numeral,
/// trip card and one chart in the body, the record bar pinned below. Nothing
/// here reads the 10 Hz `latest`; each card reads its own 5 Hz publication.
struct LiveView: View {
    @Environment(MeterManager.self) private var meter
    @Environment(SessionStore.self) private var store
    @Environment(Preferences.self) private var prefs
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var showConnect = false
    @State private var showSettings = false
    /// Refreshed once per second while the scene is active; changes only when
    /// the stream stops or resumes, so the face is not re-rendered by it.
    @State private var staleness = Staleness.fresh
    /// "Saved · 3.21 Wh" with Undo, shown for five seconds after a save. It
    /// floats above the record bar as a sibling of the navigation stack:
    /// the bottom safe-area inset host clips content that grows after its
    /// first layout, and a ScrollView's own frame extends under that inset,
    /// so neither the bar nor an overlay of the face can host it.
    @State private var toast: ToastContent?
    @State private var toastTask: Task<Void, Never>?
    /// Measured height of the record bar, so the toast clears it.
    @State private var barHeight: CGFloat = 0

    static let toastSeconds: TimeInterval = 5

    var body: some View {
        ZStack(alignment: .bottom) {
            face
            if let toast {
                SavedToast(content: toast, onUndo: { undo(toast) }, onDismiss: dismissToast)
                    .padding(.horizontal, 16)
                    .padding(.bottom, barHeight + 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: toast)
    }

    private var face: some View {
        NavigationStack {
            Group {
                if HeroState.showsFace(meter.state) {
                    ScrollView {
                        VStack(spacing: 12) {
                            HeroReadout(isStale: staleness != .fresh)
                            TripCard(isPaused: staleness == .paused)
                            MetricChartCard()
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                    }
                } else {
                    LiveEmptyState(state: meter.state,
                                   onConnect: { showConnect = true },
                                   onDemo: { meter.startDemo() })
                }
            }
            .background(Color(.systemGroupedBackground))
            .onChange(of: store.saveCount) { _, _ in showSavedToast() }
            .onChange(of: store.saveError) { _, error in
                guard let error else { return }
                show(ToastContent(title: "Could not save · \(error)", role: .failure, undoSessionID: nil))
            }
            .navigationTitle("WattBench")
            .toolbarTitleMenu {
                Button("Connect…", systemImage: "antenna.radiowaves.left.and.right") { showConnect = true }
                Button("Reconnect to Last Meter", systemImage: "arrow.clockwise") { meter.reconnectLastDevice() }
                    .disabled(!meter.hasLastDevice)
                if meter.state.isConnected {
                    Button("Disconnect", systemImage: "xmark.circle", role: .destructive) { meter.disconnect() }
                }
                Button("Try Demo Data", systemImage: "play.circle") { meter.startDemo() }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    StatusPill(isStale: staleness != .fresh) { showConnect = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gear") { showSettings = true }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    AlertBanner()
                    if meter.isDemo { DemoBanner() }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                RecordBar()
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { barHeight = $0 }
            }
            .sheet(isPresented: $showConnect) {
                DeviceListView()
                    .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .connectionFeedback(meter)
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                while !Task.isCancelled {
                    let next = Staleness(latest: meter.display.latest?.timestamp, now: Date())
                    if next != staleness { staleness = next }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
    }

    // MARK: Saved toast

    private func showSavedToast() {
        guard let saved = store.lastSaved else { return }
        let formatter = prefs.formatter
        let title: String
        if let reason = saved.autoStopReason.flatMap(AutoStopRule.Reason.init(rawValue:)) {
            // The setup sheet stores the armed rule as the default at every start.
            let detail = LiveFormat.autoStopDetail(reason, rule: prefs.defaultAutoStop, formatter: formatter)
            title = "Stopped automatically · \(detail)"
        } else {
            title = "Saved · \(formatter.energy(saved.stats.energyWh).text)"
        }
        show(ToastContent(title: title, role: .success, undoSessionID: saved.id))
    }

    private func show(_ content: ToastContent) {
        toast = content
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(Self.toastSeconds))
            guard !Task.isCancelled, toast?.id == content.id else { return }
            toast = nil
        }
    }

    private func undo(_ content: ToastContent) {
        if let id = content.undoSessionID {
            store.delete(id: id)
        }
        dismissToast()
    }

    private func dismissToast() {
        toastTask?.cancel()
        toast = nil
    }
}

// MARK: - Shared face styling

/// "VOLTAGE" style caption used above every readout.
struct LiveLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .textCase(.uppercase)
            .tracking(0.8)
            .foregroundStyle(.secondary)
    }
}

/// Card chrome: secondary grouped background, 20 pt continuous corners.
struct LiveCard: ViewModifier {
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 20, style: .continuous))
    }
}

/// Rolling digits for a number that changes, disabled under Reduce Motion.
struct RollingNumber: ViewModifier {
    let value: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .monospacedDigit()
            .contentTransition(reduceMotion ? .identity : .numericText(value: value))
            .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: value)
    }
}

/// Haptics for interactions the shared `FeedbackModifiers` do not cover
/// (metric switch, trip reset, markers), gated on Reduce Motion and the
/// haptics preference.
struct LiveFeedback<Trigger: Equatable>: ViewModifier {
    let feedback: SensoryFeedback
    let trigger: Trigger
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(Preferences.self) private var prefs

    func body(content: Content) -> some View {
        content.sensoryFeedback(feedback, trigger: trigger) { _, _ in
            !reduceMotion && prefs.hapticsEnabled
        }
    }
}

extension View {
    func liveCard(padding: CGFloat = 16) -> some View {
        modifier(LiveCard(padding: padding))
    }

    func rollingNumber(_ value: Double) -> some View {
        modifier(RollingNumber(value: value))
    }

    func liveFeedback<T: Equatable>(_ feedback: SensoryFeedback, trigger: T) -> some View {
        modifier(LiveFeedback(feedback: feedback, trigger: trigger))
    }
}

// MARK: - Shared formatting

/// Formatting shared by the Live face that `MetricFormatter` does not cover
/// directly. Every number still comes from the formatter.
enum LiveFormat {
    /// Capacity in the preferred unit ("870 mAh" or "0.870 Ah").
    static func capacity(_ ah: Double, unit: Preferences.CapacityUnit, formatter: MetricFormatter) -> FormattedValue {
        guard ah.isFinite else { return formatter.capacity(ah) }
        switch unit {
        case .mAh: return FormattedValue(number: formatter.format(ah, .current, range: .milli).number, unit: "mAh")
        case .Ah: return FormattedValue(number: formatter.format(ah, .current, range: .base).number, unit: "Ah")
        }
    }

    /// "30 s", "2 min", "1 h" for the auto-stop pickers and toasts.
    static func durationLabel(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "\(Int(seconds.rounded())) s" }
        if seconds < 3600 { return "\(Int((seconds / 60).rounded())) min" }
        let hours = seconds / 3600
        return hours == hours.rounded() ? "\(Int(hours)) h" : "\(hours.formatted(.number.precision(.fractionLength(1)))) h"
    }

    /// One line describing an auto-stop rule.
    static func ruleSummary(_ rule: AutoStopRule, formatter: MetricFormatter) -> String {
        var parts: [String] = []
        if let below = rule.belowCurrentA {
            parts.append("current below \(formatter.format(below, .current).text) for \(durationLabel(rule.forSeconds))")
        }
        if let duration = rule.maxDuration { parts.append("after \(durationLabel(duration))") }
        if let energy = rule.maxEnergyWh { parts.append("at \(formatter.energy(energy).text)") }
        return parts.isEmpty ? "never" : parts.joined(separator: ", ")
    }

    /// The detail after "Stopped automatically ·".
    static func autoStopDetail(_ reason: AutoStopRule.Reason, rule: AutoStopRule?, formatter: MetricFormatter) -> String {
        switch reason {
        case .currentBelowThreshold:
            if let below = rule?.belowCurrentA { return "current below \(formatter.format(below, .current).text)" }
        case .duration:
            if let duration = rule?.maxDuration { return "after \(durationLabel(duration))" }
        case .energy:
            if let energy = rule?.maxEnergyWh { return "at \(formatter.energy(energy).text)" }
        }
        return reason.label
    }
}
