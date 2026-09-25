import SwiftUI

/// Keep / Discard prompt for a recording that was interrupted by a crash or
/// force-quit. Stub (WS-A fills it in); `init(summary:)` is frozen.
struct RecoverySheet: View {
    let summary: SessionSummary

    var body: some View {
        EmptyView()
    }
}
