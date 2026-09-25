import Foundation
@testable import WattBench

/// Shared builders for the Sessions tests.
enum SessionTestSupport {
    static let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    /// `count` readings `spacing` seconds apart starting at `t0`, with
    /// per-index voltage and current.
    static func readings(count: Int, spacing: TimeInterval = 0.1, start: Date = t0,
                         voltage: (Int) -> Double = { _ in 9 },
                         current: (Int) -> Double = { _ in 1 }) -> [Reading] {
        (0..<count).map { k in
            let v = voltage(k), i = current(k)
            return Reading(timestamp: start.addingTimeInterval(Double(k) * spacing), voltage: v, current: i, power: v * i)
        }
    }

    static func summary(name: String, start: Date, durationS: Double = 60, energyWh: Double = 1,
                        maxPower: Double = 10, deviceName: String? = "FNB58", tags: [String] = [],
                        notes: String? = nil, state: SessionSummary.State = .complete,
                        isDemo: Bool = false, id: UUID = UUID()) -> SessionSummary {
        var stats = SessionStats()
        stats.durationS = durationS
        stats.energyWh = energyWh
        stats.maxPower = maxPower
        stats.samples = Int(durationS * 10)
        return SessionSummary(id: id, name: name, startTime: start,
                              endTime: start.addingTimeInterval(durationS), deviceName: deviceName,
                              stats: stats, sampleCount: stats.samples, markers: [], tags: tags, notes: notes,
                              autoStopReason: nil, isDemo: isDemo, state: state, sparkline: [])
    }

    static func session(readings: [Reading], name: String = "Bench", markers: [Marker] = []) -> Session {
        var stats = SessionStats()
        for r in readings { stats.add(r) }
        return Session(id: UUID(), name: name, startTime: readings.first?.timestamp ?? t0,
                       endTime: readings.last?.timestamp ?? t0, deviceName: "FNB58", stats: stats,
                       readings: readings, markers: markers)
    }
}
