import Foundation
import Observation

/// A threshold rule on one metric.
///
/// The stored shape is the foundation contract (`id`, `name`, `metric`,
/// `above`, `below`, `forSeconds`, `enabled`, `notify`) plus one additive,
/// defaulted field: `kind`, which lets the same struct describe the two
/// conditions that are not a plain bound on a metric (a voltage drop within
/// one second, and the meter being disconnected while recording). Files
/// written without `kind` decode as `.threshold`.
struct AlertRule: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        /// `metric` compared with `above` / `below`, sustained for `forSeconds`.
        case threshold
        /// Voltage falls by more than `above` volts within `ThresholdMonitor.dropWindow`.
        case voltageDrop
        /// No samples for `forSeconds` while a recording is in progress.
        case disconnected
    }

    var id: UUID
    var name: String
    var metric: Metric
    var above: Double?
    var below: Double?
    var forSeconds: TimeInterval
    var enabled: Bool
    var notify: Bool
    var kind: Kind

    init(id: UUID = UUID(), name: String, metric: Metric, above: Double? = nil, below: Double? = nil,
         forSeconds: TimeInterval = 0, enabled: Bool = true, notify: Bool = false, kind: Kind = .threshold) {
        self.id = id
        self.name = name
        self.metric = metric
        self.above = above
        self.below = below
        self.forSeconds = forSeconds
        self.enabled = enabled
        self.notify = notify
        self.kind = kind
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, metric, above, below, forSeconds, enabled, notify, kind
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        metric = try c.decode(Metric.self, forKey: .metric)
        above = try c.decodeIfPresent(Double.self, forKey: .above)
        below = try c.decodeIfPresent(Double.self, forKey: .below)
        forSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .forSeconds) ?? 0
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        notify = try c.decodeIfPresent(Bool.self, forKey: .notify) ?? false
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .threshold
    }
}

extension AlertRule {
    /// The conditions the editor and the presets offer, mapped onto the
    /// stored fields.
    enum Condition: String, CaseIterable, Identifiable {
        case overVoltage, underVoltage, overCurrent, overPower, currentBelow, voltageDrop, disconnected

        var id: String { rawValue }

        var title: String {
            switch self {
            case .overVoltage: return "Over-voltage"
            case .underVoltage: return "Under-voltage"
            case .overCurrent: return "Over-current"
            case .overPower: return "Over-power"
            case .currentBelow: return "Current below"
            case .voltageDrop: return "Voltage drop"
            case .disconnected: return "Disconnected"
            }
        }

        var symbolName: String {
            switch self {
            case .overVoltage: return "arrow.up.to.line"
            case .underVoltage: return "arrow.down.to.line"
            case .overCurrent: return "bolt.fill"
            case .overPower: return "bolt.circle.fill"
            case .currentBelow: return "arrow.down.right"
            case .voltageDrop: return "chart.line.downtrend.xyaxis"
            case .disconnected: return "antenna.radiowaves.left.and.right.slash"
            }
        }

        /// Metric the value is expressed in (nil for `disconnected`).
        var metric: Metric? {
            switch self {
            case .overVoltage, .underVoltage, .voltageDrop: return .voltage
            case .overCurrent, .currentBelow: return .current
            case .overPower: return .power
            case .disconnected: return nil
            }
        }

        var kind: Kind {
            switch self {
            case .voltageDrop: return .voltageDrop
            case .disconnected: return .disconnected
            default: return .threshold
            }
        }

        var hasValue: Bool { self != .disconnected }
        var hasDuration: Bool { self == .currentBelow || self == .disconnected }

        /// Base-unit symbol of the value ("V", "A", "W").
        var unit: String { metric?.symbol ?? "" }

        var defaultValue: Double {
            switch self {
            case .overVoltage: return 21
            case .underVoltage: return 4.75
            case .overCurrent: return 3.5
            case .overPower: return 70
            case .currentBelow: return 0.05
            case .voltageDrop: return 1
            case .disconnected: return 0
            }
        }

        var defaultSeconds: TimeInterval { hasDuration ? 60 : 0 }

        var valueRange: ClosedRange<Double> {
            switch self {
            case .overVoltage, .underVoltage: return 0...60
            case .overCurrent, .currentBelow: return 0...10
            case .overPower: return 0...300
            case .voltageDrop: return 0...30
            case .disconnected: return 0...0
            }
        }

