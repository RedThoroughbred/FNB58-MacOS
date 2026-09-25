import SwiftUI

struct ContentView: View {
    @Environment(AppRouter.self) private var router

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.tab) {
            LiveView()
                .tabItem { Label("Live", systemImage: "waveform.path.ecg") }
                .tag(AppRouter.Tab.live)
            HistoryView()
                .tabItem { Label("Sessions", systemImage: "clock.arrow.circlepath") }
                .tag(AppRouter.Tab.sessions)
        }
    }
}

// MARK: - Legacy formatting shim

/// Deprecated: the 1.0 views' helpers, now forwarding to `MetricFormatter`.
/// New code uses `MetricFormatter` (via `Preferences.formatter`) directly.
/// Deleted in the post-merge cleanup once no callers remain.
