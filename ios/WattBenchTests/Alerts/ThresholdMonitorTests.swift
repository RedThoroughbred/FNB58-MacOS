import XCTest
@testable import WattBench

final class ThresholdMonitorTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_760_000_000)
    private let formatter = MetricFormatter(locale: Locale(identifier: "en_US"), precision: 3)

    private func reading(at s: TimeInterval, v: Double = 9, i: Double = 1) -> Reading {
        Reading(timestamp: t0.addingTimeInterval(s), voltage: v, current: i, power: v * i, monotonic: 100 + s)
    }

    private func context(dt: TimeInterval, recording: Bool = false) -> SampleContext {
        SampleContext(dt: dt, isRecording: recording, recordingStats: nil, connection: .connected("FNB58"))
    }

    /// Feeds readings one at a time, deriving `dt` from the previous reading
    /// the way `SamplePipeline` does (0 for the first).
    private struct Feed {
        var last: Reading?

        mutating func send(_ r: Reading, to m: inout ThresholdMonitor, recording: Bool = false) -> [AlertEvent] {
            let dt = last.map { r.monotonic - $0.monotonic } ?? 0
            last = r
            let context = SampleContext(dt: dt, isRecording: recording, recordingStats: nil,
                                        connection: .connected("FNB58"))
            return m.evaluate(r, context: context)
        }

        mutating func send(_ readings: [Reading], to m: inout ThresholdMonitor, recording: Bool = false) -> [AlertEvent] {
            var events: [AlertEvent] = []
            for r in readings { events += send(r, to: &m, recording: recording) }
            return events
        }
    }

    // MARK: - Threshold rules

    func testHysteresisAndCooldown() {
        let rule = AlertRule(.overVoltage, value: 20)
        var m = ThresholdMonitor(rules: [rule], formatter: formatter)

        XCTAssertTrue(m.evaluate(reading(at: 0, v: 19), context: context(dt: 0)).isEmpty)
        let fired = m.evaluate(reading(at: 0.1, v: 20.5), context: context(dt: 0.1))
        XCTAssertEqual(fired.count, 1)
        XCTAssertEqual(fired.first?.ruleID, rule.id)
        XCTAssertEqual(fired.first?.title, "Over-voltage")
        XCTAssertEqual(fired.first?.metric, .voltage)
        XCTAssertEqual(fired.first?.value, 20.5)
        XCTAssertEqual(fired.first?.message, "Voltage 20.5 V is above 20 V")
        XCTAssertEqual(fired.first?.firedAt, t0.addingTimeInterval(0.1))
        XCTAssertEqual(m.state(of: rule.id)?.armed, false)

        // Still above: silent, the rule is disarmed.
        XCTAssertTrue(m.evaluate(reading(at: 0.2, v: 21), context: context(dt: 0.1)).isEmpty)
        // Under the bound but not 2 % inside it: still disarmed.
        XCTAssertTrue(m.evaluate(reading(at: 0.3, v: 19.8), context: context(dt: 0.1)).isEmpty)
        XCTAssertEqual(m.state(of: rule.id)?.armed, false)
        XCTAssertTrue(m.evaluate(reading(at: 0.4, v: 20.5), context: context(dt: 0.1)).isEmpty)
        // 2 % inside (19.6 V) re-arms ...
        XCTAssertTrue(m.evaluate(reading(at: 0.5, v: 19.5), context: context(dt: 0.1)).isEmpty)
        XCTAssertEqual(m.state(of: rule.id)?.armed, true)
        // ... but the 60 s cooldown after the first alert keeps it quiet ...
        XCTAssertTrue(m.evaluate(reading(at: 0.6, v: 20.5), context: context(dt: 0.1)).isEmpty)
        XCTAssertTrue(m.evaluate(reading(at: 30, v: 20.5), context: context(dt: 29.4)).isEmpty)
        XCTAssertTrue(m.evaluate(reading(at: 61, v: 19.5), context: context(dt: 31)).isEmpty)
        // ... until it is over: armed and above again fires a second alert.
        let again = m.evaluate(reading(at: 61.1, v: 20.5), context: context(dt: 0.1))
        XCTAssertEqual(again.count, 1)
        XCTAssertEqual(again.first?.firedAt, t0.addingTimeInterval(61.1))
    }

    func testRulesFireWhetherRecordingOrNotAndDisabledRulesNever() {
        let overCurrent = AlertRule(.overCurrent, value: 3)
        var overPower = AlertRule(.overPower, value: 10)
        overPower.enabled = false
        var m = ThresholdMonitor(rules: [overCurrent, overPower], formatter: formatter)
        var feed = Feed()
        // 31.5 W crosses the disabled power rule; only the current rule fires.
        let events = feed.send([reading(at: 0, i: 2), reading(at: 0.1, i: 3.5)], to: &m, recording: false)
        XCTAssertEqual(events.map(\.ruleID), [overCurrent.id])
        XCTAssertEqual(events.first?.message, "Current 3.5 A is above 3 A")
        XCTAssertEqual(events.first?.value, 3.5)
    }

    func testCurrentBelowCountsRealSamplesOnly() {
        let rule = AlertRule(.currentBelow, value: 0.05, seconds: 1)

        // A tapering charge: 0.5 A falling 5 mA per sample crosses 50 mA at
        // sample 91 and settles at 20 mA. One alert, one second of samples
        // later, and never again while it stays low. (Integer milliamps keep
        // sample 90 at exactly the 50 mA bound, not a rounding error under it.)
        var taper = ThresholdMonitor(rules: [rule], formatter: formatter)
        var taperFeed = Feed()
        var readings: [Reading] = []
        for k in 0..<200 {
            readings.append(reading(at: Double(k) * 0.1, i: max(0.02, Double(500 - 5 * k) / 1000)))
        }
        let events = taperFeed.send(readings, to: &taper)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.metric, .current)
        XCTAssertEqual(events.first?.firedAt, t0.addingTimeInterval(10.0))
        XCTAssertEqual(events.first?.message, "Current 20 mA has been below 50 mA for 1 sec")

        // A one-sample dip, and even a 0.9 s dip, does not.
        var dip = ThresholdMonitor(rules: [rule], formatter: formatter)
        var dipFeed = Feed()
        var dips: [Reading] = []
        for k in 0..<100 { dips.append(reading(at: Double(k) * 0.1, i: k == 20 || (50...58).contains(k) ? 0.01 : 0.5)) }
        XCTAssertTrue(dipFeed.send(dips, to: &dip).isEmpty)
        XCTAssertEqual(dip.state(of: rule.id)?.sustained, 0, "reset once the current is back 2 % inside")

        // A 60 s reconnect gap does not count toward the second.
        var gap = ThresholdMonitor(rules: [rule], formatter: formatter)
        var gapFeed = Feed()
        for k in 0...4 { XCTAssertTrue(gapFeed.send(reading(at: Double(k) * 0.1, i: 0.01), to: &gap).isEmpty) }
        XCTAssertEqual(gap.state(of: rule.id)?.sustained ?? -1, 0.4, accuracy: 1e-9)
        XCTAssertTrue(gapFeed.send(reading(at: 60.5, i: 0.01), to: &gap).isEmpty)
        XCTAssertEqual(gap.state(of: rule.id)?.sustained ?? -1, 0.4, accuracy: 1e-9, "the gap itself is not counted")
        for k in 1...5 { XCTAssertTrue(gapFeed.send(reading(at: 60.5 + Double(k) * 0.1, i: 0.01), to: &gap).isEmpty) }
        let completed = gapFeed.send(reading(at: 61.1, i: 0.01), to: &gap)
        XCTAssertEqual(completed.count, 1, "1.0 s of real samples below the threshold")
        XCTAssertEqual(completed.first?.firedAt, t0.addingTimeInterval(61.1))
    }

    // MARK: - Voltage drop

    func testVoltageDropWithinOneSecond() {
        let rule = AlertRule(.voltageDrop, value: 1)
        var m = ThresholdMonitor(rules: [rule], formatter: formatter)
        var feed = Feed()
        for k in 0..<20 { XCTAssertTrue(feed.send(reading(at: Double(k) * 0.1, v: 9), to: &m).isEmpty) }

        let drop = feed.send(reading(at: 2.0, v: 7.9), to: &m)
        XCTAssertEqual(drop.count, 1)
        XCTAssertEqual(drop.first?.metric, .voltage)
        XCTAssertEqual(drop.first?.value ?? 0, 1.1, accuracy: 1e-9)
        XCTAssertEqual(drop.first?.message, "Voltage dropped 1.1 V within 1 sec (from 9 V to 7.9 V)")

        // Holding at the lower level is not a new drop; once the old peak has
        // left the 1 s window the rule re-arms.
        for k in 1...15 { XCTAssertTrue(feed.send(reading(at: 2.0 + Double(k) * 0.1, v: 7.9), to: &m).isEmpty) }
        XCTAssertEqual(m.state(of: rule.id)?.armed, true)
        // A second drop inside the cooldown stays quiet.
        XCTAssertTrue(feed.send(reading(at: 3.6, v: 6.5), to: &m).isEmpty)

        // A slow drift (2 V over 4 s) never drops 1 V inside any one second.
        var slow = ThresholdMonitor(rules: [rule], formatter: formatter)
        var slowFeed = Feed()
        for k in 0..<40 {
            XCTAssertTrue(slowFeed.send(reading(at: Double(k) * 0.1, v: 9 - Double(k) * 0.05), to: &slow).isEmpty)
        }
    }

    func testVoltageRingKeepsTheNewestEntries() {
        var ring = VoltageRing()
        for k in 0..<40 { ring.push(time: Double(k), voltage: Double(k)) }
        XCTAssertEqual(ring.count, VoltageRing.capacity)
        XCTAssertEqual(ring.maxVoltage(since: 0), 39, "oldest entries were overwritten, newest kept")
        XCTAssertEqual(ring.maxVoltage(since: 38.5), 39)
        XCTAssertEqual(ring.maxVoltage(since: 100), -.infinity)
        ring.removeAll()
        XCTAssertEqual(ring.count, 0)
        XCTAssertEqual(ring.maxVoltage(since: 0), -.infinity)
    }

    // MARK: - Disconnected

    func testDisconnectedRuleOnlyWhileRecording() {
        let rule = AlertRule(.disconnected, value: 0, seconds: 10)
        var m = ThresholdMonitor(rules: [rule], formatter: formatter)
        XCTAssertTrue(m.hasEnabledDisconnectRule)
        XCTAssertEqual(m.disconnectNotifySeconds, 10)

        // Not recording: the meter can be away as long as it likes.
        XCTAssertTrue(m.evaluate(reading(at: 0), context: context(dt: 0, recording: false)).isEmpty)
        XCTAssertTrue(m.tick(now: t0.addingTimeInterval(30), isRecording: false, isConnected: false).isEmpty)
        XCTAssertTrue(m.tick(now: t0.addingTimeInterval(60), isRecording: false, isConnected: false).isEmpty)

        // Recording: fires once the meter has been away for 10 s, and only once.
        XCTAssertTrue(m.evaluate(reading(at: 100), context: context(dt: 100, recording: true)).isEmpty)
        XCTAssertTrue(m.tick(now: t0.addingTimeInterval(103), isRecording: true, isConnected: true).isEmpty)
        XCTAssertTrue(m.tick(now: t0.addingTimeInterval(105), isRecording: true, isConnected: false).isEmpty)
        XCTAssertTrue(m.isWatchingDisconnect)
        let fired = m.tick(now: t0.addingTimeInterval(110), isRecording: true, isConnected: false)
        XCTAssertEqual(fired.count, 1)
        XCTAssertEqual(fired.first?.ruleID, rule.id)
        XCTAssertEqual(fired.first?.title, "Disconnected")
        XCTAssertEqual(fired.first?.message, "Meter disconnected for 10 sec while recording")
        XCTAssertNil(fired.first?.metric)
        XCTAssertEqual(fired.first?.firedAt, t0.addingTimeInterval(110))
        XCTAssertFalse(m.isWatchingDisconnect)
        XCTAssertTrue(m.tick(now: t0.addingTimeInterval(120), isRecording: true, isConnected: false).isEmpty)

        // A sample means the meter is back and re-arms the rule; the cooldown
        // still applies to the next disconnection.
        XCTAssertTrue(m.evaluate(reading(at: 130), context: context(dt: 30, recording: true)).isEmpty)
        XCTAssertTrue(m.isWatchingDisconnect)
        XCTAssertTrue(m.tick(now: t0.addingTimeInterval(145), isRecording: true, isConnected: false).isEmpty,
                      "inside the 60 s cooldown")
        XCTAssertEqual(m.tick(now: t0.addingTimeInterval(175), isRecording: true, isConnected: false).count, 1)

        var disabled = rule
        disabled.enabled = false
        m.setRules([disabled])
        XCTAssertFalse(m.hasEnabledDisconnectRule)
        XCTAssertNil(m.disconnectNotifySeconds)
        XCTAssertTrue(m.tick(now: t0.addingTimeInterval(400), isRecording: true, isConnected: false).isEmpty)
    }

    // MARK: - Rule set changes

    func testSetRulesKeepsCooldownForSurvivingRules() {
        let a = AlertRule(.overVoltage, value: 20)
        var m = ThresholdMonitor(rules: [a], formatter: formatter)
        XCTAssertEqual(m.evaluate(reading(at: 0, v: 21), context: context(dt: 0)).count, 1)

        let b = AlertRule(.overCurrent, value: 3)
        m.setRules([b, a])
        XCTAssertEqual(m.rules.map(\.id), [b.id, a.id])
        XCTAssertEqual(m.state(of: a.id)?.armed, false, "state follows the rule, not its position")
        XCTAssertEqual(m.state(of: b.id)?.armed, true)

        let events = m.evaluate(reading(at: 0.1, v: 21, i: 4), context: context(dt: 0.1))
        XCTAssertEqual(events.map(\.ruleID), [b.id], "a is disarmed and cooling down")

        m.setRules([])
        XCTAssertTrue(m.evaluate(reading(at: 0.2, v: 21, i: 4), context: context(dt: 0.1)).isEmpty)
        XCTAssertNil(m.state(of: a.id))
    }
}
