import Foundation

/// Simulated readings so App Review and the Simulator (which has no radio)
/// can exercise every screen. A 9 V charger with a slowly varying load.
///
/// Foreground only: the timer does not fire while the app is suspended, so a
/// demo recording pauses in the background (the pipeline then reports the
/// pause as a gap). BLE readings keep arriving thanks to `bluetooth-central`.
@MainActor
final class DemoSource: MeterSource {
    static let interval: TimeInterval = 0.1

    var onReading: ((Reading) -> Void)?
    private var timer: Timer?
    private var phase = 0.0

    init() {}

    var isRunning: Bool { timer != nil }

    func start() {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        phase += Self.interval
        onReading?(Self.reading(phase: phase, at: Date(), monotonic: MonotonicClock.now))
    }

    /// The two-sine model behind the demo, also usable by tests and fixtures.
    nonisolated static func reading(phase: Double, at timestamp: Date, monotonic: TimeInterval = 0) -> Reading {
        let v = 9.0 + 0.05 * sin(phase * 0.7)
        let i = max(0, 1.2 + 0.8 * sin(phase * 0.25) + 0.05 * sin(phase * 5))
        return Reading(timestamp: timestamp, voltage: v, current: i, power: v * i, monotonic: monotonic)
    }
}