        var valueStep: Double {
            switch self {
            case .overVoltage, .underVoltage: return 0.25
            case .overCurrent: return 0.1
            case .currentBelow: return 0.01
            case .overPower: return 5
            case .voltageDrop: return 0.1
            case .disconnected: return 0
            }
        }

        /// One-line explanation for the editor footer.
        var help: String {
            switch self {
            case .overVoltage, .underVoltage, .overCurrent, .overPower:
                return "Re-arms once the reading is back 2% inside the limit, and fires at most once a minute."
            case .currentBelow:
                return "Counts only time with live readings, so a reconnect gap never triggers it."
            case .voltageDrop:
                return "Compares each reading with the highest voltage seen in the previous second."
            case .disconnected:
                return "Only while recording. Delivered as a notification when WattBench is in the background."
            }
        }
    }

    /// Builds a rule for one of the editor conditions. `value` is the bound
    /// (or the drop, in volts); `seconds` applies to the sustained conditions.
    init(_ condition: Condition, value: Double, seconds: TimeInterval = 0, name: String? = nil,
         enabled: Bool = true, notify: Bool = true) {
        let metric = condition.metric ?? .current
        var above: Double?
        var below: Double?
        switch condition {
        case .overVoltage, .overCurrent, .overPower, .voltageDrop: above = value
        case .underVoltage, .currentBelow: below = value
        case .disconnected: break
        }
        let duration = condition.hasDuration ? max(0, seconds) : 0
        self.init(name: name ?? condition.title, metric: metric, above: above, below: below,
                  forSeconds: duration, enabled: enabled, notify: notify, kind: condition.kind)
    }

    /// The editor condition this rule corresponds to, if it is one of them.
    var condition: Condition? {
        switch kind {
        case .voltageDrop: return .voltageDrop
        case .disconnected: return .disconnected
        case .threshold:
            switch (metric, above != nil, below != nil) {
            case (.voltage, true, false): return .overVoltage
            case (.voltage, false, true): return .underVoltage
            case (.current, true, false): return .overCurrent
            case (.current, false, true): return .currentBelow
            case (.power, true, false): return .overPower
            default: return nil
            }
        }
    }

    /// The number the editor shows: the bound or the drop; nil for `disconnected`.
    var value: Double? {
        kind == .disconnected ? nil : (above ?? below)
    }

    var isValid: Bool {
        switch kind {
        case .threshold:
            let bounds = [above, below].compactMap { $0 }
            return !bounds.isEmpty && bounds.allSatisfy(\.isFinite) && forSeconds >= 0
        case .voltageDrop:
            return (above ?? 0) > 0
        case .disconnected:
            return forSeconds > 0
        }
    }

    /// Same condition regardless of id, name or enabled state.
    func isEquivalent(to other: AlertRule) -> Bool {
        kind == other.kind && metric == other.metric && above == other.above && below == other.below
            && forSeconds == other.forSeconds
    }

    /// One line for lists and menus: "Voltage above 21 V", "Current below
    /// 50 mA for 1 min", "Meter disconnected for 1 min while recording".
    func summary(formatter: MetricFormatter) -> String {
        let locale = formatter.locale
        func v(_ x: Double) -> String { AlertFormat.value(x, metric, formatter: formatter) }
        switch kind {
        case .voltageDrop:
            return "Voltage drops \(v(above ?? 0)) within \(AlertFormat.span(ThresholdMonitor.dropWindow, locale: locale))"
        case .disconnected:
            return "Meter disconnected for \(AlertFormat.span(forSeconds, locale: locale)) while recording"
        case .threshold:
            let duration = forSeconds > 0 ? " for \(AlertFormat.span(forSeconds, locale: locale))" : ""
            switch (above, below) {
            case let (a?, b?):
                return "\(metric.title) outside \(v(b)) to \(v(a))\(duration)"
            case let (a?, nil):
                return "\(metric.title) above \(v(a))\(duration)"
            case let (nil, b?):
                return "\(metric.title) below \(v(b))\(duration)"
            case (nil, nil):
                return "\(metric.title) (no limit set)"
            }
        }
    }
}

