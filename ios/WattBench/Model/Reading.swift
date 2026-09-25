import Foundation

/// One measurement from the meter.
///
/// `monotonic` is seconds on a process-local monotonic clock (see
/// `MonotonicClock`) and is never persisted: it is 0 for readings decoded from
/// disk. Live readings carry it so that integration is immune to wall-clock
/// jumps (NTP, time-zone changes).
struct Reading: Codable, Identifiable, Equatable, Hashable {
    /// Monotonic seconds when available (unique per process), otherwise the
    /// wall-clock time. Coalesced BLE notifications can share a timestamp, so
    /// live readings must never key on `timestamp` alone.
    var id: Double { monotonic != 0 ? monotonic : timestamp.timeIntervalSinceReferenceDate }

    let timestamp: Date
    let voltage: Double   // V
    let current: Double   // A
    let power: Double     // W
    let monotonic: TimeInterval

    init(timestamp: Date, voltage: Double, current: Double, power: Double, monotonic: TimeInterval = 0) {
        self.timestamp = timestamp
        self.voltage = voltage
        self.current = current
        self.power = power
        self.monotonic = monotonic
    }

    // Codable ignores `monotonic`: it is not encoded and decodes as 0.
    private enum CodingKeys: String, CodingKey {
        case timestamp, voltage, current, power
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        voltage = try c.decode(Double.self, forKey: .voltage)
        current = try c.decode(Double.self, forKey: .current)
        power = try c.decode(Double.self, forKey: .power)
        monotonic = 0
    }
}

/// Aggregate statistics for a run of readings. Energy and capacity are
/// integrated from the real interval between consecutive samples (monotonic
/// when both readings carry it, wall clock otherwise); intervals longer than
/// `maxGapS` are counted as gaps and not integrated.
struct SessionStats: Codable, Equatable {
    var samples = 0
    var minVoltage: Double?
    var maxVoltage: Double?
    var minCurrent: Double?
    var maxCurrent: Double?
    var maxPower: Double = 0
    var avgVoltage: Double = 0
    var avgCurrent: Double = 0
    /// Plain sample mean of power (what 1.0 called `avgPower`).
    var meanPowerSampled: Double = 0
    var energyWh: Double = 0
    var capacityAh: Double = 0
    /// Integrated (active) seconds, excluding gaps.
    var durationS: Double = 0
    var gapCount = 0
    var gapSeconds: Double = 0

    /// Time-weighted average power; falls back to the sample mean before any
    /// interval has been integrated.
    var avgPower: Double { durationS > 0 ? energyWh * 3600 / durationS : meanPowerSampled }

    private var lastTimestamp: Date?
    /// Process-local; never persisted and ignored by `==`, so a decoded copy
    /// compares equal to the live value it was written from.
    private var lastMonotonic: TimeInterval?

    /// Largest interval accepted between two samples; longer intervals
    /// (reconnects, app suspended) are gaps.
    static let maxGapS: TimeInterval = 5

    init() {}

    static func == (a: SessionStats, b: SessionStats) -> Bool {
        a.samples == b.samples && a.minVoltage == b.minVoltage && a.maxVoltage == b.maxVoltage
            && a.minCurrent == b.minCurrent && a.maxCurrent == b.maxCurrent && a.maxPower == b.maxPower
            && a.avgVoltage == b.avgVoltage && a.avgCurrent == b.avgCurrent
            && a.meanPowerSampled == b.meanPowerSampled && a.energyWh == b.energyWh
            && a.capacityAh == b.capacityAh && a.durationS == b.durationS
            && a.gapCount == b.gapCount && a.gapSeconds == b.gapSeconds && a.lastTimestamp == b.lastTimestamp
    }

    /// Interval from the last added reading to `r`, using the rule in
    /// `add(_:)`. 0 for the first reading.
    func dt(to r: Reading) -> TimeInterval {
        guard let lt = lastTimestamp else { return 0 }
        if r.monotonic > 0, let lm = lastMonotonic, lm > 0 {
            return r.monotonic - lm
        }
        return r.timestamp.timeIntervalSince(lt)
    }

    mutating func add(_ r: Reading) {
        add(r, dt: dt(to: r))
    }

