import SwiftUI

@main
struct FNB58MonitorApp: App {
    @State private var meter = MeterManager()
    @State private var store = SessionStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(meter)
                .environment(store)
        }
    }
}
