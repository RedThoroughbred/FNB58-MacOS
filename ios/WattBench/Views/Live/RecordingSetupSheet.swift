import SwiftUI

// MARK: - Pure model (unit tested in RecordingSetupModelTests)

/// Everything the recording setup sheet edits, plus the composition of the
/// auto-stop rule and the default name. Free of SwiftUI so it can be tested.
struct RecordingSetupModel: Equatable {
    static let defaultTags = ["Charger", "Cable", "Power bank", "Device"]
    /// "for" choices of the below-current rule (seconds).
    static let belowOptions: [TimeInterval] = [30, 60, 120, 300]
    /// Choices of the duration rule (seconds).
    static let durationOptions: [TimeInterval] = [1800, 3600, 7200, 14400, 28800]
    static let defaultBelowCurrentA = 0.10
    static let currentStep = 0.05
    static let currentRange = 0.01...5.0
    static let recentTagLimit = 8

    var name: String
    var selectedTags: [String] = []
    /// Default tags followed by recently used ones.
    var tagChoices: [String]
    var note = ""
    var belowEnabled = false
    var belowCurrentA = RecordingSetupModel.defaultBelowCurrentA
    var forSeconds: TimeInterval = 60
    var durationEnabled = false
    var maxDuration: TimeInterval = 3600
    var energyEnabled = false
    var maxEnergyText = ""
    var locale: Locale

    init(deviceName: String?, date: Date = Date(), defaultRule: AutoStopRule? = nil, recentTags: [String] = [],
         locale: Locale = .autoupdatingCurrent, timeZone: TimeZone = .current) {
        self.locale = locale
        name = Self.defaultName(deviceName: deviceName, date: date, locale: locale, timeZone: timeZone)
        tagChoices = Self.defaultTags + recentTags.filter { tag in
            !Self.defaultTags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
        }
        if let rule = defaultRule {
            if let below = rule.belowCurrentA {
                belowEnabled = true
                belowCurrentA = below
                forSeconds = rule.forSeconds
            }
            if let duration = rule.maxDuration {
                durationEnabled = true
                maxDuration = duration
            }
            if let energy = rule.maxEnergyWh {
                energyEnabled = true
                maxEnergyText = energy.formatted(.number.grouping(.never).locale(locale))
            }
        }
    }

    /// "FNB58 · Sep 25, 14:02" (month, day, hour and minute in the locale's
    /// own order); "Session · …" when the device is unknown.
    static func defaultName(deviceName: String?, date: Date, locale: Locale = .autoupdatingCurrent,
                            timeZone: TimeZone = .current) -> String {
        let device = deviceName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let style = Date.FormatStyle(locale: locale, timeZone: timeZone).month(.abbreviated).day().hour().minute()
        return "\(device.isEmpty ? "Session" : device) · \(date.formatted(style))"
    }

    /// Tags from the newest summaries first, de-duplicated ignoring case
    /// (first spelling wins), without the default tags, at most `limit`.
    static func recentTags(from summaries: [SessionSummary], excluding defaults: [String] = defaultTags,
                           limit: Int = recentTagLimit) -> [String] {
        var seen = Set(defaults.map { $0.lowercased() })
        var out: [String] = []
        for summary in summaries.sorted(by: { $0.startTime > $1.startTime }) {
            for tag in summary.tags {
                let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
                out.append(trimmed)
                if out.count == limit { return out }
            }
        }
        return out
    }

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var noteOrNil: String? {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The energy limit parsed in the model's locale; nil when the field is
    /// empty or unparseable.
    var maxEnergyWh: Double? {
        let trimmed = maxEnergyText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let value = try? Double(trimmed, format: .number.locale(locale)),
              value.isFinite, value > 0 else { return nil }
        return value
    }

    /// The auto-stop rule composed from the toggles; nil when none is on.
    var rule: AutoStopRule? {
        guard belowEnabled || durationEnabled || energyEnabled else { return nil }
        return AutoStopRule(belowCurrentA: belowEnabled ? belowCurrentA : nil,
                            forSeconds: forSeconds,
                            maxDuration: durationEnabled ? maxDuration : nil,
                            maxEnergyWh: energyEnabled ? maxEnergyWh : nil)
    }

    /// Start is allowed: a name, and a parseable limit when the energy rule is on.
    var isValid: Bool {
        !trimmedName.isEmpty && (!energyEnabled || maxEnergyWh != nil)
    }

    func isSelected(_ tag: String) -> Bool { selectedTags.contains(tag) }

    mutating func toggleTag(_ tag: String) {
        if let i = selectedTags.firstIndex(of: tag) {
            selectedTags.remove(at: i)
        } else {
            selectedTags.append(tag)
        }
    }
}

// MARK: - Sheet

/// Name, tags, note and auto-stop rule for a new recording; two taps from
/// Record to recording because the name is prefilled.
struct RecordingSetupSheet: View {
    let isDemo: Bool
    let onStart: (RecordingSetupModel) -> Void

