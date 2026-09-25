# Workstream: WS-D Settings, Connect, formatting, feedback, app shell

Read `ios/PLAN/00-overview.md` first (UI direction, architecture, foundation contract).

## Owns (only these files/folders may be created or modified)

- ios/WattBench/Views/ContentView.swift
- ios/WattBench/Views/Connect/DeviceListView.swift
- ios/WattBench/Views/Connect/ConnectEmptyState.swift
- ios/WattBench/Views/Settings/SettingsView.swift
- ios/WattBench/Views/Settings/AboutView.swift
- ios/WattBench/Views/Settings/DiagnosticsView.swift
- ios/WattBench/Views/Components/FeedbackModifiers.swift
- ios/WattBench/Views/Components/MetricStyle.swift
- ios/WattBench/Views/Components/FloatingChrome.swift
- ios/WattBench/Model/Format/Metric.swift
- ios/WattBench/Model/Format/MetricFormatter.swift
- ios/WattBench/Model/Format/Preferences.swift
- ios/WattBench/Model/Format/AppRouter.swift
- ios/WattBench/Model/Format/SignalLevel.swift
- ios/WattBench/Assets.xcassets/*
- ios/WattBenchTests/Format/*.swift

## Depends on

- foundation

## Shared contract this stream exposes/consumes

Metric/MetricFormatter/Preferences/AppRouter exactly as in foundation. FeedbackModifiers: `extension View { func connectionFeedback(_ m: MeterManager) -> some View; func recordingFeedback(_ m: MeterManager) -> some View; func saveFeedback(_ s: SessionStore) -> some View; func floatingChrome(_ shape: some InsettableShape) -> some View }`. MetricStyle: `extension Color { static let voltage, current, power: Color }`, `extension ConnectionState { var tint: Color }`. SettingsView(): sheet root used by WS-B's gear. SignalLevel: `static func level(rssi: Int) -> Double` (0...1 for cellularbars variableValue).

## Specs

### `D1-formatter-preferences-settings` — MetricFormatter with SI auto-ranging and hysteresis, semantic colour system, Preferences, Settings screen absorbing Diagnostics/demo/keep-awake, feedback modifiers  [M]

**Why:** Standby draw reads 0.012 A today although the stream has 0.1 mA resolution; metric colours are literals scattered across views; Diagnostics and demo clutter the Live toolbar; keep-awake is a two-line change with daily bench value; and a shared haptic/symbol vocabulary is what makes connect, record and save feel confirmed.

**Spec:**

MetricFormatter (foundation API): auto-range picks m prefix when |v| < 0.95 unit and returns to base above 1.05 (formatLive keeps per-metric state), significant digits from precision (3 or 4), locale-aware via Double.formatted(.number.precision(.significantDigits(n))), NaN/inf -> "--", negative current keeps the sign (flow direction is displayed, not hidden), energy uses mWh below 1 Wh, capacity mAh below 1 Ah (Preferences.capacityUnit can lock mAh), duration via Duration.formatted(.time(pattern: .hourMinuteSecond)) with minutes:seconds under an hour, spoken() yields "12.3 milliamps". Fmt shim forwards and is deleted once WS-B/WS-C no longer reference it. MetricStyle: Color.voltage/.current/.power from colorsets, ConnectionState.tint mapping tintToken. FloatingChrome modifier: material background in the given shape, .glassEffect(in:) under if #available(iOS 26). FeedbackModifiers: connectionFeedback = .sensoryFeedback(.success, trigger: meter.connectionEventCount) + .sensoryFeedback(.warning, trigger: meter.errorEventCount); recordingFeedback = .start/.stop on recordingEventCount using meter.recording != nil to choose; saveFeedback = .impact(.light) on store.saveCount; all no-ops when Preferences.hapticsEnabled is false. Preferences: UserDefaults-backed properties per foundation; injectable suite for tests. Keep-awake: ContentView observes meter.state.isConnected, scenePhase and prefs.keepAwake and sets UIApplication.shared.isIdleTimerDisabled = keepAwake && isConnected && scenePhase == .active && !ProcessInfo.processInfo.isLowPowerModeEnabled (observe NSProcessInfoPowerStateDidChange), always reset to false on background/disconnect. ContentView: TabView(selection: $router.tab) with Live and Sessions; RecordBar remains in LiveView. SettingsView (sheet from the gear): Form sections Display (Hero metric Picker .navigationLink, Auto-range units Toggle, Precision Picker 3/4 digits, Keep screen awake while connected Toggle with battery footer), Charts (Default window Picker, Show peak line Toggle), Recording (Default auto-stop LabeledContent showing the remembered rule, Exclude demo readings from trip Toggle), Alerts (NavigationLink to AlertsSettingsView), Meter (Last meter LabeledContent, Auto-connect on launch Toggle, Forget meter Button, Show all Bluetooth devices Toggle), Advanced (Diagnostics NavigationLink, Try demo data Button, Stop demo when active), About (Version/Build from Bundle, Privacy policy and Support Links with arrow.up.right, "WattBench is an independent project and is not affiliated with FNIRSI."). DiagnosticsView: replace ShareSheet with ShareLink(item: meter.diagnosticsText), add framesRejected, journal status and restore log rows, make Clear a 44pt toolbar button.

**UI:**

Form .formStyle(.grouped), sentence-case section headers, LabeledContent for read-only values, .pickerStyle(.navigationLink) for hero metric and precision, Links styled .foregroundStyle(.primary) with trailing arrow.up.right. Gear: ToolbarItem(.topBarTrailing) Button("Settings", systemImage: "gearshape"). Colorsets: light = system blue/orange/green equivalents, dark = #5AC8FA / #FF9F0A / #30D158 so lines do not glow on OLED.

**Files to add:** ios/WattBench/Views/Settings/SettingsView.swift (replaces stub), ios/WattBench/Views/Settings/AboutView.swift, ios/WattBench/Views/Components/FeedbackModifiers.swift, ios/WattBench/Views/Components/FloatingChrome.swift, ios/WattBenchTests/Format/MetricFormatterTests.swift, ios/WattBenchTests/Format/PreferencesTests.swift

**Files to modify:** ios/WattBench/Model/Format/MetricFormatter.swift, ios/WattBench/Model/Format/Metric.swift, ios/WattBench/Model/Format/Preferences.swift, ios/WattBench/Views/Components/MetricStyle.swift, ios/WattBench/Views/ContentView.swift, ios/WattBench/Views/Settings/DiagnosticsView.swift, ios/WattBench/Assets.xcassets/Voltage.colorset/Contents.json, ios/WattBench/Assets.xcassets/Current.colorset/Contents.json, ios/WattBench/Assets.xcassets/Power.colorset/Contents.json

**Data model changes:** UserDefaults keys prefs.* (keepAwake, heroMetric, defaultWindow, precision, autoRangeUnits, hapticsEnabled, showAllDevices, autoConnect, defaultAutoStop JSON, excludeDemoFromTrips, capacityUnit).

**Acceptance criteria:**

- 0.0123 A formats as 12.3 mA, 0.9995 A as 1.000 A, and a value oscillating around 1.0 A does not flip units between samples (hysteresis).
- With keep-awake on, the screen stays lit while connected and locks normally within the system timeout after disconnect or backgrounding; Low Power Mode overrides it.
- Every metric colour on every screen comes from the three colorsets; grep finds no .blue/.orange/.green literals in Views.
- Haptics fire once per connect, record start/stop and save, never per sample, and not at all with haptics disabled or Reduce Motion for symbol effects.

**Tests:**

- MetricFormatterTests.testAutoRangeBoundaries
- MetricFormatterTests.testHysteresisStateMachine
- MetricFormatterTests.testNaNAndNegativeCurrent
- MetricFormatterTests.testLocaleDecimalSeparator (de_DE)
- MetricFormatterTests.testSpokenUnits
- PreferencesTests.testRoundTripThroughSuite
- PreferencesTests.testDefaultAutoStopCodable

### `D2-connect-flow` — Connect sheet with actionable empty states, system signal glyph, auto-connect when one meter is found, Advanced disclosure  [S]

**Why:** The first-run path from 'meter arrived' to 'numbers on screen' must need no reading; failure states should tell the user what to do instead of showing an empty list, and the custom SignalBars miss the 44pt target.

**Spec:**

DeviceListView rebuilt around ConnectEmptyState(state:) using ContentUnavailableView: .bluetoothOff -> antenna.radiowaves.left.and.right.slash with text about Control Centre; .unauthorized -> lock.shield with Open Settings button (UIApplication.openSettingsURLString); .scanning -> dot.radiowaves.left.and.right with .symbolEffect(.variableColor.iterative) and "Looking for FNB58…"; nothing found after 8 s -> troubleshooting text (enable Bluetooth in the meter's menu, keep it within a few metres) with Scan again and Try demo data; .reconnecting/.unreachable -> ProgressView with "Retrying in" countdown or Retry button (meter.retryNow()). Rows: Label with cellularbars variableValue: SignalLevel.level(rssi:) (pure: -55 -> 1.0, -67 -> 0.75, -80 -> 0.5, else 0.25), name, RSSI dBm caption, .transition(.move(edge: .top).combined(with: .opacity)) with .animation(.snappy). Auto-connect: a task sleeps 1.5 s after the first discovery; if meter.devices.count == 1 and name contains FNB58 and the user has not tapped, connect with an inline "Connecting to FNB58…" row and Cancel; cancelled on disappear. Reconnect to last meter row kept at top; Forget meter in an Advanced DisclosureGroup at the bottom together with Show all Bluetooth devices (list becomes .searchable when on). Demo remains reachable from the not-found state only (moved to Settings otherwise). SignalBars deleted.

**UI:**

List(.insetGrouped) with section Nearby; .presentationDetents([.medium, .large]) and drag indicator; Image(systemName: "cellularbars", variableValue:).symbolRenderingMode(.hierarchical); rows are full-width Buttons (44pt). Empty-state actions use .borderedProminent for the primary.

**Files to add:** ios/WattBench/Views/Connect/ConnectEmptyState.swift, ios/WattBench/Model/Format/SignalLevel.swift, ios/WattBenchTests/Format/SignalLevelTests.swift

**Files to modify:** ios/WattBench/Views/Connect/DeviceListView.swift

**Data model changes:** None.

**Acceptance criteria:**

- With Bluetooth off or unauthorized the sheet shows the matching empty state with a working action button.
- When exactly one FNB58 is found the sheet connects after 1.5 s without a tap and can be cancelled; with two meters it waits for a tap.
- No SignalBars type remains; every row hit target is at least 44pt.

**Tests:**

- SignalLevelTests.testThresholds
- ConnectAutoSelectTests.testSelectsOnlyWhenExactlyOneFNB58 (pure decision function)

