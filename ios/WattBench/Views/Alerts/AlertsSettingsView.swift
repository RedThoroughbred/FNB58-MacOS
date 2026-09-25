import SwiftUI

/// Alert rules: presets, the rule list with per-rule toggles, a test
/// notification and the notification permission state. Pushed from
/// Settings; the zero-argument init is frozen.
struct AlertsSettingsView: View {
    @Environment(AlertCoordinator.self) private var alerts
    @Environment(Preferences.self) private var prefs
    @State private var editing: AlertRule?
    @State private var testResult: TestResult?

    private enum TestResult { case sent, notAllowed }

    var body: some View {
        Form {
            if alerts.rules.isEmpty {
                emptySection
            } else {
                presetSection
                rulesSection
            }
            notificationsSection
        }
        .navigationTitle("Alerts")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { rule in
            AlertRuleEditor(rule: rule, isNew: !alerts.rules.contains { $0.id == rule.id }) { saved in
                Task { await alerts.upsert(saved) }
            }
        }
        .task { await alerts.refreshAuthorization() }
        .task {  // TEMP-WSE-SCREENSHOT
            let args = ProcessInfo.processInfo.arguments
            if args.contains("-wse-editor") { editing = newRule }
            if args.contains("-wse-permission") { await alerts.apply(.fiveVoltDevice) }
        }
    }

    // MARK: - Sections

    private var emptySection: some View {
        Section {
            ContentUnavailableView {
                Label("No Alert Rules", systemImage: "bell.slash")
            } description: {
                Text("Be told when a reading leaves its safe range, while WattBench is open or in the background.")
            } actions: {
                presetMenu {
                    Text("Add Preset")
                }
                .menuStyle(.button)
                .buttonStyle(.borderedProminent)
                Button("Add Rule") { editing = newRule }
                    .buttonStyle(.bordered)
            }
        }
        .listRowBackground(Color.clear)
    }

    private var rulesSection: some View {
        Section {
            ForEach(alerts.rules) { rule in
                ruleRow(rule)
            }
            .onDelete { alerts.remove(atOffsets: $0) }
        } header: {
            Text("Rules")
        } footer: {
            Text("Rules are checked on every reading, recording or not; Disconnected only while recording. "
                 + "Each rule fires at most once a minute and re-arms once the value is back 2% inside its bound. "
                 + "A fired alert adds a marker to the recording.")
        }
    }

    /// Preset menu at the top, as the entry point for a new bench setup.
    private var presetSection: some View {
        Section {
            presetMenu {
                Label("Add preset", systemImage: "square.stack.3d.up")
            }
            Button { editing = newRule } label: {
                Label("Add rule", systemImage: "plus.circle")
            }
        } footer: {
            Text("A preset adds its rules to the list; rules you already have are kept.")
        }
    }

    private var notificationsSection: some View {
        Section {
            LabeledContent("Notifications", value: authorizationText)
            if alerts.notificationAuthorization == .denied,
               let url = URL(string: UIApplication.openSettingsURLString) {
                Link(destination: url) {
                    HStack {
                        Text("Open Settings")
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.primary)
                }
            }
            Button {
                Task { await sendTest() }
            } label: {
                Label(testLabel, systemImage: testSymbol)
            }
        } footer: {
            Text(authorizationFooter)
        }
    }

    // MARK: - Rows

    private func ruleRow(_ rule: AlertRule) -> some View {
        HStack(spacing: 12) {
            Button { editing = rule } label: {
                HStack(spacing: 12) {
                    Image(systemName: rule.condition?.symbolName ?? "bell")
                        .foregroundStyle(.secondary)
                        .frame(width: 24)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(rule.name)
                        Text(rule.summary(formatter: prefs.formatter))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Edits the rule")
            Toggle("Enabled", isOn: Binding(
                get: { rule.enabled },
                set: { on in Task { await alerts.setEnabled(rule.id, on) } }))
                .labelsHidden()
        }
    }

    private func presetMenu<L: View>(@ViewBuilder label: () -> L) -> some View {
        Menu {
            ForEach(AlertPreset.allCases) { preset in
                Button {
                    Task { await alerts.apply(preset) }
                } label: {
                    Label {
                        Text(preset.title)
                        Text(preset.summary(formatter: prefs.formatter))
                    } icon: {
                        Image(systemName: preset.symbolName)
                    }
                }
            }
        } label: {
            label()
        }
    }

    // MARK: - Helpers

    private var newRule: AlertRule {
        AlertRule(.overVoltage, value: AlertRule.Condition.overVoltage.defaultValue)
    }

    private func sendTest() async {
        testResult = await alerts.sendTestNotification() ? .sent : .notAllowed
        try? await Task.sleep(for: .seconds(3))
        testResult = nil
    }

    private var testLabel: String {
        switch testResult {
        case .sent?: return "Test notification sent"
        case .notAllowed?: return "Notifications are not allowed"
        case nil: return "Send test notification"
        }
    }

    private var testSymbol: String {
        switch testResult {
        case .sent?: return "checkmark.circle"
        case .notAllowed?: return "bell.slash"
        case nil: return "bell.badge"
        }
    }

    private var authorizationText: String {
        switch alerts.notificationAuthorization {
        case .notDetermined: return "Not yet asked"
        case .authorized: return "Allowed"
        case .denied: return "Off"
        }
    }

    private var authorizationFooter: String {
        switch alerts.notificationAuthorization {
        case .notDetermined:
            return "WattBench asks to send notifications the first time you enable a rule, never before."
        case .authorized:
            return "While WattBench is in the background, alerts arrive as notifications; one that fires during a recording offers Stop & save."
        case .denied:
            return "Notifications are off for WattBench, so alerts show only while the app is open. Turn them on in Settings to be alerted in the background."
        }
    }
}
