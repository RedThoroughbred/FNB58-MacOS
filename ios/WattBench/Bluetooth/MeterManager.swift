import CoreBluetooth
import Foundation
import Observation

/// A device seen while scanning.
struct DiscoveredDevice: Identifiable, Equatable {
    let id: UUID
    let name: String
    var rssi: Int
    var lastSeen: Date
}

/// One line in the diagnostics log.
struct LogEntry: Identifiable {
    let id = UUID()
    let time: Date
    let message: String
}

enum ConnectionState: Equatable {
    case bluetoothOff
    case unauthorized
    case idle
    case scanning
    case connecting(String)
    case connected(String)
    case demo

    var isConnected: Bool {
        switch self {
        case .connected, .demo: return true
        default: return false
        }
    }

    var label: String {
        switch self {
        case .bluetoothOff: return "Bluetooth is off"
        case .unauthorized: return "Bluetooth access denied"
        case .idle: return "Not connected"
        case .scanning: return "Scanning…"
        case .connecting(let n): return "Connecting to \(n)…"
        case .connected(let n): return n
        case .demo: return "Demo data"
        }
    }
}

/// Owns the CoreBluetooth central, the live reading buffer and the session
/// recorder. All published state is mutated on the main queue.
@Observable
final class MeterManager: NSObject {
    // MARK: Published state
    private(set) var state: ConnectionState = .idle
    private(set) var devices: [DiscoveredDevice] = []
    private(set) var latest: Reading?
    /// Sliding window for the live charts (~2 minutes at 10 Hz).
    private(set) var history: [Reading] = []
    private(set) var recording: SessionRecorder?
    private(set) var lastError: String?
    var showAllDevices = false {
        didSet { if state == .scanning { restartScan() } }
    }

    // MARK: Diagnostics (visible in the Diagnostics screen; no Xcode needed)
    private(set) var log: [LogEntry] = []
    private(set) var discoveredGATT: [String] = []
    private(set) var framesReceived = 0
    private(set) var framesParsed = 0
    private(set) var lastFrameHex = ""

    static let historyLimit = 1200
    private static let logLimit = 400
    private static let lastDeviceKey = "lastDeviceIdentifier"

