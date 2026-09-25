import Foundation

/// The three quantities the meter reports.
enum Metric: String, CaseIterable, Codable, Identifiable {
    case voltage, current, power

    var id: String { rawValue }

    var title: String {
        switch self {
        case .voltage: return "Voltage"
        case .current: return "Current"
        case .power: return "Power"
        }
    }

    /// Base unit symbol.
    var symbol: String {
        switch self {
        case .voltage: return "V"
        case .current: return "A"
        case .power: return "W"
        }
    }

    /// Name of the colorset in Assets.xcassets.
    var colorName: String {
        switch self {
        case .voltage: return "Voltage"
        case .current: return "Current"
        case .power: return "Power"
        }
    }

    /// Unit name for VoiceOver.
    var spokenName: String {
        switch self {
        case .voltage: return "volts"
        case .current: return "amps"
        case .power: return "watts"
        }
    }

    func value(_ r: Reading) -> Double {
        switch self {
        case .voltage: return r.voltage
        case .current: return r.current
        case .power: return r.power
        }
    }
}
