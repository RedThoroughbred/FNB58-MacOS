import XCTest
@testable import WattBench

final class ConnectionStateTests: XCTestCase {
    func testLabelsSymbolsAndTransientFlags() {
        let since = Date()
        let all: [ConnectionState] = [.bluetoothOff, .unauthorized, .idle, .scanning, .connecting("FNB58"),
                                      .connected("FNB58"), .reconnecting(name: "FNB58", since: since),
                                      .unreachable("FNB58"), .demo]
        for s in all {
            XCTAssertFalse(s.label.isEmpty)
            XCTAssertFalse(s.shortLabel.isEmpty)
            XCTAssertFalse(s.symbolName.isEmpty)
            XCTAssertTrue(["green", "orange", "gray", "purple", "red"].contains(s.tintToken), s.tintToken)
        }

        // Connected-ness: data is flowing (or simulated).
        XCTAssertTrue(ConnectionState.connected("FNB58").isConnected)
        XCTAssertTrue(ConnectionState.demo.isConnected)
        XCTAssertFalse(ConnectionState.reconnecting(name: "FNB58", since: since).isConnected)
        XCTAssertFalse(ConnectionState.unreachable("FNB58").isConnected)
        XCTAssertFalse(ConnectionState.idle.isConnected)

        // Transient states drive the antenna's variable-colour effect.
        XCTAssertTrue(ConnectionState.scanning.isTransient)
        XCTAssertTrue(ConnectionState.connecting("FNB58").isTransient)
        XCTAssertTrue(ConnectionState.reconnecting(name: "FNB58", since: since).isTransient)
        XCTAssertFalse(ConnectionState.connected("FNB58").isTransient)
        XCTAssertFalse(ConnectionState.unreachable("FNB58").isTransient)
        XCTAssertFalse(ConnectionState.demo.isTransient)

        // Tints: green connected, orange in flight, gray off/idle, purple demo, red trouble.
        XCTAssertEqual(ConnectionState.connected("FNB58").tintToken, "green")
        XCTAssertEqual(ConnectionState.reconnecting(name: "FNB58", since: since).tintToken, "orange")
        XCTAssertEqual(ConnectionState.idle.tintToken, "gray")
        XCTAssertEqual(ConnectionState.demo.tintToken, "purple")
        XCTAssertEqual(ConnectionState.unreachable("FNB58").tintToken, "red")
        XCTAssertEqual(ConnectionState.unauthorized.tintToken, "red")

        // Labels carry the meter name where there is one.
        XCTAssertEqual(ConnectionState.connected("FNB58").label, "FNB58")
        XCTAssertEqual(ConnectionState.connected("FNB58").shortLabel, "FNB58")
        XCTAssertTrue(ConnectionState.reconnecting(name: "FNB58", since: since).label.contains("FNB58"))
        XCTAssertTrue(ConnectionState.unreachable("FNB58").label.contains("FNB58"))
        XCTAssertEqual(ConnectionState.demo.shortLabel, "Demo")

        // Equality includes the associated values (the pill re-renders on a new `since`).
        XCTAssertEqual(ConnectionState.reconnecting(name: "FNB58", since: since), .reconnecting(name: "FNB58", since: since))
        XCTAssertNotEqual(ConnectionState.reconnecting(name: "FNB58", since: since),
                          .reconnecting(name: "FNB58", since: since.addingTimeInterval(1)))
    }
}