    // MARK: Private
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var didStartStreaming = false
    private var wantsAutoReconnect = false
    private var demoTimer: Timer?
    private var demoPhase = 0.0

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: false])
        logEvent("App started")
    }

    // MARK: - Public API

    func startScan() {
        guard central.state == .poweredOn else {
            logEvent("Scan requested but Bluetooth state is \(central.state.rawValue)")
            return
        }
        devices.removeAll()
        state = .scanning
        logEvent("Scanning (filter: \(showAllDevices ? "all names" : "contains \(FNB58Protocol.nameFilter)"))")
        // The FNB58 does not reliably include FFE0 in its advertisement, so scan
        // for everything and filter by name.
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    func stopScan() {
        central.stopScan()
        if state == .scanning { state = .idle }
    }

    func connect(_ device: DiscoveredDevice) {
        guard let p = central.retrievePeripherals(withIdentifiers: [device.id]).first else {
            lastError = "Device is no longer available"
            logEvent("connect: peripheral \(device.id) not retrievable")
            return
        }
        connect(peripheral: p, name: device.name)
    }

    func disconnect() {
        wantsAutoReconnect = false
        stopDemo()
        if let p = peripheral {
            logEvent("Disconnecting from \(p.name ?? p.identifier.uuidString)")
            central.cancelPeripheralConnection(p)
        }
        cleanupConnection()
        state = central.state == .poweredOn ? .idle : state
    }

    /// Try to reconnect to the previously used meter without scanning.
    func reconnectLastDevice() {
        guard central.state == .poweredOn,
              let s = UserDefaults.standard.string(forKey: Self.lastDeviceKey),
              let id = UUID(uuidString: s),
              let p = central.retrievePeripherals(withIdentifiers: [id]).first else {
            logEvent("reconnectLastDevice: nothing to reconnect to")
            return
        }
        connect(peripheral: p, name: p.name ?? "FNB58")
    }

    var hasLastDevice: Bool {
        UserDefaults.standard.string(forKey: Self.lastDeviceKey) != nil
    }

    func startRecording(name: String) {
        recording = SessionRecorder(name: name, deviceName: state.label)
        logEvent("Recording started: \(name)")
    }

    @discardableResult
    func stopRecording() -> Session? {
        defer { recording = nil }
        logEvent("Recording stopped (\(recording?.readings.count ?? 0) samples)")
        return recording?.finish()
    }

    func clearHistory() {
        history.removeAll()
    }

    func clearLog() {
        log.removeAll()
        framesReceived = 0
        framesParsed = 0
        lastFrameHex = ""
    }

    /// Plain-text dump for copy/share.
    var diagnosticsText: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        var out = "WattBench diagnostics\n"
        out += "State: \(state.label)\n"
        if let e = lastError { out += "Last error: \(e)\n" }
        out += "Frames received: \(framesReceived), parsed: \(framesParsed)\n"
        out += "Last frame: \(lastFrameHex)\n"
        out += "GATT:\n" + discoveredGATT.map { "  " + $0 }.joined(separator: "\n") + "\n"
        out += "Log:\n" + log.map { "  \(f.string(from: $0.time)) \($0.message)" }.joined(separator: "\n")
        return out
    }

    // MARK: - Demo source (also lets App Review see the UI without a meter)

    func startDemo() {
        disconnect()
        state = .demo
        logEvent("Demo data started")
        demoTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            demoPhase += 0.1
            let v = 9.0 + 0.05 * sin(demoPhase * 0.7)
            let i = max(0, 1.2 + 0.8 * sin(demoPhase * 0.25) + 0.05 * sin(demoPhase * 5))
            ingest(Reading(timestamp: Date(), voltage: v, current: i, power: v * i))
        }
    }

    private func stopDemo() {
        demoTimer?.invalidate()
        demoTimer = nil
        if state == .demo { state = .idle }
    }

    // MARK: - Internals

    private func connect(peripheral p: CBPeripheral, name: String) {
        stopScan()
        stopDemo()
        peripheral = p
        p.delegate = self
        wantsAutoReconnect = true
        lastError = nil
        discoveredGATT.removeAll()
        didStartStreaming = false
        state = .connecting(name)
        logEvent("Connecting to \(name) (\(p.identifier.uuidString.prefix(8)))")
        central.connect(p, options: nil)
    }

    private func restartScan() {
        central.stopScan()
        startScan()
    }

    private func cleanupConnection() {
        peripheral?.delegate = nil
        peripheral = nil
        writeCharacteristic = nil
        notifyCharacteristic = nil
        didStartStreaming = false
    }

    /// Once both characteristics are known, enable notifications and send the
    /// init commands. They may live in different services, so this is called
    /// after every characteristic-discovery callback.
    private func startStreamingIfReady(_ peripheral: CBPeripheral) {
        guard !didStartStreaming, let w = writeCharacteristic, let n = notifyCharacteristic else { return }
        didStartStreaming = true
        peripheral.setNotifyValue(true, for: n)
        let type: CBCharacteristicWriteType = w.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        for cmd in FNB58Protocol.initCommands {
            peripheral.writeValue(cmd, for: w, type: type)
            logEvent("Wrote \(hex(cmd)) to \(w.uuid) (\(type == .withResponse ? "with" : "without") response)")
        }
        state = .connected(peripheral.name ?? "FNB58")
        lastError = nil
    }

    fileprivate func ingest(_ r: Reading) {
        latest = r
        history.append(r)
        if history.count > Self.historyLimit {
            history.removeFirst(history.count - Self.historyLimit)
        }
        recording?.add(r)
    }

    private func fail(_ message: String) {
        lastError = message
        logEvent("ERROR: \(message)")
        cleanupConnection()
        state = central.state == .poweredOn ? .idle : state
    }

    private func logEvent(_ message: String) {
        log.append(LogEntry(time: Date(), message: message))
        if log.count > Self.logLimit {
            log.removeFirst(log.count - Self.logLimit)
        }
    }

    private func hex(_ data: Data, limit: Int = 64) -> String {
        let shown = data.prefix(limit).map { String(format: "%02x", $0) }.joined(separator: " ")
        return data.count > limit ? shown + " … (\(data.count) bytes)" : shown
    }

    private func describe(_ p: CBCharacteristicProperties) -> String {
        var parts: [String] = []
        if p.contains(.read) { parts.append("read") }
        if p.contains(.write) { parts.append("write") }
        if p.contains(.writeWithoutResponse) { parts.append("writeNoRsp") }
        if p.contains(.notify) { parts.append("notify") }
        if p.contains(.indicate) { parts.append("indicate") }
        return parts.joined(separator: ",")
    }
}

