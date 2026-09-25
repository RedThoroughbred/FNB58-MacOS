import SwiftUI

/// Settings sheet root (WS-D fills it in). The zero-argument init is frozen.
struct SettingsView: View {
    var body: some View {
        NavigationStack {
            if ProcessInfo.processInfo.arguments.contains("-wse-alerts") { AlertsSettingsView() } else {  // TEMP-WSE-SCREENSHOT
            Form {
                NavigationLink("Diagnostics") { DiagnosticsView() }
                NavigationLink("Alerts") { AlertsSettingsView() }  // TEMP-WSE-SCREENSHOT
            }
            .navigationTitle("Settings")
            }  // TEMP-WSE-SCREENSHOT
        }
    }
}
