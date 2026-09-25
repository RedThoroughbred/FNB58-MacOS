import SwiftUI

/// The Connect sheet: nearby meters with a system signal glyph, one empty
/// state per situation, zero-tap auto-connect when exactly one FNB58 is
/// found, and an Advanced disclosure for Forget meter / Show all devices.
/// The zero-argument init is frozen.
struct DeviceListView: View {
    @Environment(MeterManager.self) private var meter
    @Environment(\.dismiss) private var dismiss

    /// Set on the first tap anywhere in the list; blocks auto-connect.
    @State private var userInteracted = false
    /// The device auto-connect picked, shown as an inline row with Cancel.
    @State private var autoConnecting: DiscoveredDevice?
    @State private var didAutoConnect = false
    @State private var scanStartedAt: Date?
    @State private var timedOut = false
    @State private var showAdvanced = false
    @State private var search = ""

    /// Seconds of scanning without a discovery before the troubleshooting
    /// text replaces the spinner.
    static let notFoundAfter: TimeInterval = 8

    var body: some View {
        NavigationStack {
            Group {
                if meter.showAllDevices {
                    list.searchable(text: $search, prompt: "Device name")
                } else {
                    list
                }
            }
            .navigationTitle("Connect")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { scanButton }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear(perform: beginScanIfIdle)
        .onDisappear {
            if meter.state == .scanning { meter.stopScan() }
        }
        .onChange(of: meter.state) { _, state in
            switch state {
            case .scanning:
                scanStartedAt = Date()
                timedOut = false
            case .connected:
                if autoConnecting != nil { dismiss() }
            case .connecting, .reconnecting:
                break
            default:
                // A failed auto-connect lands back in .idle with lastError set.
                autoConnecting = nil
            }
        }
        .onChange(of: meter.devices.isEmpty) { _, isEmpty in
            if !isEmpty { timedOut = false }
        }
        .task(id: scanStartedAt) {
            guard scanStartedAt != nil else { return }
            try? await Task.sleep(for: .seconds(Self.notFoundAfter))
            guard !Task.isCancelled, meter.state == .scanning, meter.devices.isEmpty else { return }
            timedOut = true
        }
        .task(id: meter.devices.first?.id) {
            // Zero-tap connect: wait for discovery to settle, then connect if
            // the list holds exactly one FNB58 and the user has not tapped.
            guard !didAutoConnect, !meter.devices.isEmpty, meter.state == .scanning else { return }
            try? await Task.sleep(for: .seconds(ConnectAutoSelect.settleDelay))
            guard !Task.isCancelled, !didAutoConnect, meter.state == .scanning,
                  let device = ConnectAutoSelect.candidate(in: meter.devices, userInteracted: userInteracted) else { return }
            didAutoConnect = true
            autoConnecting = device
            meter.connect(device)
        }
    }

    // MARK: List

    private var list: some View {
        List {
            if let device = autoConnecting {
                Section {
                    connectingRow(device)
                }
            }

            switch meter.state {
            case .bluetoothOff:
                emptyState(.bluetoothOff)
            case .unauthorized:
                emptyState(.unauthorized)
            case .reconnecting(let name, let since):
                emptyState(.reconnecting(name: name, since: since))
            case .unreachable(let name):
                emptyState(.unreachable(name))
            case .connected(let name):
                connectedSection(name: name, isDemo: false)
                nearbySection
            case .demo:
                // Demo has its own Stop; a Scan action here would be a no-op
                // whenever Bluetooth is off, so Nearby only appears with rows.
                connectedSection(name: "Demo data", isDemo: true)
                if !visibleDevices.isEmpty { nearbySection }
            case .idle, .scanning, .connecting:
                if autoConnecting == nil, meter.hasLastDevice, meter.recording == nil {
                    Section {
                        Button {
                            userInteracted = true
                            meter.reconnectLastDevice()
                            dismiss()
                        } label: {
                            Label("Reconnect to last meter", systemImage: "arrow.clockwise")
                                .frame(minHeight: 44)
                        }
                    }
                }
                nearbySection
            }

            if let error = meter.lastError, meter.state != .demo {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            advancedSection
        }
        .listStyle(.insetGrouped)
        // Keyed on membership/order only: MeterManager rewrites the array on
        // every advertisement, which must not re-animate the list per sample.
        .animation(.snappy, value: meter.devices.map(\.id))
        .animation(.snappy, value: autoConnecting)
    }

    private func emptyState(_ kind: ConnectEmptyState.Kind) -> some View {
        Section {
            ConnectEmptyState(state: kind, primaryAction: {
                userInteracted = true
                switch kind {
                case .reconnecting, .unreachable: meter.retryNow()
                default: restartScan()
                }
            }, secondaryAction: {
                userInteracted = true
                switch kind {
                case .nothingFound:
                    meter.startDemo()
                    dismiss()
                case .reconnecting:
                    meter.disconnect()
                case .unreachable:
                    meter.disconnect()
                    restartScan()
                default:
                    break
                }
            })
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
        }
    }

    private func connectedSection(name: String, isDemo: Bool) -> some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: isDemo ? "play.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(isDemo ? Color.demo : meter.state.tint)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.body)
                    Text(isDemo ? "Simulated readings" : "Connected").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(isDemo ? "Stop" : "Disconnect", role: .destructive) {
                    userInteracted = true
                    meter.disconnect()
                }
                .buttonStyle(.bordered)
            }
            .frame(minHeight: 44)
        }
    }

    @ViewBuilder
    private var nearbySection: some View {
        let devices = visibleDevices
        Section {
            if devices.isEmpty {
                switch meter.state {
                case .scanning:
                    if timedOut {
                        ConnectEmptyState(state: .nothingFound, primaryAction: {
                            userInteracted = true
                            restartScan()
                        }, secondaryAction: {
                            meter.startDemo()
                            dismiss()
                        })
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                    } else {
                        ConnectEmptyState(state: .scanning)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                    }
                case .connecting:
                    // The auto-connect row above already shows this state.
                    if autoConnecting == nil {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text(meter.state.label).foregroundStyle(.secondary)
                        }
                        .frame(minHeight: 44)
                    }
                default:
                    if !search.isEmpty {
                        Text("No devices match “\(search)”").foregroundStyle(.secondary)
                    } else {
                        ConnectEmptyState(state: .idle, primaryAction: {
                            userInteracted = true
                            restartScan()
                        })
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                    }
                }
            }
            ForEach(devices) { device in
                deviceRow(device)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        } header: {
            HStack {
                Text("Nearby")
                if meter.state == .scanning {
                    ProgressView().controlSize(.mini)
                }
            }
        }
    }

    private var visibleDevices: [DiscoveredDevice] {
        let devices = meter.devices.filter { $0.id != autoConnecting?.id }
        guard meter.showAllDevices, !search.isEmpty else { return devices }
        return devices.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    private func deviceRow(_ device: DiscoveredDevice) -> some View {
        Button {
            userInteracted = true
            meter.connect(device)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "cellularbars", variableValue: SignalLevel.level(rssi: device.rssi))
                    .symbolRenderingMode(.hierarchical)
                    .font(.title3)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name).font(.body)
                    Text("\(device.rssi) dBm")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .tint(.primary)
        .accessibilityLabel("\(device.name), \(SignalLevel.description(rssi: device.rssi))")
        .accessibilityHint("Connects to this meter")
    }

    private func connectingRow(_ device: DiscoveredDevice) -> some View {
        HStack(spacing: 12) {
            ProgressView()
            VStack(alignment: .leading, spacing: 2) {
                Text("Connecting to \(device.name)…").font(.body)
                Text("Found only this meter").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") {
                userInteracted = true
                autoConnecting = nil
                meter.disconnect()
                restartScan()
            }
            .buttonStyle(.bordered)
        }
        .frame(minHeight: 44)
    }

    private var advancedSection: some View {
        @Bindable var meter = meter
        return Section {
            DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                Toggle("Show all Bluetooth devices", isOn: $meter.showAllDevices)
                    .onChange(of: meter.showAllDevices) { _, _ in
                        userInteracted = true
                        search = ""
                    }
                Button("Forget meter", role: .destructive) {
                    userInteracted = true
                    meter.forgetLastDevice()
                }
                .disabled(!meter.hasLastDevice)
            }
        } footer: {
            if showAdvanced {
                Text("Forgetting the meter stops auto-connect on launch. Show all lists every advertising device, not only names containing FNB58.")
            }
        }
    }

    // MARK: Toolbar

    @ViewBuilder
    private var scanButton: some View {
        switch meter.state {
        case .scanning:
            Button("Stop") { userInteracted = true; meter.stopScan() }
        case .idle, .unreachable:
            Button("Scan") { userInteracted = true; restartScan() }
        default:
            EmptyView()
        }
    }

    // MARK: Actions

    /// Only an idle meter starts scanning by itself; a connected, connecting
    /// or reconnecting meter keeps its state until the user asks.
    private func beginScanIfIdle() {
        if meter.state == .idle { meter.startScan() }
    }

    /// Starts (or restarts) a scan and resets the not-found timer locally:
    /// when the meter is already `.scanning`, `startScan()` assigns an equal
    /// state and `.onChange(of: meter.state)` never fires.
    private func restartScan() {
        timedOut = false
        scanStartedAt = Date()
        meter.startScan()
    }
}

#Preview {
    DeviceListView()
        .environment(MeterManager())
}
