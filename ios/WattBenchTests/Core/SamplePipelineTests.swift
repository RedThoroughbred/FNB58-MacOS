import XCTest
@testable import WattBench

@MainActor
final class SamplePipelineTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_760_000_000)
    private let connected = ConnectionState.connected("FNB58")

    private func reading(_ k: Int, power: Double = 10, current: Double = 2, dt: Double = 0.1) -> Reading {
        Reading(timestamp: t0.addingTimeInterval(Double(k) * dt), voltage: 5, current: current, power: power,
                monotonic: 100 + Double(k) * dt)
    }

    func testRingBufferBoundsHistory() throws {
        let p = SamplePipeline()
        for k in 0..<10_000 {
            p.ingest(reading(k), recording: nil, observers: [], connection: connected)
            XCTAssertLessThanOrEqual(p.history.count, SamplePipeline.historyCapacity)
        }
        XCTAssertEqual(p.history.count, SamplePipeline.historyCapacity)
        XCTAssertEqual(p.history[0].id, reading(10_000 - SamplePipeline.historyCapacity).id, "oldest retained sample")
        XCTAssertEqual(p.history.last?.id, reading(9999).id)
        XCTAssertLessThanOrEqual(p.chart.points.count, SamplePipeline.historyCapacity)
        // The chart is throttled, so it may trail `latest` by a sample or two.
        XCTAssertLessThanOrEqual(try XCTUnwrap(p.chart.points.last).id, try XCTUnwrap(p.latest).id)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(p.chart.points.last).id, reading(9997).id)
        p.clearHistory()
        XCTAssertEqual(p.history.count, 0)
        XCTAssertEqual(p.chart, .empty)
    }

    func testSnapshotThrottledTo5Hz() {
        let p = SamplePipeline()
        var snapshots = 0
        // 10,000 readings = 1000 s of reading time at 10 Hz.
        for k in 0..<10_000 {
            if p.ingest(reading(k), recording: nil, observers: [], connection: connected) != nil { snapshots += 1 }
        }
        XCTAssertLessThanOrEqual(snapshots, 5001, "at most one ChartSnapshot per 200 ms of reading time")
        XCTAssertGreaterThanOrEqual(snapshots, 4990)
        XCTAssertEqual(p.chart.points.count, SamplePipeline.historyCapacity)
        XCTAssertEqual(p.chart.publishedAt, p.chart.points.last?.timestamp)
        XCTAssertTrue(p.chart.gaps.isEmpty)
        // A window's worth of points spans at most 120 s.
        let span = (p.chart.points.last?.timestamp ?? t0).timeIntervalSince(p.chart.points.first?.timestamp ?? t0)
        XCTAssertLessThanOrEqual(span, ChartSnapshot.windowSeconds)
    }

    func testDisplayFrameThrottled() {
        let p = SamplePipeline()
        var frames = 0
        var generation = p.displayGeneration
        for k in 0..<100 {   // 10 s at 10 Hz
            p.ingest(reading(k), recording: nil, observers: [], connection: connected)
            if p.displayGeneration != generation {
                generation = p.displayGeneration
                frames += 1
            }
        }
        XCTAssertEqual(p.latest?.id, reading(99).id, "latest is updated for every sample")
        XCTAssertLessThanOrEqual(frames, 51, "at most one DisplayFrame per 200 ms of reading time")
        XCTAssertGreaterThanOrEqual(frames, 45)
        XCTAssertEqual(p.display.latest?.id, p.chart.points.last?.id)
        XCTAssertEqual(p.display.tripStats.count, 1)
        XCTAssertGreaterThanOrEqual(p.display.tripStats[0].samples, p.trips[0].stats.samples - 1, "the frame trails the pipeline by at most one sample")
        XCTAssertEqual(p.display.extremes, p.extremes)
        XCTAssertNil(p.display.recordingStats)
    }

    func testGapIntervalsDetected() {
        let p = SamplePipeline()
        p.ingest(reading(0), recording: nil, observers: [], connection: connected)
        p.ingest(reading(1), recording: nil, observers: [], connection: connected)
        // 30 s later
        p.ingest(Reading(timestamp: t0.addingTimeInterval(30.1), voltage: 5, current: 2, power: 10, monotonic: 130.1),
                 recording: nil, observers: [], connection: connected)
        p.ingest(Reading(timestamp: t0.addingTimeInterval(30.2), voltage: 5, current: 2, power: 10, monotonic: 130.2),
                 recording: nil, observers: [], connection: connected)
        XCTAssertEqual(p.chart.gaps.count, 1)
        XCTAssertEqual(p.chart.gaps.first?.start, t0.addingTimeInterval(0.1))
        XCTAssertEqual(p.chart.gaps.first?.duration ?? 0, 30, accuracy: 1e-6)
        XCTAssertNil(p.chart.openGap, "the gap is closed by the sample after it")
        // The trip is not integrated across the gap; extremes are unaffected.
        XCTAssertEqual(p.trips[0].stats.gapCount, 1)
        XCTAssertEqual(p.trips[0].stats.durationS, 0.2, accuracy: 1e-6)
        XCTAssertEqual(p.extremes.maxW?.value, 10)
    }

    func testRefreshChartAddsTrailingGapWhileStalled() {
        let p = SamplePipeline()
        for k in 0..<5 { p.ingest(reading(k), recording: nil, observers: [], connection: connected) }
        let last = t0.addingTimeInterval(0.4)
        // Under 5 s of silence: no gap yet.
        XCTAssertTrue(p.refreshChart(at: last.addingTimeInterval(3)).gaps.isEmpty)
        // Past the gap threshold: an open-ended gap from the last sample.
        let stalled = p.refreshChart(at: last.addingTimeInterval(12))
        XCTAssertEqual(stalled.gaps.count, 1)
        XCTAssertEqual(stalled.openGap?.start, last)
        XCTAssertEqual(stalled.openGap?.end, last.addingTimeInterval(12))
        XCTAssertEqual(stalled.publishedAt, last.addingTimeInterval(12))
        XCTAssertEqual(stalled.points.count, 5, "points are untouched")
        XCTAssertEqual(p.chart, stalled)
        // The next real sample closes it into an ordinary gap.
        p.ingest(Reading(timestamp: last.addingTimeInterval(20), voltage: 5, current: 2, power: 10, monotonic: 120.4),
                 recording: nil, observers: [], connection: connected)
        XCTAssertEqual(p.chart.gaps.count, 1)
        XCTAssertNil(p.chart.openGap)
        XCTAssertEqual(p.chart.gaps[0].end, last.addingTimeInterval(20))
    }

    func testObserversReceiveContext() {
        final class Probe: SampleObserver {
            var readings: [Reading] = []
            var contexts: [SampleContext] = []
            func observe(_ r: Reading, context: SampleContext) {
                readings.append(r)
                contexts.append(context)
            }
        }
        let probe = Probe()
        let p = SamplePipeline()
        let rec = SessionRecorder(name: "x", deviceName: nil)
        p.ingest(reading(0), recording: nil, observers: [probe], connection: connected)
        p.ingest(reading(1), recording: rec, observers: [probe], connection: .reconnecting(name: "FNB58", since: t0))
        XCTAssertEqual(probe.readings.map(\.id), [reading(0).id, reading(1).id])
        XCTAssertEqual(probe.contexts.count, 2)
        XCTAssertEqual(probe.contexts[0].dt, 0, "first reading has no interval")
        XCTAssertFalse(probe.contexts[0].isRecording)
        XCTAssertNil(probe.contexts[0].recordingStats)
        XCTAssertEqual(probe.contexts[0].connection, connected)
        XCTAssertEqual(probe.contexts[1].dt, 0.1, accuracy: 1e-9)
        XCTAssertTrue(probe.contexts[1].isRecording)
        XCTAssertEqual(probe.contexts[1].recordingStats?.samples, 1, "observers see the recorder's stats after the sample was added")
        XCTAssertEqual(probe.contexts[1].connection, .reconnecting(name: "FNB58", since: t0))
    }

    func testDemoReadingsExcludedFromTrips() {
        let p = SamplePipeline()
        XCTAssertTrue(p.excludeDemoFromTrips, "default")
        p.ingest(reading(0), recording: nil, observers: [], connection: .demo)
        p.ingest(reading(1), recording: nil, observers: [], connection: .demo)
        XCTAssertEqual(p.trips[0].stats.samples, 0, "demo readings do not feed the trip by default")
        XCTAssertEqual(p.extremes.maxW?.value, 10, "but they do feed the readouts")
        XCTAssertEqual(p.history.count, 2)
        p.excludeDemoFromTrips = false
        p.ingest(reading(2), recording: nil, observers: [], connection: .demo)
        XCTAssertEqual(p.trips[0].stats.samples, 1)
        p.excludeDemoFromTrips = true
        p.ingest(reading(3), recording: nil, observers: [], connection: connected)
        XCTAssertEqual(p.trips[0].stats.samples, 2, "real readings always count")
    }

    func testAutoStopReasonSurfacesOnce() {
        let p = SamplePipeline()
        let rec = SessionRecorder(name: "x", deviceName: nil, autoStop: AutoStopRule(belowCurrentA: 0.1, forSeconds: 0.3))
        for k in 0..<3 {
            p.ingest(reading(k, current: 0.01), recording: rec, observers: [], connection: connected)
            XCTAssertNil(p.takeAutoStop())
        }
        p.ingest(reading(3, current: 0.01), recording: rec, observers: [], connection: connected)
        XCTAssertEqual(p.takeAutoStop(), .currentBelowThreshold)
        XCTAssertNil(p.takeAutoStop(), "cleared on read")
        XCTAssertEqual(rec.markers.last?.kind, .autoStop)
        XCTAssertEqual(rec.finish().autoStopReason, "currentBelowThreshold")
    }
}
