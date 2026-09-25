import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            LiveView()
                .tabItem { Label("Live", systemImage: "waveform.path.ecg") }
            HistoryView()
                .tabItem { Label("Sessions", systemImage: "clock.arrow.circlepath") }
        }
    }
}

// MARK: - Formatting helpers shared by the views

enum Fmt {
    static func value(_ v: Double?, _ digits: Int = 3) -> String {
        guard let v, v.isFinite else { return "--" }
        return String(format: "%.\(digits)f", v)
    }

    static func duration(_ s: TimeInterval) -> String {
        let t = Int(s.rounded(.down))
        if t >= 3600 { return String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60) }
        return String(format: "%02d:%02d", t / 60, t % 60)
    }

    static func energy(_ wh: Double) -> String {
        wh < 1 ? String(format: "%.1f mWh", wh * 1000) : String(format: "%.3f Wh", wh)
    }

    static func capacity(_ ah: Double) -> String {
        ah < 1 ? String(format: "%.1f mAh", ah * 1000) : String(format: "%.3f Ah", ah)
    }
}
