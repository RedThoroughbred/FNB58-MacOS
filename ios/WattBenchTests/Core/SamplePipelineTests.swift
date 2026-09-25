import XCTest
@testable import WattBench

@MainActor
final class SamplePipelineTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_760_000_000)

    private func reading(_ k: Int, power: Double = 10, current: Double = 2, dt: Double = 0.1) -> Reading {
        Reading(timestamp: t0.addingTimeInterval(Double(k) * dt), voltage: 5, current: current, power: power,
                monotonic: 100 + Double(k) * dt)
    }

    func testDisplayFrameThrottled() {
        let p = SamplePipeline()
        var frames = 0
        var snapshots = 0
        var generation = p.displayGeneration
        // 10 s of readings at 10 Hz.
        for k in 0..<100 {
            if p.ingest(reading(k), recording: nil, observers: [], connection: .connected("FNB58")) != nil { snapshots += 1 }
            if p.displayGeneration != generation {
                generation = p.displayGeneration
                frames += 1
            }
        }
        XCTAssertEqual(p.latest?.id, reading(99).id)
        XCTAssertLessThanOrEqual(frames, 51, "at most one DisplayFrame per 200 ms of reading time")
        XCTAssertGreaterThanOrEqual(frames, 45)
        XCTAssertLessThanOrEqual(snapshots, 51, "at most one ChartSnapshot per 200 ms of reading time")
        XCTAssertGreaterThanOrEqual(snapshots, 45)
        XCTAssertEqual(p.display.latest?.id, p.chart.points.last?.id)
        XCTAssertEqual(p.display.tripStats.count, 1)
        XCTAssertNil(p.display.recordingStats)
    }

    func testRingBufferBoundsHistoryAndChart() throws {
        let p = SamplePipeline()
        for k in 0..<1500 {
            p.ingest(reading(k), recording: nil, observers: [], connection: .connected("FNB58"))
        }
        XCTAssertEqual(p.history.count, SamplePipeline.historyCapacity)
        XCTAssertEqual(p.chart.points.count, SamplePipeline.historyCapacity)
        // The chart is throttled, so it may trail `latest` by a sample or two.
        XCTAssertLessThanOrEqual(try XCTUnwrap(p.chart.points.last).id, try XCTUnwrap(p.latest).id)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(p.chart.points.last).id, reading(1497).id)
        p.clearHistory()
        XCTAssertEqual(p.history.count, 0)
        XCTAssertEqual(p.chart, .empty)
    }

    func testGapIntervalsDetectedAndTripsNotIntegratedAcrossGap() {
        let p = SamplePipeline()
        p.ingest(reading(0), recording: nil, observers: [], connection: .connected("FNB58"))
        p.ingest(reading(1), recording: nil, observers: [], connection: .connected("FNB58"))
        // 30 s later
        p.ingest(Reading(timestamp: t0.addingTimeInterval(30.1), voltage: 5, current: 2, power: 10, monotonic: 130.1),
                 recording: nil, observers: [], connection: .connected("FNB58"))
        p.ingest(Reading(timestamp: t0.addingTimeInterval(30.2), voltage: 5, current: 2, power: 10, monotonic: 130.2),
                 recording: nil, observers: [], connection: .connected("FNB58"))
        XCTAssertEqual(p.chart.gaps.count, 1)
        XCTAssertEqual(p.chart.gaps.first?.duration ?? 0, 30, accuracy: 1e-6)
        XCTAssertEqual(p.trips[0].stats.gapCount, 1)
        XCTAssertEqual(p.trips[0].stats.durationS, 0.2, accuracy: 1e-6)
        XCTAssertEqual(p.extremes.maxW?.value, 10)
    }

    func testObserversReceiveContextAndDemoIsExcludedFromTrips() {
        final class Probe: SampleObserver {
            var contexts: [SampleContext] = []
            func observe(_ r: Reading, context: SampleContext) { contexts.append(context) }
        }
        let probe = Probe()
        let p = SamplePipeline()
        let rec = SessionRecorder(name: "x", deviceName: nil)
        p.ingest(reading(0), recording: nil, observers: [probe], connection: .demo)
        p.ingest(reading(1), recording: rec, observers: [probe], connection: .demo)
        XCTAssertEqual(probe.contexts.count, 2)
        XCTAssertEqual(probe.contexts[0].dt, 0)
        XCTAssertFalse(probe.contexts[0].isRecording)
        XCTAssertEqual(probe.contexts[1].dt, 0.1, accuracy: 1e-9)
        XCTAssertTrue(probe.contexts[1].isRecording)
        XCTAssertEqual(probe.contexts[1].recordingStats?.samples, 1)
        XCTAssertEqual(probe.contexts[1].connection, .demo)
        XCTAssertEqual(p.trips[0].stats.samples, 0, "demo readings do not feed the trip by default")

        p.excludeDemoFromTrips = false
        p.ingest(reading(2), recording: rec, observers: [], connection: .demo)
        XCTAssertEqual(p.trips[0].stats.samples, 1)
    }

    func testAutoStopReasonSurfacesOnce() {
        let p = SamplePipeline()
        let rec = SessionRecorder(name: "x", deviceName: nil, autoStop: AutoStopRule(belowCurrentA: 0.1, forSeconds: 0.3))
        for k in 0..<3 {
            p.ingest(reading(k, current: 0.01), recording: rec, observers: [], connection: .connected("FNB58"))
            XCTAssertNil(p.takeAutoStop())
        }
        p.ingest(reading(3, current: 0.01), recording: rec, observers: [], connection: .connected("FNB58"))
        XCTAssertEqual(p.takeAutoStop(), .currentBelowThreshold)
        XCTAssertNil(p.takeAutoStop())
        XCTAssertEqual(rec.markers.last?.kind, .autoStop)
        XCTAssertEqual(rec.finish().autoStopReason, "currentBelowThreshold")
    }
}
