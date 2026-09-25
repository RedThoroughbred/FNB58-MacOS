import SwiftUI

/// Semantic colours for the three metrics (colorsets in Assets.xcassets:
/// light system hues, dark #5AC8FA / #FF9F0A / #30D158). Accent stays for
/// interactive chrome; red only for Record/Stop, destructive actions and
/// fired alerts; purple only for Demo.
extension Color {
    static let voltage = Color("Voltage")
    static let current = Color("Current")
    static let power = Color("Power")
}

extension Metric {
    var color: Color { Color(colorName) }
}

extension ConnectionState {
    /// Pill / status tint derived from `tintToken`.
    var tint: Color {
        switch tintToken {
        case "green": return .green
        case "orange": return .orange
        case "purple": return .purple
        case "red": return .red
        default: return .secondary
        }
    }
}
