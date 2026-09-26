import CoreBluetooth
import Foundation

/// FNIRSI FNB58 BLE protocol constants and frame parsing.
///
/// The meter exposes a UART-style GATT service. Two short commands written to
/// `ffe9` start streaming; each notification on `ffe4` carries voltage,
/// current and power as three little-endian Int32 values at byte offset 21,
/// scaled by 1/10000. (Reverse engineered; see parkerlreed's gist.)
enum FNB58Protocol {
    static let serviceUUID = CBUUID(string: "FFE0")
    static let writeUUID = CBUUID(string: "0000ffe9-0000-1000-8000-00805f9b34fb")
    static let notifyUUID = CBUUID(string: "0000ffe4-0000-1000-8000-00805f9b34fb")

    static let initCommands: [Data] = [
        Data([0xAA, 0x81, 0x00, 0xF4]),
        Data([0xAA, 0x82, 0x00, 0xA7]),
    ]

    static let frameOffset = 21
    static let scale = 10_000.0
    static let voltageRange = 0.0...150.0

    /// Substring matched (case-insensitively) against advertised names.
    static let nameFilter = "FNB58"

    /// Parse one notification frame. Returns nil for short frames or
    /// out-of-range voltages (the meter occasionally emits status frames on
    /// the same characteristic). `monotonic` is the `MonotonicClock` stamp
    /// for live frames (0 = none).
    static func parse(_ data: Data, at timestamp: Date = Date(), monotonic: TimeInterval = 0) -> Reading? {
        guard data.count >= frameOffset + 12 else { return nil }
        let base = data.startIndex + frameOffset
        func int32(_ i: Int) -> Int32 {
            let s = base + i * 4
            let u = UInt32(data[s]) | UInt32(data[s + 1]) << 8 | UInt32(data[s + 2]) << 16 | UInt32(data[s + 3]) << 24
            return Int32(bitPattern: u)
        }
        let voltage = Double(int32(0)) / scale
        let current = Double(int32(1)) / scale
        let power = Double(int32(2)) / scale
        guard voltageRange.contains(voltage) else { return nil }
        return Reading(timestamp: timestamp, voltage: voltage, current: current, power: power, monotonic: monotonic)
    }
}
