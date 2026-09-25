import SwiftUI

@main
struct WattBenchApp: App {
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
