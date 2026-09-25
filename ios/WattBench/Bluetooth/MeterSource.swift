import Foundation

/// Anything that produces readings for `MeterManager.ingest`: the BLE
/// notification path, the demo generator, a fixture replay in tests.
protocol MeterSource: AnyObject {
    var onReading: ((Reading) -> Void)? { get set }
    func start()
    func stop()
}

/// Connection state shown by the status pill and the Connect sheet.
/// The cases are frozen for 1.1.
enum ConnectionState: Equatable {
    case bluetoothOff
    case unauthorized
    case idle
    case scanning
    case connecting(String)
    case connected(String)
    /// The meter dropped; a `connect` is pending with CoreBluetooth since `since`.
    case reconnecting(name: String, since: Date)
    /// No connection for `ReconnectPolicy.giveUpAfter` seconds.
    case unreachable(String)
    case demo

    var isConnected: Bool {
        switch self {
        case .connected, .demo: return true
        default: return false
        }
    }

    /// True while the state will change by itself (scanning, connecting, reconnecting).
    var isTransient: Bool {
        switch self {
        case .scanning, .connecting, .reconnecting: return true
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
        case .reconnecting(let n, _): return "Reconnecting to \(n)…"
        case .unreachable(let n): return "\(n) is unreachable"
        case .demo: return "Demo data"
        }
    }

    var shortLabel: String {
        switch self {
        case .bluetoothOff: return "Bluetooth off"
        case .unauthorized: return "No access"
        case .idle: return "Not connected"
        case .scanning: return "Scanning"
        case .connecting: return "Connecting"
        case .connected(let n): return n
        case .reconnecting: return "Reconnecting"
        case .unreachable: return "Unreachable"
        case .demo: return "Demo"
        }
    }

    var symbolName: String {
        switch self {
        case .bluetoothOff, .idle: return "antenna.radiowaves.left.and.right.slash"
        case .unauthorized, .unreachable: return "exclamationmark.triangle"
        case .scanning, .connecting, .connected: return "antenna.radiowaves.left.and.right"
        case .reconnecting: return "arrow.clockwise"
        case .demo: return "play.circle"
        }
    }

    /// "green", "orange", "gray", "purple" or "red"; mapped to a Color by WS-D.
    var tintToken: String {
        switch self {
        case .connected: return "green"
        case .scanning, .connecting, .reconnecting: return "orange"
        case .bluetoothOff, .idle: return "gray"
        case .demo: return "purple"
        case .unauthorized, .unreachable: return "red"
        }
    }
}