/// A fired rule.
struct AlertEvent: Identifiable, Equatable {
    let id: UUID
    let ruleID: UUID
    let title: String
    let message: String
    let firedAt: Date
    let metric: Metric?
    let value: Double?

    init(id: UUID = UUID(), ruleID: UUID, title: String, message: String, firedAt: Date = Date(),
         metric: Metric? = nil, value: Double? = nil) {
        self.id = id
        self.ruleID = ruleID
        self.title = title
        self.message = message
        self.firedAt = firedAt
        self.metric = metric
        self.value = value
    }
}

/// Watches every sample for alert rules and drives banners, haptics, markers
/// and local notifications.
///
/// Rules are loaded from and persisted to `Preferences.alertRulesData`. Every
/// sample runs through a `ThresholdMonitor`; a fired event is appended to
/// `active` (the banner shows the newest, at most `maxActive` are kept),
/// bumps `alertEventCount` (the banner's haptic trigger), is handed to
/// `onAlert` (wired by `WattBenchApp` to `MeterManager.addMarker`) and, when
/// the app is not active and the rule asks for it, is posted as a local
/// notification by the `AlertNotifying` delegate. The notification's
/// "Stop & save" action arrives through `onStopAndSave` (wired to
/// `MeterManager.stopRecording`).
///
/// The `.disconnected` rule cannot be sample-driven, so while a recording is
/// in progress the coordinator runs a 1 s timer in the foreground and keeps a
/// "dead man's switch" notification pending for the background: it is pushed
/// forward while samples keep arriving and fires on its own once they stop.
///
/// Notification permission is requested lazily, the first time a rule is
/// enabled (`setEnabled`) or `ensureNotificationAuthorization()` is called
/// (auto-stop), never at launch.
@MainActor
@Observable
final class AlertCoordinator: SampleObserver {
    static let maxActive = 20
    nonisolated static let disconnectWatchIdentifier = "wattbench.disconnect-watch"
    nonisolated static let recordingNoticeIdentifier = "wattbench.recording-notice"
    nonisolated static let testIdentifier = "wattbench.test"

    var rules: [AlertRule] {
        didSet { rulesDidChange() }
    }
    private(set) var active: [AlertEvent] = []
    private(set) var alertEventCount = 0
    /// Last known notification permission (refreshed on request and by the
    /// Alerts screen; never queried at launch).
    private(set) var notificationAuthorization: NotificationAuthorization = .notDetermined

    @ObservationIgnored var onAlert: (@MainActor (AlertEvent) -> Void)?
    @ObservationIgnored var onStopAndSave: (@MainActor () -> Void)?

    @ObservationIgnored private var monitor: ThresholdMonitor
    @ObservationIgnored private let notifier: any AlertNotifying
    @ObservationIgnored private let prefs: Preferences
    @ObservationIgnored private var lastSampleAt: Date?
    @ObservationIgnored private var lastContext: SampleContext?
    @ObservationIgnored private var disconnectTimer: Timer?
    @ObservationIgnored private var watchRefreshedAt = Date.distantPast
    @ObservationIgnored private var watchPending = false
    @ObservationIgnored private var formatterKey: (precision: Int, autoRange: Bool)

    init(preferences: Preferences = .shared, notifier: (any AlertNotifying)? = nil) {
        prefs = preferences
        self.notifier = notifier ?? AlertNotifier()
        let loaded = Self.decodeRules(preferences.alertRulesData)
        rules = loaded
        formatterKey = (preferences.precision, preferences.autoRangeUnits)
        monitor = ThresholdMonitor(rules: loaded, formatter: preferences.formatter)
        self.notifier.onStopAndSave = { [weak self] in self?.stopAndSaveFromNotification() }
    }

    // MARK: - SampleObserver

    func observe(_ r: Reading, context: SampleContext) {
        // The reading's own wall-clock stamp keeps the disconnect clock on
        // the same time base as the monitor (and deterministic in tests).
        let now = r.timestamp
        lastSampleAt = now
        lastContext = context
        refreshFormatterIfNeeded()
        let events = monitor.evaluate(r, context: context)
        for event in events { fire(event, isRecording: context.isRecording) }
        maintainDisconnectWatch(now: now, isRecording: context.isRecording)
    }

    // MARK: - Active alerts

    func dismiss(_ id: UUID) {
        active.removeAll { $0.id == id }
    }

    func dismissAll() {
        active.removeAll()
    }

