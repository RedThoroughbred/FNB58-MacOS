import Charts
import SwiftUI

struct HistoryView: View {
    @Environment(SessionStore.self) private var store

    var body: some View {
        NavigationStack {
            Group {
                if store.sessions.isEmpty {
                    ContentUnavailableView("No sessions yet",
                                           systemImage: "clock.arrow.circlepath",
                                           description: Text("Recordings you save from the Live tab appear here."))
                } else {
                    List {
                        ForEach(store.sessions) { s in
                            NavigationLink(value: s.id) { SessionRow(session: s) }
                        }
                        .onDelete { idx in idx.map { store.sessions[$0] }.forEach(store.delete) }
                    }
                }
            }
            .navigationTitle("Sessions")
            .navigationDestination(for: UUID.self) { id in
                if let s = store.sessions.first(where: { $0.id == id }) {
                    SessionDetailView(session: s)
                }
            }
            .refreshable { store.load() }
        }
    }
}

struct SessionRow: View {
    let session: Session
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.name).font(.headline)
            HStack(spacing: 12) {
                Label(session.startTime.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                Label(Fmt.duration(session.duration), systemImage: "timer")
                Label(Fmt.energy(session.stats.energyWh), systemImage: "bolt")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

struct SessionDetailView: View {
    @Environment(SessionStore.self) private var store
    let session: Session
    @State private var shareURL: URL?
    @State private var exportError: String?

    var body: some View {
        List {
            Section("Summary") {
                row("Started", session.startTime.formatted(date: .abbreviated, time: .standard))
                row("Duration", Fmt.duration(session.duration))
                row("Samples", "\(session.stats.samples)")
                if let d = session.deviceName { row("Device", d) }
            }
            Section("Energy") {
                row("Energy", Fmt.energy(session.stats.energyWh))
                row("Capacity", Fmt.capacity(session.stats.capacityAh))
                row("Average power", "\(Fmt.value(session.stats.avgPower, 3)) W")
                row("Peak power", "\(Fmt.value(session.stats.maxPower, 3)) W")
            }
            Section("Voltage / Current") {
                row("Voltage", "\(Fmt.value(session.stats.minVoltage, 3)) – \(Fmt.value(session.stats.maxVoltage, 3)) V")
                row("Average voltage", "\(Fmt.value(session.stats.avgVoltage, 3)) V")
                row("Current", "\(Fmt.value(session.stats.minCurrent, 3)) – \(Fmt.value(session.stats.maxCurrent, 3)) A")
                row("Average current", "\(Fmt.value(session.stats.avgCurrent, 3)) A")
            }
            Section("Chart") {
                Chart(decimated) { p in
                    LineMark(x: .value("Time", p.timestamp), y: .value("V", p.voltage), series: .value("Series", "Voltage"))
                        .foregroundStyle(.blue)
                    LineMark(x: .value("Time", p.timestamp), y: .value("A", p.current), series: .value("Series", "Current"))
                        .foregroundStyle(.orange)
                }
                .chartForegroundStyleScale(["Voltage (V)": Color.blue, "Current (A)": Color.orange])
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.hour().minute().second()) } }
                .frame(height: 200)
                .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
            }
        }
        .navigationTitle(session.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Export CSV", systemImage: "square.and.arrow.up") {
                    do { shareURL = try store.csvURL(for: session) } catch { exportError = error.localizedDescription }
                }
            }
        }
        .sheet(item: $shareURL) { url in
            ShareSheet(items: [url])
        }
        .alert("Export failed", isPresented: .init(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(exportError ?? "") }
    }

    /// Keep the detail chart responsive for long sessions.
    private var decimated: [Reading] {
        let maxPoints = 1500
        let r = session.readings
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

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
