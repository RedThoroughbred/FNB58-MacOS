import Charts
import SwiftUI

struct LiveView: View {
    @Environment(MeterManager.self) private var meter
    @Environment(SessionStore.self) private var store

    @State private var showDevices = false
    @State private var showNamePrompt = false
    @State private var sessionName = ""
    @State private var saveError: String?
    @State private var windowSeconds = 30.0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    connectionBanner
                    readoutGrid
                    chartCard(title: "Voltage", unit: "V", color: .blue) { $0.voltage }
                    chartCard(title: "Current", unit: "A", color: .orange) { $0.current }
                    chartCard(title: "Power", unit: "W", color: .green) { $0.power }
                    recordingCard
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("FNB58")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Window", selection: $windowSeconds) {
                            Text("10 s").tag(10.0)
                            Text("30 s").tag(30.0)
                            Text("60 s").tag(60.0)
                            Text("2 min").tag(120.0)
                        }
                        Button("Clear chart", systemImage: "eraser") { meter.clearHistory() }
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                }
            }
            .sheet(isPresented: $showDevices) { DeviceListView() }
            .alert("Name this session", isPresented: $showNamePrompt) {
                TextField("e.g. iPhone charge test", text: $sessionName)
                Button("Start") { meter.startRecording(name: sessionName) }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Could not save session", isPresented: .init(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(saveError ?? "") }
        }
    }

    // MARK: Sections

    private var connectionBanner: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(meter.state.isConnected ? Color.green : Color.secondary)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(meter.state.label).font(.headline)
                if let err = meter.lastError {
                    Text(err).font(.caption).foregroundStyle(.red)
                } else if case .connected = meter.state, let r = meter.latest {
                    Text("Last sample \(r.timestamp, style: .relative) ago").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if meter.state.isConnected {
                Button("Disconnect", role: .destructive) { meter.disconnect() }
                    .buttonStyle(.bordered)
            } else {
                Button("Connect") { showDevices = true }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private var readoutGrid: some View {
        let r = meter.latest
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            readout("VOLTAGE", Fmt.value(r?.voltage, 3), "V", .blue)
            readout("CURRENT", Fmt.value(r?.current, 3), "A", .orange)
            readout("POWER", Fmt.value(r?.power, 2), "W", .green)
        }
    }

    private func readout(_ title: String, _ value: String, _ unit: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title2, design: .rounded).monospacedDigit().weight(.semibold))
                .foregroundStyle(color)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(unit).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private var windowedHistory: [Reading] {
        guard let last = meter.history.last else { return [] }
        let cutoff = last.timestamp.addingTimeInterval(-windowSeconds)
        // history is time-ordered; find the first index inside the window.
        if let idx = meter.history.firstIndex(where: { $0.timestamp >= cutoff }) {
            return Array(meter.history[idx...])
        }
        return meter.history
    }

    private func chartCard(title: String, unit: String, color: Color, _ key: @escaping (Reading) -> Double) -> some View {
        let points = windowedHistory
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                if let last = points.last {
                    Text("\(Fmt.value(key(last), 3)) \(unit)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            Chart(points) { p in
                LineMark(x: .value("Time", p.timestamp), y: .value(title, key(p)))
                    .foregroundStyle(color)
                    .interpolationMethod(.monotone)
                AreaMark(x: .value("Time", p.timestamp), y: .value(title, key(p)))
                    .foregroundStyle(color.opacity(0.12))
                    .interpolationMethod(.monotone)
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.minute().second())
                }
            }
            .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) }
            .frame(height: 140)
            .overlay {
                if points.isEmpty {
                    Text("Waiting for data").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private var recordingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recording").font(.subheadline.weight(.semibold))
                Spacer()
                if let rec = meter.recording {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Label(Fmt.duration(rec.elapsed), systemImage: "record.circle")
                            .foregroundStyle(.red)
                            .font(.subheadline.monospacedDigit())
                    }
                }
            }
            if let rec = meter.recording {
                let s = rec.stats
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                    stat("Samples", "\(s.samples)")
                    stat("Energy", Fmt.energy(s.energyWh))
                    stat("Capacity", Fmt.capacity(s.capacityAh))
                    stat("Avg power", "\(Fmt.value(s.avgPower, 2)) W")
                    stat("V range", "\(Fmt.value(s.minVoltage, 2))–\(Fmt.value(s.maxVoltage, 2)) V")
                    stat("Peak current", "\(Fmt.value(s.maxCurrent, 3)) A")
                }
                Button(role: .destructive) { stopAndSave() } label: {
                    Label("Stop & save", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button {
                    sessionName = ""
                    showNamePrompt = true
                } label: {
                    Label("Start recording", systemImage: "record.circle").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!meter.state.isConnected)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit())
        }
    }

    private func stopAndSave() {
        guard let session = meter.stopRecording() else { return }
        do { try store.save(session) } catch { saveError = error.localizedDescription }
    }
}
