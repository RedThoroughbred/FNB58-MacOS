import Foundation

/// Seconds on `ContinuousClock` relative to a process-static origin. Live
/// readings are stamped with this so integration and journal offsets are
/// immune to wall-clock adjustments. Values are always > 0 once the origin
/// has been taken; 0 means "no monotonic stamp" throughout the model.
enum MonotonicClock {
    private static let origin = ContinuousClock.now

    static var now: TimeInterval {
        let d = ContinuousClock.now - origin
        // 1 s head start keeps the very first stamp clearly non-zero.
        return 1 + Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    /// Forces the origin to be taken now (call once at launch).
    static func prime() {
        _ = now
    }
}
