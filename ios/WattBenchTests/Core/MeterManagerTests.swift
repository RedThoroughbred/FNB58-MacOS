import XCTest
@testable import WattBench

/// Drives `MeterManager` through its pipeline seam (`ingest`, `attach`) with
/// a private UserDefaults suite and a temporary sessions directory. The
/// CoreBluetooth side (`willRestoreState` glue, reconnect) is covered by
/// `RestorePlanTests` and on-device testing; nothing here needs a radio.
@MainActor
final class MeterManagerTests: XCTestCase {
    private var dir: URL!
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        suite = "wattbench.tests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeMeter() -> MeterManager {
        MeterManager(defaults: defaults, sessionsDirectory: dir, restoreIdentifier: nil)
    }

    /// Feeds `count` wall-clock readings 100 ms apart, starting now.
    @discardableResult
    private func feed(_ meter: MeterManager, count: Int, power: Double = 10, current: Double? = nil,
                      from start: Date = Date()) -> Date {
        var t = start
        for _ in 0..<count {
            meter.ingest(Reading(timestamp: t, voltage: 5, current: current ?? power / 5, power: power))
            t = t.addingTimeInterval(0.1)
        }
        return t
    }

    func testCountersIncrementOnce() throws {
        let meter = makeMeter()
        var stops: [(Session, AutoStopRule.Reason?)] = []
        meter.onRecordingStopped = { stops.append(($0, $1)) }
        XCTAssertEqual(meter.recordingEventCount, 0)
        XCTAssertEqual(meter.connectionEventCount, 0)
        XCTAssertEqual(meter.errorEventCount, 0)

        meter.startRecording(name: "A", tags: ["t"], notes: "n")
        XCTAssertEqual(meter.recordingEventCount, 1, "start fires once")
        feed(meter, count: 20)
        let session = try XCTUnwrap(meter.stopRecording())
        XCTAssertEqual(meter.recordingEventCount, 2, "stop fires once")
        XCTAssertEqual(stops.count, 1, "the save hook runs exactly once per stop")
        XCTAssertEqual(session.sampleCount, 20)
        XCTAssertEqual(session.tags, ["t"])
        XCTAssertNil(stops[0].1)
        XCTAssertNil(meter.recording)

        XCTAssertNil(meter.stopRecording(), "stopping twice is a no-op")
        XCTAssertEqual(meter.recordingEventCount, 2)
        XCTAssertEqual(stops.count, 1)

        // An auto-stop rule ends the recording from inside ingest: one stop
        // event, the hook once, with the reason.
        meter.startRecording(name: "B", autoStop: AutoStopRule(belowCurrentA: 0.5, forSeconds: 0.3))
        XCTAssertEqual(meter.recordingEventCount, 3)
        feed(meter, count: 10, power: 0.05)
        XCTAssertNil(meter.recording, "the rule stopped it")
        XCTAssertEqual(meter.recordingEventCount, 4)
        XCTAssertEqual(stops.count, 2)
        XCTAssertEqual(stops[1].1, .currentBelowThreshold)
        XCTAssertEqual(stops[1].0.autoStopReason, AutoStopRule.Reason.currentBelowThreshold.rawValue)
        XCTAssertEqual(stops[1].0.sampleCount, 4, "0.3 s below threshold = 4 samples")
        XCTAssertEqual(stops[1].0.markers.last?.kind, .autoStop)

        // Discarding is a stop event too, but never reaches the hook.
        meter.startRecording(name: "C")
        feed(meter, count: 3)
        XCTAssertNil(meter.stopRecording(discard: true))
        XCTAssertEqual(meter.recordingEventCount, 6)
        XCTAssertEqual(stops.count, 2)
        XCTAssertEqual(meter.errorEventCount, 0)
    }

    func testStopRoutesThroughHookAndStoreSavesJournaledSession() async throws {
        let store = SessionStore(directory: dir)
        let meter = makeMeter()
        meter.onRecordingStopped = { session, _ in
            do { try store.save(session) } catch { XCTFail("\(error)") }
        }
        meter.startRecording(name: "Journaled")
        let rec = try XCTUnwrap(meter.recording)
        XCTAssertNotNil(rec.journal, "recordings are journaled under the store's directory")
        XCTAssertEqual(rec.folder, SessionFolder.url(for: rec.id, in: dir))
        feed(meter, count: 50)
        XCTAssertTrue(rec.readings.isEmpty)
        XCTAssertEqual(rec.sampleCount, 50)

        let session = try XCTUnwrap(meter.stopRecording())
        XCTAssertTrue(session.readings.isEmpty, "no read-back on stop")
        XCTAssertEqual(session.sampleCount, 50)
        XCTAssertEqual(store.saveCount, 1)
        XCTAssertEqual(store.summaries.map(\.id), [session.id])
        XCTAssertEqual(store.summaries.first?.sampleCount, 50)
        XCTAssertEqual(store.summaries.first?.state, .complete)
        XCTAssertEqual(store.summaries.first?.sparkline.count, 5, "1 Hz mean power for 5 s")
        XCTAssertNil(store.interrupted)

        let loaded = try await store.session(for: session.id)
        XCTAssertEqual(loaded.readings.count, 50)
        XCTAssertEqual(loaded.readings[1].timestamp.timeIntervalSince(loaded.readings[0].timestamp), 0.1, accuracy: 1e-3)
        XCTAssertEqual(loaded.stats, session.stats)

        // A fresh store on the next launch sees it and nothing to recover.
        let relaunched = SessionStore(directory: dir)
        XCTAssertNil(relaunched.interrupted)
        XCTAssertEqual(relaunched.summaries.map(\.id), [session.id])
    }

    func testDiscardRemovesFolder() throws {
        let meter = makeMeter()
        meter.startRecording(name: "Discard me")
        let rec = try XCTUnwrap(meter.recording)
        let folder = try XCTUnwrap(rec.folder)
        feed(meter, count: 10)
        XCTAssertTrue(FileManager.default.fileExists(atPath: SessionFolder.manifestURL(in: folder).path))
        meter.stopRecording(discard: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "discard deletes the folder")
        XCTAssertNil(SessionStore(directory: dir).interrupted, "and leaves nothing to recover")
    }

    func testInterruptedRecordingIsOfferedNotResumed() throws {
        let meter = makeMeter()
        meter.startRecording(name: "Crash")
        let rec = try XCTUnwrap(meter.recording)
        feed(meter, count: 30)
        // Simulate the process dying: secure the journal, drop the manager.
        rec.checkpoint(synchronize: true)
        rec.journal?.waitForWrites()

        let store = SessionStore(directory: dir)
        let interrupted = try XCTUnwrap(store.interrupted)
        XCTAssertEqual(interrupted.id, rec.id)
        XCTAssertEqual(interrupted.sampleCount, 30)
        XCTAssertEqual(interrupted.state, .recovered)
        XCTAssertTrue(interrupted.name.hasPrefix("Recovered: "))

        // A new manager on the relaunch starts with no recording.
        let relaunched = MeterManager(defaults: defaults, sessionsDirectory: dir, restoreIdentifier: nil)
        XCTAssertNil(relaunched.recording)
        XCTAssertEqual(relaunched.recordingEventCount, 0)
    }

    func testBackgroundingCheckpointsRecordingAndPersistsTrip() throws {
        let meter = makeMeter()
        meter.startRecording(name: "Locked phone")
        let rec = try XCTUnwrap(meter.recording)
        let folder = try XCTUnwrap(rec.folder)
        feed(meter, count: 25)
        XCTAssertEqual(rec.checkpointCount, 0)
        meter.scene = .background
        rec.journal?.waitForWrites()
        XCTAssertEqual(rec.checkpointCount, 1, "backgrounding rewrites the manifest")
        XCTAssertEqual(try SessionFolder.readManifest(in: folder).sampleCount, 25)
        XCTAssertEqual(RecordingJournal.count(url: SessionFolder.samplesURL(in: folder)), 25, "and fsyncs the journal")
        XCTAssertNotNil(defaults.data(forKey: "trip.0"), "the trip is persisted")
        meter.scene = .active
        feed(meter, count: 5)
        XCTAssertEqual(rec.sampleCount, 30, "recording continues after returning")
    }

    func testTripPersistsAndRestoresAcrossInstances() {
        let meter = makeMeter()
        XCTAssertEqual(meter.trips.count, 1)
        XCTAssertEqual(meter.trips[0].stats.samples, 0)
        feed(meter, count: 20, power: 10)
        meter.persistTrips()
        // The published copy is throttled with the display frame, so it may
        // trail the pipeline by a sample; the persisted copy never does.
        XCTAssertGreaterThanOrEqual(meter.trips[0].stats.samples, 19)

        let relaunched = makeMeter()
        XCTAssertEqual(relaunched.trips[0].stats.samples, 20, "survives a relaunch")
        XCTAssertEqual(relaunched.trips[0].stats.energyWh, 10 * 1.9 / 3600, accuracy: 1e-7)
        XCTAssertEqual(relaunched.extremes.maxW?.value, 10, "so do the peak-hold values")

        relaunched.resetTrip(0)
        XCTAssertEqual(relaunched.tripResetCount, 1)
        XCTAssertEqual(relaunched.trips[0].stats, SessionStats())
        XCTAssertEqual(makeMeter().trips[0].stats.samples, 0, "the reset is persisted at once")
        XCTAssertEqual(makeMeter().extremes.maxW?.value, 10, "extremes are independent of the trip")
        relaunched.resetExtremes()
        XCTAssertNil(relaunched.extremes.maxW)
        XCTAssertNil(makeMeter().extremes.maxW)
    }

    func testStopPersistsTripAndNoOpOnUnknownIndex() {
        let meter = makeMeter()
        meter.startRecording(name: "x")
        feed(meter, count: 4)
        meter.stopRecording()
        XCTAssertNotNil(defaults.data(forKey: "trip.0"))
        meter.resetTrip(5)
        XCTAssertEqual(meter.tripResetCount, 0)
    }

    func testDisplayAndChartAreThrottledAndExtremesTrack() {
        let meter = makeMeter()
        let start = Date()
        feed(meter, count: 10, power: 10, from: start)
        meter.ingest(Reading(timestamp: start.addingTimeInterval(1.0), voltage: 5, current: 6, power: 30))   // inrush
        feed(meter, count: 10, power: 10, from: start.addingTimeInterval(1.1))
        XCTAssertEqual(meter.latest?.power, 10)
        XCTAssertEqual(meter.extremes.maxW?.value, 30)
        XCTAssertEqual(meter.extremes.maxW?.at, start.addingTimeInterval(1.0))
        XCTAssertEqual(meter.extremes.maxI?.value, 6)
        XCTAssertEqual(meter.display.extremes, meter.extremes)
        XCTAssertEqual(meter.chart.points.count, 21)
        XCTAssertTrue(meter.chart.gaps.isEmpty)
        XCTAssertGreaterThan(meter.display.tripStats[0].samples, 0)
        meter.clearHistory()
        XCTAssertEqual(meter.chart, .empty)
    }

    func testDemoSourceFeedsPipelineAndIsExcludedFromTrips() async throws {
        let meter = makeMeter()
        XCTAssertFalse(meter.isDemo)
        meter.startDemo()
        XCTAssertEqual(meter.state, .demo)
        XCTAssertTrue(meter.isDemo)
        try await Task.sleep(for: .milliseconds(450))
        let latest = try XCTUnwrap(meter.latest, "the demo timer delivers readings")
        XCTAssertEqual(latest.voltage, 9, accuracy: 0.1)
        XCTAssertGreaterThan(latest.monotonic, 0)
        XCTAssertGreaterThan(meter.chart.points.count, 1)
        XCTAssertNotNil(meter.display.latest)
        XCTAssertEqual(meter.trips[0].stats.samples, 0, "demo readings are excluded from the trip by default")
        XCTAssertNotNil(meter.extremes.maxW)

        // A demo recording carries the flag.
        meter.startRecording(name: "Demo rec")
        try await Task.sleep(for: .milliseconds(250))
        let session = try XCTUnwrap(meter.stopRecording())
        XCTAssertTrue(session.isDemo)
        XCTAssertEqual(session.deviceName, ConnectionState.demo.label)
        XCTAssertGreaterThan(session.sampleCount, 0)

        meter.disconnect()
        XCTAssertEqual(meter.state, .idle)
        let count = meter.chart.points.count
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(meter.chart.points.count, count, "the demo source stops with the demo")

        meter.excludeDemoFromTrips = false
        meter.startDemo()
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertGreaterThan(meter.trips[0].stats.samples, 0, "opt-in: demo readings feed the trip")
        meter.disconnect()
    }

    func testAttachedFixtureSourceDrivesIngest() async throws {
        let meter = makeMeter()
        let readings = FixtureSource.synthetic(seconds: 1)
        // Verbatim replay at 10x: the pipeline's throttles run on the
        // fixture's own time base (100 ms spacing), not on the wall clock.
        let fixture = FixtureSource(readings: readings, timeScale: 10, restamp: false)
        meter.attach(source: fixture)
        let deadline = Date().addingTimeInterval(5)
        while fixture.emitted < 10, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(fixture.emitted, 10)
        XCTAssertEqual(meter.latest?.id, readings.last?.id)
        XCTAssertGreaterThanOrEqual(meter.chart.points.count, 9, "chart snapshots every 200 ms of fixture time")
        XCTAssertGreaterThanOrEqual(meter.display.tripStats[0].samples, 9)
        // Trips read the pipeline directly when persisted.
        meter.persistTrips()
        XCTAssertEqual(makeMeter().trips[0].stats.samples, 10)
    }

    func testDiagnosticsTextMentionsJournalAndCounters() throws {
        let meter = makeMeter()
        meter.startRecording(name: "Diag")
        feed(meter, count: 70)
        let rec = try XCTUnwrap(meter.recording)
        rec.journal?.waitForWrites()
        let text = meter.diagnosticsText
        XCTAssertTrue(text.contains("Recording: Diag (70 samples"), text)
        XCTAssertTrue(text.contains("Journal: "), text)
        XCTAssertTrue(text.contains("\(rec.id.uuidString)/samples.wbj"), "journal path is shown from the sessions folder: \(text)")
        XCTAssertTrue(text.contains("bytes"), text)
        XCTAssertTrue(text.contains("last flush"), text)
        XCTAssertTrue(text.contains("rejected: 0"), text)
        XCTAssertTrue(text.contains("recordings 1"), text)
        XCTAssertTrue(text.contains("Recording started: Diag"), text)
        meter.stopRecording()
    }

    func testShowAllDevicesIsPersistedByTheManager() {
        let meter = makeMeter()
        XCTAssertFalse(meter.showAllDevices)
        meter.showAllDevices = true
        XCTAssertTrue(makeMeter().showAllDevices)
        XCTAssertFalse(meter.hasLastDevice)
        meter.forgetLastDevice()
        XCTAssertFalse(meter.hasLastDevice)
    }
}
