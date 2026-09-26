import SwiftUI

/// Semantic colours for the three metrics (colorsets in Assets.xcassets:
/// light system hues, dark #5AC8FA / #FF9F0A / #30D158 so lines do not glow
/// on OLED). Accent stays for interactive chrome; red only for Record/Stop,
/// destructive actions and fired alerts; purple only for Demo.
extension Color {
    static let voltage = Color("Voltage")
    static let current = Color("Current")
    static let power = Color("Power")

    /// The one colour reserved for demo data (pill, banner).
    static let demo = Color(uiColor: .systemPurple)
}

extension Metric {
    var color: Color { Color(colorName) }

    /// Fill under a chart line: metric colour fading from 25 percent to clear.
    var areaGradient: LinearGradient {
        LinearGradient(colors: [color.opacity(0.25), color.opacity(0)], startPoint: .top, endPoint: .bottom)
    }
}

extension ConnectionState {
    /// Pill / status tint derived from `tintToken`. Status colours are system
    /// hues, deliberately not the metric colorsets.
    var tint: Color {
        switch tintToken {
        case "green": return Color(uiColor: .systemGreen)
        case "orange": return Color(uiColor: .systemOrange)
        case "purple": return .demo
        case "red": return Color(uiColor: .systemRed)
        default: return .secondary
        }
    }
}

/// The type scale from the UI direction, so every screen uses the same
/// modifiers for labels, tile values and table values.
extension View {
    /// Small uppercase tracked caption used above readouts and tiles.
    func metricLabelStyle() -> some View {
        font(.caption2.weight(.semibold))
            .textCase(.uppercase)
            .tracking(0.8)
            .foregroundStyle(.secondary)
    }

    /// Secondary tile / stat tile value.
    func tileValueStyle() -> some View {
        font(.system(.title2, design: .rounded).weight(.semibold).monospacedDigit())
    }

    /// Value column in tables and rows.
    func tableValueStyle() -> some View {
        font(.callout.monospacedDigit())
    }

    /// Card background from the UI direction: secondary grouped background,
    /// 20pt continuous corners, 16pt inner padding.
    func cardStyle() -> some View {
        padding(16)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 20, style: .continuous))
    }
}
