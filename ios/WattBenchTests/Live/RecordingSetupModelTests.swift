import XCTest
@testable import WattBench

final class RecordingSetupModelTests: XCTestCase {
    /// 2025-10-09 08:53:20 UTC
    private let t0 = Date(timeIntervalSince1970: 1_760_000_000)
    private let posix = Locale(identifier: "en_US_POSIX")
    private var utc: TimeZone { TimeZone(identifier: "UTC") ?? .current }

    func testDefaultNameComposition() {
        let name = RecordingSetupModel.defaultName(deviceName: "FNB58", date: t0, locale: posix, timeZone: utc)
        XCTAssertTrue(name.hasPrefix("FNB58 · "), name)
        XCTAssertTrue(name.contains("Oct 9"), name)
        XCTAssertTrue(name.contains("8:53"), name)
        XCTAssertFalse(name.contains("2025"), "the year is noise on a bench: \(name)")

        XCTAssertTrue(RecordingSetupModel.defaultName(deviceName: nil, date: t0, locale: posix, timeZone: utc).hasPrefix("Session · "))
        XCTAssertTrue(RecordingSetupModel.defaultName(deviceName: "  ", date: t0, locale: posix, timeZone: utc).hasPrefix("Session · "))
        XCTAssertTrue(RecordingSetupModel.defaultName(deviceName: " Demo data ", date: t0, locale: posix, timeZone: utc).hasPrefix("Demo data · "))

        let model = RecordingSetupModel(deviceName: "FNB58", date: t0, locale: posix, timeZone: utc)
        XCTAssertEqual(model.name, name)
        XCTAssertEqual(model.trimmedName, name)
        XCTAssertTrue(model.isValid)
        XCTAssertNil(model.noteOrNil)
        XCTAssertTrue(model.selectedTags.isEmpty)
        XCTAssertEqual(model.tagChoices, RecordingSetupModel.defaultTags)
    }

    func testRuleCompositionFromToggles() {
        var m = RecordingSetupModel(deviceName: "x", date: t0, locale: posix, timeZone: utc)
        XCTAssertNil(m.rule, "nothing enabled means no rule")

        m.belowEnabled = true
        XCTAssertEqual(m.rule, AutoStopRule(belowCurrentA: 0.10, forSeconds: 60))
        m.forSeconds = 120
        m.belowCurrentA = 0.25
        XCTAssertEqual(m.rule, AutoStopRule(belowCurrentA: 0.25, forSeconds: 120))

        m.durationEnabled = true
        m.maxDuration = 3600
        XCTAssertEqual(m.rule?.maxDuration, 3600)

        m.energyEnabled = true
        XCTAssertFalse(m.isValid, "energy rule needs a number")
        XCTAssertNil(m.rule?.maxEnergyWh)
        m.maxEnergyText = "12.5"
        XCTAssertTrue(m.isValid)
        XCTAssertEqual(m.rule?.maxEnergyWh, 12.5)
        m.maxEnergyText = "abc"
        XCTAssertFalse(m.isValid)
        m.maxEnergyText = "-3"
        XCTAssertFalse(m.isValid, "a negative limit would stop immediately")

        m.belowEnabled = false
        m.energyEnabled = false
        XCTAssertEqual(m.rule, AutoStopRule(belowCurrentA: nil, forSeconds: 120, maxDuration: 3600, maxEnergyWh: nil))
        XCTAssertTrue(m.isValid)

        m.name = "   "
        XCTAssertFalse(m.isValid, "a blank name cannot start")

        // The locale's decimal separator is honoured.
        var de = RecordingSetupModel(deviceName: "x", date: t0, locale: Locale(identifier: "de_DE"), timeZone: utc)
        de.energyEnabled = true
        de.maxEnergyText = "3,5"
        XCTAssertEqual(de.maxEnergyWh, 3.5)

        // A remembered rule populates the toggles.
        let remembered = AutoStopRule(belowCurrentA: 0.3, forSeconds: 300, maxDuration: 7200, maxEnergyWh: 3)
        let seeded = RecordingSetupModel(deviceName: "x", date: t0, defaultRule: remembered, locale: posix, timeZone: utc)
        XCTAssertTrue(seeded.belowEnabled)
        XCTAssertEqual(seeded.belowCurrentA, 0.3)
        XCTAssertEqual(seeded.forSeconds, 300)
        XCTAssertTrue(seeded.durationEnabled)
        XCTAssertEqual(seeded.maxDuration, 7200)
        XCTAssertTrue(seeded.energyEnabled)
        XCTAssertEqual(seeded.maxEnergyText, "3")
        XCTAssertEqual(seeded.rule, remembered)
    }

    func testRecentTagsFromSummariesDeduped() {
        let summaries = [
            summary(start: t0.addingTimeInterval(-300), tags: ["Anker 65W", "Cable"]),
            summary(start: t0, tags: ["Charger", "iPhone 15", " "]),
            summary(start: t0.addingTimeInterval(-100), tags: ["iphone 15", "Anker 65W", "Bench PSU"]),
        ]
        XCTAssertEqual(RecordingSetupModel.recentTags(from: summaries), ["iPhone 15", "Anker 65W", "Bench PSU"],
                       "newest first, first spelling wins, defaults excluded, blanks dropped")
        XCTAssertEqual(RecordingSetupModel.recentTags(from: summaries, limit: 2), ["iPhone 15", "Anker 65W"])
        XCTAssertEqual(RecordingSetupModel.recentTags(from: []), [])

        var model = RecordingSetupModel(deviceName: "x", date: t0, recentTags: ["iPhone 15", "cable", "Anker 65W"],
                                        locale: posix, timeZone: utc)
        XCTAssertEqual(model.tagChoices, RecordingSetupModel.defaultTags + ["iPhone 15", "Anker 65W"],
                       "a recent tag that only differs in case from a default is not offered twice")
        model.toggleTag("Charger")
        model.toggleTag("iPhone 15")
        XCTAssertEqual(model.selectedTags, ["Charger", "iPhone 15"])
        XCTAssertTrue(model.isSelected("Charger"))
        model.toggleTag("Charger")
        XCTAssertEqual(model.selectedTags, ["iPhone 15"])
    }

    private func summary(start: Date, tags: [String]) -> SessionSummary {
        SessionSummary(id: UUID(), name: "s", startTime: start, endTime: start.addingTimeInterval(10), deviceName: nil,
                       stats: SessionStats(), sampleCount: 0, markers: [], tags: tags, notes: nil,
                       autoStopReason: nil, isDemo: false, state: .complete, sparkline: [])
    }
}
