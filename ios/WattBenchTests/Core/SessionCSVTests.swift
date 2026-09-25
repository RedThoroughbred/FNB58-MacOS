import XCTest
@testable import WattBench

final class SessionCSVTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_760_000_000)

    private func session(samples: Int, markers: [Marker] = []) -> Session {
        var stats = SessionStats()
        var readings: [Reading] = []
        readings.reserveCapacity(samples)
        for k in 0..<samples {
            let r = Reading(timestamp: t0.addingTimeInterval(Double(k) * 0.1), voltage: 9.0123, current: 1.2345, power: 11.1257)
            stats.add(r)
            readings.append(r)
        }
        return Session(id: UUID(), name: "CSV", startTime: t0, endTime: t0.addingTimeInterval(Double(samples) * 0.1),
                       deviceName: "FNB58", stats: stats, readings: readings, markers: markers)
    }

    /// The 1.0 export, byte for byte, for the first four columns.
    private func legacyRow(_ r: Reading) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return "\(f.string(from: r.timestamp)),\(r.voltage),\(r.current),\(r.power)"
    }

    func testFirstFourColumnsUnchangedAndMarkerColumnAppended() {
        let s = session(samples: 5, markers: [
            Marker(timestamp: t0.addingTimeInterval(0.2), label: "Plugged in", kind: .user),
            Marker(timestamp: t0.addingTimeInterval(0.25), label: "Load, \"step\"", kind: .user),
            Marker(timestamp: t0.addingTimeInterval(99), label: "late", kind: .gap),
        ])
        let lines = s.csv().split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines[0], "timestamp,voltage_v,current_a,power_w,elapsed_s,marker_label")
        XCTAssertEqual(lines.count, 7, "header, 5 rows, trailing newline")
        XCTAssertEqual(lines[6], "")
        for k in 0..<5 {
            XCTAssertTrue(lines[k + 1].hasPrefix(legacyRow(s.readings[k]) + ","), "row \(k): \(lines[k + 1])")
        }
        XCTAssertEqual(lines[1], "2025-10-09T08:53:20.000Z,9.0123,1.2345,11.1257,0.0,")
        XCTAssertEqual(lines[3], "2025-10-09T08:53:20.200Z,9.0123,1.2345,11.1257,0.2,Plugged in")
        XCTAssertEqual(lines[4], "2025-10-09T08:53:20.300Z,9.0123,1.2345,11.1257,0.3,\"Load, \"\"step\"\"\"",
                       "a marker between rows attaches to the next row; commas and quotes are RFC 4180 quoted")
        XCTAssertTrue(lines[5].hasSuffix(",0.4,late"), "a marker after the last sample attaches to the last row")
    }

    func test100kRowsUnderTwoSeconds() throws {
        let s = session(samples: 100_000, markers: [Marker(timestamp: t0.addingTimeInterval(5000), label: "half", kind: .user)])
        let clock = ContinuousClock()
        var text = ""
        let inMemory = clock.measure { text = s.csv() }
        XCTAssertLessThan(inMemory, .seconds(2), "csv() took \(inMemory)")
        XCTAssertEqual(text.utf8.count, text.split(separator: "\n").reduce(0) { $0 + $1.utf8.count + 1 })
        XCTAssertEqual(text.split(separator: "\n").count, 100_001)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: url) }
        let streamed = clock.measure { try? s.writeCSV(to: url) }
        XCTAssertLessThan(streamed, .seconds(2), "writeCSV took \(streamed)")
        let onDisk = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(onDisk, text, "the streamed file is identical to the in-memory text")
    }

    func testISO8601MillisMatchesFoundation() {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        // Exactly representable fractions so both sides agree on the millisecond.
        let seconds: [TimeInterval] = [0, 1, 86_399, 86_400, 951_782_400 /* 2000-02-29 */, 1_078_012_800,
                                       1_760_000_000, 4_102_444_800 /* 2100-01-01 */, -1, -86_401,
                                       1_709_164_800.5, 1_709_164_800.25, 1_709_164_800.125]
        for s in seconds {
            let d = Date(timeIntervalSince1970: s)
            XCTAssertEqual(ISO8601Millis.string(d), f.string(from: d), "\(s)")
        }
    }
}
