import Foundation

/// Receives every reading after the pipeline has updated its own state
/// (threshold monitors, alert coordinator).
protocol SampleObserver: AnyObject {
    @MainActor func observe(_ r: Reading, context: SampleContext)
}

struct SampleContext {
    /// Interval since the previous reading (0 for the first).
    let dt: TimeInterval
    let isRecording: Bool
    let recordingStats: SessionStats?
    let connection: ConnectionState
}