    // MARK: - Rules

    /// Enables or disables a rule. Enabling a rule for the first time asks
    /// for notification permission; if it is denied the rule stays enabled
    /// for foreground banners.
    func setEnabled(_ id: UUID, _ on: Bool) async {
        guard let i = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[i].enabled = on
        if on { await ensureNotificationAuthorization() }
    }

    /// Adds or replaces a rule (matched by id).
    func upsert(_ rule: AlertRule) async {
        if let i = rules.firstIndex(where: { $0.id == rule.id }) {
            rules[i] = rule
        } else {
            rules.append(rule)
        }
        if rule.enabled { await ensureNotificationAuthorization() }
    }

    func remove(id: UUID) {
        rules.removeAll { $0.id == id }
    }

    func remove(atOffsets offsets: IndexSet) {
        rules.remove(atOffsets: offsets)
    }

    /// Adds the preset's rules that are not already present.
    func apply(_ preset: AlertPreset) async {
        let missing = preset.rules.filter { candidate in !rules.contains { $0.isEquivalent(to: candidate) } }
        guard !missing.isEmpty else { return }
        rules.append(contentsOf: missing)
        await ensureNotificationAuthorization()
    }

    // MARK: - Notifications

    /// Re-reads the system permission (no prompt).
    func refreshAuthorization() async {
        notificationAuthorization = await notifier.authorizationStatus()
    }

    /// Asks for notification permission if it has never been asked. Call
    /// when the user enables a rule or an auto-stop; never at launch.
    @discardableResult
    func ensureNotificationAuthorization() async -> Bool {
        let status = await notifier.authorizationStatus()
        notificationAuthorization = status
        guard status == .notDetermined else { return status == .authorized }
        notificationAuthorization = await notifier.requestAuthorization()
        return notificationAuthorization == .authorized
    }

    /// Posts a test notification (asking for permission first if needed).
    /// Returns false when notifications are not allowed.
    @discardableResult
    func sendTestNotification() async -> Bool {
        guard await ensureNotificationAuthorization() else { return false }
        notifier.post(AlertNotification(identifier: Self.testIdentifier, category: .test,
                                        body: "Test alert. Notifications from WattBench are working."))
        return true
    }

    // MARK: - Recording notices (call sites live in WS-A; see integration notes)

    /// Cancels the disconnect watch and, when the app is in the background,
    /// posts "Recording finished · 27.4 Wh (stopped: current below 100 mA
    /// for 1 min)". Meant to be called from `MeterManager.onRecordingStopped`.
    func recordingDidStop(_ session: Session, reason: AutoStopRule.Reason?) {
        notifyRecordingStopped(name: session.name, energyWh: session.stats.energyWh, reason: reason)
    }

    /// Same notice from a saved summary (`SessionStore.lastSaved`).
    func notifyRecordingStopped(_ summary: SessionSummary, reason: AutoStopRule.Reason?) {
        notifyRecordingStopped(name: summary.name, energyWh: summary.stats.energyWh, reason: reason)
    }

    private func notifyRecordingStopped(name: String, energyWh: Double, reason: AutoStopRule.Reason?) {
        endRecordingWatch()
        guard !notifier.isAppActive else { return }
        var body = "Recording finished · \(AlertFormat.energy(energyWh, formatter: prefs.formatter))"
        if let reason {
            let detail = prefs.defaultAutoStop?.description(of: reason, formatter: prefs.formatter) ?? reason.label
            body += " (stopped: \(detail))"
        }
        notifier.post(AlertNotification(identifier: Self.recordingNoticeIdentifier, category: .recordingNotice,
                                        subtitle: name, body: body))
    }

    /// "Meter unreachable, recording paused" for the background; call when
    /// the connection becomes `.unreachable` while recording.
    func recordingDidPause(meterName: String) {
        guard !notifier.isAppActive else { return }
        notifier.post(AlertNotification(identifier: Self.recordingNoticeIdentifier, category: .recordingAlert,
                                        body: "\(meterName) is unreachable; the recording is paused until it reconnects."))
    }

    /// "Recording was interrupted" after a relaunch that found an unfinished
    /// recording; call from the restoration path.
    func recordingWasInterrupted(_ summary: SessionSummary) {
        guard !notifier.isAppActive else { return }
        notifier.post(AlertNotification(identifier: Self.recordingNoticeIdentifier, category: .recordingNotice,
                                        subtitle: summary.name,
                                        body: "The recording was interrupted. Open WattBench to keep or discard it."))
    }

