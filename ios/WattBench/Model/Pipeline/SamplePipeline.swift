import Foundation

/// Everything the readouts need, published together at most 5 times per
/// second so SwiftUI bodies are not re-evaluated per sample.
struct DisplayFrame: Equatable {
    var latest: Reading?
    var tripStats: [SessionStats]
    var recordingStats: SessionStats?
    var extremes: Extremes
    var publishedAt: Date

    static let empty = DisplayFrame(latest: nil, tripStats: [], recordingStats: nil,
                                    extremes: Extremes(since: .distantPast), publishedAt: .distantPast)
}

/// Pure, CoreBluetooth-free sample path shared by the BLE source, the demo
/// source and tests. `ingest` performs the ordered steps from the
/// architecture: latest, ring buffer, extremes, trips, recorder (which
/// evaluates the auto-stop rule), observers, then the throttled DisplayFrame
/// and ChartSnapshot publications.
///
/// Throttling is measured on the readings' own time base (monotonic when
/// present, wall clock otherwise) so replays and tests are deterministic.
@MainActor
final class SamplePipeline {
    nonisolated static let historyCapacity = 1200
    nonisolated static let chartInterval: TimeInterval = 0.2
    nonisolated static let displayInterval: TimeInterval = 0.2
    /// Slack so 10 Hz samples with floating-point jitter publish every 2nd
    /// sample rather than every 2nd-or-3rd (1 ms).
    nonisolated static let intervalTolerance: TimeInterval = 0.001

    var history: RingBuffer<Reading>
    var latest: Reading?
    var trips: [TripMeter]
    var extremes: Extremes
    /// When true, readings that arrive while `connection == .demo` do not
    /// feed the trip meters.
    var excludeDemoFromTrips = true

    private(set) var display = DisplayFrame.empty
    /// Incremented every time `display` is published (cheap change detection).
    private(set) var displayGeneration = 0
    private(set) var chart = ChartSnapshot.empty
    private var pendingAutoStop: AutoStopRule.Reason?

    private var lastTime: TimeInterval?
    private var lastChartTime: TimeInterval = -.infinity
    private var lastDisplayTime: TimeInterval = -.infinity

    init(historyCapacity: Int = SamplePipeline.historyCapacity,
         trips: [TripMeter] = [TripMeter(label: "Trip")],
         extremes: Extremes = Extremes()) {
        history = RingBuffer(capacity: historyCapacity)
        self.trips = trips
        self.extremes = extremes
    }

    /// Returns a new `ChartSnapshot` when one was published for this reading.
    @discardableResult
    func ingest(_ r: Reading, recording: SessionRecorder?, observers: [any SampleObserver],
                connection: ConnectionState) -> ChartSnapshot? {
        let t = Self.time(of: r)
        let dt = lastTime.map { t - $0 } ?? 0
        lastTime = t

        latest = r
        history.append(r)
        extremes.update(r)
        if !(excludeDemoFromTrips && connection == .demo) {
            for i in trips.indices { trips[i].add(r) }
        }
        if let recording, let reason = recording.add(r) {
            pendingAutoStop = reason
        }
        let context = SampleContext(dt: dt, isRecording: recording != nil,
                                    recordingStats: recording?.stats, connection: connection)
        for o in observers { o.observe(r, context: context) }

        if t - lastDisplayTime >= Self.displayInterval - Self.intervalTolerance || t < lastDisplayTime {
            lastDisplayTime = t
            display = DisplayFrame(latest: r, tripStats: trips.map(\.stats),
                                   recordingStats: recording?.stats, extremes: extremes,
                                   publishedAt: r.timestamp)
            displayGeneration &+= 1
        }
        if t - lastChartTime >= Self.chartInterval - Self.intervalTolerance || t < lastChartTime {
            lastChartTime = t
            chart = ChartSnapshot.make(from: history.array(), at: r.timestamp)
            return chart
        }
        return nil
    }

    /// The auto-stop reason raised by the last `ingest`, cleared on read.
    func takeAutoStop() -> AutoStopRule.Reason? {
        defer { pendingAutoStop = nil }
        return pendingAutoStop
    }

    func clearHistory() {
        history.removeAll()
        chart = .empty
        lastChartTime = -.infinity
    }

    private static func time(of r: Reading) -> TimeInterval {
        r.monotonic > 0 ? r.monotonic : r.timestamp.timeIntervalSinceReferenceDate
    }
}
