import XCTest
@testable import WattBench

final class SignalLevelTests: XCTestCase {
    func testThresholds() {
        // The four steps of the cellularbars symbol.
        XCTAssertEqual(SignalLevel.level(rssi: -40), 1.0)
        XCTAssertEqual(SignalLevel.level(rssi: -55), 1.0)
        XCTAssertEqual(SignalLevel.level(rssi: -56), 0.75)
        XCTAssertEqual(SignalLevel.level(rssi: -67), 0.75)
        XCTAssertEqual(SignalLevel.level(rssi: -68), 0.5)
        XCTAssertEqual(SignalLevel.level(rssi: -80), 0.5)
        XCTAssertEqual(SignalLevel.level(rssi: -81), 0.25)
        XCTAssertEqual(SignalLevel.level(rssi: -100), 0.25)
        // 127 (and any non-negative value) means "RSSI unavailable".
        XCTAssertEqual(SignalLevel.level(rssi: 127), 0.25)
        XCTAssertEqual(SignalLevel.level(rssi: 0), 0.25)

        for rssi in stride(from: -110, through: 0, by: 1) {
            let level = SignalLevel.level(rssi: rssi)
            XCTAssertTrue((0...1).contains(level), "\(rssi) dBm -> \(level)")
        }
        XCTAssertEqual(SignalLevel.description(rssi: -50), "excellent signal")
        XCTAssertEqual(SignalLevel.description(rssi: -90), "weak signal")
    }
}

final class ConnectAutoSelectTests: XCTestCase {
    private func device(_ name: String, rssi: Int = -60) -> DiscoveredDevice {
        DiscoveredDevice(id: UUID(), name: name, rssi: rssi, lastSeen: Date())
    }

    func testSelectsOnlyWhenExactlyOneFNB58() {
        let meter = device("FNB58")
        XCTAssertEqual(ConnectAutoSelect.candidate(in: [meter], userInteracted: false)?.id, meter.id)
        // Case-insensitive substring match, like the scan filter.
        XCTAssertNotNil(ConnectAutoSelect.candidate(in: [device("fnb58-2A1B")], userInteracted: false))

        XCTAssertNil(ConnectAutoSelect.candidate(in: [], userInteracted: false), "nothing found")
        XCTAssertNil(ConnectAutoSelect.candidate(in: [meter, device("FNB58")], userInteracted: false),
                     "two meters wait for a tap")
        XCTAssertNil(ConnectAutoSelect.candidate(in: [device("Bench Lamp")], userInteracted: false),
                     "a single non-FNB58 device (Show all on) is never auto-selected")
        XCTAssertNil(ConnectAutoSelect.candidate(in: [meter, device("Bench Lamp")], userInteracted: false))
        XCTAssertNil(ConnectAutoSelect.candidate(in: [meter], userInteracted: true), "the user already tapped")
        XCTAssertEqual(ConnectAutoSelect.settleDelay, 1.5)
    }
}
