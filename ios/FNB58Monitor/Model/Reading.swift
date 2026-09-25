import Foundation

/// One measurement from the meter.
struct Reading: Codable, Identifiable, Equatable {
    var id: Date { timestamp }
    let timestamp: Date
    let voltage: Double   // V
    let current: Double   // A
    let power: Double     // W
}

/// Aggregate statistics for a recorded session. Energy/capacity are integrated
/// from the actual timestamps between consecutive samples.
struct SessionStats: Codable, Equatable {
    var samples = 0
    var minVoltage: Double?
    var maxVoltage: Double?
    var minCurrent: Double?
    var maxCurrent: Double?
    var maxPower: Double = 0
    var avgVoltage: Double = 0
    var avgCurrent: Double = 0
    var avgPower: Double = 0
    var energyWh: Double = 0
    var capacityAh: Double = 0
    var durationS: Double = 0

    private var lastTimestamp: Date?

    /// Largest gap accepted between two samples; longer gaps (reconnects,
    /// app suspended) are not integrated.
    static let maxGapS: TimeInterval = 5

    mutating func add(_ r: Reading) {
        samples += 1
        let n = Double(samples)

        minVoltage = min(minVoltage ?? r.voltage, r.voltage)
        maxVoltage = max(maxVoltage ?? r.voltage, r.voltage)
        minCurrent = min(minCurrent ?? r.current, r.current)
        maxCurrent = max(maxCurrent ?? r.current, r.current)
        maxPower = max(maxPower, r.power)

        avgVoltage += (r.voltage - avgVoltage) / n
        avgCurrent += (r.current - avgCurrent) / n
        avgPower += (r.power - avgPower) / n

        if let last = lastTimestamp {
            let dt = r.timestamp.timeIntervalSince(last)
            if dt >= 0, dt <= Self.maxGapS {
                durationS += dt
                energyWh += r.power * dt / 3600
                capacityAh += r.current * dt / 3600
            }
        }
        lastTimestamp = r.timestamp
    }
}

struct Session: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var startTime: Date
    var endTime: Date
    var deviceName: String?
    var stats: SessionStats
    var readings: [Reading]

    var duration: TimeInterval { endTime.timeIntervalSince(startTime) }

    /// RFC 4180 CSV, same columns as the desktop app's export.
    func csv() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var out = "timestamp,voltage_v,current_a,power_w\n"
        out.reserveCapacity(readings.count * 48)
        for r in readings {
            out += "\(f.string(from: r.timestamp)),\(r.voltage),\(r.current),\(r.power)\n"
        }
        return out
    }
}
