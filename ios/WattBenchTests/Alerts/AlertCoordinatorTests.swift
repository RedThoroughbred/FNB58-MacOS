import XCTest
@testable import WattBench

/// Records what the coordinator asks of the notification layer.
@MainActor
final class MockNotifier: AlertNotifying {
    var isAppActive = true
    var onStopAndSave: (@MainActor () -> Void)?
    var status: NotificationAuthorization = .notDetermined
    var grantsOnRequest = true
    private(set) var statusQueries = 0
    private(set) var requestCount = 0
    private(set) var posted: [AlertNotification] = []
    private(set) var cancelled: [String] = []

    func authorizationStatus() async -> NotificationAuthorization {
        statusQueries += 1
        return status
    }

    func requestAuthorization() async -> NotificationAuthorization {
        requestCount += 1
        status = grantsOnRequest ? .authorized : .denied
        return status
    }

    func post(_ notification: AlertNotification) {
        posted.append(notification)
    }

    func cancelPending(identifier: String) {
        cancelled.append(identifier)
    }
}

@MainActor
final class AlertCoordinatorTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_760_000_000)

    /// Preferences backed by a throw-away UserDefaults suite.
    private func makePrefs() throws -> Preferences {
        let suite = "wattbench.tests.alerts.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return Preferences(defaults: defaults)
    }

    private func reading(at s: TimeInterval, v: Double = 9, i: Double = 1) -> Reading {
        Reading(timestamp: t0.addingTimeInterval(s), voltage: v, current: i, power: v * i, monotonic: 100 + s)
    }

    private func context(dt: TimeInterval = 0.1, recording: Bool) -> SampleContext {
        SampleContext(dt: dt, isRecording: recording, recordingStats: nil, connection: .connected("FNB58"))
    }

    private func session(name: String = "Bench run", energyWh: Double) -> Session {
        var stats = SessionStats()
        stats.energyWh = energyWh
        return Session(id: UUID(), name: name, startTime: t0, endTime: t0.addingTimeInterval(600),
                       deviceName: "FNB58", stats: stats, readings: [])
    }

    // MARK: - Firing

    func testAddsAlertMarkerAndIncrementsCounter() throws {
        let prefs = try makePrefs()
        let notifier = MockNotifier()
        let alerts = AlertCoordinator(preferences: prefs, notifier: notifier)
        let rule = AlertRule(.overCurrent, value: 3)
        alerts.rules = [rule]
        var markers: [String] = []
        alerts.onAlert = { markers.append($0.title) }

        alerts.observe(reading(at: 0, i: 2), context: context(recording: true))
        XCTAssertTrue(alerts.active.isEmpty)
        XCTAssertEqual(alerts.alertEventCount, 0)
        XCTAssertTrue(markers.isEmpty)

        alerts.observe(reading(at: 0.1, i: 3.5), context: context(recording: true))
        XCTAssertEqual(alerts.active.count, 1)
        XCTAssertEqual(alerts.active.first?.ruleID, rule.id)
        XCTAssertEqual(alerts.active.first?.message, "Current 3.5 A is above 3 A")
        XCTAssertEqual(alerts.alertEventCount, 1)
        XCTAssertEqual(markers, ["Over-current"], "the marker goes into the recording through onAlert")
        XCTAssertTrue(notifier.posted.isEmpty, "in the foreground an alert is a banner, not a notification")

        alerts.observe(reading(at: 0.2, i: 3.6), context: context(recording: true))
        XCTAssertEqual(alerts.alertEventCount, 1, "disarmed until the current is back inside the bound")
        XCTAssertEqual(markers.count, 1)

        alerts.dismiss(try XCTUnwrap(alerts.active.first?.id))
        XCTAssertTrue(alerts.active.isEmpty)
        XCTAssertEqual(alerts.alertEventCount, 1, "the counter drives the haptic and never goes back")
    }

    func testBackgroundAlertPostsNotificationWhoseStopAndSaveActionStopsTheRecording() throws {
        let prefs = try makePrefs()
        let notifier = MockNotifier()
        notifier.isAppActive = false
        let alerts = AlertCoordinator(preferences: prefs, notifier: notifier)
        let loud = AlertRule(.overPower, value: 30)
        var quiet = AlertRule(.overVoltage, value: 5)
        quiet.notify = false
        alerts.rules = [loud, quiet]
        var stops = 0
        alerts.onStopAndSave = { stops += 1 }

        // 9 V x 4 A = 36 W crosses both rules.
        alerts.observe(reading(at: 0, v: 9, i: 4), context: context(recording: true))
        XCTAssertEqual(alerts.active.count, 2, "both show as banners once the app is back")
        XCTAssertEqual(notifier.posted.count, 1, "only a rule with notify posts a notification")
        let n = try XCTUnwrap(notifier.posted.first)
        XCTAssertEqual(n.identifier, loud.id.uuidString)
        XCTAssertEqual(n.category, .recordingAlert, "during a recording the notification offers Stop & save")
        XCTAssertEqual(n.title, "WattBench")
        XCTAssertEqual(n.subtitle, "Over-power")
        XCTAssertEqual(n.body, "Power 36 W is above 30 W")
        XCTAssertEqual(n.delay, 0)

        // The action arrives through the notifier and ends the recording.
        notifier.onStopAndSave?()
        XCTAssertEqual(stops, 1)

        // Outside a recording the notification carries no action.
        let idle = AlertCoordinator(preferences: try makePrefs(), notifier: notifier)
        idle.rules = [AlertRule(.overPower, value: 30)]
        idle.observe(reading(at: 0, v: 9, i: 4), context: context(recording: false))
        XCTAssertEqual(notifier.posted.last?.category, .alert)
    }

    func testActiveListIsCappedAtTwenty() throws {
        let alerts = AlertCoordinator(preferences: try makePrefs(), notifier: MockNotifier())
        alerts.rules = (0..<25).map { AlertRule(.overCurrent, value: 1, name: "Rule \($0)") }
        alerts.observe(reading(at: 0, i: 2), context: context(recording: false))
        XCTAssertEqual(alerts.alertEventCount, 25)
        XCTAssertEqual(alerts.active.count, AlertCoordinator.maxActive)
        XCTAssertEqual(alerts.active.first?.title, "Rule 5", "the oldest are dropped")
        XCTAssertEqual(alerts.active.last?.title, "Rule 24", "the newest is what the banner shows")
        alerts.dismissAll()
        XCTAssertTrue(alerts.active.isEmpty)
    }

    // MARK: - Permission

    func testPermissionIsRequestedOnlyWhenARuleIsFirstEnabled() async throws {
        let prefs = try makePrefs()
        let notifier = MockNotifier()
        let alerts = AlertCoordinator(preferences: prefs, notifier: notifier)
        XCTAssertEqual(notifier.requestCount, 0)
        XCTAssertEqual(notifier.statusQueries, 0, "never at launch")
        XCTAssertEqual(alerts.notificationAuthorization, .notDetermined)

        alerts.observe(reading(at: 0), context: context(recording: false))
        var rule = AlertRule(.overCurrent, value: 3)
        rule.enabled = false
        alerts.rules = [rule]
        XCTAssertEqual(notifier.requestCount, 0, "samples and a disabled rule do not ask")
        XCTAssertEqual(notifier.statusQueries, 0)

        await alerts.setEnabled(rule.id, true)
        XCTAssertEqual(notifier.requestCount, 1)
        XCTAssertEqual(alerts.notificationAuthorization, .authorized)
        XCTAssertEqual(alerts.rules.first?.enabled, true)

        await alerts.setEnabled(rule.id, false)
        XCTAssertEqual(alerts.rules.first?.enabled, false)
        await alerts.setEnabled(rule.id, true)
        await alerts.upsert(AlertRule(.overVoltage, value: 20))
        await alerts.apply(.fiveVoltDevice)
        XCTAssertEqual(notifier.requestCount, 1, "asked once; later enables only re-read the status")
        XCTAssertGreaterThan(notifier.statusQueries, 1)
    }

    func testDeniedPermissionKeepsTheRuleEnabledForForegroundBanners() async throws {
        let notifier = MockNotifier()
        notifier.grantsOnRequest = false
        let alerts = AlertCoordinator(preferences: try makePrefs(), notifier: notifier)
        var rule = AlertRule(.overCurrent, value: 3)
        rule.enabled = false
        alerts.rules = [rule]

        await alerts.setEnabled(rule.id, true)
        XCTAssertEqual(alerts.notificationAuthorization, .denied)
        XCTAssertEqual(alerts.rules.first?.enabled, true, "the toggle stays on for banners")
        let sentWhileDenied = await alerts.sendTestNotification()
        XCTAssertFalse(sentWhileDenied)
        XCTAssertTrue(notifier.posted.isEmpty)

        alerts.observe(reading(at: 0, i: 3.5), context: context(recording: false))
        XCTAssertEqual(alerts.active.count, 1)

        notifier.status = .authorized
        await alerts.refreshAuthorization()
        XCTAssertEqual(alerts.notificationAuthorization, .authorized)
        let sentWhenAllowed = await alerts.sendTestNotification()
        XCTAssertTrue(sentWhenAllowed)
        XCTAssertEqual(notifier.posted.last?.category, .test)
        XCTAssertEqual(notifier.posted.last?.identifier, AlertCoordinator.testIdentifier)
    }

    // MARK: - Rules

    func testRulesPersistThroughPreferences() throws {
        let prefs = try makePrefs()
        let first = AlertCoordinator(preferences: prefs, notifier: MockNotifier())
        XCTAssertTrue(first.rules.isEmpty)
        let rule = AlertRule(.currentBelow, value: 0.05, seconds: 60)
        first.rules = [rule]
        XCTAssertNotNil(prefs.alertRulesData)

        let second = AlertCoordinator(preferences: prefs, notifier: MockNotifier())
        XCTAssertEqual(second.rules, [rule])
        second.remove(id: rule.id)
        XCTAssertTrue(AlertCoordinator(preferences: prefs, notifier: MockNotifier()).rules.isEmpty)
    }

    func testPresetsAddOnlyMissingRules() async throws {
        let alerts = AlertCoordinator(preferences: try makePrefs(), notifier: MockNotifier())
        await alerts.apply(.usbC65W)
        XCTAssertEqual(alerts.rules.count, 4)
        await alerts.apply(.usbC65W)
        XCTAssertEqual(alerts.rules.count, 4, "applying a preset twice adds nothing")
        await alerts.apply(.fiveVoltDevice)
        XCTAssertEqual(alerts.rules.count, 6, "3 A over-current differs from the 3.5 A one")
        await alerts.apply(.powerBankDrain)
        XCTAssertEqual(alerts.rules.count, 8)
        XCTAssertTrue(alerts.rules.allSatisfy(\.isValid))

        var edited = try XCTUnwrap(alerts.rules.first)
        edited.name = "Charger limit"
        await alerts.upsert(edited)
        XCTAssertEqual(alerts.rules.count, 8, "upsert replaces by id")
        XCTAssertEqual(alerts.rules.first?.name, "Charger limit")
        alerts.remove(atOffsets: IndexSet(integer: 0))
        XCTAssertEqual(alerts.rules.count, 7)
    }

    // MARK: - Disconnected while recording

    func testDisconnectedRuleFiresFromTheClockOnlyWhileRecording() throws {
        let notifier = MockNotifier()
        let alerts = AlertCoordinator(preferences: try makePrefs(), notifier: notifier)
        alerts.rules = [AlertRule(.disconnected, value: 0, seconds: 10)]

        // Not recording: nothing, however long the meter is away.
        alerts.observe(reading(at: 0), context: context(recording: false))
        alerts.checkDisconnect(now: t0.addingTimeInterval(60))
        XCTAssertTrue(alerts.active.isEmpty)
        XCTAssertTrue(notifier.posted.isEmpty)

        // Recording: a dead man's switch is kept pending for the background ...
        alerts.observe(reading(at: 100), context: context(recording: true))
        let watch = try XCTUnwrap(notifier.posted.last)
        XCTAssertEqual(watch.identifier, AlertCoordinator.disconnectWatchIdentifier)
        XCTAssertEqual(watch.category, .recordingAlert)
        XCTAssertGreaterThanOrEqual(watch.delay, 10)
        XCTAssertEqual(watch.body, "Meter disconnected for 10 sec while recording")

        // ... and the foreground clock fires the rule after 10 s without samples.
        alerts.checkDisconnect(now: t0.addingTimeInterval(104))   // within maxGapS: still connected
        alerts.checkDisconnect(now: t0.addingTimeInterval(109))
        XCTAssertTrue(alerts.active.isEmpty)
        alerts.checkDisconnect(now: t0.addingTimeInterval(110))
        XCTAssertEqual(alerts.active.count, 1)
        XCTAssertEqual(alerts.active.first?.title, "Disconnected")
        XCTAssertEqual(alerts.alertEventCount, 1)
        alerts.checkDisconnect(now: t0.addingTimeInterval(120))
        XCTAssertEqual(alerts.alertEventCount, 1)

        // Stopping the recording cancels the pending switch and the clock.
        alerts.recordingDidStop(session(energyWh: 1), reason: nil)
        XCTAssertEqual(notifier.cancelled.last, AlertCoordinator.disconnectWatchIdentifier)
        alerts.checkDisconnect(now: t0.addingTimeInterval(300))
        XCTAssertEqual(alerts.alertEventCount, 1, "no recording, no disconnect alerts")
    }

    // MARK: - Recording notices

    func testRecordingFinishedNoticeIsPostedOnlyInTheBackground() throws {
        let prefs = try makePrefs()
        prefs.defaultAutoStop = AutoStopRule(belowCurrentA: 0.1, forSeconds: 60)
        let notifier = MockNotifier()
        let alerts = AlertCoordinator(preferences: prefs, notifier: notifier)

        alerts.recordingDidStop(session(energyWh: 27.4), reason: .currentBelowThreshold)
        XCTAssertTrue(notifier.posted.isEmpty, "in front, the saved toast is enough")

        notifier.isAppActive = false
        alerts.recordingDidStop(session(energyWh: 27.4), reason: .currentBelowThreshold)
        let n = try XCTUnwrap(notifier.posted.last)
        XCTAssertEqual(n.category, .recordingNotice)
        XCTAssertEqual(n.identifier, AlertCoordinator.recordingNoticeIdentifier)
        XCTAssertEqual(n.subtitle, "Bench run")
        XCTAssertEqual(n.body, "Recording finished · 27.4 Wh (stopped: current below 100 mA for 1 min)")

        alerts.recordingDidStop(session(energyWh: 0.5), reason: nil)
        XCTAssertEqual(notifier.posted.last?.body, "Recording finished · 500 mWh")

        alerts.recordingDidPause(meterName: "FNB58")
        XCTAssertEqual(notifier.posted.last?.category, .recordingAlert)
        XCTAssertEqual(notifier.posted.last?.body, "FNB58 is unreachable; the recording is paused until it reconnects.")

        alerts.recordingWasInterrupted(session(name: "Overnight", energyWh: 3).summary())
        XCTAssertEqual(notifier.posted.last?.category, .recordingNotice)
        XCTAssertEqual(notifier.posted.last?.subtitle, "Overnight")
    }
}
