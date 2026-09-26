import Foundation

/// Replays stored readings with their original spacing (monotonic stamps when
/// both readings carry them, wall clock otherwise). Used by tests and to
/// drive the app in the Simulator without a meter.
///
/// `timeScale` > 1 replays faster than real time; with `restamp` (the
/// default) every emitted reading carries the current wall clock and
/// `MonotonicClock` stamp so live charts and trips treat it like a fresh
/// sample, and a pause between two fixture readings replays as a real pause.
@MainActor
final class FixtureSource: MeterSource {
    var onReading: ((Reading) -> Void)?

    let readings: [Reading]
    let timeScale: Double
    let restamp: Bool
    let loop: Bool

    /// Readings emitted since `start()`.
    private(set) var emitted = 0
    private var task: Task<Void, Never>?

    init(readings: [Reading], timeScale: Double = 1, restamp: Bool = true, loop: Bool = false) {
        self.readings = readings
        self.timeScale = max(timeScale, 1e-6)
        self.restamp = restamp
        self.loop = loop
    }

    var isRunning: Bool { task != nil }

    func start() {
        stop()
        emitted = 0
        task = Task { [weak self] in
            await self?.run()
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    // MARK: - Replay

    private func run() async {
        defer { task = nil }
        var previous: Reading?
        repeat {
            for r in readings {
                if Task.isCancelled { return }
                if let p = previous {
                    let dt = Self.interval(from: p, to: r)
                    if dt > 0 {
                        do {
                            try await Task.sleep(for: .seconds(dt / timeScale))
                        } catch {
                            return
                        }
                    }
                }
                emit(r)
                previous = r
            }
            // When looping, the wrap-around is spaced like an ordinary sample.
            previous = nil
        } while loop && !Task.isCancelled
    }

    private func emit(_ r: Reading) {
        emitted += 1
        if restamp {
            onReading?(Reading(timestamp: Date(), voltage: r.voltage, current: r.current, power: r.power,
                               monotonic: MonotonicClock.now))
        } else {
            onReading?(r)
        }
    }

    /// Seconds between two fixture readings, by the same rule `SessionStats`
    /// uses. Negative intervals (unsorted fixtures) count as 0.
    nonisolated static func interval(from a: Reading, to b: Reading) -> TimeInterval {
        let dt = (a.monotonic > 0 && b.monotonic > 0) ? b.monotonic - a.monotonic : b.timestamp.timeIntervalSince(a.timestamp)
        return max(0, dt)
    }

    // MARK: - Synthetic fixtures

    /// A synthetic bench run at `hz` samples per second for `seconds`, using
    /// the demo signal model. Values are quantised to the meter's 1/10000
    /// resolution so they round-trip through the journal exactly.
    nonisolated static func synthetic(seconds: TimeInterval, hz: Double = 10,
                                      start: Date = Date(timeIntervalSince1970: 1_760_000_000)) -> [Reading] {
        let n = max(0, Int(seconds * hz))
        let dt = 1 / hz
        var out: [Reading] = []
        out.reserveCapacity(n)
        for k in 0..<n {
            let t = Double(k) * dt
            let r = DemoSource.reading(phase: t, at: start.addingTimeInterval(t), monotonic: 1 + t)
            out.append(Reading(timestamp: r.timestamp, voltage: quantise(r.voltage), current: quantise(r.current),
                               power: quantise(r.power), monotonic: r.monotonic))
        }
        return out
    }

    nonisolated static func quantise(_ v: Double) -> Double {
        (v * 10_000).rounded() / 10_000
    }
}
