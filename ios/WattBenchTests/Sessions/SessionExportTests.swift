import XCTest
@testable import WattBench

/// Records which session ids a loader was asked for (the loader closure is
/// `@Sendable`, so it cannot mutate a captured array directly).
private actor LoadLog {
    var ids: [UUID] = []
    func record(_ id: UUID) { ids.append(id) }
}

final class SessionExportTests: XCTestCase {
    private typealias S = SessionTestSupport
    private let posix = Locale(identifier: "en_US_POSIX")

    func testCSVFileHasCSVExtensionAndHeader() async throws {
        let readings = S.readings(count: 25, voltage: { _ in 9 }, current: { _ in 1.5 })
        let marker = Marker(timestamp: readings[3].timestamp, label: "Plugged in")
        let session = S.session(readings: readings, name: "Anker 65W / test #1", markers: [marker])
        let loads = LoadLog()
        let export = SessionExport(summary: session.summary()) { id in
            await loads.record(id)
            return session
        }

        let url = try await export.writeCSV()
        let loadedIDs = await loads.ids
        XCTAssertEqual(loadedIDs, [session.id], "samples are loaded on demand, once")
        XCTAssertEqual(url.pathExtension, "csv")
        XCTAssertTrue(url.path.hasPrefix(FileManager.default.temporaryDirectory.path), "exports live in tmp: \(url.path)")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "exports")
        XCTAssertFalse(url.lastPathComponent.contains("/"))
        XCTAssertTrue(url.lastPathComponent.hasPrefix("Anker_65W_test_1_"))

        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(separator: "\n")
        XCTAssertEqual(lines.first, "timestamp,voltage_v,current_a,power_w,elapsed_s,marker_label")
        XCTAssertEqual(lines.count, 26)
        XCTAssertTrue(lines[4].hasSuffix(",Plugged in"), "\(lines[4])")
        XCTAssertTrue(lines[1].contains(",9.0,1.5,13.5,"), "\(lines[1])")
        try? FileManager.default.removeItem(at: url)

        // A blank name still produces a usable file name.
        XCTAssertEqual(SessionExport.fileName(name: "  ", id: session.id), "session_\(session.id.uuidString.prefix(8)).csv")
    }

    func testSummaryTextUsesMetricFormatter() {
        let summary = S.summary(name: "Anker 65W", start: S.t0, durationS: 6_120, energyWh: 27.4123, maxPower: 61.3456)
        let export = SessionExport(summary: summary, formatter: MetricFormatter(locale: posix, precision: 3)) { _ in
            throw SessionStore.StoreError.notFound
        }
        let text = export.summaryText
        XCTAssertTrue(text.hasPrefix("Anker 65W · "), text)
        XCTAssertTrue(text.contains(" · 27.4 Wh · "), text)
        XCTAssertTrue(text.hasSuffix(" · peak 61.3 W"), text)
        XCTAssertTrue(text.contains("42"), "minutes come from the duration formatter: \(text)")
        XCTAssertEqual(text.components(separatedBy: " · ").count, 4)

        // Precision and locale follow the formatter, never String(format:).
        let de = SessionExport(summary: summary, formatter: MetricFormatter(locale: Locale(identifier: "de_DE"), precision: 4)) { _ in
            throw SessionStore.StoreError.notFound
        }
        XCTAssertTrue(de.summaryText.contains("27,41 Wh"), de.summaryText)

        // Small sessions auto-range to milli units.
        let small = S.summary(name: "Sleep current", start: S.t0, durationS: 45, energyWh: 0.0123, maxPower: 0.35)
        let smallText = SessionExport(summary: small, formatter: MetricFormatter(locale: posix, precision: 3)) { _ in
            throw SessionStore.StoreError.notFound
        }.summaryText
        XCTAssertTrue(smallText.contains("12.3 mWh"), smallText)
        XCTAssertTrue(smallText.hasSuffix("peak 350 mW"), smallText)

        let f = MetricFormatter(locale: posix)
        XCTAssertEqual(f.compactDuration(-1), "--")
        XCTAssertTrue(f.compactDuration(45).contains("45"))
        XCTAssertTrue(f.compactDuration(6_120).contains("1"))
        XCTAssertTrue(f.compactDuration(6_120).contains("42"))
    }
}