    mutating func add(_ r: Reading, dt: TimeInterval) {
        samples += 1
        let n = Double(samples)

        minVoltage = min(minVoltage ?? r.voltage, r.voltage)
        maxVoltage = max(maxVoltage ?? r.voltage, r.voltage)
        minCurrent = min(minCurrent ?? r.current, r.current)
        maxCurrent = max(maxCurrent ?? r.current, r.current)
        maxPower = max(maxPower, r.power)

        avgVoltage += (r.voltage - avgVoltage) / n
        avgCurrent += (r.current - avgCurrent) / n
        meanPowerSampled += (r.power - meanPowerSampled) / n

        if dt > Self.maxGapS {
            gapCount += 1
            gapSeconds += dt
        } else if dt > 0 {
            durationS += dt
            energyWh += r.power * dt / 3600
            capacityAh += r.current * dt / 3600
        }
        lastTimestamp = r.timestamp
        lastMonotonic = r.monotonic > 0 ? r.monotonic : nil
    }

    // MARK: Codable (tolerates 1.0 files: `avgPower` key, no gap fields)

    private enum CodingKeys: String, CodingKey {
        case samples, minVoltage, maxVoltage, minCurrent, maxCurrent, maxPower
        case avgVoltage, avgCurrent, meanPowerSampled, avgPower
        case energyWh, capacityAh, durationS, gapCount, gapSeconds, lastTimestamp
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        samples = try c.decodeIfPresent(Int.self, forKey: .samples) ?? 0
        minVoltage = try c.decodeIfPresent(Double.self, forKey: .minVoltage)
        maxVoltage = try c.decodeIfPresent(Double.self, forKey: .maxVoltage)
        minCurrent = try c.decodeIfPresent(Double.self, forKey: .minCurrent)
        maxCurrent = try c.decodeIfPresent(Double.self, forKey: .maxCurrent)
        maxPower = try c.decodeIfPresent(Double.self, forKey: .maxPower) ?? 0
        avgVoltage = try c.decodeIfPresent(Double.self, forKey: .avgVoltage) ?? 0
        avgCurrent = try c.decodeIfPresent(Double.self, forKey: .avgCurrent) ?? 0
        meanPowerSampled = try c.decodeIfPresent(Double.self, forKey: .meanPowerSampled)
            ?? c.decodeIfPresent(Double.self, forKey: .avgPower)
            ?? 0
        energyWh = try c.decodeIfPresent(Double.self, forKey: .energyWh) ?? 0
        capacityAh = try c.decodeIfPresent(Double.self, forKey: .capacityAh) ?? 0
        durationS = try c.decodeIfPresent(Double.self, forKey: .durationS) ?? 0
        gapCount = try c.decodeIfPresent(Int.self, forKey: .gapCount) ?? 0
        gapSeconds = try c.decodeIfPresent(Double.self, forKey: .gapSeconds) ?? 0
        lastTimestamp = try c.decodeIfPresent(Date.self, forKey: .lastTimestamp)
        lastMonotonic = nil
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(samples, forKey: .samples)
        try c.encodeIfPresent(minVoltage, forKey: .minVoltage)
        try c.encodeIfPresent(maxVoltage, forKey: .maxVoltage)
        try c.encodeIfPresent(minCurrent, forKey: .minCurrent)
        try c.encodeIfPresent(maxCurrent, forKey: .maxCurrent)
        try c.encode(maxPower, forKey: .maxPower)
        try c.encode(avgVoltage, forKey: .avgVoltage)
        try c.encode(avgCurrent, forKey: .avgCurrent)
        try c.encode(meanPowerSampled, forKey: .meanPowerSampled)
        // Written too so a 1.0 build can still open files saved by 1.1.
        try c.encode(avgPower, forKey: .avgPower)
        try c.encode(energyWh, forKey: .energyWh)
        try c.encode(capacityAh, forKey: .capacityAh)
        try c.encode(durationS, forKey: .durationS)
        try c.encode(gapCount, forKey: .gapCount)
        try c.encode(gapSeconds, forKey: .gapSeconds)
        try c.encodeIfPresent(lastTimestamp, forKey: .lastTimestamp)
    }
}

