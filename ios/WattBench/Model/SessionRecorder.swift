import Foundation
import Observation

/// Accumulates readings, markers and statistics for one recording, evaluates
/// the auto-stop rule and keeps a 1 Hz mean-power series for the sparkline.
///
/// Foundation keeps every reading in memory and `journal` is nil; WS-A routes
/// samples into a `RecordingJournal` and drops the in-memory array.
@MainActor
@Observable
final class SessionRecorder {
    let id = UUID()
    let name: String
    let deviceName: String?
    let tags: [String]
    let notes: String?
    let isDemo: Bool
    let startTime = Date()
    private(set) var stats = SessionStats()
    private(set) var readings: [Reading] = []
    private(set) var markers: [Marker] = []
    /// Mean power for each second since the first sample (0 for seconds
    /// without samples).
    private(set) var sparkline: [Float] = []
    var autoStop: AutoStopRule?
    /// Set once the auto-stop rule fires.
    private(set) var autoStopReason: AutoStopRule.Reason?
    @ObservationIgnored var journal: RecordingJournal?

    @ObservationIgnored private var firstSampleTime: TimeInterval?
    @ObservationIgnored private var bucketIndex = 0
    @ObservationIgnored private var bucketSum = 0.0
    @ObservationIgnored private var bucketCount = 0

    init(name: String, deviceName: String?, tags: [String] = [], notes: String? = nil,
         autoStop: AutoStopRule? = nil, isDemo: Bool = false) {
        self.name = name.trimmingCharacters(in: .whitespaces)
        self.deviceName = deviceName
        self.tags = tags
        self.notes = notes
        self.autoStop = autoStop
        self.isDemo = isDemo
    }

    /// Wall-clock seconds since the recording started.
    var elapsed: TimeInterval { Date().timeIntervalSince(startTime) }

    func addMarker(label: String, kind: Marker.Kind = .user) {
        markers.append(Marker(timestamp: Date(), label: label, kind: kind))
    }

    /// Adds one sample. Returns the auto-stop reason when the rule fired on
    /// this sample (the caller stops the recording).
    func add(_ r: Reading) -> AutoStopRule.Reason? {
        let dt = stats.dt(to: r)
        stats.add(r, dt: dt)
        readings.append(r)
        journal?.append(r)
        if dt > SessionStats.maxGapS {
            markers.append(Marker(timestamp: r.timestamp, label: Self.gapLabel(dt), kind: .gap))
        }
        accumulateSparkline(r)
        if autoStop != nil, autoStopReason == nil, let reason = autoStop?.evaluate(r, dt: dt, stats: stats) {
            autoStopReason = reason
            markers.append(Marker(timestamp: r.timestamp, label: "Auto-stop: \(reason.label)", kind: .autoStop))
            return reason
        }
        return nil
    }

    func finish() -> Session {
        flushSparklineBucket()
        return Session(id: id,
                       name: name.isEmpty ? "Session" : name,
                       startTime: startTime,
                       endTime: Date(),
                       deviceName: deviceName,
                       stats: stats,
                       readings: readings,
                       markers: markers,
                       tags: tags,
                       notes: notes,
                       autoStopReason: autoStopReason?.rawValue,
                       isDemo: isDemo,
                       sparkline: sparkline)
    }

    // MARK: - Sparkline (1 Hz mean power)

    private func accumulateSparkline(_ r: Reading) {
        let t = r.monotonic > 0 ? r.monotonic : r.timestamp.timeIntervalSinceReferenceDate
        guard let first = firstSampleTime else {
            firstSampleTime = t
            bucketIndex = 0
            bucketSum = r.power
            bucketCount = 1
            return
        }
        let second = Int(max(0, t - first))
        if second > bucketIndex {
            flushSparklineBucket()
            // Seconds with no samples (gaps) read as 0 W.
            let missing = second - bucketIndex - 1
            if missing > 0 { sparkline.append(contentsOf: repeatElement(0, count: missing)) }
            bucketIndex = second
        }
        bucketSum += r.power
        bucketCount += 1
    }

    private func flushSparklineBucket() {
        guard bucketCount > 0 else { return }
        sparkline.append(Float(bucketSum / Double(bucketCount)))
        bucketSum = 0
        bucketCount = 0
    }

    static func gapLabel(_ dt: TimeInterval) -> String {
        let s = Int(dt.rounded())
        return s >= 60 ? "Gap \(s / 60) m \(s % 60) s" : "Gap \(s) s"
    }
}
