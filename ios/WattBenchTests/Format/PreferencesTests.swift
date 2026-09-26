import XCTest
@testable import WattBench

@MainActor
final class PreferencesTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "wattbench.tests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testDefaults() {
        let p = Preferences(defaults: defaults)
        XCTAssertFalse(p.keepAwake)
        XCTAssertEqual(p.heroMetric, .power)
        XCTAssertEqual(p.defaultWindow, 30)
        XCTAssertEqual(p.precision, 4)
        XCTAssertTrue(p.autoRangeUnits)
        XCTAssertTrue(p.hapticsEnabled)
        XCTAssertTrue(p.autoConnect)
        XCTAssertNil(p.defaultAutoStop)
        XCTAssertNil(p.alertRulesData)
        XCTAssertTrue(p.excludeDemoFromTrips)
        XCTAssertEqual(p.capacityUnit, .mAh)
        XCTAssertTrue(p.showPeakLine)
        XCTAssertTrue(Preferences.precisionChoices.contains(p.precision))
        XCTAssertTrue(Preferences.windowChoices.contains(p.defaultWindow))
    }

    func testRoundTripThroughSuite() {
        let p = Preferences(defaults: defaults)
        p.keepAwake = true
        p.heroMetric = .current
        p.defaultWindow = 60
        p.precision = 3
        p.autoRangeUnits = false
        p.hapticsEnabled = false
        p.autoConnect = false
        p.alertRulesData = Data([1, 2, 3])
        p.excludeDemoFromTrips = false
        p.capacityUnit = .Ah
        p.showPeakLine = false

        // Every didSet writes the suite under a prefs.* key ...
        XCTAssertEqual(defaults.bool(forKey: "prefs.keepAwake"), true)
        XCTAssertEqual(defaults.string(forKey: "prefs.heroMetric"), "current")
        XCTAssertEqual(defaults.double(forKey: "prefs.defaultWindow"), 60)
        XCTAssertEqual(defaults.integer(forKey: "prefs.precision"), 3)
        XCTAssertEqual(defaults.string(forKey: "prefs.capacityUnit"), "Ah")

        // ... and a fresh instance on the same suite reads it all back.
        let q = Preferences(defaults: defaults)
        XCTAssertTrue(q.keepAwake)
        XCTAssertEqual(q.heroMetric, .current)
        XCTAssertEqual(q.defaultWindow, 60)
        XCTAssertEqual(q.precision, 3)
        XCTAssertFalse(q.autoRangeUnits)
        XCTAssertFalse(q.hapticsEnabled)
        XCTAssertFalse(q.autoConnect)
        XCTAssertEqual(q.alertRulesData, Data([1, 2, 3]))
        XCTAssertFalse(q.excludeDemoFromTrips)
        XCTAssertEqual(q.capacityUnit, .Ah)
        XCTAssertFalse(q.showPeakLine)

        // A different suite is untouched.
        let other = "wattbench.tests.other.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: other)?.removePersistentDomain(forName: other) }
        let isolated = Preferences(defaults: UserDefaults(suiteName: other) ?? .standard)
        XCTAssertEqual(isolated.heroMetric, .power)
    }

    func testDefaultAutoStopCodable() {
        let p = Preferences(defaults: defaults)
        let rule = AutoStopRule(belowCurrentA: 0.1, forSeconds: 30, maxDuration: 3600, maxEnergyWh: nil)
        p.defaultAutoStop = rule
        XCTAssertNotNil(defaults.data(forKey: "prefs.defaultAutoStop"))
        XCTAssertEqual(Preferences(defaults: defaults).defaultAutoStop, rule)

        p.defaultAutoStop = nil
        XCTAssertNil(defaults.data(forKey: "prefs.defaultAutoStop"))
        XCTAssertNil(Preferences(defaults: defaults).defaultAutoStop)

        // Garbage in the suite is ignored rather than crashing.
        defaults.set(Data("not json".utf8), forKey: "prefs.defaultAutoStop")
        XCTAssertNil(Preferences(defaults: defaults).defaultAutoStop)
        defaults.set("bogus", forKey: "prefs.heroMetric")
        XCTAssertEqual(Preferences(defaults: defaults).heroMetric, .power)
    }

    func testFormatterReflectsSettings() {
        let p = Preferences(defaults: defaults)
        p.precision = 3
        p.autoRangeUnits = true
        p.capacityUnit = .mAh
        var f = p.formatter
        f.locale = Locale(identifier: "en_US_POSIX")
        XCTAssertEqual(f.format(0.0123, .current).text, "12.3 mA")
        XCTAssertEqual(f.capacity(2.5).text, "2500 mAh")

        p.precision = 4
        p.autoRangeUnits = false
        p.capacityUnit = .Ah
        f = p.formatter
        f.locale = Locale(identifier: "en_US_POSIX")
        XCTAssertEqual(f.format(0.0123, .current).text, "0.01230 A")
        XCTAssertEqual(f.capacity(2.5).text, "2.500 Ah")
    }

    func testKeepAwakePolicy() {
        XCTAssertTrue(Preferences.shouldKeepAwake(keepAwake: true, isConnected: true, isActive: true, lowPowerMode: false))
        XCTAssertFalse(Preferences.shouldKeepAwake(keepAwake: false, isConnected: true, isActive: true, lowPowerMode: false))
        XCTAssertFalse(Preferences.shouldKeepAwake(keepAwake: true, isConnected: false, isActive: true, lowPowerMode: false),
                       "locks normally after a disconnect")
        XCTAssertFalse(Preferences.shouldKeepAwake(keepAwake: true, isConnected: true, isActive: false, lowPowerMode: false),
                       "locks normally once backgrounded")
        XCTAssertFalse(Preferences.shouldKeepAwake(keepAwake: true, isConnected: true, isActive: true, lowPowerMode: true),
                       "Low Power Mode overrides it")
    }
}
