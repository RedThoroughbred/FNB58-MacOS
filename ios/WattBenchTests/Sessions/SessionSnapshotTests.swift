import SwiftUI
import XCTest
@testable import WattBench

/// Renders the Sessions screens to PNG files for visual review on a Mac
/// without Simulator.app (headless CoreSimulator only). Skipped unless the
/// test runner environment sets `WATTBENCH_SNAPSHOTS=1`; `WATTBENCH_SEED_DIR`
/// points at a folder of `<uuid>.json` sessions and `WATTBENCH_SNAPSHOT_DIR`
/// receives the images (default /tmp).
///
///     TEST_RUNNER_WATTBENCH_SNAPSHOTS=1 TEST_RUNNER_WATTBENCH_SEED_DIR=... \
///     xcodebuild test ... -only-testing:WattBenchTests/SessionSnapshotTests
@MainActor
final class SessionSnapshotTests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private var outputDir: URL { URL(fileURLWithPath: env["WATTBENCH_SNAPSHOT_DIR"] ?? "/tmp") }

    private var window: UIWindow?
    private var store: SessionStore?
    private var router: AppRouter?

    override func setUpWithError() throws {
        try XCTSkipUnless(env["WATTBENCH_SNAPSHOTS"] == "1", "snapshot rendering is opt-in")
        let seed = try XCTUnwrap(env["WATTBENCH_SEED_DIR"], "WATTBENCH_SEED_DIR must point at seeded sessions")
        store = SessionStore(directory: URL(fileURLWithPath: seed, isDirectory: true))
        router = AppRouter()
    }

    override func tearDown() {
        window?.isHidden = true
        window = nil
    }

    // MARK: - Scenes

    func testRenderSessionsList() throws {
        let store = try XCTUnwrap(store)
        XCTAssertFalse(store.summaries.isEmpty, "seed directory holds no sessions")
        mount(SessionsListView())
        pump(1.5)
        snapshot("list-light")
        setDark(true)
        snapshot("list-dark")
    }

    func testRenderSessionsEmpty() throws {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("wb-empty-\(UUID().uuidString)")
        store = SessionStore(directory: empty)
        mount(SessionsListView())
        pump(1)
        snapshot("empty-light")
        setDark(true)
        snapshot("empty-dark")
    }

    func testRenderSessionDetail() throws {
        let store = try XCTUnwrap(store)
        let router = try XCTUnwrap(router)
        let anker = try XCTUnwrap(store.summaries.first { $0.name.hasPrefix("Anker") })
        mount(SessionsListView())
        pump(0.5)
        router.sessionPath = [anker.id]
        pump(3)   // samples load off the main actor, then decimate
        snapshot("detail-top-light")
        scroll(to: 560)
        snapshot("detail-chart-light")
        scroll(to: 1150)
        snapshot("detail-markers-light")
        scroll(to: 1900)
        snapshot("detail-bottom-light")
        setDark(true)
        scroll(to: 0)
        snapshot("detail-top-dark")
        scroll(to: 560)
        snapshot("detail-chart-dark")
        scroll(to: 1150)
        snapshot("detail-markers-dark")
    }

    func testRenderSessionDetailSmallSession() throws {
        let store = try XCTUnwrap(store)
        let router = try XCTUnwrap(router)
        let sleep = try XCTUnwrap(store.summaries.first { $0.name.hasPrefix("Sleep") })
        mount(SessionsListView())
        pump(0.5)
        router.sessionPath = [sleep.id]
        pump(2)
        snapshot("detail-small-light")
    }

    // Synchronous on purpose: an async test body runs as a main-queue job, and
    // a nested run loop cannot drain further main-queue jobs from inside one,
    // so the model's decimation task would never deliver.
    func testRenderChartInteractions() throws {
        let store = try XCTUnwrap(store)
        let anker = try XCTUnwrap(store.summaries.first { $0.name.hasPrefix("Anker") })
        var loaded: Session?
        Task { loaded = try? await store.session(for: anker.id) }
        let deadline = Date().addingTimeInterval(10)
        while loaded == nil, Date() < deadline { pump(0.1) }
        let session = try XCTUnwrap(loaded)
        let model = SessionChartModel(start: session.startTime, end: session.endTime, markers: session.markers)
        model.setReadings(session.readings)
        model.metric = .current
        let mid = session.startTime.addingTimeInterval(session.duration * 0.42)
        model.cursor = mid
        let range = session.startTime.addingTimeInterval(session.duration * 0.55)...session.startTime.addingTimeInterval(session.duration * 0.75)
        model.range = range
        let stats = RangeStats.stats(session.readings[model.indexRange(for: range)])
        let view = VStack(spacing: 12) {
            SessionChart(model: model, placeholder: anker.sparkline)
            RangeStatsCard(range: range, stats: stats, sessionStart: session.startTime,
                           sessionEnergyWh: session.stats.energyWh, onSaveMarkers: {}, onClose: {})
            SessionPreviewCard(summary: anker)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(.systemGroupedBackground))
        mount(view)
        pump(1.5)
        snapshot("chart-cursor-range-light")
        // `drawHierarchy` cannot capture materials faithfully; with
        // WATTBENCH_HOLD=1 the view stays on screen so the device screen can
        // be captured with `xcrun simctl io <udid> screenshot` meanwhile.
        if env["WATTBENCH_HOLD"] == "1" { pump(12) }
        model.select(span: .minute)
        model.reveal(mid)
        pump(1)
        snapshot("chart-zoomed-light")
        setDark(true)
        snapshot("chart-zoomed-dark")
    }

    // MARK: - Harness

    private func mount<V: View>(_ view: V) {
        guard let store, let router else { return }
        let meter = MeterManager()
        let root = view
            .environment(meter)
            .environment(store)
            .environment(Preferences.shared)
            .environment(router)
            .environment(AlertCoordinator())
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let bounds = scene?.screen.bounds ?? CGRect(x: 0, y: 0, width: 402, height: 874)
        let w = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: bounds)
        w.frame = bounds
        w.rootViewController = UIHostingController(rootView: root)
        w.windowLevel = .alert + 1
        w.overrideUserInterfaceStyle = .light
        w.makeKeyAndVisible()
        window = w
        pump(0.3)
    }

    private func setDark(_ dark: Bool) {
        window?.overrideUserInterfaceStyle = dark ? .dark : .light
        pump(1)
    }

    private func scroll(to y: CGFloat) {
        guard let window, let scrollView = firstScrollView(in: window) else { return }
        let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom)
        scrollView.setContentOffset(CGPoint(x: 0, y: min(y, maxY) - scrollView.adjustedContentInset.top), animated: false)
        pump(0.8)
    }

    private func firstScrollView(in view: UIView) -> UIScrollView? {
        var best: UIScrollView?
        for sub in view.subviews {
            if let s = sub as? UIScrollView, s.bounds.height > 300, s.contentSize.height > s.bounds.height {
                if best == nil || s.bounds.height > (best?.bounds.height ?? 0) { best = s }
            }
            if let deeper = firstScrollView(in: sub) {
                if best == nil || deeper.bounds.height > (best?.bounds.height ?? 0) { best = deeper }
            }
        }
        return best
    }

    /// Runs the main run loop so SwiftUI, Observation and detached tasks
    /// make progress.
    private func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func snapshot(_ name: String) {
        guard let window else { return XCTFail("no window") }
        let format = UIGraphicsImageRendererFormat()
        format.scale = window.screen.scale
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        guard let data = image.pngData() else { return XCTFail("no png") }
        let url = outputDir.appendingPathComponent("ws-C-\(name).png")
        do {
            try data.write(to: url)
        } catch {
            XCTFail("could not write \(url.path): \(error)")
        }
    }
}
