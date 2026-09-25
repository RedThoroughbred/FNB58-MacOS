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

/// Owns the CoreBluetooth central, the sample pipeline, the trip meter and
/// the session recorder. Everything runs on the main actor (the central is
/// created with the main queue).
///
/// Reconnect: on an unexpected disconnect a `connect` is issued at once and
/// left PENDING with CoreBluetooth, which completes it whenever the meter
/// reappears (also in the background with `bluetooth-central`). The displayed
/// state goes `.reconnecting` -> `.unreachable` after
/// `ReconnectPolicy.giveUpAfter` seconds; the pending connect is only
/// cancelled at that point when no recording is in progress.
@MainActor
@Observable
final class MeterManager: NSObject {
    // MARK: Published state
    private(set) var state: ConnectionState = .idle
    private(set) var devices: [DiscoveredDevice] = []
    /// Every reading at the meter's own rate (10 Hz). Views should prefer
    /// `display.latest`, which is throttled to 5 Hz.
    private(set) var latest: Reading?
    /// Readouts, trip and recording statistics and extremes, at most 5 Hz.
    private(set) var display = DisplayFrame.empty
    /// The live chart's window, at most 5 Hz.
    private(set) var chart = ChartSnapshot.empty
    /// One always-on trip meter, persisted across launches.
    private(set) var trips: [TripMeter]
    /// Peak-hold values since the last reset; assigned only when they change.
    private(set) var extremes: Extremes
    private(set) var recording: SessionRecorder?
    private(set) var lastError: String?
    private(set) var connectionEventCount = 0
    private(set) var recordingEventCount = 0
    private(set) var errorEventCount = 0
    private(set) var tripResetCount = 0

    /// Single owner of this setting (persisted here, not in Preferences).
    var showAllDevices: Bool {
        didSet {
            defaults.set(showAllDevices, forKey: Self.showAllDevicesKey)
            if state == .scanning { restartScan() }
        }
    }
    /// Connect to the last meter as soon as Bluetooth is powered on.
    var autoConnectOnLaunch = true
    /// Mirrors `Preferences.excludeDemoFromTrips` into the pipeline.
    var excludeDemoFromTrips: Bool {
        get { pipeline.excludeDemoFromTrips }
        set { pipeline.excludeDemoFromTrips = newValue }
    }
    /// Invoked for every non-discarded stop (manual, auto-stop, notification
    /// action). `WattBenchApp` wires it to `SessionStore.save`.
    @ObservationIgnored var onRecordingStopped: (@MainActor (Session, AutoStopRule.Reason?) -> Void)?

    var isDemo: Bool { state == .demo }

    var hasLastDevice: Bool {
        defaults.string(forKey: Self.lastDeviceKey) != nil
    }

    // MARK: Diagnostics (visible in the Diagnostics screen; no Xcode needed)
    private(set) var log: [LogEntry] = []
    private(set) var discoveredGATT: [String] = []
    private(set) var framesReceived = 0
    private(set) var framesParsed = 0
    private(set) var lastFrameHex = ""

    static let historyLimit = SamplePipeline.historyCapacity
    private static let logLimit = 400
    private static let lastDeviceKey = "lastDeviceIdentifier"
    private static let showAllDevicesKey = "showAllDevices"
    private static let tripKey = "trip.0"
    private static let tripPersistInterval: TimeInterval = 10

