import XCTest
@testable import WattBench

final class AlertRuleTests: XCTestCase {
    private let formatter = MetricFormatter(locale: Locale(identifier: "en_US"), precision: 3)

    func testConditionsRoundTripThroughTheStoredFields() {
        for condition in AlertRule.Condition.allCases {
            let rule = AlertRule(condition, value: condition.defaultValue, seconds: condition.defaultSeconds)
            XCTAssertEqual(rule.condition, condition, "\(condition)")
            XCTAssertEqual(rule.kind, condition.kind, "\(condition)")
            XCTAssertEqual(rule.name, condition.title)
            XCTAssertTrue(rule.isValid, "\(condition)")
            XCTAssertTrue(rule.enabled)
            XCTAssertTrue(rule.notify)
        }
        let over = AlertRule(.overVoltage, value: 21)
        XCTAssertEqual(over.above, 21)
        XCTAssertNil(over.below)
        XCTAssertEqual(over.value, 21)
        XCTAssertEqual(over.forSeconds, 0)

        let below = AlertRule(.currentBelow, value: 0.05, seconds: 60)
        XCTAssertEqual(below.below, 0.05)
        XCTAssertNil(below.above)
        XCTAssertEqual(below.forSeconds, 60)
        XCTAssertEqual(below.metric, .current)

        let gone = AlertRule(.disconnected, value: 0, seconds: 60)
        XCTAssertNil(gone.value)
        XCTAssertEqual(gone.forSeconds, 60)
        XCTAssertFalse(AlertRule(.disconnected, value: 0, seconds: 0).isValid)
        XCTAssertFalse(AlertRule(.voltageDrop, value: 0).isValid)
        XCTAssertTrue(AlertRule(.overVoltage, value: 21).isEquivalent(to: AlertRule(.overVoltage, value: 21, name: "Other")))
        XCTAssertFalse(AlertRule(.overVoltage, value: 21).isEquivalent(to: AlertRule(.overVoltage, value: 20)))
    }

    func testDecodesTheFoundationShapeWithoutKind() throws {
        let id = UUID()
        let json = """
        [{"id":"\(id.uuidString)","name":"Over-current","metric":"current","above":3.5,"forSeconds":0,"enabled":true,"notify":true}]
        """
        let rules = try JSONDecoder().decode([AlertRule].self, from: Data(json.utf8))
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules.first?.id, id)
        XCTAssertEqual(rules.first?.kind, .threshold)
        XCTAssertEqual(rules.first?.condition, .overCurrent)

        let encoded = try JSONEncoder().encode(rules + [AlertRule(.disconnected, value: 0, seconds: 30)])
        let back = try JSONDecoder().decode([AlertRule].self, from: encoded)
        XCTAssertEqual(back.count, 2)
        XCTAssertEqual(back.first, rules.first)
        XCTAssertEqual(back.last?.kind, .disconnected)
        XCTAssertEqual(back.last?.forSeconds, 30)
    }

    func testSummaries() {
        XCTAssertEqual(AlertRule(.overVoltage, value: 21).summary(formatter: formatter), "Voltage above 21 V")
        XCTAssertEqual(AlertRule(.underVoltage, value: 4.75).summary(formatter: formatter), "Voltage below 4.75 V")
        XCTAssertEqual(AlertRule(.overCurrent, value: 3.5).summary(formatter: formatter), "Current above 3.5 A")
        XCTAssertEqual(AlertRule(.overPower, value: 70).summary(formatter: formatter), "Power above 70 W")
        XCTAssertEqual(AlertRule(.currentBelow, value: 0.05, seconds: 60).summary(formatter: formatter),
                       "Current below 50 mA for 1 min")
        XCTAssertEqual(AlertRule(.voltageDrop, value: 1).summary(formatter: formatter),
                       "Voltage drops 1 V within 1 sec")
        XCTAssertEqual(AlertRule(.disconnected, value: 0, seconds: 60).summary(formatter: formatter),
                       "Meter disconnected for 1 min while recording")
        XCTAssertEqual(AlertFormat.span(90, locale: Locale(identifier: "en_US")), "1 min, 30 sec")
        XCTAssertEqual(AlertFormat.span(3600, locale: Locale(identifier: "en_US")), "1 hr")
    }

    func testPresetsMatchTheSpec() {
        XCTAssertEqual(AlertPreset.usbC65W.rules.map(\.condition), [.overVoltage, .overCurrent, .overPower, .voltageDrop])
        XCTAssertEqual(AlertPreset.usbC65W.rules.map { $0.value ?? 0 }, [21, 3.5, 70, 1])
        XCTAssertEqual(AlertPreset.fiveVoltDevice.rules.map(\.condition), [.underVoltage, .overCurrent])
        XCTAssertEqual(AlertPreset.fiveVoltDevice.rules.map { $0.value ?? 0 }, [4.75, 3])
        XCTAssertEqual(AlertPreset.powerBankDrain.rules.map(\.condition), [.currentBelow, .disconnected])
        XCTAssertEqual(AlertPreset.powerBankDrain.rules.first?.value, 0.05)
        XCTAssertEqual(AlertPreset.powerBankDrain.rules.map(\.forSeconds), [60, 60])
        for preset in AlertPreset.allCases {
            XCTAssertTrue(preset.rules.allSatisfy { $0.isValid && $0.enabled && $0.notify }, preset.title)
            XCTAssertFalse(preset.summary(formatter: formatter).isEmpty)
        }
    }

    func testEditorDurationStepper() {
        XCTAssertEqual(AlertRuleEditor.step(5, up: false), 5, "clamped at 5 s")
        XCTAssertEqual(AlertRuleEditor.step(5, up: true), 10)
        XCTAssertEqual(AlertRuleEditor.step(55, up: true), 60)
        XCTAssertEqual(AlertRuleEditor.step(60, up: true), 90, "30 s steps above a minute")
        XCTAssertEqual(AlertRuleEditor.step(60, up: false), 55)
        XCTAssertEqual(AlertRuleEditor.step(300, up: true), 360, "whole minutes above five")
        XCTAssertEqual(AlertRuleEditor.step(300, up: false), 270)
        XCTAssertEqual(AlertRuleEditor.step(7200, up: true), 7200, "clamped at 2 h")
    }
}
