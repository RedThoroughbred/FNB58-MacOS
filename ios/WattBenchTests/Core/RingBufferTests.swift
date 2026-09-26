import XCTest
@testable import WattBench

final class RingBufferTests: XCTestCase {
    func testWraparound() {
        var b = RingBuffer<Int>(capacity: 3)
        XCTAssertTrue(b.isEmpty)
        XCTAssertNil(b.last)
        b.append(1)
        b.append(2)
        b.append(3)
        XCTAssertEqual(b.array(), [1, 2, 3])
        b.append(4)
        b.append(5)
        XCTAssertEqual(b.count, 3)
        XCTAssertEqual(b.array(), [3, 4, 5])
        XCTAssertEqual(b.last, 5)
        XCTAssertEqual(b[0], 3)
        XCTAssertEqual(b[2], 5)
        for k in 6...100 { b.append(k) }
        XCTAssertEqual(b.array(), [98, 99, 100])
        b.removeAll()
        XCTAssertEqual(b.count, 0)
        XCTAssertNil(b.last)
        XCTAssertEqual(b.array(), [])
        b.append(7)
        XCTAssertEqual(b.array(), [7])
    }
}
