import Foundation

/// Ready-made rule sets offered by the Alerts screen. Applying one adds its
/// rules (skipping any that are already present).
enum AlertPreset: String, CaseIterable, Identifiable {
    case usbC65W, fiveVoltDevice, powerBankDrain

    var id: String { rawValue }

    var title: String {
        switch self {
        case .usbC65W: return "USB-C 65 W"
        case .fiveVoltDevice: return "5 V device"
        case .powerBankDrain: return "Power bank drain"
        }
    }

    var symbolName: String {
        switch self {
        case .usbC65W: return "bolt.fill"
        case .fiveVoltDevice: return "powerplug.fill"
        case .powerBankDrain: return "battery.25percent"
        }
    }

    var rules: [AlertRule] {
        switch self {
        case .usbC65W:
            return [
                AlertRule(.overVoltage, value: 21),
                AlertRule(.overCurrent, value: 3.5),
                AlertRule(.overPower, value: 70),
                AlertRule(.voltageDrop, value: 1),
            ]
        case .fiveVoltDevice:
            return [
                AlertRule(.underVoltage, value: 4.75),
                AlertRule(.overCurrent, value: 3),
            ]
        case .powerBankDrain:
            return [
                AlertRule(.currentBelow, value: 0.05, seconds: 60),
                AlertRule(.disconnected, value: 0, seconds: 60),
            ]
        }
    }

    /// "Voltage above 21 V · Current above 3.5 A · …" for the menu subtitle.
    func summary(formatter: MetricFormatter) -> String {
        rules.map { $0.summary(formatter: formatter) }.joined(separator: " · ")
    }
}
