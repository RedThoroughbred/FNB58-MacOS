# Workstream: WS-A Core: BLE, pipeline, journal, storage

Read `ios/PLAN/00-overview.md` first (UI direction, architecture, foundation contract).

## Owns (only these files/folders may be created or modified)

- ios/WattBench/Bluetooth/MeterManager.swift
- ios/WattBench/Bluetooth/FNB58Protocol.swift
- ios/WattBench/Bluetooth/MeterSource.swift
- ios/WattBench/Model/Reading.swift
- ios/WattBench/Model/SessionRecorder.swift
- ios/WattBench/Model/Pipeline/SamplePipeline.swift
- ios/WattBench/Model/Pipeline/RingBuffer.swift
- ios/WattBench/Model/Pipeline/ChartSnapshot.swift
- ios/WattBench/Model/Pipeline/TripMeter.swift
- ios/WattBench/Model/Pipeline/Extremes.swift
- ios/WattBench/Model/Pipeline/ReconnectPolicy.swift
- ios/WattBench/Model/Storage/SessionStore.swift
- ios/WattBench/Model/Storage/SessionSummary.swift
- ios/WattBench/Model/Storage/RecordingJournal.swift
- ios/WattBench/Model/Storage/LegacyMigration.swift
- ios/WattBench/WattBenchApp.swift
- ios/WattBench/Views/Components/RecoverySheet.swift
- ios/project.yml
- ios/WattBench/Info.plist
- ios/WattBench/PrivacyInfo.xcprivacy
- ios/AppStore/metadata.md
- ios/WattBenchTests/Core/*.swift
- ios/WattBenchTests/Fixtures/*

## Depends on

—

## Shared contract this stream exposes/consumes

MeterManager (@MainActor, @Observable): state: ConnectionState; latest: Reading?; chart: ChartSnapshot; trips: [TripMeter]; extremes: Extremes; recording: SessionRecorder?; lastError: String?; connectionEventCount/recordingEventCount/errorEventCount: Int; func startScan()/stopScan()/connect(_:)/disconnect()/reconnectLastDevice()/forgetLastDevice()/retryNow(); func startRecording(name: String, tags: [String], notes: String?, autoStop: AutoStopRule?); @discardableResult func stopRecording(discard: Bool = false, reason: String? = nil) -> Session?; func addMarker(label: String); func resetTrip(_ index: Int); func resetExtremes(); func addObserver(_ o: any SampleObserver); func startDemo(); var diagnosticsText: String. SessionStore (@MainActor, @Observable): summaries: [SessionSummary]; saveCount: Int; interrupted: SessionSummary?; func session(for id: UUID) async throws -> Session; func samples(for id: UUID) async throws -> [Reading]; func save(_ s: Session) throws; func delete(id: UUID); func rename(id: UUID, to: String) throws; func update(id: UUID, notes: String?, tags: [String]?) throws; func csvURL(for s: Session) throws -> URL (temporary dir); func keepInterrupted()/discardInterrupted(). Reading(timestamp:voltage:current:power:monotonic:). SessionStats as in foundation. ConnectionState cases and computed properties as in foundation.

## Specs

### `A1-crash-safe-background-recording` — Crash-safe recording that survives lock screen, backgrounding and BLE drops  [L]

**Why:** Every long test (charge cycle, power-bank drain) dies today when the phone locks: no UIBackgroundModes, no restore identifier, SessionRecorder holds every reading in RAM. This is the change that makes WattBench a logger instead of a demo and it is the prerequisite for auto-stop, alerts and the later Live Activity.

**Spec:**

(1) Background: project.yml adds UIBackgroundModes [bluetooth-central] (done in foundation); MeterManager.init passes [CBCentralManagerOptionRestoreIdentifierKey: "com.thebench.wattbench.central", CBCentralManagerOptionShowPowerAlertKey: false]; implement centralManager(_:willRestoreState:): take CBCentralManagerRestoredStatePeripheralsKey.first, set delegate, keep it as `peripheral`, and if it is already connected walk peripheral.services to re-find ffe9/ffe4 and call startStreamingIfReady, else central.connect. Log every restore step so Diagnostics shows it. (2) Monotonic time: didUpdateValueFor stamps Reading(monotonic: ContinuousClock.now seconds since a process-static origin) so NTP jumps cannot distort dt; SessionStats.add prefers monotonic dt (foundation). (3) Journal: SessionRecorder creates RecordingJournal at Documents/sessions/<id>/samples.wbj on start and writes manifest.json with state .recording; every add(_:) appends one 16-byte record (UInt32 ms since startEpoch, Int32 V/I/W = value*10000 rounded); the journal buffers on the main actor and flushes on a serial utility queue every 1 s or 64 records with FileHandle.write + synchronize; manifest (stats, sampleCount, markers) is rewritten atomically every 10 s. stopRecording closes the journal, writes the final manifest with state .complete, and returns a Session whose readings are read back from the file (single pass) so save() no longer re-encodes samples as JSON. discard: true deletes the folder. (4) Gaps: pipeline passes dt; when dt > SessionStats.maxGapS the recorder appends Marker(kind: .gap, label: "Gap 2 m 14 s"); didDisconnectPeripheral while recording appends a .gap marker at reconnect time with the measured interval; gapCount/gapSeconds come from SessionStats. Elapsed shown in the UI is stats.durationS (excludes gaps) with the wall-clock span shown secondary. (5) Recovery: SessionStore.load finds manifests with state .recording, seals them (endTime = last record time, stats replayed from the file, state .recovered, name prefixed "Recovered: ") into store.interrupted; WattBenchApp presents RecoverySheet (Keep / Discard). A recording is never auto-resumed after a relaunch (state restoration relaunches reconnect the meter but start no recording). (6) Demo source is foreground-only: startDemo logs it and the recording sheet shows a footer when in demo mode. (7) Memory: recorder keeps no readings array; live charts keep using the 1200-sample ring; a 4-hour recording (144k samples) holds at most 64 buffered records. (8) Metadata: AppStore/metadata.md review note rewritten to say Bluetooth runs in the background only while connected so multi-hour recordings complete, plus a Battery footnote in Settings (WS-D copies the string). (9) Truncated tail: RecordingJournal.read ignores a trailing partial record and never throws for it; a missing samples.wbj yields StoreError.corruptSamples and the summary still lists with a "Samples unavailable" row (WS-C handles).

**UI:**

RecoverySheet (Views/Components/RecoverySheet.swift, WS-A): modelled on Voice Memos' interrupted-recording prompt, .presentationDetents([.medium]), title "Recording was interrupted", the session name, a 2x2 grid of Energy / Capacity / Duration / Samples in .title2 rounded monospaced digits, footer "WattBench closed while recording. The samples written so far were kept.", Keep (.borderedProminent) and Discard (role: .destructive, confirmationDialog). Gap markers render in every chart as RectangleMark bands (WS-B/WS-C draw them; WS-A only emits them). Diagnostics shows journal path, bytes written and last flush time via diagnosticsText.

**Files to add:** ios/WattBench/Model/Storage/RecordingJournal.swift (complete), ios/WattBench/Views/Components/RecoverySheet.swift, ios/WattBenchTests/Core/RecordingJournalTests.swift, ios/WattBenchTests/Core/RecoveryTests.swift

**Files to modify:** ios/WattBench/Bluetooth/MeterManager.swift, ios/WattBench/Model/SessionRecorder.swift, ios/WattBench/Model/Storage/SessionStore.swift, ios/WattBench/WattBenchApp.swift, ios/project.yml, ios/AppStore/metadata.md

**Data model changes:** samples.wbj binary journal (header 16 B magic WBJ1 + version + startEpoch; 16-byte records t_ms/V/I/W native units); manifest.json = SessionSummary with state recording|complete|recovered; Marker.kind .gap entries; Reading.monotonic populated for live readings only (never persisted).

**Acceptance criteria:**

- Lock the phone for 20 minutes mid-recording with the meter streaming: the saved session's sampleCount grows by roughly 12,000 and gapCount stays 0.
- Force-quit the app mid-recording, relaunch: RecoverySheet appears, Keep produces a session with all records up to the last flush (at most 1 s lost) and state recovered.
- Power the meter off for 30 s while recording: one gap marker with the measured duration appears, durationS excludes it, energyWh is unchanged by the gap, and recording continues after reconnect.
- A 4-hour synthetic recording via FixtureSource keeps resident memory flat (no readings array) and the journal file is exactly 16 + 16 * sampleCount bytes.
- Truncating samples.wbj by 7 bytes still loads sampleCount - 1 readings without error.

**Tests:**

- RecordingJournalTests.testAppendReadRoundTripIsBitExact (values quantised to 1/10000)
- RecordingJournalTests.testTruncatedTrailingRecordIgnored
- RecordingJournalTests.testFlushEvery64RecordsOr1Second (injected clock)
- RecoveryTests.testInterruptedManifestIsSealedAsRecovered
- RecoveryTests.testDiscardRemovesFolder
- SessionRecorderTests.testGapMarkerAppendedWhenDtExceeds5s
- SessionStatsTests.testMonotonicDtUsedWhenPresent
- MeterManagerTests.testWillRestoreStateReattachesDelegate (fake peripheral protocol seam)

### `A2-sessions-that-scale` — Summary index + lazy binary samples with migration of 1.0 JSON sessions  [M]

**Why:** SessionStore.load decodes every reading of every session at launch; one hour at 10 Hz is ~36k readings and background recording makes multi-hour sessions normal, so the Sessions tab would get slower every week and eventually crash on launch. The journal from A1 becomes the canonical samples file.

**Spec:**

SessionStore internals: on load, enumerate Documents/sessions/*/manifest.json (decode SessionSummary only) plus any legacy root *.json; sort newest first; never decode samples at launch. session(for:) and samples(for:) read samples.wbj in Task.detached, decode to [Reading] (timestamp = startEpoch + t_ms/1000, monotonic 0) and hop back to main. save(_ s: Session): if the folder already has samples.wbj (came from a recorder) write only the manifest; otherwise (imports, tests, legacy) write both files. delete removes the folder. rename/update rewrite manifest.json atomically and update summaries in place. Sparkline: at save time compute 60 mean-power points via Decimator.minMaxBuckets(targetCount: 60) and store in the manifest so list rows never touch samples. csvURL writes to FileManager.temporaryDirectory/exports/<name>_<id8>.csv (directory cleared in init) and streams rows with a cached ISO8601 formatter plus elapsed_s and marker_label columns after the original four. Migration (LegacyMigration.swift): for each root <uuid>.json: decode Session (v1 fields), write folder manifest + samples.wbj, verify RecordingJournal.count == readings.count and manifest decodes, then delete the legacy file; on any failure keep the legacy file, log to loadError, and still list it by decoding lazily. Runs synchronously on first load if <= 5 legacy files, otherwise in a background task with a progress row (summaries gains a `migrating: Int` count). Demo sessions carry isDemo = true so exports and trips can exclude them. 100k samples: samples(for:) decodes ~1.6 MB in < 50 ms; views must decimate before charting.

