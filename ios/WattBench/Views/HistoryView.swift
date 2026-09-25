import Charts
import SwiftUI

struct HistoryView: View {
    @Environment(SessionStore.self) private var store
    @Environment(AppRouter.self) private var router

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.sessionPath) {
            Group {
                if store.summaries.isEmpty {
                    ContentUnavailableView("No sessions yet",
                                           systemImage: "clock.arrow.circlepath",
                                           description: Text("Recordings you save from the Live tab appear here."))
                } else {
                    List {
                        ForEach(store.summaries) { s in
                            NavigationLink(value: s.id) { SessionRow(summary: s) }
                        }
                        .onDelete { idx in idx.map { store.summaries[$0].id }.forEach { store.delete(id: $0) } }
                    }
                }
            }
            .navigationTitle("Sessions")
            .navigationDestination(for: UUID.self) { id in
                if let s = store.summaries.first(where: { $0.id == id }) {
                    SessionDetailView(summary: s)
                }
            }
            .refreshable { store.load() }
        }
    }
}

struct SessionRow: View {
    let summary: SessionSummary
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(summary.name).font(.headline)
            HStack(spacing: 12) {
                Label(summary.startTime.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                Label(Fmt.duration(summary.duration), systemImage: "timer")
                Label(Fmt.energy(summary.stats.energyWh), systemImage: "bolt")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

struct SessionDetailView: View {
    @Environment(SessionStore.self) private var store
    let summary: SessionSummary
    @State private var session: Session?
    @State private var shareURL: URL?
    @State private var loadError: String?
    @State private var exportError: String?

    var body: some View {
        List {
            Section("Summary") {
                row("Started", summary.startTime.formatted(date: .abbreviated, time: .standard))
                row("Duration", Fmt.duration(summary.duration))
                row("Samples", "\(summary.sampleCount)")
                if let d = summary.deviceName { row("Device", d) }
            }
            Section("Energy") {
                row("Energy", Fmt.energy(summary.stats.energyWh))
                row("Capacity", Fmt.capacity(summary.stats.capacityAh))
                row("Average power", "\(Fmt.value(summary.stats.avgPower, 3)) W")
                row("Peak power", "\(Fmt.value(summary.stats.maxPower, 3)) W")
            }
            Section("Voltage / Current") {
                row("Voltage", "\(Fmt.value(summary.stats.minVoltage, 3)) – \(Fmt.value(summary.stats.maxVoltage, 3)) V")
                row("Average voltage", "\(Fmt.value(summary.stats.avgVoltage, 3)) V")
                row("Current", "\(Fmt.value(summary.stats.minCurrent, 3)) – \(Fmt.value(summary.stats.maxCurrent, 3)) A")
                row("Average current", "\(Fmt.value(summary.stats.avgCurrent, 3)) A")
            }
            Section("Chart") {
                if let session {
                    Chart(decimated(session.readings)) { p in
                        LineMark(x: .value("Time", p.timestamp), y: .value("V", p.voltage), series: .value("Series", "Voltage"))
                            .foregroundStyle(.blue)
                        LineMark(x: .value("Time", p.timestamp), y: .value("A", p.current), series: .value("Series", "Current"))
                            .foregroundStyle(.orange)
                    }
                    .chartForegroundStyleScale(["Voltage (V)": Color.blue, "Current (A)": Color.orange])
                    .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.hour().minute().second()) } }
                    .frame(height: 200)
                    .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
                } else if let loadError {
                    Text(loadError).foregroundStyle(.secondary)
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
        }
        .navigationTitle(summary.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if let shareURL {
                    ShareLink(item: shareURL) {
                        Label("Export CSV", systemImage: "square.and.arrow.up")
                    }
                } else {
                    Button("Export CSV", systemImage: "square.and.arrow.up") {}
                        .disabled(true)
                }
            }
        }
        .task(id: summary.id) {
            do {
                let s = try await store.session(for: summary.id)
                session = s
                do { shareURL = try store.csvURL(for: s) } catch { exportError = error.localizedDescription }
            } catch {
                loadError = error.localizedDescription
            }
        }
        .alert("Export failed", isPresented: .init(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(exportError ?? "") }
    }

    /// Keep the detail chart responsive for long sessions.
    private func decimated(_ r: [Reading]) -> [Reading] {
        let maxPoints = 1500
        guard r.count > maxPoints else { return r }
        let step = Double(r.count) / Double(maxPoints)
        return (0..<maxPoints).map { r[Int(Double($0) * step)] }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}
