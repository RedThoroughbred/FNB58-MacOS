import SwiftUI

@main
struct WattBenchApp: App {
    @State private var meter: MeterManager
    @State private var store: SessionStore
    @State private var prefs: Preferences
    @State private var router: AppRouter
    @State private var alerts: AlertCoordinator
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let meter = MeterManager()
        let store = SessionStore()
        let prefs = Preferences.shared
        let router = AppRouter()
        let alerts = AlertCoordinator()

        // Every stop (Stop button, auto-stop rule, notification action) goes
        // through MeterManager.stopRecording, which hands the session here.
        meter.onRecordingStopped = { session, _ in
            do {
                try store.save(session)
            } catch {
                store.saveError = error.localizedDescription
            }
        }
        meter.addObserver(alerts)
        meter.autoConnectOnLaunch = prefs.autoConnect
        meter.excludeDemoFromTrips = prefs.excludeDemoFromTrips
        alerts.onAlert = { meter.addMarker(label: $0.title) }
        alerts.onStopAndSave = { _ = meter.stopRecording() }

        _meter = State(initialValue: meter)
        _store = State(initialValue: store)
        _prefs = State(initialValue: prefs)
        _router = State(initialValue: router)
        _alerts = State(initialValue: alerts)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(meter)
                .environment(store)
                .environment(prefs)
                .environment(router)
                .environment(alerts)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { meter.persistTrips() }
                }
        }
    }
}
