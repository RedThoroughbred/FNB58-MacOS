import Foundation

/// Maps a BLE RSSI (dBm) onto the 0...1 `variableValue` of the system
/// `cellularbars` symbol, so the Connect sheet needs no custom bar drawing.
enum SignalLevel {
    static func level(rssi: Int) -> Double {
        // CoreBluetooth reports 127 (or any non-negative value) when the RSSI
        // is unavailable; show that as the weakest level rather than full bars.
        guard rssi < 0 else { return 0.25 }
        if rssi >= -55 { return 1.0 }
        if rssi >= -67 { return 0.75 }
        if rssi >= -80 { return 0.5 }
        return 0.25
    }

    /// Spoken strength for VoiceOver.
    static func description(rssi: Int) -> String {
        switch level(rssi: rssi) {
        case 1.0: return "excellent signal"
        case 0.75: return "good signal"
        case 0.5: return "fair signal"
        default: return "weak signal"
        }
    }
}

/// The Connect sheet's zero-tap decision: after the first discovery has
/// settled for `settleDelay`, connect automatically only when exactly one
/// device is listed, it is an FNB58, and the user has not touched the list.
enum ConnectAutoSelect {
    static let settleDelay: TimeInterval = 1.5

    static func candidate(in devices: [DiscoveredDevice], userInteracted: Bool) -> DiscoveredDevice? {
        guard !userInteracted, devices.count == 1, let only = devices.first,
              only.name.localizedCaseInsensitiveContains(FNB58Protocol.nameFilter) else { return nil }
        return only
    }
}