**UI:**

No new screens. Sessions list shows a ProgressView row "Updating 12 sessions…" only during a background migration. Detail views show a .redacted skeleton while samples load (WS-C).

**Files to add:** ios/WattBench/Model/Storage/LegacyMigration.swift, ios/WattBenchTests/Core/LegacyMigrationTests.swift, ios/WattBenchTests/Core/SessionStoreLazyTests.swift, ios/WattBenchTests/Fixtures/session-v1.json (10 readings, generated by 1.0 encoder)

**Files to modify:** ios/WattBench/Model/Storage/SessionStore.swift, ios/WattBench/Model/Storage/SessionSummary.swift, ios/WattBench/Model/Reading.swift (csv columns, summary()), ios/WattBenchTests/Core/SessionStoreTests.swift

**Data model changes:** Per-session folder Documents/sessions/<uuid>/{manifest.json, samples.wbj}; legacy <uuid>.json removed after verified migration; SessionSummary.sparkline [Float]; CSV gains elapsed_s and marker_label columns after timestamp,voltage_v,current_a,power_w; exports live in tmp.

**Acceptance criteria:**

- 50 synthetic one-hour sessions (36k samples each) load summaries in under 300 ms on an iPhone 12 and resident memory stays flat while scrolling the list.
- A 1.0 session JSON placed in the directory is migrated on first load with identical stats, sampleCount and sub-second spacing, and the legacy file is deleted only after verification.
- Deleting a session removes its folder; renaming updates manifest and summaries without touching samples.wbj.
- Documents/sessions contains no .csv files after sharing.

