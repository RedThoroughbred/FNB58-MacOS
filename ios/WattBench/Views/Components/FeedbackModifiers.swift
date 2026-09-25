import SwiftUI

// Foundation stub — WS-D owns the real implementation (sensoryFeedback keyed on
// MeterManager/SessionStore event counters, gated on accessibilityReduceMotion).
// Signatures are frozen; other streams may call these today and get no-ops.
extension View {
    func connectionFeedback(_ meter: MeterManager) -> some View { self }
    func recordingFeedback(_ meter: MeterManager) -> some View { self }
    func saveFeedback(_ store: SessionStore) -> some View { self }
}