    // MARK: - Internals

    private func fire(_ event: AlertEvent, isRecording: Bool) {
        active.append(event)
        if active.count > Self.maxActive { active.removeFirst(active.count - Self.maxActive) }
        alertEventCount += 1
        onAlert?(event)
        guard !notifier.isAppActive, let rule = rules.first(where: { $0.id == event.ruleID }), rule.notify else { return }
        let identifier = rule.kind == .disconnected ? Self.disconnectWatchIdentifier : event.ruleID.uuidString
        notifier.post(AlertNotification(identifier: identifier,
                                        category: isRecording ? .recordingAlert : .alert,
                                        subtitle: event.title, body: event.message))
    }

    private func rulesDidChange() {
        prefs.alertRulesData = try? JSONEncoder().encode(rules)
        monitor.setRules(rules)
        if !monitor.hasEnabledDisconnectRule { endRecordingWatch() }
    }

    private func refreshFormatterIfNeeded() {
        let key = (prefs.precision, prefs.autoRangeUnits)
        guard key != formatterKey else { return }
        formatterKey = key
        monitor.formatter = prefs.formatter
    }

    private static func decodeRules(_ data: Data?) -> [AlertRule] {
        guard let data else { return [] }
        return (try? JSONDecoder().decode([AlertRule].self, from: data)) ?? []
    }

    private func stopAndSaveFromNotification() {
        endRecordingWatch()
        onStopAndSave?()
    }

    // MARK: Disconnect watch

    /// Refresh cadence of the background dead man's switch: often enough
    /// that the notification lands within `seconds`...`seconds + cadence`
    /// of the last sample, rarely enough to stay cheap.
    private static func watchCadence(for seconds: TimeInterval) -> TimeInterval {
        min(15, max(2, seconds / 4))
    }

    private func maintainDisconnectWatch(now: Date, isRecording: Bool) {
        guard isRecording, monitor.hasEnabledDisconnectRule else {
            endRecordingWatch()
            return
        }
        if disconnectTimer == nil { startDisconnectTimer() }
        guard let seconds = monitor.disconnectNotifySeconds else {
            cancelDisconnectWatch()
            return
        }
        let cadence = Self.watchCadence(for: seconds)
        guard now.timeIntervalSince(watchRefreshedAt) >= cadence else { return }
        watchRefreshedAt = now
        watchPending = true
        let span = AlertFormat.span(seconds, locale: prefs.formatter.locale)
        notifier.post(AlertNotification(identifier: Self.disconnectWatchIdentifier, category: .recordingAlert,
                                        subtitle: "Disconnected",
                                        body: "Meter disconnected for \(span) while recording",
                                        delay: seconds + cadence))
    }

    private func cancelDisconnectWatch() {
        guard watchPending else { return }
        watchPending = false
        watchRefreshedAt = .distantPast
        notifier.cancelPending(identifier: Self.disconnectWatchIdentifier)
    }

    private func endRecordingWatch() {
        stopDisconnectTimer()
        cancelDisconnectWatch()
        if let c = lastContext, c.isRecording {
            lastContext = SampleContext(dt: c.dt, isRecording: false, recordingStats: nil, connection: c.connection)
        }
    }

    private func startDisconnectTimer() {
        disconnectTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkDisconnect() }
        }
    }

    private func stopDisconnectTimer() {
        disconnectTimer?.invalidate()
        disconnectTimer = nil
    }

    /// One tick of the foreground disconnect watch: the meter counts as
    /// disconnected once no sample has arrived for `SessionStats.maxGapS`.
    /// Called by the 1 s timer; tests call it directly with a synthetic `now`.
    func checkDisconnect(now: Date = Date()) {
        let recording = lastContext?.isRecording ?? false
        let connected = lastSampleAt.map { now.timeIntervalSince($0) <= SessionStats.maxGapS } ?? false
        let events = monitor.tick(now: now, isRecording: recording, isConnected: connected)
        for event in events { fire(event, isRecording: recording) }
        if !recording || !monitor.isWatchingDisconnect { stopDisconnectTimer() }
    }
}
