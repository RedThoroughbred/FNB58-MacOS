import Combine
import SwiftUI

/// App shell: the two tabs, keep-awake, and the preferences that have to be
/// mirrored into `MeterManager` (auto-connect, demo exclusion) plus Home
/// Screen quick actions.
struct ContentView: View {
    @Environment(AppRouter.self) private var router
    @Environment(MeterManager.self) private var meter
    @Environment(SessionStore.self) private var store
    @Environment(Preferences.self) private var prefs
    @Environment(\.scenePhase) private var scenePhase

    @State private var lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled

    private let powerStateChanged = NotificationCenter.default
        .publisher(for: .NSProcessInfoPowerStateDidChange)
        .receive(on: DispatchQueue.main)

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.tab) {
            LiveView()
                .tabItem { Label("Live", systemImage: "waveform.path.ecg") }
                .tag(AppRouter.Tab.live)
            SessionsListView()
                .tabItem { Label("Sessions", systemImage: "clock.arrow.circlepath") }
                .tag(AppRouter.Tab.sessions)
        }
        // Haptics attach once, here at the root, so they fire exactly once
        // per connect/error, record start/stop and save regardless of which
        // tab or sheet is on screen. Subviews must not attach these again.
        .connectionFeedback(meter)
        .recordingFeedback(meter)
        .saveFeedback(store)
        // Keep-awake: recomputed whenever any input changes and reset to
        // false the moment the app leaves the foreground or the meter drops.
        .onChange(of: keepAwakeWanted, initial: true) { _, wanted in
            UIApplication.shared.isIdleTimerDisabled = wanted
        }
        .onReceive(powerStateChanged) { _ in
            lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
        // Preferences that MeterManager needs at runtime.
        .onChange(of: prefs.autoConnect, initial: true) { _, on in
            meter.autoConnectOnLaunch = on
        }
        .onChange(of: prefs.excludeDemoFromTrips, initial: true) { _, on in
            meter.excludeDemoFromTrips = on
        }
        .onChange(of: router.pendingQuickAction, initial: true) { _, action in
            handle(quickAction: action)
        }
    }

    private var keepAwakeWanted: Bool {
        Preferences.shouldKeepAwake(keepAwake: prefs.keepAwake,
                                    isConnected: meter.state.isConnected,
                                    isActive: scenePhase == .active,
                                    lowPowerMode: lowPowerMode)
    }

    /// Quick actions land on the Live tab. Connecting is done here; starting
    /// a recording is left pending for the Record bar to pick up.
    private func handle(quickAction action: AppRouter.QuickAction?) {
        guard let action else { return }
        router.tab = .live
        switch action {
        case .connectLastMeter:
            router.takeQuickAction(.connectLastMeter)
            meter.reconnectLastDevice()
        case .startRecording:
            break
        }
    }
}
