import SwiftUI

/// Settings sheet root, opened from the gear on the Live tab. Diagnostics,
/// Alerts and About live inside it as NavigationLinks. The zero-argument
/// init is frozen.
struct SettingsView: View {
    @Environment(Preferences.self) private var prefs
    @Environment(MeterManager.self) private var meter
    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var storageBytes: Int?
    @State private var confirmDeleteAll = false
    @State private var confirmForget = false

    var body: some View {
        NavigationStack {
            Form {
                displaySection
                chartsSection
                recordingSection
                alertsSection
                meterSection
                storageSection
                advancedSection
                aboutSection
            }
            .formStyle(.grouped)
            .textCase(nil)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task(id: store.summaries.count) {
                storageBytes = await SessionStorageUsage.bytes()
            }
        }
    }

    // MARK: Sections

    private var displaySection: some View {
        @Bindable var prefs = prefs
        return Section {
            Picker("Hero metric", selection: $prefs.heroMetric) {
                ForEach(Metric.allCases) { metric in
                    Label(metric.title, systemImage: metric.symbolName).tag(metric)
                }
            }
            .pickerStyle(.navigationLink)

            Toggle("Auto-range units", isOn: $prefs.autoRangeUnits)

            Picker("Precision", selection: $prefs.precision) {
                ForEach(Preferences.precisionChoices, id: \.self) { digits in
                    Text("\(digits) digits").tag(digits)
                }
            }
            .pickerStyle(.navigationLink)

            Picker("Capacity", selection: $prefs.capacityUnit) {
                Text("mAh").tag(Preferences.CapacityUnit.mAh)
                Text("Auto").tag(Preferences.CapacityUnit.Ah)
            }

            Toggle("Haptic feedback", isOn: $prefs.hapticsEnabled)

            Toggle("Keep screen awake while connected", isOn: $prefs.keepAwake)
        } header: {
            Text("Display")
        } footer: {
            Text("Readouts look like \(sample). Keeping the screen on uses more battery; Low Power Mode overrides it.")
        }
    }

    /// A live example of the current formatting settings.
    private var sample: String {
        let f = prefs.formatter
        return "\(f.format(1.2345, .current).text) or \(f.format(0.0123, .current).text)"
    }

    private var chartsSection: some View {
        @Bindable var prefs = prefs
        return Section("Charts") {
            Picker("Default window", selection: $prefs.defaultWindow) {
                ForEach(Preferences.windowChoices, id: \.self) { seconds in
                    Text(prefs.formatter.interval(seconds)).tag(seconds)
                }
            }
            Toggle("Show peak line", isOn: $prefs.showPeakLine)
        }
    }

    private var recordingSection: some View {
        @Bindable var prefs = prefs
        return Section {
            LabeledContent("Default auto-stop", value: prefs.formatter.describe(prefs.defaultAutoStop))
            if prefs.defaultAutoStop != nil {
                Button("Clear default auto-stop") { prefs.defaultAutoStop = nil }
            }
            Toggle("Exclude demo readings from trip", isOn: $prefs.excludeDemoFromTrips)
        } header: {
            Text("Recording")
        } footer: {
            Text("The auto-stop rule is set when you start a recording; WattBench remembers the last one.")
        }
    }

    private var alertsSection: some View {
        Section("Alerts") {
            NavigationLink {
                AlertsSettingsView()
                    .navigationTitle("Alerts")
            } label: {
                Label("Alert rules", systemImage: "bell.badge")
            }
        }
    }

    private var meterSection: some View {
        @Bindable var prefs = prefs
        @Bindable var meter = meter
        return Section {
            LabeledContent("Last meter", value: lastMeterDescription)
            Toggle("Auto-connect on launch", isOn: $prefs.autoConnect)
            Toggle("Show all Bluetooth devices", isOn: $meter.showAllDevices)
            Button("Forget meter", role: .destructive) { confirmForget = true }
                .disabled(!meter.hasLastDevice)
                .confirmationDialog("Forget this meter?", isPresented: $confirmForget, titleVisibility: .visible) {
                    Button("Forget Meter", role: .destructive) { meter.forgetLastDevice() }
                } message: {
                    Text("WattBench will stop connecting to it automatically. You can pick it again from the Connect sheet.")
                }
        } header: {
            Text("Meter")
        } footer: {
            Text("Only devices named FNB58 are listed unless Show all Bluetooth devices is on.\n\nBluetooth stays active in the background only while WattBench is connected to a meter, so a recording continues with the screen locked. Disconnect when you are done to save battery. WattBench never scans for meters in the background.")
        }
    }

    private var lastMeterDescription: String {
        switch meter.state {
        case .connected(let name), .connecting(let name), .unreachable(let name):
            return name
        case .reconnecting(let name, _):
            return name
        default:
            return meter.hasLastDevice ? "Remembered" : "None"
        }
    }

    private var storageSection: some View {
        Section {
            LabeledContent("Sessions", value: store.summaries.count.formatted())
            LabeledContent("Space used", value: storageBytes.map { prefs.formatter.byteCount($0) } ?? "–")
            Button("Delete All Sessions", role: .destructive) { confirmDeleteAll = true }
                .disabled(store.summaries.isEmpty)
                .confirmationDialog("Delete all sessions?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
                    Button("Delete \(store.summaries.count) Sessions", role: .destructive) { deleteAllSessions() }
                } message: {
                    Text("This removes every saved recording from this iPhone. Export anything you want to keep first.")
                }
        } header: {
            Text("Storage")
        } footer: {
            Text("Recordings live in WattBench's Documents folder, which you can also browse in the Files app.")
        }
    }

    private var advancedSection: some View {
        Section("Advanced") {
            NavigationLink {
                DiagnosticsView()
            } label: {
                Label("Diagnostics", systemImage: "stethoscope")
            }
            if meter.isDemo {
                Button {
                    meter.disconnect()
                } label: {
                    Label("Stop demo data", systemImage: "stop.circle")
                }
                .foregroundStyle(Color.demo)
            } else {
                Button {
                    meter.startDemo()
                    dismiss()
                } label: {
                    Label("Try demo data", systemImage: "play.circle")
                }
                .foregroundStyle(Color.demo)
            }
        }
    }

    private var aboutSection: some View {
        Section {
            NavigationLink {
                AboutView()
            } label: {
                LabeledContent("Version", value: AppInfo.versionSummary)
            }
            ExternalLink("Privacy policy", url: AppInfo.privacyPolicyURL)
            ExternalLink("Support", url: AppInfo.supportURL)
        } header: {
            Text("About")
        } footer: {
            Text(AppInfo.disclaimer)
        }
    }

    // MARK: Actions

    private func deleteAllSessions() {
        for summary in store.summaries {
            store.delete(id: summary.id)
        }
    }
}

/// Bytes used by the sessions folder (manifests, journals and legacy JSON),
/// measured off the main actor. File sizes only: no timestamps are read, so
/// no privacy-manifest reason is needed.
enum SessionStorageUsage {
    static func bytes() async -> Int {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return 0 }
        let root = docs.appendingPathComponent("sessions", isDirectory: true)
        return await Task.detached(priority: .utility) { bytes(under: root) }.value
    }

    nonisolated static func bytes(under root: URL) -> Int {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys),
                                                              options: [.skipsHiddenFiles]) else { return 0 }
        var total = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            total += values.fileSize ?? 0
        }
        return total
    }
}

#Preview {
    SettingsView()
        .environment(Preferences(defaults: UserDefaults(suiteName: "preview") ?? .standard))
        .environment(MeterManager())
        .environment(SessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("preview-sessions")))
}