**Tests:**

- LegacyMigrationTests.testV1FixtureMigratesLosslessly
- LegacyMigrationTests.testCorruptLegacyFileIsKeptAndReported
- SessionStoreLazyTests.testLoadDoesNotReadSamples (file access counter via injected FileManager wrapper or timing)
- SessionStoreLazyTests.testSaveRenameUpdateDeleteRoundTrip
- SessionStoreLazyTests.testMissingSamplesFileYieldsCorruptSamplesButSummaryListed
- SessionCSVTests.testFirstFourColumnsUnchangedAndMarkerColumnAppended
- SessionCSVTests.test100kRowsUnderTwoSeconds

### `A3-sample-pipeline-trips-extremes` — SamplePipeline: ring buffer, 5 Hz chart snapshots, trip meter, peak hold, testability seam  [M]

**Why:** ingest does history.removeFirst (O(n)) and mutates observed state 10 times a second so the whole LiveView re-renders per sample; 90 percent of bench use is plug in, glance, unplug, so Wh/mAh must accumulate without a named session; peak inrush is only visible inside a saved session today; and nothing in ingest is unit-testable without a peripheral.

**Spec:**

SamplePipeline (pure @MainActor class, no CoreBluetooth): ingest(r, recording:, observers:, connection:) performs the ordered steps in the architecture. RingBuffer replaces the history array (capacity 1200). ChartSnapshot is published at most every 200 ms: points = Decimator.window(history, seconds: 120) as [Reading] capped to <= 600 by minMax buckets when the ring holds more, gaps = intervals where consecutive dt > 5 s; the hero numeral reads meter.latest (10 Hz) while charts read meter.chart (5 Hz). TripMeter: one trip persisted in UserDefaults key trip.0 as JSON on a 10 s debounce and on stop/background (scenePhase observed in WattBenchApp); add(r) uses SessionStats.add with the gap guard so a reconnect pause is not integrated; elapsed = durationS; resetTrip(0) restarts at now and fires recordingEventCount-independent tripResetCount += 1 for haptics; trips exclude demo readings when Preferences.excludeDemoFromTrips is true (default true). Extremes.update tracks max/min V, I and max W with timestamps since the last reset; both Extremes and TripMeter live on MeterManager and are Codable. avgPower fix (foundation). MeterSource protocol: BLE source is MeterManager's own delegate path; DemoSource (Timer, existing sine model moved out of MeterManager) and FixtureSource (replays [Reading] with real dt via Task.sleep, used by tests and the simulator) both conform; MeterManager.attach(source:) routes onReading -> ingest. Concurrency: everything @MainActor; RingBuffer is a value type. Chart snapshot publish also runs on a 200 ms Timer while connected so a stalled stream still refreshes the gaps band and stale state. Frame accounting stays: framesReceived/framesParsed plus new framesRejected exposed for the Diagnostics screen.