// MARK: - CBCentralManagerDelegate

extension MeterManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        logEvent("Bluetooth state: \(central.state.rawValue) (\(central.state == .poweredOn ? "on" : "not on"))")
        switch central.state {
        case .poweredOn:
            if state == .bluetoothOff || state == .unauthorized { state = .idle }
            if wantsAutoReconnect { reconnectLastDevice() }
        case .unauthorized:
            state = .unauthorized
        case .poweredOff, .resetting, .unsupported, .unknown:
            if state != .demo { state = .bluetoothOff }
        @unknown default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        guard let name = peripheral.name ?? advName, !name.isEmpty else { return }
        if !showAllDevices, !name.localizedCaseInsensitiveContains(FNB58Protocol.nameFilter) { return }

        let now = Date()
        if let idx = devices.firstIndex(where: { $0.id == peripheral.identifier }) {
            devices[idx].rssi = RSSI.intValue
            devices[idx].lastSeen = now
        } else {
            devices.append(DiscoveredDevice(id: peripheral.identifier, name: name, rssi: RSSI.intValue, lastSeen: now))
            let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?.map(\.uuidString).joined(separator: ",") ?? "none"
            logEvent("Found \(name) RSSI \(RSSI.intValue) adv services: \(services)")
        }
        devices.sort { $0.rssi > $1.rssi }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.lastDeviceKey)
        logEvent("Connected to \(peripheral.name ?? "?"); discovering services")
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        fail(error?.localizedDescription ?? "Failed to connect")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let name = peripheral.name ?? "FNB58"
        logEvent("Disconnected from \(name)\(error.map { ": \($0.localizedDescription)" } ?? "")")
        cleanupConnection()
        if wantsAutoReconnect {
            // Unexpected drop (meter powered off, out of range): keep trying.
            lastError = error?.localizedDescription
            state = .connecting(name)
            self.peripheral = peripheral
            peripheral.delegate = self
            central.connect(peripheral, options: nil)
        } else {
            state = .idle
        }
    }
}

// MARK: - CBPeripheralDelegate

extension MeterManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { return fail("Service discovery failed: \(error.localizedDescription)") }
        guard let services = peripheral.services, !services.isEmpty else {
            return fail("No services found on device")
        }
        logEvent("Services: " + services.map { $0.uuid.uuidString }.joined(separator: ", "))
        for s in services {
            // Discover everything so the diagnostics screen shows the full GATT table.
            peripheral.discoverCharacteristics(nil, for: s)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error { return fail("Characteristic discovery failed: \(error.localizedDescription)") }
        for c in service.characteristics ?? [] {
            discoveredGATT.append("\(service.uuid) → \(c.uuid) [\(describe(c.properties))]")
            if c.uuid == FNB58Protocol.writeUUID {
                writeCharacteristic = c
            } else if c.uuid == FNB58Protocol.notifyUUID {
                notifyCharacteristic = c
            }
        }
        startStreamingIfReady(peripheral)
        if !didStartStreaming, peripheral.services?.allSatisfy({ $0.characteristics != nil }) == true {
            fail("Meter does not expose the expected characteristics (\(FNB58Protocol.writeUUID) / \(FNB58Protocol.notifyUUID)). See Diagnostics.")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            fail("Could not enable notifications: \(error.localizedDescription)")
        } else {
            logEvent("Notifications \(characteristic.isNotifying ? "enabled" : "disabled") on \(characteristic.uuid)")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { logEvent("Write to \(characteristic.uuid) failed: \(error.localizedDescription)") }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            logEvent("Value update error on \(characteristic.uuid): \(error.localizedDescription)")
            return
        }
        guard characteristic.uuid == FNB58Protocol.notifyUUID, let data = characteristic.value else { return }
        framesReceived += 1
        lastFrameHex = hex(data)
        if framesReceived <= 5 {
            logEvent("Frame #\(framesReceived) (\(data.count) B): \(lastFrameHex)")
        }
        guard let reading = FNB58Protocol.parse(data) else {
            if framesReceived <= 5 { logEvent("Frame #\(framesReceived) rejected by parser") }
            return
        }
        framesParsed += 1
        if framesParsed == 1 {
            logEvent(String(format: "First reading: %.4f V  %.4f A  %.4f W", reading.voltage, reading.current, reading.power))
        }
        ingest(reading)
    }
}
