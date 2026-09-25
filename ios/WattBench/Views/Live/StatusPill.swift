import SwiftUI

/// Connection state where FaceTime and Fitness put it: a material capsule in
/// the leading toolbar slot. Tapping opens the Connect sheet; while
/// unreachable a Retry button re-issues the pending connect.
struct StatusPill: View {
    /// From the parent's 1 Hz staleness check (only meaningful while connected).
    let isStale: Bool
    let onTap: () -> Void

    @Environment(MeterManager.self) private var meter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let state = meter.state
        let stale = state.isConnected && isStale && HeroState.isStale(latest: meter.display.latest?.timestamp, now: Date())
        HStack(spacing: 8) {
            Button(action: onTap) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(state.tint)
                        .frame(width: 8, height: 8)
                    Image(systemName: state.symbolName)
                        .font(.footnote)
                        .symbolEffect(.variableColor.iterative.reversing, isActive: state.isTransient && !reduceMotion)
                        .symbolEffect(.bounce, value: meter.connectionEventCount)
                    Text(stale ? "No data" : state.shortLabel)
                        .font(.footnote.weight(.medium))
                        .lineLimit(1)
                        .fixedSize()
                    if case .reconnecting(_, let since) = state {
                        Text(timerInterval: since...Date.distantFuture, countsDown: false)
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .frame(minHeight: 32)
                .floatingChrome(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Connection")
            .accessibilityValue(stale ? "\(state.label), no recent data" : state.label)
            .accessibilityHint("Opens the Connect sheet")

            if case .unreachable = state {
                Button("Retry", systemImage: "arrow.clockwise") { meter.retryNow() }
                    .labelStyle(.iconOnly)
                    .font(.footnote.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .accessibilityLabel("Retry connection")
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: state)
    }
}
