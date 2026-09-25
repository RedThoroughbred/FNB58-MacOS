import SwiftUI

/// Settings sheet root (WS-D fills it in). The zero-argument init is frozen.
struct SettingsView: View {
    var body: some View {
        NavigationStack {
            Form {
                NavigationLink("Diagnostics") { DiagnosticsView() }
            }
            .navigationTitle("Settings")
        }
    }
}