    // MARK: Private
    @ObservationIgnored private var central: CBCentralManager!
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var writeCharacteristic: CBCharacteristic?
    @ObservationIgnored private var notifyCharacteristic: CBCharacteristic?
    @ObservationIgnored private var didStartStreaming = false
    @ObservationIgnored private var wantsAutoReconnect = false
    @ObservationIgnored private var didAutoConnect = false
    @ObservationIgnored private var demoTimer: Timer?
    @ObservationIgnored private var demoPhase = 0.0
    @ObservationIgnored private var reconnectTimer: Timer?
    @ObservationIgnored private var reconnectPolicy = ReconnectPolicy()
    @ObservationIgnored private let pipeline: SamplePipeline
    @ObservationIgnored private var observers: [any SampleObserver] = []
    @ObservationIgnored private var source: (any MeterSource)?
    @ObservationIgnored private var lastDisplayGeneration = 0
    @ObservationIgnored private var lastTripPersist = Date.distantPast
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let trip = Self.loadTrip(from: defaults)
        pipeline = SamplePipeline(trips: [trip], extremes: Extremes(since: Date()))
        trips = pipeline.trips
        extremes = pipeline.extremes
        showAllDevices = defaults.bool(forKey: Self.showAllDevicesKey)
        super.init()
        MonotonicClock.prime()
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: false])
        logEvent("App started")
    }

    // MARK: - Scanning and connecting

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
        stopReconnectTimer()
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
        guard central.state == .poweredOn, let p = lastPeripheral() else {
            logEvent("reconnectLastDevice: nothing to reconnect to")
            return
        }
        connect(peripheral: p, name: p.name ?? "FNB58")
    }

    /// Re-issues the pending connect (from `.reconnecting` or `.unreachable`),
    /// or connects to the last meter.
    func retryNow() {
        switch state {
        case .reconnecting(let name, _), .unreachable(let name):
            guard let p = peripheral ?? lastPeripheral() else {
                reconnectLastDevice()
                return
            }
            peripheral = p
            p.delegate = self
            wantsAutoReconnect = true
            state = .reconnecting(name: name, since: Date())
            startReconnectTimer()
            logEvent("Retrying connection to \(name)")
            central.connect(p, options: nil)
        default:
            reconnectLastDevice()
        }
    }

    /// Cancels any pending connect and forgets the stored identifier.
    func forgetLastDevice() {
        defaults.removeObject(forKey: Self.lastDeviceKey)
        switch state {
        case .connecting, .reconnecting, .unreachable:
            wantsAutoReconnect = false
            stopReconnectTimer()
            if let p = peripheral { central.cancelPeripheralConnection(p) }
            cleanupConnection()
            state = central.state == .poweredOn ? .idle : state
        default:
            break
        }
        logEvent("Forgot last meter")
    }

    // MARK: - Recording

    func startRecording(name: String, tags: [String] = [], notes: String? = nil, autoStop: AutoStopRule? = nil) {
        if recording != nil { stopRecording() }
        recording = SessionRecorder(name: name, deviceName: state.label, tags: tags, notes: notes,
                                    autoStop: autoStop, isDemo: state == .demo)
        recordingEventCount += 1
        logEvent("Recording started: \(name)\(autoStop != nil ? " (auto-stop armed)" : "")")
    }

    /// Ends the recording. Unless `discard` is set, the finished session is
    /// handed to `onRecordingStopped` (which saves it) and returned.
    /// `reason` is an `AutoStopRule.Reason` raw value when a rule fired.
    @discardableResult
    func stopRecording(discard: Bool = false, reason: String? = nil) -> Session? {
        guard let rec = recording else { return nil }
        recording = nil
        rec.journal?.close()
        recordingEventCount += 1
        if discard {
            logEvent("Recording discarded (\(rec.stats.samples) samples)")
            return nil
        }
        var session = rec.finish()
        if let reason { session.autoStopReason = reason }
        logEvent("Recording stopped (\(session.sampleCount) samples)\(reason.map { ", reason: \($0)" } ?? "")")
        onRecordingStopped?(session, reason.flatMap(AutoStopRule.Reason.init(rawValue:)))
        persistTrips()
        return session
    }

    func addMarker(label: String) {
        guard let rec = recording else { return }
        rec.addMarker(label: label)
        logEvent("Marker: \(label)")
    }

    // MARK: - Pipeline

    func addObserver(_ observer: any SampleObserver) {
        guard !observers.contains(where: { $0 === observer }) else { return }
        observers.append(observer)
    }

    /// Routes a source's readings into `ingest`, replacing any previous source.
    func attach(source: any MeterSource) {
        self.source?.stop()
        self.source = source
        source.onReading = { [weak self] r in self?.ingest(r) }
        source.start()
    }

    /// Feeds one reading through the pipeline. Internal so tests can drive it.
    func ingest(_ r: Reading) {
        latest = r
        if let snapshot = pipeline.ingest(r, recording: recording, observers: observers, connection: state) {
            chart = snapshot
        }
        if pipeline.displayGeneration != lastDisplayGeneration {
            lastDisplayGeneration = pipeline.displayGeneration
            display = pipeline.display
            trips = pipeline.trips
            if Date().timeIntervalSince(lastTripPersist) >= Self.tripPersistInterval { persistTrips() }
        }
        if pipeline.extremes != extremes { extremes = pipeline.extremes }
        if let reason = pipeline.takeAutoStop() {
            logEvent("Auto-stop: \(reason.label)")
            stopRecording(reason: reason.rawValue)
        }
    }

    func resetTrip(_ index: Int) {
        guard pipeline.trips.indices.contains(index) else { return }
        pipeline.trips[index].reset()
        trips = pipeline.trips
        tripResetCount += 1
        persistTrips()
        logEvent("Trip \(index) reset")
    }

    func resetExtremes() {
        pipeline.extremes.reset()
        extremes = pipeline.extremes
    }

    func clearHistory() {
        pipeline.clearHistory()
        chart = .empty
    }

    /// Writes the trip meter to UserDefaults (also called on backgrounding).
    func persistTrips() {
        if let trip = pipeline.trips.first, let data = try? JSONEncoder().encode(trip) {
            defaults.set(data, forKey: Self.tripKey)
        }
        lastTripPersist = Date()
    }

    // MARK: - Diagnostics

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
        out += "Events: connections \(connectionEventCount), recordings \(recordingEventCount), errors \(errorEventCount)\n"
        if let rec = recording {
            out += "Recording: \(rec.name) (\(rec.stats.samples) samples, \(rec.markers.count) markers)\n"
            if let j = rec.journal { out += "Journal: \(j.url.lastPathComponent), \(j.bytesWritten) bytes, last flush \(f.string(from: j.lastFlush))\n" }
        }
        out += "Last frame: \(lastFrameHex)\n"
        out += "GATT:\n" + discoveredGATT.map { "  " + $0 }.joined(separator: "\n") + "\n"
        out += "Log:\n" + log.map { "  \(f.string(from: $0.time)) \($0.message)" }.joined(separator: "\n")
        return out
    }

    // MARK: - Demo source (also lets App Review see the UI without a meter)

    /// Foreground only: the timer does not fire while the app is suspended.
    func startDemo() {
        disconnect()
        state = .demo
        logEvent("Demo data started (foreground only)")
        demoTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.demoTick() }
        }
    }

    private func demoTick() {
        demoPhase += 0.1
        let v = 9.0 + 0.05 * sin(demoPhase * 0.7)
        let i = max(0, 1.2 + 0.8 * sin(demoPhase * 0.25) + 0.05 * sin(demoPhase * 5))
        ingest(Reading(timestamp: Date(), voltage: v, current: i, power: v * i, monotonic: MonotonicClock.now))
    }

    private func stopDemo() {
        demoTimer?.invalidate()
        demoTimer = nil
        if state == .demo { state = .idle }
    }

    // MARK: - Internals

    private static func loadTrip(from defaults: UserDefaults) -> TripMeter {
        if let data = defaults.data(forKey: tripKey), let trip = try? JSONDecoder().decode(TripMeter.self, from: data) {
            return trip
        }
        return TripMeter(label: "Trip")
    }

    private func lastPeripheral() -> CBPeripheral? {
        guard let s = defaults.string(forKey: Self.lastDeviceKey), let id = UUID(uuidString: s) else { return nil }
        return central.retrievePeripherals(withIdentifiers: [id]).first
    }

    private func connect(peripheral p: CBPeripheral, name: String) {
        stopScan()
        stopDemo()
        stopReconnectTimer()
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
        clearCharacteristics()
    }

    private func clearCharacteristics() {
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

    private func fail(_ message: String) {
        lastError = message
        errorEventCount += 1
        logEvent("ERROR: \(message)")
        stopReconnectTimer()
        cleanupConnection()
        state = central.state == .poweredOn ? .idle : state
    }

    // MARK: Reconnect display timer

    private func startReconnectTimer() {
        stopReconnectTimer()
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconnectTick() }
        }
    }

    private func stopReconnectTimer() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
    }

    private func reconnectTick() {
        guard case .reconnecting(let name, let since) = state else {
            stopReconnectTimer()
            return
        }
        guard Date().timeIntervalSince(since) >= ReconnectPolicy.giveUpAfter else { return }
        stopReconnectTimer()
        state = .unreachable(name)
        lastError = "Meter appears to be off or out of range"
        errorEventCount += 1
        logEvent("Gave up waiting for \(name) after \(Int(ReconnectPolicy.giveUpAfter)) s")
        if recording == nil, let p = peripheral {
            // Not recording: stop waiting. While recording the pending connect
            // stays so a meter that comes back later resumes the session.
            central.cancelPeripheralConnection(p)
            logEvent("Cancelled pending connect (not recording)")
        } else if recording != nil {
            logEvent("Recording in progress; pending connect left in place")
        }
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
// The central runs on the main queue, so the main-actor witnesses are safe.

extension MeterManager: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        logEvent("Bluetooth state: \(central.state.rawValue) (\(central.state == .poweredOn ? "on" : "not on"))")
        switch central.state {
        case .poweredOn:
            if state == .bluetoothOff || state == .unauthorized { state = .idle }
            if wantsAutoReconnect {
                reconnectLastDevice()
            } else if autoConnectOnLaunch, !didAutoConnect, state == .idle, hasLastDevice {
                didAutoConnect = true
                logEvent("Auto-connecting to the last meter")
                reconnectLastDevice()
            }
        case .unauthorized:
            state = .unauthorized
        case .poweredOff, .resetting, .unsupported, .unknown:
            stopReconnectTimer()
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
        defaults.set(peripheral.identifier.uuidString, forKey: Self.lastDeviceKey)
        stopReconnectTimer()
        reconnectPolicy.reset()
        connectionEventCount += 1
        lastError = nil
        logEvent("Connected to \(peripheral.name ?? "?"); discovering services")
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        if case .reconnecting = state, wantsAutoReconnect, reconnectTimer != nil {
            // Keep the reconnect pending; the display timer still gives up at 120 s.
            logEvent("Reconnect attempt failed (\(error?.localizedDescription ?? "unknown")); connect re-issued")
            central.connect(peripheral, options: nil)
            return
        }
        fail(error?.localizedDescription ?? "Failed to connect")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let name = peripheral.name ?? "FNB58"
        logEvent("Disconnected from \(name)\(error.map { ": \($0.localizedDescription)" } ?? "")")
        if case .unreachable = state {
            // Our own cancellation of the pending connect after giving up.
            clearCharacteristics()
            return
        }
        guard wantsAutoReconnect else {
            cleanupConnection()
            state = .idle
            return
        }
        // Unexpected drop (meter powered off, out of range): keep the
        // peripheral and leave a connect pending with CoreBluetooth.
        clearCharacteristics()
        lastError = error?.localizedDescription
        self.peripheral = peripheral
        peripheral.delegate = self
        if case .reconnecting = state {
            // already counting
        } else {
            state = .reconnecting(name: name, since: Date())
            startReconnectTimer()
        }
        central.connect(peripheral, options: nil)
    }
}

// MARK: - CBPeripheralDelegate

extension MeterManager: @preconcurrency CBPeripheralDelegate {
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
        guard let reading = FNB58Protocol.parse(data, at: Date(), monotonic: MonotonicClock.now) else {
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
