# Workstream: WS-E Alerts, auto-stop rules, notifications

Read `ios/PLAN/00-overview.md` first (UI direction, architecture, foundation contract).

## Owns (only these files/folders may be created or modified)

- ios/WattBench/Model/Analysis/ThresholdMonitor.swift
- ios/WattBench/Model/Pipeline/AutoStopRule.swift
- ios/WattBench/Alerts/AlertCoordinator.swift
- ios/WattBench/Alerts/AlertNotifier.swift
- ios/WattBench/Alerts/AlertPresets.swift
- ios/WattBench/Views/Alerts/AlertsSettingsView.swift
- ios/WattBench/Views/Alerts/AlertRuleEditor.swift
- ios/WattBench/Views/Components/AlertBanner.swift
- ios/WattBenchTests/Alerts/*.swift

## Depends on

- foundation

## Shared contract this stream exposes/consumes

`protocol SampleObserver: AnyObject { @MainActor func observe(_ r: Reading, context: SampleContext) }` and `struct SampleContext { let dt: TimeInterval; let isRecording: Bool; let recordingStats: SessionStats?; let connection: ConnectionState }` (foundation). `@MainActor @Observable final class AlertCoordinator: SampleObserver { var rules: [AlertRule]; private(set) var active: [AlertEvent]; private(set) var alertEventCount: Int; func dismiss(_ id: UUID); func setEnabled(_ id: UUID, _ on: Bool) async }`. `struct AutoStopRule: Codable, Equatable` as in foundation. `struct AlertBanner: View` (reads AlertCoordinator from environment) placed by WS-B via .safeAreaInset(edge: .top). `AlertsSettingsView()` linked from WS-D's SettingsView.

## Specs

### `E1-alerts-and-autostop` — Threshold alerts with hysteresis and cooldown, presets, foreground banner + haptic, background local notifications, and the AutoStopRule engine  [M]

**Why:** Lets the bench run itself: a power-bank drain or a suspect cable should ping the user instead of requiring polling, and auto-stop needs a tested rule engine that cannot fire on a reconnect gap.

**Spec:**

ThresholdMonitor (pure): rules [AlertRule] where AlertRule: Codable, Identifiable { id, kind: overVoltage(v) | underVoltage(v) | overCurrent(a) | overPower(w) | currentBelow(a, seconds) | voltageDrop(deltaV, within: 1 s) | disconnected(seconds), enabled, cooldown = 60 s }; evaluate(r, context) -> [AlertEvent]; hysteresis re-arms only after the value returns 2 percent inside the bound; per-rule cooldown; currentBelow and disconnected count real sample dt (dt <= maxGapS) or connection-state time respectively; voltageDrop keeps a 1 s ring of voltages; allocation-free hot path (fixed arrays). AlertEvent { id, ruleID, kind, value, at, message }. AutoStopRule.evaluate implemented per foundation with the same real-sample rule and tests. AlertCoordinator (SampleObserver, @MainActor): loads rules from Preferences.alertRulesData, runs the monitor in observe, appends to active (max 20), increments alertEventCount, adds a Marker(kind: .alert) to the recording through a closure injected by WattBenchApp (`onAlert: (AlertEvent) -> Void` set to meter.addMarker) and delegates delivery to AlertNotifier: if UIApplication.shared.applicationState == .active -> banner + haptic; else -> UNNotificationRequest(identifier: rule id, content title "WattBench", body message, sound default, interruptionLevel .timeSensitive only if authorised, trigger nil) with a category recordingAlert whose Stop & save action calls meter.stopRecording via the UNUserNotificationCenterDelegate installed by an AppDelegate adaptor owned by this stream (Alerts/AlertNotifier.swift registers itself in init; WattBenchApp already constructs AlertCoordinator so no other stream edits are needed). Authorization is requested lazily the first time a rule is enabled (setEnabled async); if denied, the toggle stays on for foreground alerts and the row footer says notifications are off with an Open Settings link. Presets (AlertPresets): USB-C 65 W (over 21 V, over 3.5 A, over 70 W, drop 1 V), 5 V device (under 4.75 V, over 3 A), Power bank drain (current below 0.05 A for 60 s, disconnected 60 s), each applied as a set of rules. Rules are evaluated for live data whether or not recording; the disconnected rule only while recording.

**UI:**

AlertsSettingsView (Form): Preset Menu at top, then a List of rules with Toggle + value text, tap opens AlertRuleEditor sheet (Picker for kind, TextField(.decimalPad)/Stepper for value, Stepper for seconds), a Test notification button, footer explaining cooldown and background delivery. AlertBanner: top-anchored capsule on .thinMaterial via floatingChrome with exclamationmark.triangle.fill red, rule message, Dismiss; .transition(.move(edge: .top).combined(with: .opacity)); .sensoryFeedback(.warning, trigger: alerts.alertEventCount). Fired alerts render as red marker RuleMarks on charts (via Marker.kind .alert) and in the detail Markers section.

**Files to add:** ios/WattBench/Model/Analysis/ThresholdMonitor.swift, ios/WattBench/Alerts/AlertNotifier.swift, ios/WattBench/Alerts/AlertPresets.swift, ios/WattBench/Views/Alerts/AlertRuleEditor.swift, ios/WattBenchTests/Alerts/ThresholdMonitorTests.swift, ios/WattBenchTests/Alerts/AutoStopRuleTests.swift, ios/WattBenchTests/Alerts/AlertCoordinatorTests.swift

**Files to modify:** ios/WattBench/Model/Pipeline/AutoStopRule.swift, ios/WattBench/Alerts/AlertCoordinator.swift, ios/WattBench/Views/Alerts/AlertsSettingsView.swift, ios/WattBench/Views/Components/AlertBanner.swift

**Data model changes:** Preferences.alertRulesData (JSON [AlertRule]); Marker.kind .alert/.autoStop entries in sessions; no entitlements (time-sensitive level used only when granted, no critical alerts).

**Acceptance criteria:**

- A synthetic tapering current triggers currentBelow exactly once, a one-sample dip does not, and a 60 s reconnect gap does not count toward the seconds.
- Over-voltage fires once, stays silent inside the 60 s cooldown, and re-arms only after the voltage drops 2 percent below the bound.
- With the app backgrounded and a rule firing, a local notification arrives and its Stop & save action ends and saves the recording.
- Notification permission is requested only when the first rule is enabled, never at launch.

**Tests:**

- ThresholdMonitorTests.testHysteresisAndCooldown
- ThresholdMonitorTests.testCurrentBelowCountsRealSamplesOnly
- ThresholdMonitorTests.testVoltageDropWithinOneSecond
- ThresholdMonitorTests.testDisconnectedRuleOnlyWhileRecording
- AutoStopRuleTests.testDurationAndEnergyReasons
- AutoStopRuleTests.testBelowThresholdResetsAbove102Percent
- AlertCoordinatorTests.testAddsAlertMarkerAndIncrementsCounter (notifier mocked)

