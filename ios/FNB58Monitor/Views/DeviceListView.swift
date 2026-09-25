import SwiftUI

struct DeviceListView: View {
    @Environment(MeterManager.self) private var meter
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var meter = meter
        NavigationStack {
            List {
                if meter.hasLastDevice {
                    Section {
                        Button {
                            meter.reconnectLastDevice()
                            dismiss()
                        } label: {
                            Label("Reconnect to last meter", systemImage: "arrow.clockwise")
                        }
                    }
                }

                Section {
                    if meter.devices.isEmpty {
                        HStack {
                            if meter.state == .scanning { ProgressView().padding(.trailing, 8) }
                            Text(emptyMessage).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(meter.devices) { d in
                        Button {
                            meter.connect(d)
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(d.name).font(.body)
                                    Text(d.id.uuidString.prefix(8)).font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                SignalBars(rssi: d.rssi)
                                Text("\(d.rssi) dBm").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                        .tint(.primary)
                    }
                } header: {
                    Text("Nearby devices")
                } footer: {
                    Text("Turn the FNB58 on and enable Bluetooth in its settings menu. Only devices whose name contains “FNB58” are shown unless you enable “Show all”.")
                }

                Section {
                    Toggle("Show all Bluetooth devices", isOn: $meter.showAllDevices)
                }

                #if targetEnvironment(simulator)
                Section {
                    Button("Use demo data") {
                        meter.startDemo()
                        dismiss()
                    }
                } footer: {
                    Text("The iOS Simulator has no Bluetooth radio.")
                }
                #endif
            }
            .navigationTitle("Connect")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    if meter.state == .scanning {
                        Button("Stop") { meter.stopScan() }
                    } else {
                        Button("Scan") { meter.startScan() }
                    }
                }
            }
            .onAppear { meter.startScan() }
            .onDisappear { meter.stopScan() }
        }
    }

    private var emptyMessage: String {
        switch meter.state {
        case .bluetoothOff: return "Bluetooth is turned off."
        case .unauthorized: return "Allow Bluetooth for this app in Settings."
        case .scanning: return "Looking for FNB58…"
        default: return "Tap Scan to search."
        }
    }
}

struct SignalBars: View {
    let rssi: Int
    var body: some View {
        let level = rssi > -55 ? 4 : rssi > -67 ? 3 : rssi > -80 ? 2 : 1
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(1...4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i <= level ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 4, height: CGFloat(4 + i * 3))
            }
        }
    }
}
