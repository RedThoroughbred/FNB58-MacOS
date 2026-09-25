import SwiftUI

/// The Live tab before a meter is connected: one primary action per state.
struct LiveEmptyState: View {
    let state: ConnectionState
    let onConnect: () -> Void
    let onDemo: () -> Void

    @Environment(\.openURL) private var openURL

    var body: some View {
        ContentUnavailableView {
            if state.isTransient {
                ProgressView()
                    .controlSize(.large)
                    .padding(.bottom, 8)
                Text(title)
                    .font(.title2.weight(.bold))
            } else {
                Label(title, systemImage: symbol)
            }
        } description: {
            Text(description)
        } actions: {
            HStack(spacing: 12) {
                if state == .unauthorized {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Connect", action: onConnect)
                        .buttonStyle(.borderedProminent)
                }
                Button("Try Demo Data", action: onDemo)
                    .buttonStyle(.bordered)
            }
            .controlSize(.large)
        }
    }

    private var title: String {
        switch state {
        case .bluetoothOff: return "Bluetooth Is Off"
        case .unauthorized: return "Bluetooth Access Needed"
        case .scanning: return "Looking for Meters"
        case .connecting(let name): return "Connecting to \(name)"
        default: return "No Meter Connected"
        }
    }

    private var symbol: String {
        switch state {
        case .bluetoothOff: return "antenna.radiowaves.left.and.right.slash"
        case .unauthorized: return "exclamationmark.triangle"
        default: return "powermeter"
        }
    }

    private var description: String {
        switch state {
        case .bluetoothOff:
            return "Turn on Bluetooth in Control Center or Settings, then connect to the FNB58."
        case .unauthorized:
            return "Allow Bluetooth for WattBench in Settings so it can find the FNB58."
        case .scanning, .connecting:
            return "Keep the meter powered on and within a few metres."
        default:
            return "Turn on Bluetooth in the FNB58's settings menu, then connect."
        }
    }
}
