import Foundation

/// The decision behind `centralManager(_:willRestoreState:)`, kept free of
/// CoreBluetooth objects so it can be unit tested (a `CBPeripheral` cannot be
/// faked). `MeterManager` turns the restored peripherals into snapshots,
/// asks for a plan and applies it; the glue itself is verified on a device.
///
/// `willRestoreState` arrives before the central reports `.poweredOn`, so a
/// `.reconnect` plan only records the peripheral: the connect is issued from
/// `centralManagerDidUpdateState`.
enum RestorePlan: Equatable {
    /// The restore identifier passed to `CBCentralManager`.
    static let identifier = "com.thebench.wattbench.central"

    /// What CoreBluetooth handed back for one peripheral.
    struct PeripheralSnapshot: Equatable {
        var id: UUID
        var name: String?
        /// `CBPeripheral.state == .connected`.
        var isConnected: Bool
        /// Both the write (`ffe9`) and notify (`ffe4`) characteristics are
        /// already present on the restored service objects.
        var hasCharacteristics: Bool
    }

    /// Nothing was restored.
    case nothing
    /// The link and the GATT table survived: adopt the peripheral and start
    /// streaming again (notifications may need to be re-enabled).
    case resumeStreaming(UUID)
    /// The link survived but the characteristics are unknown: adopt it and
    /// discover services again.
    case rediscoverServices(UUID)
    /// The link is down: adopt the peripheral and reconnect once powered on.
    case reconnect(UUID)

    /// Uses the first restored peripheral (the app only ever connects to one).
    static func make(_ peripherals: [PeripheralSnapshot]) -> RestorePlan {
        guard let p = peripherals.first else { return .nothing }
        if p.isConnected {
            return p.hasCharacteristics ? .resumeStreaming(p.id) : .rediscoverServices(p.id)
        }
        return .reconnect(p.id)
    }

    /// The peripheral the plan adopts, if any.
    var peripheralID: UUID? {
        switch self {
        case .nothing: return nil
        case .resumeStreaming(let id), .rediscoverServices(let id), .reconnect(let id): return id
        }
    }

    /// One line for the diagnostics log.
    var description: String {
        switch self {
        case .nothing: return "nothing to restore"
        case .resumeStreaming(let id): return "resume streaming on \(id.uuidString.prefix(8))"
        case .rediscoverServices(let id): return "rediscover services on \(id.uuidString.prefix(8))"
        case .reconnect(let id): return "reconnect to \(id.uuidString.prefix(8)) once powered on"
        }
    }
}