**UI:**

No views in this stream. Provides the data WS-B renders: TripCard reads meter.trips[0] (energyWh big, capacityAh + elapsed small, peak W caption) and calls resetTrip(0); SecondaryTile captions read meter.extremes ("PEAK 27.4 W 14:02:11", labelled peak (100 ms)).

**Files to add:** ios/WattBench/Model/Pipeline/SamplePipeline.swift (complete), ios/WattBench/Bluetooth/DemoSource.swift, ios/WattBench/Bluetooth/FixtureSource.swift, ios/WattBenchTests/Core/SamplePipelineTests.swift, ios/WattBenchTests/Core/TripMeterTests.swift, ios/WattBenchTests/Core/ExtremesTests.swift

**Files to modify:** ios/WattBench/Bluetooth/MeterManager.swift, ios/WattBench/Bluetooth/MeterSource.swift, ios/WattBench/Model/Pipeline/RingBuffer.swift, ios/WattBench/Model/Pipeline/ChartSnapshot.swift, ios/WattBench/Model/Pipeline/TripMeter.swift, ios/WattBench/Model/Pipeline/Extremes.swift

**Data model changes:** UserDefaults keys trip.0 (TripMeter JSON) and extremes.since; MeterManager.history removed in favour of chart: ChartSnapshot; framesRejected counter.