    @Environment(Preferences.self) private var prefs
    @Environment(\.dismiss) private var dismiss
    @State private var model: RecordingSetupModel
    @FocusState private var nameFocused: Bool

    init(deviceName: String?, isDemo: Bool, defaultRule: AutoStopRule?, recentTags: [String],
         onStart: @escaping (RecordingSetupModel) -> Void) {
        self.isDemo = isDemo
        self.onStart = onStart
        _model = State(initialValue: RecordingSetupModel(deviceName: deviceName, defaultRule: defaultRule,
                                                         recentTags: recentTags))
    }

    var body: some View {
        let formatter = prefs.formatter
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $model.name)
                        .textInputAutocapitalization(.words)
                        .focused($nameFocused)
                        .submitLabel(.done)
                    tagRow
                    TextField("Note", text: $model.note, axis: .vertical)
                        .lineLimit(1...4)
                }

                Section {
                    Toggle("When current stays below", isOn: $model.belowEnabled)
                    if model.belowEnabled {
                        Stepper(value: $model.belowCurrentA, in: RecordingSetupModel.currentRange,
                                step: RecordingSetupModel.currentStep) {
                            LabeledContent("Current", value: formatter.format(model.belowCurrentA, .current).text)
                                .monospacedDigit()
                        }
                        Picker("For", selection: $model.forSeconds) {
                            ForEach(RecordingSetupModel.belowOptions, id: \.self) { s in
                                Text(LiveFormat.durationLabel(s)).tag(s)
                            }
                        }
                    }
                    Toggle("After duration", isOn: $model.durationEnabled)
                    if model.durationEnabled {
                        Picker("Duration", selection: $model.maxDuration) {
                            ForEach(RecordingSetupModel.durationOptions, id: \.self) { s in
                                Text(LiveFormat.durationLabel(s)).tag(s)
                            }
                        }
                    }
                    Toggle("At energy", isOn: $model.energyEnabled)
                    if model.energyEnabled {
                        LabeledContent("Energy") {
                            HStack(spacing: 4) {
                                TextField("0", text: $model.maxEnergyText)
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                    .monospacedDigit()
                                Text("Wh").foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Stop automatically")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        if model.rule != nil {
                            Text("The recording is saved by itself when the rule is met, also with the screen locked. Allow notifications to be told when it stops.")
                        }
                        if isDemo {
                            Text("Demo recordings run only while the app is open.")
                        }
                    }
                }
            }
            .navigationTitle("New Recording")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start Recording") { start() }
                        .fontWeight(.semibold)
                        .disabled(!model.isValid)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var tagRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(model.tagChoices, id: \.self) { tag in
                    let on = model.isSelected(tag)
                    Button(tag) { model.toggleTag(tag) }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)
                        .tint(on ? Color.accentColor : Color.secondary)
                        .fontWeight(on ? .semibold : .regular)
                        .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 0))
        .accessibilityLabel("Tags")
    }

    private func start() {
        guard model.isValid else { return }
        prefs.defaultAutoStop = model.rule
        onStart(model)
        dismiss()
    }
}
