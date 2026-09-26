import SwiftUI

/// Red dot plus elapsed time shown in the Sessions tab's toolbar while a
/// recording runs; tapping it switches back to the Live tab. Renders nothing
/// when idle. The zero-argument init is frozen.
struct RecordingStatusChip: View {
    @Environment(MeterManager.self) private var meter
    @Environment(AppRouter.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let recording = meter.recording {
            Button {
                router.tab = .live
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.red)
                        .symbolEffect(.pulse, isActive: !reduceMotion)
                    Text(timerInterval: recording.startTime...Date.distantFuture, countsDown: false)
                        .font(.footnote.weight(.medium).monospacedDigit())
                        .foregroundStyle(.primary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .frame(minHeight: 32)
                .floatingChrome(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Recording in progress")
            .accessibilityHint("Shows the Live tab")
        }
    }
}