/// A point of interest inside a recording.
struct Marker: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case user, gap, autoStop, alert }

    var id: UUID = UUID()
    var timestamp: Date
    var label: String
    var kind: Kind = .user
}

/// A fully loaded session: metadata, statistics and (when loaded) every sample.
struct Session: Codable, Identifiable, Equatable {
    static let currentSchema = 2

    var schemaVersion: Int = Session.currentSchema
    var id: UUID
    var name: String
    var startTime: Date
    var endTime: Date
    var deviceName: String?
    var stats: SessionStats
    /// In-memory samples. May be empty for a session whose samples live in a
    /// journal; `sampleCount` is authoritative.
    var readings: [Reading]
    var markers: [Marker] = []
    var tags: [String] = []
    var notes: String? = nil
    var autoStopReason: String? = nil
    var isDemo: Bool = false
    /// 1 Hz mean-power series maintained by the recorder (empty for sessions
    /// that were not recorded in this process; `summary()` then derives it
    /// from `readings`).
    var sparkline: [Float] = []

    /// Wall-clock span of the recording. Use `stats.durationS` for the active
    /// (integrated) duration.
    var duration: TimeInterval { endTime.timeIntervalSince(startTime) }

    var sampleCount: Int { max(readings.count, stats.samples) }

    init(schemaVersion: Int = Session.currentSchema, id: UUID, name: String, startTime: Date, endTime: Date,
         deviceName: String?, stats: SessionStats, readings: [Reading], markers: [Marker] = [],
         tags: [String] = [], notes: String? = nil, autoStopReason: String? = nil, isDemo: Bool = false,
         sparkline: [Float] = []) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.startTime = startTime
        self.endTime = endTime
        self.deviceName = deviceName
        self.stats = stats
        self.readings = readings
        self.markers = markers
        self.tags = tags
        self.notes = notes
        self.autoStopReason = autoStopReason
        self.isDemo = isDemo
        self.sparkline = sparkline
    }

    // MARK: Codable (every field added after 1.0 is optional on decode)

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, name, startTime, endTime, deviceName, stats, readings
        case markers, tags, notes, autoStopReason, isDemo, sparkline
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        startTime = try c.decode(Date.self, forKey: .startTime)
        endTime = try c.decode(Date.self, forKey: .endTime)
        deviceName = try c.decodeIfPresent(String.self, forKey: .deviceName)
        stats = try c.decodeIfPresent(SessionStats.self, forKey: .stats) ?? SessionStats()
        readings = try c.decodeIfPresent([Reading].self, forKey: .readings) ?? []
        markers = try c.decodeIfPresent([Marker].self, forKey: .markers) ?? []
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        autoStopReason = try c.decodeIfPresent(String.self, forKey: .autoStopReason)
        isDemo = try c.decodeIfPresent(Bool.self, forKey: .isDemo) ?? false
        sparkline = try c.decodeIfPresent([Float].self, forKey: .sparkline) ?? []
    }

    // MARK: Derived

    func summary() -> SessionSummary {
        let spark: [Float]
        if !sparkline.isEmpty {
            spark = Decimator.condense(sparkline, targetCount: SessionSummary.sparklineCount)
        } else {
            spark = Decimator.meanPower(readings[...], targetCount: SessionSummary.sparklineCount)
        }
        return SessionSummary(schemaVersion: schemaVersion, id: id, name: name, startTime: startTime,
                              endTime: endTime, deviceName: deviceName, stats: stats, sampleCount: sampleCount,
                              markers: markers, tags: tags, notes: notes, autoStopReason: autoStopReason,
                              isDemo: isDemo, state: .complete, sparkline: spark)
    }

    /// RFC 4180 CSV. The first four columns match the 1.0 export and the
    /// desktop app; `elapsed_s` (seconds since `startTime`) and
    /// `marker_label` (markers that fall at or before the row, "; " joined)
    /// follow.
    func csv() -> String {
        var out = Self.csvHeader
        out.reserveCapacity(readings.count * 60)
        forEachCSVChunk { out += $0 }
        return out
    }

    /// Streams the same CSV to `url` in 64 KB chunks so a 100k-row session
    /// never needs its whole text in memory.
    func writeCSV(to url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.write(contentsOf: Data(Self.csvHeader.utf8))
        var failure: Error?
        forEachCSVChunk { chunk in
            guard failure == nil else { return }
            do { try handle.write(contentsOf: Data(chunk.utf8)) } catch { failure = error }
        }
        if let failure { throw failure }
    }

    static let csvHeader = "timestamp,voltage_v,current_a,power_w,elapsed_s,marker_label\n"
    private static let csvChunkSize = 64 * 1024

    /// Builds the rows into chunks of about `csvChunkSize` bytes.
    private func forEachCSVChunk(_ emit: (String) -> Void) {
        let sortedMarkers = markers.sorted { $0.timestamp < $1.timestamp }
        var nextMarker = 0
        var chunk = ""
        chunk.reserveCapacity(Self.csvChunkSize + 256)
        let start = startTime.timeIntervalSince1970
        for (index, r) in readings.enumerated() {
            var labels: [String] = []
            let isLast = index == readings.count - 1
            while nextMarker < sortedMarkers.count,
                  isLast || sortedMarkers[nextMarker].timestamp <= r.timestamp {
                labels.append(sortedMarkers[nextMarker].label)
                nextMarker += 1
            }
            let elapsed = ((r.timestamp.timeIntervalSince1970 - start) * 1000).rounded() / 1000
            chunk += ISO8601Millis.string(r.timestamp)
            chunk += ",\(r.voltage),\(r.current),\(r.power),\(elapsed),"
            chunk += Self.csvField(labels.joined(separator: "; "))
            chunk += "\n"
            if chunk.utf8.count >= Self.csvChunkSize {
                emit(chunk)
                chunk.removeAll(keepingCapacity: true)
            }
        }
        if !chunk.isEmpty { emit(chunk) }
    }

    private static func csvField(_ s: String) -> String {
        guard s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

/// UTC timestamps in the form `2026-09-25T14:02:11.123Z`, byte for byte what
/// `ISO8601DateFormatter` produces with `.withInternetDateTime` and
/// `.withFractionalSeconds` (the 1.0 CSV format), computed with integer
/// arithmetic so a 100k-row export formats in well under a second.
enum ISO8601Millis {
    static func string(_ date: Date) -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        let totalMs = Int64((date.timeIntervalSince1970 * 1000).rounded())
        let msPerDay: Int64 = 86_400_000
        var days = totalMs / msPerDay
        var rem = totalMs - days * msPerDay
        if rem < 0 {
            rem += msPerDay
            days -= 1
        }
        let (y, m, d) = civil(fromDays: days)
        put(&bytes, y, at: 0, width: 4)
        bytes[4] = UInt8(ascii: "-")
        put(&bytes, m, at: 5, width: 2)
        bytes[7] = UInt8(ascii: "-")
        put(&bytes, d, at: 8, width: 2)
        bytes[10] = UInt8(ascii: "T")
        put(&bytes, rem / 3_600_000, at: 11, width: 2)
        bytes[13] = UInt8(ascii: ":")
        put(&bytes, (rem / 60_000) % 60, at: 14, width: 2)
        bytes[16] = UInt8(ascii: ":")
        put(&bytes, (rem / 1000) % 60, at: 17, width: 2)
        bytes[19] = UInt8(ascii: ".")
        put(&bytes, rem % 1000, at: 20, width: 3)
        bytes[23] = UInt8(ascii: "Z")
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Proleptic Gregorian date for a day count since 1970-01-01
    /// (Howard Hinnant's `civil_from_days`).
    private static func civil(fromDays z0: Int64) -> (Int64, Int64, Int64) {
        let z = z0 + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        let y = yoe + era * 400 + (m <= 2 ? 1 : 0)
        return (y, m, d)
    }

    private static func put(_ bytes: inout [UInt8], _ value: Int64, at index: Int, width: Int) {
        var v = max(0, value)
        for k in stride(from: width - 1, through: 0, by: -1) {
            bytes[index + k] = UInt8(ascii: "0") + UInt8(v % 10)
            v /= 10
        }
    }
}
