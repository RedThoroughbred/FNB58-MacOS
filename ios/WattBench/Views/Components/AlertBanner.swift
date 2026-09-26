import SwiftUI

/// Foreground alert banner placed by the Live tab via `safeAreaInset(edge: .top)`.
/// Shows the newest active alert as a floating capsule; Dismiss clears it and
/// reveals the previous one, if any. The zero-argument init is frozen.
struct AlertBanner: View {
    @Environment(AlertCoordinator.self) private var alerts
    @Environment(Preferences.self) private var prefs
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .top) {
            if let event = alerts.active.last {
                banner(event, more: alerts.active.count - 1)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .snappy, value: alerts.active.last?.id)
        .sensoryFeedback(.warning, trigger: alerts.alertEventCount) { old, new in
            new > old && prefs.hapticsEnabled && !reduceMotion
        }
    }

    private func banner(_ event: AlertEvent, more: Int) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(event.title)
                        .font(.subheadline.weight(.semibold))
                    if more > 0 {
                        Text("\(more) more")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(event.message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Alert: \(event.title). \(event.message)")
            Spacer(minLength: 4)
            Button("Dismiss") { alerts.dismiss(event.id) }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.borderless)
                .frame(minHeight: 44)
                .accessibilityLabel("Dismiss alert")
        }
        .padding(.leading, 16)
        .padding(.trailing, 14)
        .padding(.vertical, 6)
        .floatingChrome(Capsule())
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }
}
