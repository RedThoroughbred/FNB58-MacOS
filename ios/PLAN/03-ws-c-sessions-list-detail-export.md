# Workstream: WS-C Sessions list, detail, export

Read `ios/PLAN/00-overview.md` first (UI direction, architecture, foundation contract).

## Owns (only these files/folders may be created or modified)

- ios/WattBench/Views/HistoryView.swift
- ios/WattBench/Views/Sessions/SessionsListView.swift
- ios/WattBench/Views/Sessions/SessionRow.swift
- ios/WattBench/Views/Sessions/SessionSparkline.swift
- ios/WattBench/Views/Sessions/SessionDetailView.swift
- ios/WattBench/Views/Sessions/StatTile.swift
- ios/WattBench/Views/Sessions/SessionChart.swift
- ios/WattBench/Views/Sessions/RangeStatsCard.swift
- ios/WattBench/Views/Sessions/MarkersSection.swift
- ios/WattBench/Model/Analysis/Decimator.swift
- ios/WattBench/Model/Analysis/RangeStats.swift
- ios/WattBench/Model/Analysis/SessionQuery.swift
- ios/WattBench/Export/SessionExport.swift
- ios/WattBenchTests/Sessions/*.swift

## Depends on

- foundation

## Shared contract this stream exposes/consumes

Decimator (landed in foundation, owned here for tests): `struct DecimatedPoint { let time: Date; let min: Double; let max: Double; let mean: Double }`; `enum Decimator { static func minMaxBuckets(_ readings: ArraySlice<Reading>, metric: Metric, targetCount: Int) -> [DecimatedPoint]; static func yDomain(_ points: [DecimatedPoint], padding: Double = 0.05) -> ClosedRange<Double>; static func window(_ readings: [Reading], seconds: TimeInterval) -> ArraySlice<Reading> }`. RangeStats: `enum RangeStats { static func indexRange(in readings: [Reading], from: Date, to: Date) -> Range<Int>; static func stats(_ slice: ArraySlice<Reading>) -> SessionStats }`. SessionQuery: `enum SortOrder: String, CaseIterable { case newest, longest, mostEnergy }`, `struct SessionQuery { static func group(_ s: [SessionSummary], calendar: Calendar) -> [(day: Date, sessions: [SessionSummary])]; static func filter(_ s: [SessionSummary], query: String) -> [SessionSummary]; static func sorted(_ s: [SessionSummary], by: SortOrder) -> [SessionSummary] }`. SessionExport: `struct SessionExport: Transferable { let session: Session }` with FileRepresentation(.commaSeparatedText) and ProxyRepresentation(summary text).

## Specs

### `C1-session-detail-report` — Session detail as a report: stat tiles, per-metric scroll/zoom chart with envelope, scrub and range selection, markers, rename, notes  [L]

**Why:** The current detail chart plots V and A on one y axis with stride decimation that deletes one-sample spikes, and stats are a flat list. Bench work is about the shape (CC-to-CV knee, sag, power-bank cut-off) and about 'how much energy went in during that phase'.

**Spec:**

Loads samples lazily: on appear `readings = try await store.samples(for: id)` in a task; show .redacted skeleton until then; StoreError.corruptSamples shows a "Samples unavailable" row while tiles still render from the summary. Header: three StatTiles (Energy, Capacity, Duration) then a secondary row (Avg power, Peak power, V range, I range, Gaps if gapCount > 0). SessionChart: Picker V / A / W segmented; points = Decimator.minMaxBuckets(readings[...], metric, targetCount: 4 * visible pixel width / 2 capped 1500), recomputed when the visible domain changes (debounced 100 ms) and cached per (metric, bucket seconds); marks = AreaMark(yStart: min, yEnd: max) at 0.18 opacity when any bucket has > 1 sample, LineMark(mean) on top; gap markers as RectangleMark bands; markers as dashed RuleMarks with capsule labels; alert/autoStop markers use the red tint. .chartScrollableAxes(.horizontal) with .chartXVisibleDomain(length: visibleSeconds) driven by a window Picker (All / 1 h / 10 min / 1 min) plus MagnifyGesture that scales visibleSeconds between 10 s and the full duration. .chartXSelection(value: $cursor) shows time-elapsed and V/A/W at the nearest raw reading (binary search). .chartXSelection(range: $range): when set, RangeStatsCard slides in with RangeStats.stats over the slice: duration, Wh, mAh, avg V/A/W, min/max, peak W, and the fraction of session energy; a Save as marker pair button adds two markers labelled Range start/end. Title editable via navigationTitle(_: Binding) persisted with store.rename; toolbar Menu: Rename, Delete (confirmationDialog), Share (ShareLink(item: SessionExport(session)) preview with waveform.path.ecg), Copy summary text. MarkersSection lists markers with elapsed time, V/A/W at that instant and Wh between consecutive markers (RangeStats over each span); tapping scrolls the chart to that instant (chartScrollPosition) and sets the cursor; swipe to delete a user marker (store.update markers via save(session)). Notes section: TextField(axis: .vertical) saved on submit through store.update(notes:). Tags shown as capsules under the title with an Edit sheet. Integrity row: sample rate = samples / durationS, gaps count and seconds, device name, demo badge when isDemo.

**UI:**

StatTile: VStack(alignment: .leading) { caption2 uppercase label; Text(value).font(.system(.title, design: .rounded).weight(.semibold)).monospacedDigit(); unit .caption .secondary } on secondarySystemGroupedBackground radius 20, three across in ViewThatFits (HStack, then 2+1 grid). Chart height 260 in a full-width card; scrub annotation identical to the Live card; RangeStatsCard on .regularMaterial with .transition(.move(edge: .bottom).combined(with: .opacity)) and a close button. Sections named Highlights, Chart, Markers, Notes, Integrity in an inset grouped List below the header. Title menu via .toolbarTitleMenu. Envelope band uses the metric colour at 0.18 opacity; mean line 2pt.

**Files to add:** ios/WattBench/Views/Sessions/SessionDetailView.swift, ios/WattBench/Views/Sessions/StatTile.swift, ios/WattBench/Views/Sessions/SessionChart.swift, ios/WattBench/Views/Sessions/RangeStatsCard.swift, ios/WattBench/Views/Sessions/MarkersSection.swift, ios/WattBench/Model/Analysis/RangeStats.swift, ios/WattBenchTests/Sessions/RangeStatsTests.swift, ios/WattBenchTests/Sessions/DecimatorTests.swift

**Files to modify:** ios/WattBench/Views/HistoryView.swift (remove SessionDetailView, ShareSheet, URL extension), ios/WattBench/Model/Analysis/Decimator.swift

**Data model changes:** None beyond foundation (markers, notes, tags persisted via store.update/save).

**Acceptance criteria:**

- A one-sample 1 mA to 3 A spike remains visible after decimation at every zoom level.
- Scrubbing a 144k-sample session stays at 60 fps (cursor lookup is a binary search over a pre-bucketed array; no raw array is handed to Chart).
- Drag-selecting a range shows stats for just that slice and they equal the whole-session stats when the range covers everything.
- Rename, notes and marker deletion persist and are reflected in the list immediately.

**Tests:**

- RangeStatsTests.testIndexRangeBinarySearchBoundaries
- RangeStatsTests.testFullRangeEqualsSessionStats
- RangeStatsTests.testEnergyBetweenMarkers
- DecimatorTests.testPreservesGlobalMinAndMax
- DecimatorTests.testBucketCountAndMonotonicTime
- DecimatorTests.testSingleSampleBucketsHaveNoEnvelope
- DecimatorTests.testYDomainPadding

### `C2-sessions-list-and-sharelink` — Sessions list with day grouping, search, sort, sparklines, swipe/context actions, and ShareLink + Transferable export  [M]

**Why:** Once the user has thirty captures of cables and chargers, finding one takes a swipe or a typed word instead of opening each; and the UIKit ShareSheet bridge plus the retroactive URL: Identifiable extension go away in favour of system share previews everywhere.

**Spec:**

SessionsListView replaces HistoryView: reads store.summaries; SessionQuery.group by calendar day with headers Today / Yesterday / weekday, month day; .searchable(text:) over name, deviceName, tags and notes with .searchSuggestions of recent tags; Sort menu (Newest, Longest, Most energy) persisted in @AppStorage; rows: name .headline, HStack(start .dateTime.hour().minute(), duration, energy) .subheadline.monospacedDigit .secondary, tag capsules .caption2, recovered badge (exclamationmark.triangle orange) when state == .recovered, Demo badge when isDemo, trailing SessionSparkline (Chart of summary.sparkline, hidden axes, 72x32, Color.power). Swipe leading: Rename (alert with TextField -> store.rename); trailing: Share (ShareLink) and Delete (role .destructive, confirmationDialog). Context menu with preview (a larger sparkline card): Rename, Share CSV, Copy summary, Delete. EditButton multi-select with bulk Delete and ShareLink(items:). Empty states: ContentUnavailableView("No sessions yet") and ContentUnavailableView.search. Interrupted recording: if store.interrupted != nil show a top Section with the RecoverySheet's actions inline. Toolbar leading shows RecordingStatusChip when meter.recording != nil. Navigation via router.sessionPath so later deep links work. SessionExport: FileRepresentation(exportedContentType: .commaSeparatedText, exporting: { export in SentTransferredFile(try export.writeCSV(to: FileManager.default.temporaryDirectory)) }) using Session.csv(), plus ProxyRepresentation(exporting: \.summaryText) ("Anker 65W · 27.4 Wh · 1 h 42 m · peak 61.3 W"). Diagnostics share becomes ShareLink(item: meter.diagnosticsText) (WS-D applies). Because ShareLink needs a full Session for CSV, SessionExport takes the summary and loads samples in the exporting closure via store.session(for:) (async inside FileRepresentation is allowed) so the list never preloads samples.

**UI:**

List(.insetGrouped). Row layout as above; section headers via Text(day, format: .dateTime.weekday(.wide).month().day()) with Today/Yesterday relative names. Sparkline uses LineMark only, .chartXAxis(.hidden), .chartYAxis(.hidden). Swipe tints: Rename .orange, Share .blue, Delete .red; .sensoryFeedback(.impact(weight: .light), trigger: store.saveCount) on delete. Recovered badge tint orange; Demo badge purple capsule.

**Files to add:** ios/WattBench/Views/Sessions/SessionsListView.swift, ios/WattBench/Views/Sessions/SessionRow.swift, ios/WattBench/Views/Sessions/SessionSparkline.swift, ios/WattBench/Model/Analysis/SessionQuery.swift, ios/WattBench/Export/SessionExport.swift, ios/WattBenchTests/Sessions/SessionQueryTests.swift, ios/WattBenchTests/Sessions/SessionExportTests.swift

**Files to modify:** ios/WattBench/Views/HistoryView.swift (reduced to `typealias HistoryView = SessionsListView` then deleted at the end)

**Data model changes:** @AppStorage sessions.sort; nothing persisted otherwise.

**Acceptance criteria:**

- Sessions group correctly across midnight and a DST change; search matches name, device, tag and note text; sort orders are stable.
- Share from the detail toolbar, a swipe, a context menu and multi-select all produce a .csv whose header is timestamp,voltage_v,current_a,power_w,elapsed_s,marker_label and whose file lives in the temporary directory.
- No UIActivityViewController or URL: Identifiable code remains in the target.

**Tests:**

- SessionQueryTests.testGroupsAcrossMidnightAndDST
- SessionQueryTests.testFilterMatchesTagsAndNotesCaseInsensitive
- SessionQueryTests.testSortOrders
- SessionExportTests.testCSVFileHasCSVExtensionAndHeader
- SessionExportTests.testSummaryTextUsesMetricFormatter

