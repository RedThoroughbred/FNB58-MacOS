# Workstream: WS-B Live instrument face

Read `ios/PLAN/00-overview.md` first (UI direction, architecture, foundation contract).

## Owns (only these files/folders may be created or modified)

- ios/WattBench/Views/LiveView.swift
- ios/WattBench/Views/Live/HeroReadout.swift
- ios/WattBench/Views/Live/SecondaryTile.swift
- ios/WattBench/Views/Live/StatusPill.swift
- ios/WattBench/Views/Live/MetricChartCard.swift
- ios/WattBench/Views/Live/TripCard.swift
- ios/WattBench/Views/Live/RecordBar.swift
- ios/WattBench/Views/Live/RecordingSetupSheet.swift
- ios/WattBench/Views/Live/SavedToast.swift
- ios/WattBench/Views/Live/DemoBanner.swift
- ios/WattBench/Views/Live/LiveEmptyState.swift
- ios/WattBench/Model/Pipeline/ChartWindow.swift
- ios/WattBenchTests/Live/*.swift

## Depends on

- foundation

## Shared contract this stream exposes/consumes

Views only; exposes `struct RecordingStatusChip: View` (red dot + elapsed, tap -> AppRouter.tab = .live) for WS-C's toolbar, and `enum ChartWindow: Double, CaseIterable { case s10 = 10, s30 = 30, s60 = 60, m2 = 120; var label: String }` used by Preferences.defaultWindow. Consumes MeterManager, SessionStore, Preferences, AppRouter, MetricFormatter, Decimator, ChartSnapshot, FeedbackModifiers, SettingsView (stub), AlertBanner (stub).

## Specs

### `B1-hero-readout-status-pill` — Hero numeral with numericText, tap-to-promote secondary tiles, peak captions, status pill and title menu  [M]

**Why:** The most visible Apple-esque change the user asked for: one number you can read across the bench with digits that roll instead of flicker at 10 Hz, and connection state where FaceTime and Fitness put it. Deleting the connection banner and the three equal tiles frees the space that lets the instrument face fit one screen.

**Spec:**

HeroReadout: primary metric = Preferences.heroMetric (default .power). Value via MetricFormatter.formatLive with hysteresis; hero shows number + unit; below it two SecondaryTiles for the other metrics in a ViewThatFits { HStack; VStack }. Tapping a secondary tile sets Preferences.heroMetric with matchedGeometryEffect(id: metric, in: ns) and .sensoryFeedback(.selection). Each tile shows a caption from meter.extremes: "PEAK 27.4 W · 14:02:11" (for voltage show min–max), .caption2.monospacedDigit, with an info footnote "peak (100 ms samples)" in the context menu; context menu offers Reset peaks (meter.resetExtremes(), haptic .impact(.light)) and Copy value. Staleness: TimelineView(.periodic(by: 1)) compares meter.latest?.timestamp; if older than 2 s numerals go .tertiary and the pill shows "No data"; if state is not connected show LiveEmptyState (ContentUnavailableView with Connect and Try Demo Data actions) instead of tiles and chart. Reduce Motion disables numericText and matchedGeometry. Whole hero is accessibilityElement(children: .combine) with label metric.spokenName and value MetricFormatter.spoken, trait .updatesFrequently. StatusPill (topBarLeading): Circle(8pt, state.tint) + Image(systemName: state.symbolName) with .symbolEffect(.variableColor.iterative.reversing, isActive: state.isTransient) and .symbolEffect(.bounce, value: meter.connectionEventCount) + Text(state.shortLabel).font(.footnote.weight(.medium)) + optional RSSI cellularbars(variableValue: SignalLevel.level(rssi:)); for .reconnecting append "· retry in" Text(timerInterval: now...nextRetry, countsDown: true); for .unreachable a small Retry button calling meter.retryNow(). Tap opens DeviceListView sheet. .toolbarTitleMenu on "WattBench": Connect…, Reconnect to last meter (disabled when !hasLastDevice), Disconnect (when connected), Try demo data. Demo mode: pill purple with text Demo and DemoBanner via .safeAreaInset(edge: .top). LiveView body becomes: ScrollView { VStack(spacing: 12) { HeroReadout; TripCard; MetricChartCard } .padding(.horizontal, 16) } .safeAreaInset(edge: .bottom) { RecordBar } .safeAreaInset(edge: .top) { AlertBanner } toolbar: pill + gear (Button opening SettingsView sheet). Removes connectionBanner, readoutGrid, the three chartCards, recordingCard, the slider Menu, and the Last sample caption.

**UI:**

Hero: Text(number).font(.system(size: 56, weight: .semibold, design: .rounded)).monospacedDigit().minimumScaleFactor(0.5).lineLimit(1).foregroundStyle(metric.color).contentTransition(.numericText(value: v)); unit .title3 .secondary lastTextBaseline aligned; label above in the caption2 uppercase tracking style. Secondary tiles: label, .title2 rounded semibold monospaced value, unit .caption .secondary, peak caption, on secondarySystemGroupedBackground card radius 20 continuous, accessibilityHint "Double-tap to make this the large readout". Pill: padding(.horizontal 10, .vertical 5), .thinMaterial Capsule through .floatingChrome(Capsule()). Empty state: ContentUnavailableView { Label("No Meter Connected", systemImage: "powermeter") } description: Text("Turn on Bluetooth in the FNB58's settings menu, then connect.") actions: Connect (.borderedProminent), Try Demo Data (.bordered).

**Files to add:** ios/WattBench/Views/Live/HeroReadout.swift, ios/WattBench/Views/Live/SecondaryTile.swift, ios/WattBench/Views/Live/StatusPill.swift, ios/WattBench/Views/Live/LiveEmptyState.swift, ios/WattBench/Views/Live/DemoBanner.swift, ios/WattBenchTests/Live/HeroStateTests.swift

**Files to modify:** ios/WattBench/Views/LiveView.swift

**Data model changes:** None (reads Preferences.heroMetric, meter.extremes, meter.rssi, counters).

**Acceptance criteria:**

- On a 6.1-inch iPhone at default text size the pill, hero, two tiles, trip card, chart and record bar are visible without scrolling.
- Tapping a secondary tile swaps it into the hero slot with a matched-geometry animation and persists across launches; with Reduce Motion on, no numericText or matched animation runs.
- When frames stop for 2 s the numerals dim and the pill reads No data; when the meter is unreachable the pill shows Retry.
- Demo mode always shows the purple pill and the top banner on the Live tab.

**Tests:**

- HeroStateTests.testStaleAfterTwoSeconds (pure HeroState.isStale(latest:now:))
- HeroStateTests.testSecondaryOrderForEachHeroMetric
- HeroStateTests.testPeakCaptionFormatting

### `B2-single-scrubbable-chart` — One interactive chart card: V / A / W / All segmented, scrollable window, scrub cursor, peak line, gap bands, markers  [L]

**Why:** Three passive 140pt strips recompute windowedHistory three times per body at 10 Hz. One touchable surface like Health or Stocks reads a value under the finger, hosts markers and gaps, and frees ~300pt.

**Spec:**

MetricChartCard reads meter.chart (5 Hz snapshot) and never meter.latest. Controls: Picker("Metric", selection: $metric).pickerStyle(.segmented) with V / A / W / All above the plot; window Picker(.segmented) with ChartWindow cases below it (initial value Preferences.defaultWindow; persisted in @SceneStorage). Plot: Chart { ForEach(points) LineMark + AreaMark for the selected metric; for .all three LineMarks each normalised to its own min–max in the window (pure ChartWindow.normalise) with a legend and per-metric dash pattern when accessibilityDifferentiateWithoutColor; ForEach(snapshot.gaps) RectangleMark(xStart:xEnd:) secondary 0.15; ForEach(recording.markers) RuleMark(x:) dashed accent with .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) capsule label; peak-hold RuleMark(y: extremes.max for metric) dashed metric color 0.6 opacity toggled in the context menu }. Modifiers: .chartScrollableAxes(.horizontal), .chartXVisibleDomain(length: window.rawValue), .chartScrollPosition(x: $scrollX) pinned to the newest sample unless the user scrolled back (resume-live button appears), .chartXSelection(value: $cursor) producing a RuleMark hairline plus annotation with MetricFormatter value(s) and time .dateTime.minute().second(); .chartYScale(domain: Decimator.yDomain(points)); axis marks desiredCount 4; frame(height: 220). Performance: the card is its own View struct taking only the snapshot, metric and window so a 10 Hz `latest` change does not invalidate it; points never exceed 600. Context menu: Clear chart (meter.clearHistory()), Show peak line toggle, Copy value under cursor. Accessibility: .accessibilityChartDescriptor built from the same points (AXNumericDataAxisDescriptor for time and value). Haptics: .sensoryFeedback(.selection, trigger: metric) and window. Empty: overlay Text("Waiting for data") only when connected and points.isEmpty.

**UI:**

Card on secondarySystemGroupedBackground radius 20 continuous, 16pt padding; header row = metric title + live value in .callout.monospacedDigit .secondary. Scrub annotation: VStack { Text(value).font(.callout.monospacedDigit().weight(.semibold)); Text(time).font(.caption2) }.padding(8).background(.regularMaterial, in: .rect(cornerRadius: 8)). Resume-live: small capsule button "Live" bottom-trailing with arrow.right.to.line. Never animate the line; the only animation is on the y-domain change (.snappy).

**Files to add:** ios/WattBench/Views/Live/MetricChartCard.swift, ios/WattBench/Model/Pipeline/ChartWindow.swift, ios/WattBenchTests/Live/ChartWindowTests.swift

**Files to modify:** ios/WattBench/Views/LiveView.swift

**Data model changes:** None; @SceneStorage chart.window and chart.metric.

**Acceptance criteria:**

- With a 10 Hz stream the chart body re-evaluates at most 5 times per second (Instruments SwiftUI view body count) and scrolling the window is smooth on an iPhone 12.
- Dragging shows a hairline and the exact V/A/W value and time under the finger; releasing hides it.
- Gap bands, user markers and the peak line all render on the live chart; All mode shows three normalised series with a legend.
- Switching window keeps the newest sample pinned to the trailing edge unless the user has scrolled back.

**Tests:**

- ChartWindowTests.testNormaliseMapsMinMaxToZeroOne
- ChartWindowTests.testWindowSliceIsTimeBounded
- ChartWindowTests.testYDomainPaddingAndFlatLineFallback

### `B3-record-bar-setup-sheet-markers` — Bottom Record bar, recording setup sheet with tags/notes/auto-stop, Mark button, save toast with Undo and Discard  [M]

**Why:** Replaces the .alert-with-TextField and the recording card with the Voice Memos gesture; unattended charge tests end themselves; markers replace scribbling times on paper; today stopRecording always saves even a zero-sample session and there is no discard.

**Spec:**

RecordBar via .safeAreaInset(edge: .bottom) on .bar material. Idle: one prominent Record button (disabled with .tertiary when !meter.state.isConnected) opening RecordingSetupSheet. Recording: pulsing record.circle, Text(timerInterval: rec.startTime...Date.distantFuture, countsDown: false).monospacedDigit(), Wh + mAh from rec.stats via MetricFormatter, current auto-stop rule glyph if set, Mark button (bookmark), Stop button. Mark: tap adds Marker(label: "Mark \(n)"); long-press shows a Menu of quick labels Plugged in, Unplugged, Cable swapped, Load changed, Custom… (TextField alert) and calls meter.addMarker(label:) with .sensoryFeedback(.impact(weight: .light)). Stop: if rec.stats.samples == 0 show confirmationDialog "No samples were recorded" with Discard; otherwise stopRecording() saves immediately via store.save, shows SavedToast "Saved · 3.21 Wh" for 5 s with Undo (deletes the session via store.delete(id:)) and .sensoryFeedback(.stop). A Discard action lives in the bar's overflow Menu while recording (confirmationDialog, calls stopRecording(discard: true)). RecordingSetupSheet (.presentationDetents([.medium, .large]), drag indicator): Form with TextField("Name") prefilled "\(deviceName) · \(date, .dateTime.month().day().hour().minute())" and .textInputAutocapitalization(.words); a horizontal chip row of tags (Charger, Cable, Power bank, Device, plus recently used tags from store.summaries) toggling membership; optional Note TextField(axis: .vertical); Section("Stop automatically") with Toggle "When current stays below" + value Stepper (default 0.10 A, step 0.05) + "for" Picker (30 s, 1 min, 2 min, 5 min), Toggle "After duration" + Picker (30 min, 1 h, 2 h, 4 h, 8 h), Toggle "At energy" + TextField(.decimalPad) Wh; the composed AutoStopRule is remembered in Preferences.defaultAutoStop. Confirmation action Start Recording calls meter.startRecording(name:tags:notes:autoStop:) and fires .sensoryFeedback(.start). Auto-stop completion: when meter.recording becomes nil with recordingEventCount change and the saved session has autoStopReason, the toast reads "Stopped automatically · current below 0.10 A". Demo mode footer in the sheet: "Demo recordings run only while the app is open." Sessions tab chip: RecordingStatusChip implemented here (red dot with .symbolEffect(.pulse), Text(timerInterval:), Button sets router.tab = .live).

**UI:**

Idle bar: Button { } label: { Label("Record", systemImage: "record.circle.fill") }.buttonStyle(.borderedProminent).controlSize(.large).tint(.red) centred with 12pt padding. Recording bar: HStack(spacing: 12) { Image(systemName: "record.circle").foregroundStyle(.red).symbolEffect(.pulse, isActive: true); timer .title3.monospacedDigit; Spacer; VStack(alignment: .trailing) { energy .callout.monospacedDigit; capacity .caption2 .secondary }; Button(Mark, systemImage: bookmark).buttonStyle(.bordered).buttonBorderShape(.circle); Button(Stop, systemImage: stop.fill).buttonStyle(.borderedProminent).tint(.red).buttonBorderShape(.circle) }. Record/Stop glyph uses .contentTransition(.symbolEffect(.replace)). Toast: Label("Saved", systemImage: "checkmark.circle.fill") with .symbolEffect(.bounce, options: .nonRepeating) in a .regularMaterial capsule above the bar, Undo as a text button.

**Files to add:** ios/WattBench/Views/Live/RecordBar.swift, ios/WattBench/Views/Live/RecordingSetupSheet.swift, ios/WattBench/Views/Live/SavedToast.swift, ios/WattBench/Views/Live/RecordingStatusChip.swift (replaces stub), ios/WattBenchTests/Live/RecordingSetupModelTests.swift

**Files to modify:** ios/WattBench/Views/LiveView.swift, ios/WattBench/Views/Live/TripCard.swift

**Data model changes:** None beyond foundation (tags, notes, markers, autoStop on startRecording).

**Acceptance criteria:**

- Start-to-recording is two taps (Record, Start Recording) with the name prefilled; Stop saves without prompting and shows a toast whose Undo removes the session.
- A zero-sample stop offers Discard instead of saving.
- With the below-current rule at 0.10 A for 60 s, a FixtureSource taper ends the recording exactly once and the session carries autoStopReason and a .autoStop marker.
- Mark adds a labelled marker that appears on the live chart within one snapshot (200 ms).

**Tests:**

- RecordingSetupModelTests.testDefaultNameComposition
- RecordingSetupModelTests.testRuleCompositionFromToggles
- RecordingSetupModelTests.testRecentTagsFromSummariesDeduped

### `B4-trip-card` — Always-on Trip card under the hero  [S]

**Why:** The odometer of a bench meter: how much went into this device since I plugged it in, with no naming ceremony, mirroring the Stopwatch lap aesthetic.

**Spec:**

TripCard reads meter.trips[0]: Wh as the big number (MetricFormatter.energy), mAh and elapsed (Duration formatted hourMinuteSecond from stats.durationS) as secondaries, peak W caption from stats.maxPower and time-weighted average power from stats.avgPower. Header "TRIP" with "since 14:02" caption. Tap the Reset button (or long-press the card) -> confirmationDialog when energyWh > 0.01 -> meter.resetTrip(0) with .sensoryFeedback(.impact(weight: .light)). Paused glyph (pause.circle) appears when meter.state is not connected or the last sample is older than 5 s, since the gap guard stops integration. Context menu: Reset, Copy values ("3.21 Wh · 870 mAh · 1:02:14"). Demo readings are excluded by the pipeline; the card shows "Demo readings are not counted" footnote in demo mode. Numbers use numericText transitions gated on Reduce Motion.

**UI:**

Card radius 20 continuous; HStack { VStack(alignment: .leading) { label TRIP; Text(wh).font(.system(.title, design: .rounded).weight(.semibold)).monospacedDigit(); HStack(spacing: 8) { Text(mAh); Text("·"); Text(elapsed) }.font(.subheadline.monospacedDigit()).foregroundStyle(.secondary); Text("Peak 27.4 W · avg 18.2 W").font(.caption2.monospacedDigit()).foregroundStyle(.secondary) }; Spacer(); Button("Reset", systemImage: "arrow.counterclockwise").buttonStyle(.bordered).buttonBorderShape(.capsule) }.

**Files to add:** ios/WattBench/Views/Live/TripCard.swift

**Files to modify:** ios/WattBench/Views/LiveView.swift

**Data model changes:** None (TripMeter from A3).

**Acceptance criteria:**

- Trip values accumulate while connected with no recording running and survive relaunch.
- Reset requires confirmation when the trip holds more than 0.01 Wh and clears immediately otherwise.
- The paused glyph shows within 5 s of the stream stopping.

**Tests:**

- Covered by TripMeterTests in WS-A; view has no logic beyond formatting.

