import Foundation
import Observation

/// User settings, each mirrored to UserDefaults on change. Inject a separate
/// suite in tests. `showAllDevices` deliberately lives on `MeterManager`,
/// which persists it itself.
@MainActor
@Observable
final class Preferences {
    static let shared = Preferences()

    enum CapacityUnit: String, Codable, CaseIterable { case mAh, Ah }

    private enum Key {
        static let keepAwake = "prefs.keepAwake"
        static let heroMetric = "prefs.heroMetric"
        static let defaultWindow = "prefs.defaultWindow"
        static let precision = "prefs.precision"
        static let autoRangeUnits = "prefs.autoRangeUnits"
        static let hapticsEnabled = "prefs.hapticsEnabled"
        static let autoConnect = "prefs.autoConnect"
        static let defaultAutoStop = "prefs.defaultAutoStop"
        static let alertRulesData = "prefs.alertRulesData"
        static let excludeDemoFromTrips = "prefs.excludeDemoFromTrips"
        static let capacityUnit = "prefs.capacityUnit"
        static let showPeakLine = "prefs.showPeakLine"
    }

    var keepAwake: Bool { didSet { defaults.set(keepAwake, forKey: Key.keepAwake) } }
    var heroMetric: Metric { didSet { defaults.set(heroMetric.rawValue, forKey: Key.heroMetric) } }
    /// Live chart window in seconds.
    var defaultWindow: Double { didSet { defaults.set(defaultWindow, forKey: Key.defaultWindow) } }
    /// Significant digits for readouts.
    var precision: Int { didSet { defaults.set(precision, forKey: Key.precision) } }
    var autoRangeUnits: Bool { didSet { defaults.set(autoRangeUnits, forKey: Key.autoRangeUnits) } }
    var hapticsEnabled: Bool { didSet { defaults.set(hapticsEnabled, forKey: Key.hapticsEnabled) } }
    var autoConnect: Bool { didSet { defaults.set(autoConnect, forKey: Key.autoConnect) } }
    var defaultAutoStop: AutoStopRule? {
        didSet { defaults.set(defaultAutoStop.flatMap { try? JSONEncoder().encode($0) }, forKey: Key.defaultAutoStop) }
    }
    var alertRulesData: Data? { didSet { defaults.set(alertRulesData, forKey: Key.alertRulesData) } }
    var excludeDemoFromTrips: Bool { didSet { defaults.set(excludeDemoFromTrips, forKey: Key.excludeDemoFromTrips) } }
    var capacityUnit: CapacityUnit { didSet { defaults.set(capacityUnit.rawValue, forKey: Key.capacityUnit) } }
    var showPeakLine: Bool { didSet { defaults.set(showPeakLine, forKey: Key.showPeakLine) } }

    /// Significant digits offered by the Settings picker.
    static let precisionChoices = [3, 4]

    /// Live chart windows (seconds) offered by the Settings picker; mirrors
    /// the Live tab's window segments.
    static let windowChoices: [Double] = [10, 30, 60, 120]

    /// The keep-awake decision applied to `UIApplication.isIdleTimerDisabled`
    /// by the app shell: only while connected, in the foreground and not in
    /// Low Power Mode, so the screen always locks normally after a disconnect
    /// or when the app is backgrounded.
    nonisolated static func shouldKeepAwake(keepAwake: Bool, isConnected: Bool, isActive: Bool,
                                            lowPowerMode: Bool) -> Bool {
        keepAwake && isConnected && isActive && !lowPowerMode
    }

    /// A formatter reflecting the current precision, auto-range and
    /// capacity-unit settings.
    var formatter: MetricFormatter {
        MetricFormatter(precision: precision, autoRange: autoRangeUnits, capacityUnit: capacityUnit)
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        keepAwake = defaults.object(forKey: Key.keepAwake) as? Bool ?? false
        heroMetric = defaults.string(forKey: Key.heroMetric).flatMap(Metric.init(rawValue:)) ?? .power
        defaultWindow = defaults.object(forKey: Key.defaultWindow) as? Double ?? 30
        precision = defaults.object(forKey: Key.precision) as? Int ?? 4
        autoRangeUnits = defaults.object(forKey: Key.autoRangeUnits) as? Bool ?? true
        hapticsEnabled = defaults.object(forKey: Key.hapticsEnabled) as? Bool ?? true
        autoConnect = defaults.object(forKey: Key.autoConnect) as? Bool ?? true
        defaultAutoStop = defaults.data(forKey: Key.defaultAutoStop).flatMap { try? JSONDecoder().decode(AutoStopRule.self, from: $0) }
        alertRulesData = defaults.data(forKey: Key.alertRulesData)
        excludeDemoFromTrips = defaults.object(forKey: Key.excludeDemoFromTrips) as? Bool ?? true
        capacityUnit = defaults.string(forKey: Key.capacityUnit).flatMap(CapacityUnit.init(rawValue:)) ?? .mAh
        showPeakLine = defaults.object(forKey: Key.showPeakLine) as? Bool ?? true
    }
}
