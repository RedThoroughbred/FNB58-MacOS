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
        // The store first: its load seals any recording that was interrupted
        // by a crash or force-quit (offered below, never resumed), and the
        // meter journals new recordings into the same folder.
        let store = SessionStore()
        let meter = MeterManager(sessionsDirectory: store.directory)
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
                // Single presenter of the recovery prompt (the Sessions list
                // only shows a passive "Recovered" badge).
                .sheet(item: interruptedRecording) { summary in
                    RecoverySheet(summary: summary)
                        .environment(store)
                        .environment(prefs)
                }
                // `initial: true` matters for a relaunch by CoreBluetooth
                // state restoration, which starts in the background.
                .onChange(of: scenePhase, initial: true) { _, phase in
                    meter.scene = Self.presence(of: phase)
                }
                .onChange(of: prefs.excludeDemoFromTrips) { _, on in
                    meter.excludeDemoFromTrips = on
                }
                .onChange(of: prefs.autoConnect) { _, on in
                    meter.autoConnectOnLaunch = on
                }
        }
    }

    /// The sheet is dismissed only by Keep or Discard, both of which clear
    /// `store.interrupted`; setting the binding to nil is therefore a no-op.
    private var interruptedRecording: Binding<SessionSummary?> {
        Binding(get: { store.interrupted }, set: { _ in })
    }

    private static func presence(of phase: ScenePhase) -> MeterManager.ScenePresence {
        switch phase {
        case .active: return .active
        case .inactive: return .inactive
        case .background: return .background
        @unknown default: return .active
        }
    }
}
