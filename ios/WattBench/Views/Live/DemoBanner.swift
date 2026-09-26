import SwiftUI

/// Thin, persistent strip under the navigation bar while demo data runs so
/// simulated readings can never be mistaken for a meter.
struct DemoBanner: View {
    var body: some View {
        Label("Demo data · simulated readings", systemImage: "play.circle")
            .font(.caption.weight(.medium))
            .foregroundStyle(.purple)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .background(.purple.opacity(0.12))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Demo data, simulated readings")
    }
}