**Acceptance criteria:**

- Feeding 10,000 readings through SamplePipeline in a test produces at most one ChartSnapshot per 200 ms of reading time and the ring never exceeds 1200.
- Trip Wh/mAh survive app relaunch and a BLE reconnect; a 60 s gap adds nothing to the trip and the elapsed value excludes it.
- Tapping reset zeroes the trip and its persisted copy within 10 s.
- Extremes report the correct maxima with timestamps after a synthetic inrush spike and reset independently of the trip.

**Tests:**

- SamplePipelineTests.testRingBufferBoundsHistory
- SamplePipelineTests.testSnapshotThrottledTo5Hz
- SamplePipelineTests.testGapIntervalsDetected
- SamplePipelineTests.testObserversReceiveContext
- TripMeterTests.testPersistsAndRestores
- TripMeterTests.testGapNotIntegrated
- TripMeterTests.testResetRestartsClock
- ExtremesTests.testTracksMaxMinWithTimestamps
- FixtureSourceTests.testReplaysWithOriginalSpacing

### `A4-reconnect-policy-autoconnect` — ReconnectPolicy with backoff and give-up, zero-tap auto-connect, event counters  [S]

**Why:** didDisconnectPeripheral calls central.connect immediately and forever with the banner stuck on Connecting; the user's first hour was spent fighting the connection. A visible countdown, an honest unreachable state and auto-connect on launch remove the daily friction.

**Spec:**

On unexpected disconnect with wantsAutoReconnect: policy = ReconnectPolicy(); loop: delay = policy.nextDelay(now) (1,2,4,8,16,30,30… until 120 s since first failure) -> state = .reconnecting(name, attempt, nextRetry: now + delay) -> Task.sleep -> central.connect. On nil -> state = .unreachable(name), lastError = "Meter appears to be off or out of range", errorEventCount += 1; retryNow() restarts the policy; connecting from the sheet cancels the loop. On didConnect: policy.reset(), connectionEventCount += 1, lastError = nil. Auto-connect: in centralManagerDidUpdateState(.poweredOn) if Preferences.autoConnect and hasLastDevice and state == .idle call reconnectLastDevice() (retrievePeripherals path, no scan); also when the Connect sheet sees exactly one FNB58 for 1.5 s (WS-D calls connect). Pending central.connect survives backgrounding once bluetooth-central is declared, so reconnect works with the screen off. forgetLastDevice removes the UserDefaults key. RSSI: readRSSI() every 5 s while connected -> `rssi: Int?` for the pill. All state transitions increment the right counter exactly once so .sensoryFeedback triggers fire once. Demo: startDemo disconnects and sets .demo; state never flips to .bluetoothOff while in demo (existing guard kept).

**UI:**

None in this stream; WS-B's StatusPill shows "Retrying in 8 s" via Text(timerInterval:) for .reconnecting and a Retry button for .unreachable; WS-D's Connect sheet shows the same states.

**Files to add:** ios/WattBenchTests/Core/ReconnectPolicyTests.swift, ios/WattBenchTests/Core/ConnectionStateTests.swift

**Files to modify:** ios/WattBench/Bluetooth/MeterManager.swift, ios/WattBench/Model/Pipeline/ReconnectPolicy.swift

**Data model changes:** ConnectionState.reconnecting/unreachable (foundation); MeterManager.rssi: Int?; UserDefaults lastDeviceIdentifier unchanged.

**Acceptance criteria:**

- Cold launch with the meter on and auto-connect enabled shows live data within 5 s with zero taps.
- Powering the meter off produces reconnecting states with a visible countdown and reaches unreachable within 120 s; powering it back on inside the window reconnects without user action.
- connectionEventCount increments exactly once per successful connection and errorEventCount once per give-up.

**Tests:**

- ReconnectPolicyTests.testDelaySequenceAndCap
- ReconnectPolicyTests.testGivesUpAfter120Seconds
- ReconnectPolicyTests.testResetOnSuccess
- ConnectionStateTests.testLabelsSymbolsAndTransientFlags
- MeterManagerTests.testCountersIncrementOnce (FixtureSource + fake central seam)

