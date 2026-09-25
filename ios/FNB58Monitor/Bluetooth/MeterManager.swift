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

    static let historyLimit = 1200
    private static let lastDeviceKey = "lastDeviceIdentifier"

    // MARK: Private
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var wantsAutoReconnect = false
    private var demoTimer: Timer?
    private var demoPhase = 0.0

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }

    // MARK: - Public API

    func startScan() {
        guard central.state == .poweredOn else { return }
        devices.removeAll()
        state = .scanning
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
            return
        }
        connect(peripheral: p, name: device.name)
    }

    func disconnect() {
        wantsAutoReconnect = false
        stopDemo()
        if let p = peripheral {
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
              let p = central.retrievePeripherals(withIdentifiers: [id]).first else { return }
        connect(peripheral: p, name: p.name ?? "FNB58")
    }

    var hasLastDevice: Bool {
        UserDefaults.standard.string(forKey: Self.lastDeviceKey) != nil
    }

    func startRecording(name: String) {
        recording = SessionRecorder(name: name, deviceName: state.label)
    }

    @discardableResult
    func stopRecording() -> Session? {
        defer { recording = nil }
        return recording?.finish()
    }

    func clearHistory() {
        history.removeAll()
    }

    // MARK: - Demo source (simulator has no Bluetooth)

    func startDemo() {
        disconnect()
        state = .demo
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
        state = .connecting(name)
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
        cleanupConnection()
        state = central.state == .poweredOn ? .idle : state
    }
}

// MARK: - CBCentralManagerDelegate

extension MeterManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
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
        }
        devices.sort { $0.rssi > $1.rssi }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.lastDeviceKey)
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        fail(error?.localizedDescription ?? "Failed to connect")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let name = peripheral.name ?? "FNB58"
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
        for s in services {
            peripheral.discoverCharacteristics([FNB58Protocol.writeUUID, FNB58Protocol.notifyUUID], for: s)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error { return fail("Characteristic discovery failed: \(error.localizedDescription)") }
        for c in service.characteristics ?? [] {
            if c.uuid == FNB58Protocol.writeUUID {
                writeCharacteristic = c
            } else if c.uuid == FNB58Protocol.notifyUUID {
                peripheral.setNotifyValue(true, for: c)
            }
        }
        // Once both ends are known, kick off streaming.
        if let w = writeCharacteristic,
           service.characteristics?.contains(where: { $0.uuid == FNB58Protocol.notifyUUID }) == true {
            let type: CBCharacteristicWriteType = w.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
            for cmd in FNB58Protocol.initCommands {
                peripheral.writeValue(cmd, for: w, type: type)
            }
            state = .connected(peripheral.name ?? "FNB58")
            lastError = nil
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error { fail("Could not enable notifications: \(error.localizedDescription)") }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, characteristic.uuid == FNB58Protocol.notifyUUID,
              let data = characteristic.value,
              let reading = FNB58Protocol.parse(data) else { return }
        ingest(reading)
    }
}
