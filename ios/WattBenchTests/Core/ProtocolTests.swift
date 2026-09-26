import XCTest
@testable import WattBench

final class ProtocolTests: XCTestCase {
    private func frame(v: Double, i: Double, w: Double, prefix: Int = FNB58Protocol.frameOffset) -> Data {
        var d = Data(repeating: 0, count: prefix)
        for x in [v, i, w] {
            var le = Int32((x * FNB58Protocol.scale).rounded()).littleEndian
            d.append(Data(bytes: &le, count: 4))
        }
        return d
    }

    func testParsesVoltageCurrentPower() throws {
        let r = try XCTUnwrap(FNB58Protocol.parse(frame(v: 9.0123, i: 1.2345, w: 11.1234)))
        XCTAssertEqual(r.voltage, 9.0123, accuracy: 1e-6)
        XCTAssertEqual(r.current, 1.2345, accuracy: 1e-6)
        XCTAssertEqual(r.power, 11.1234, accuracy: 1e-6)
    }

    func testParsesFromSlicedData() throws {
        // Data slices have non-zero startIndex; parser must index relative to it.
        let padded = Data([0xFF, 0xFF]) + frame(v: 5, i: 2, w: 10)
        let slice = padded[2...]
        let r = try XCTUnwrap(FNB58Protocol.parse(slice))
        XCTAssertEqual(r.voltage, 5, accuracy: 1e-9)
    }

    func testRejectsShortFrame() {
        XCTAssertNil(FNB58Protocol.parse(Data(repeating: 0, count: FNB58Protocol.frameOffset + 11)))
    }

    func testRejectsOutOfRangeVoltage() {
        XCTAssertNil(FNB58Protocol.parse(frame(v: -1, i: 0, w: 0)))
        XCTAssertNil(FNB58Protocol.parse(frame(v: 200, i: 0, w: 0)))
    }

    func testNegativeCurrentAllowed() throws {
        let r = try XCTUnwrap(FNB58Protocol.parse(frame(v: 5, i: -0.5, w: -2.5)))
        XCTAssertEqual(r.current, -0.5, accuracy: 1e-9)
    }

    func testInitCommands() {
        XCTAssertEqual(FNB58Protocol.initCommands, [Data([0xAA, 0x81, 0x00, 0xF4]), Data([0xAA, 0x82, 0x00, 0xA7])])
    }

    func testCarriesMonotonicStamp() throws {
        let r = try XCTUnwrap(FNB58Protocol.parse(frame(v: 5, i: 1, w: 5), monotonic: 12.5))
        XCTAssertEqual(r.monotonic, 12.5)
        XCTAssertEqual(r.id, 12.5)
    }
}
