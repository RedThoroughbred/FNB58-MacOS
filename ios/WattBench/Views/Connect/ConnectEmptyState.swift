import SwiftUI

/// One `ContentUnavailableView` per situation the Connect sheet can be in,
/// each with the action that gets the user out of it.
struct ConnectEmptyState: View {
    enum Kind: Equatable {
        case bluetoothOff
        case unauthorized
        case idle
        case scanning
        case nothingFound
        case reconnecting(name: String, since: Date)
        case unreachable(String)
    }

    let state: Kind
    /// Scan / Scan again / Retry / Open Settings, depending on `state`.
    var primaryAction: () -> Void = {}
    /// Try demo data / Scan instead / Stop trying, depending on `state`.
    var secondaryAction: () -> Void = {}

    @Environment(\.openURL) private var openURL

    var body: some View {
        ContentUnavailableView {
            label
        } description: {
            Text(description)
        } actions: {
            actions
        }
        .symbolRenderingMode(.hierarchical)
    }

    // MARK: Pieces

    @ViewBuilder
    private var label: some View {
        switch state {
        case .bluetoothOff:
            Label("Bluetooth Is Off", systemImage: "antenna.radiowaves.left.and.right.slash")
        case .unauthorized:
            Label("Bluetooth Access Needed", systemImage: "lock.shield")
        case .idle:
            Label("Not Scanning", systemImage: "antenna.radiowaves.left.and.right")
        case .scanning:
            Label {
                Text("Looking for FNB58…")
            } icon: {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .symbolEffectRespectingMotion(.variableColor.iterative)
            }
        case .nothingFound:
            Label("No Meter Found", systemImage: "powermeter")
        case .reconnecting(let name, _):
            Label {
                Text("Reconnecting to \(name)…")
            } icon: {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .symbolEffectRespectingMotion(.variableColor.iterative)
            }
        case .unreachable(let name):
            Label("\(name) Is Unreachable", systemImage: "exclamationmark.triangle")
        }
    }

    private var description: String {
        switch state {
        case .bluetoothOff:
            return "Turn on Bluetooth in Control Centre or in Settings to find your meter."
        case .unauthorized:
            return "Allow Bluetooth for WattBench in Settings. It is only used to talk to the meter."
        case .idle:
            return "Tap Scan to look for nearby meters."
        case .scanning:
            return "Turn the meter on and enable Bluetooth in its settings menu."
        case .nothingFound:
            return "Enable Bluetooth in the meter's settings menu and keep it within a few metres. Only devices named FNB58 are listed unless Show all Bluetooth devices is on."
        case .reconnecting:
            return "The meter dropped out. WattBench connects again as soon as it is back in range or powered on."
        case .unreachable:
            return "Power the meter on and keep it within a few metres, then retry."
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch state {
        case .bluetoothOff, .unauthorized:
            Button("Open Settings") { openSettings() }
                .buttonStyle(.borderedProminent)
        case .idle:
            Button("Scan", action: primaryAction)
                .buttonStyle(.borderedProminent)
        case .scanning:
            ProgressView()
                .padding(.top, 4)
        case .nothingFound:
            VStack(spacing: 8) {
                Button("Scan Again", action: primaryAction)
                    .buttonStyle(.borderedProminent)
                Button("Try Demo Data", action: secondaryAction)
                    .tint(.demo)
            }
        case .reconnecting(_, let since):
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Gives up in ")
                        + Text(timerInterval: since...since.addingTimeInterval(ReconnectPolicy.giveUpAfter),
                               countsDown: true)
                }
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
                Button("Retry Now", action: primaryAction)
                    .buttonStyle(.borderedProminent)
                Button("Stop Trying", role: .destructive, action: secondaryAction)
            }
        case .unreachable:
            VStack(spacing: 8) {
                Button("Retry", action: primaryAction)
                    .buttonStyle(.borderedProminent)
                Button("Scan Instead", action: secondaryAction)
            }
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }
}

#Preview("Nothing found") {
    ConnectEmptyState(state: .nothingFound)
}

#Preview("Reconnecting") {
    ConnectEmptyState(state: .reconnecting(name: "FNB58", since: Date()))
}
