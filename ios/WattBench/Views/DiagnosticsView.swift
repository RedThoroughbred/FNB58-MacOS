import SwiftUI

/// Connection log, GATT table and raw frames - what you'd otherwise need the
/// Xcode console for when testing against the real meter.
struct DiagnosticsView: View {
    @Environment(MeterManager.self) private var meter
    @Environment(\.dismiss) private var dismiss
    @State private var showShare = false
    @State private var copied = false

    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        NavigationStack {
            List {
                Section("Connection") {
                    row("State", meter.state.label)
                    if let e = meter.lastError {
                        row("Last error", e).foregroundStyle(.red)
                    }
                }
                Section("Frames") {
                    row("Received", "\(meter.framesReceived)")
                    row("Parsed", "\(meter.framesParsed)")
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Last frame").font(.caption).foregroundStyle(.secondary)
                        Text(meter.lastFrameHex.isEmpty ? "—" : meter.lastFrameHex)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                Section("GATT") {
                    if meter.discoveredGATT.isEmpty {
                        Text("Nothing discovered yet").foregroundStyle(.secondary)
                    }
                    ForEach(meter.discoveredGATT, id: \.self) { line in
                        Text(line).font(.system(.caption, design: .monospaced))
                    }
                }
                Section {
                    ForEach(meter.log.reversed()) { entry in
                        HStack(alignment: .top, spacing: 8) {
                            Text(Self.timeFormat.string(from: entry.time))
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Text(entry.message).font(.caption)
                        }
                    }
                } header: {
                    HStack {
                        Text("Log (newest first)")
                        Spacer()
                        Button("Clear") { meter.clearLog() }.font(.caption)
                    }
                }
            }
            .navigationTitle("Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                        UIPasteboard.general.string = meter.diagnosticsText
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    }
                    Button("Share", systemImage: "square.and.arrow.up") { showShare = true }
                }
            }
            .sheet(isPresented: $showShare) {
                ShareSheet(items: [meter.diagnosticsText])
            }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
    }
}
