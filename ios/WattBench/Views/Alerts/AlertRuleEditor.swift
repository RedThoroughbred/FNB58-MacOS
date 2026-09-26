import SwiftUI

/// Sheet for one alert rule: condition, threshold (or drop), duration, name
/// and background delivery. Edits a draft and hands the finished rule to
/// `onSave`; the rule's id and enabled state are preserved.
struct AlertRuleEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Preferences.self) private var prefs

    @State private var condition: AlertRule.Condition
    @State private var value: Double
    @State private var seconds: TimeInterval
    @State private var name: String
    @State private var notify: Bool
    @State private var nameIsCustom: Bool
    @FocusState private var valueFocused: Bool

    private let original: AlertRule
    private let isNew: Bool
    private let onSave: (AlertRule) -> Void

    init(rule: AlertRule, isNew: Bool = false, onSave: @escaping (AlertRule) -> Void) {
        original = rule
        self.isNew = isNew
        self.onSave = onSave
        let c = rule.condition ?? .overVoltage
        _condition = State(initialValue: c)
        _value = State(initialValue: rule.value ?? c.defaultValue)
        _seconds = State(initialValue: rule.forSeconds > 0 ? rule.forSeconds : c.defaultSeconds)
        _name = State(initialValue: rule.name)
        _notify = State(initialValue: rule.notify)
        _nameIsCustom = State(initialValue: rule.name != c.title)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Condition") {
                    Picker("Condition", selection: $condition) {
                        ForEach(AlertRule.Condition.allCases) { c in
                            Label(c.title, systemImage: c.symbolName).tag(c)
                        }
                    }
                }
                if condition.hasValue || condition.hasDuration {
                    Section {
                        if condition.hasValue { valueRow }
                        if condition.hasDuration { durationRow }
                    } header: {
                        Text(condition.hasValue ? (condition == .voltageDrop ? "Drop" : "Threshold") : "Duration")
                    } footer: {
                        Text("\(draft.summary(formatter: prefs.formatter)). \(condition.help)")
                    }
                }
                Section("Name") {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.sentences)
                }
                Section {
                    Toggle("Notify in the background", isOn: $notify)
                } footer: {
                    Text("A banner shows while WattBench is open. In the background the alert arrives as a notification and, during a recording, offers Stop & save.")
                }
            }
            .navigationTitle(isNew ? "New Rule" : "Edit Rule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Add" : "Save") { save() }
                        .disabled(!draft.isValid)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { valueFocused = false }
                }
            }
            .onChange(of: condition) { old, new in
                if !nameIsCustom { name = new.title }
                if old.metric != new.metric || !new.valueRange.contains(value) { value = new.defaultValue }
                if new.hasDuration, seconds <= 0 { seconds = new.defaultSeconds }
            }
            .onChange(of: name) { _, new in
                nameIsCustom = new != condition.title
            }
        }
    }

    // MARK: - Rows

    private var valueRow: some View {
        HStack(spacing: 8) {
            TextField("Value", value: $value, format: .number.precision(.fractionLength(0...3)))
                .keyboardType(.decimalPad)
                .focused($valueFocused)
                .accessibilityLabel("Value in \(condition.metric?.spokenName ?? "")")
            Text(condition.unit)
                .foregroundStyle(.secondary)
            Stepper("Value", value: $value, in: condition.valueRange, step: condition.valueStep)
                .labelsHidden()
        }
    }

    private var durationRow: some View {
        Stepper {
            LabeledContent("For", value: AlertFormat.span(seconds, locale: prefs.formatter.locale))
        } onIncrement: {
            seconds = Self.step(seconds, up: true)
        } onDecrement: {
            seconds = Self.step(seconds, up: false)
        }
    }

    // MARK: - Draft

    /// The rule as currently edited.
    private var draft: AlertRule {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        var rule = AlertRule(condition, value: value, seconds: condition.hasDuration ? seconds : 0,
                             name: trimmed.isEmpty ? condition.title : trimmed,
                             enabled: original.enabled, notify: notify)
        rule.id = original.id
        return rule
    }

    private func save() {
        onSave(draft)
        dismiss()
    }

    /// 5 s steps up to a minute, 30 s to five minutes, then whole minutes;
    /// clamped to 5 s ... 2 h.
    static func step(_ s: TimeInterval, up: Bool) -> TimeInterval {
        let size: TimeInterval
        if up {
            size = s < 60 ? 5 : (s < 300 ? 30 : 60)
        } else {
            size = s <= 60 ? 5 : (s <= 300 ? 30 : 60)
        }
        let next = up ? s + size : s - size
        return min(7200, max(5, next))
    }
}
