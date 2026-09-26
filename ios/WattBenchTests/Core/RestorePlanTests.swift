import XCTest
@testable import WattBench

/// The decision behind `centralManager(_:willRestoreState:)`. A `CBPeripheral`
/// cannot be faked, so the glue in `MeterManager` stays thin and this pure
/// plan is what gets tested: it says which restored peripheral to re-adopt
/// (the delegate is reattached to it) and what to do once powered on.
final class RestorePlanTests: XCTestCase {
    private let id = UUID()

    private func snapshot(connected: Bool, characteristics: Bool, id: UUID? = nil) -> RestorePlan.PeripheralSnapshot {
        RestorePlan.PeripheralSnapshot(id: id ?? self.id, name: "FNB58", isConnected: connected,
                                       hasCharacteristics: characteristics)
    }

    func testConnectedPeripheralWithCharacteristicsResumesStreaming() {
        let plan = RestorePlan.make([snapshot(connected: true, characteristics: true)])
        XCTAssertEqual(plan, .resumeStreaming(id))
        XCTAssertEqual(plan.peripheralID, id, "the delegate is reattached to this peripheral")
    }

    func testConnectedPeripheralWithoutCharacteristicsRediscoversServices() {
        let plan = RestorePlan.make([snapshot(connected: true, characteristics: false)])
        XCTAssertEqual(plan, .rediscoverServices(id))
        XCTAssertEqual(plan.peripheralID, id)
    }

    func testDisconnectedPeripheralReconnectsOncePoweredOn() {
        let plan = RestorePlan.make([snapshot(connected: false, characteristics: true)])
        XCTAssertEqual(plan, .reconnect(id))
        XCTAssertEqual(plan.peripheralID, id)
        XCTAssertTrue(plan.description.contains("powered on"), "connect waits for centralManagerDidUpdateState")
    }

    func testNothingRestoredLeavesStateAlone() {
        let plan = RestorePlan.make([])
        XCTAssertEqual(plan, .nothing)
        XCTAssertNil(plan.peripheralID)
        XCTAssertFalse(plan.description.isEmpty)
    }

    func testOnlyTheFirstRestoredPeripheralIsAdopted() {
        let other = UUID()
        let plan = RestorePlan.make([snapshot(connected: false, characteristics: false),
                                     snapshot(connected: true, characteristics: true, id: other)])
        XCTAssertEqual(plan, .reconnect(id), "the app only ever connects to one meter")
    }

    func testRestoreIdentifierIsStable() {
        // Changing it would orphan sessions restored by an older build.
        XCTAssertEqual(RestorePlan.identifier, "com.thebench.wattbench.central")
    }
}
