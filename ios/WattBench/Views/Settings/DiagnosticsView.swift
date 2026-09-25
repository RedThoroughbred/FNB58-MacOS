import SwiftUI

/// Connection log, frame counters, journal status, GATT table and raw frames:
/// what you would otherwise need the Xcode console for when testing against
/// the real meter. Pushed from Settings; the zero-argument init is frozen.
struct DiagnosticsView: View {
    @Environment(MeterManager.self) private var meter
    @State private var copied = false

    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        List {
            connectionSection
            framesSection
            recordingSection
            restoreSection
            gattSection
            logSection
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    UIPasteboard.general.string = meter.diagnosticsText
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                }
                ShareLink(item: meter.diagnosticsText) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                Button("Clear log", systemImage: "trash", role: .destructive) { meter.clearLog() }
                    .disabled(meter.log.isEmpty && meter.framesReceived == 0)
            }
        }
    }

    // MARK: Sections

    private var connectionSection: some View {
        Section("Connection") {
            row("State", meter.state.label)
            if let e = meter.lastError {
                row("Last error", e).foregroundStyle(.red)
            }
            row("Connections", "\(meter.connectionEventCount)")
            row("Errors", "\(meter.errorEventCount)")
            row("Auto-connect on launch", meter.autoConnectOnLaunch ? "On" : "Off")
        }
    }

    private var framesSection: some View {
        Section("Frames") {
            row("Received", "\(meter.framesReceived)")
            row("Parsed", "\(meter.framesParsed)")
            row("Rejected", "\(max(0, meter.framesReceived - meter.framesParsed))")
            VStack(alignment: .leading, spacing: 4) {
                Text("Last frame").font(.caption).foregroundStyle(.secondary)
                Text(meter.lastFrameHex.isEmpty ? "—" : meter.lastFrameHex)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
    }

    private var recordingSection: some View {
        Section("Recording and journal") {
            if let rec = meter.recording {
                row("Session", rec.name)
                row("Samples", "\(rec.stats.samples)")
                row("Markers", "\(rec.markers.count)")
                row("Gaps", "\(rec.stats.gapCount)")
                if let j = rec.journal {
                    row("Journal", j.url.lastPathComponent)
                    row("Records", "\(j.recordCount)")
                    row("Bytes written", "\(j.bytesWritten)")
                    row("Last flush", Self.timeFormat.string(from: j.lastFlush))
                    if let e = j.lastError {
                        row("Journal error", e).foregroundStyle(.red)
                    }
                } else {
                    row("Journal", "In memory")
                }
            } else {
                Text("No recording in progress").foregroundStyle(.secondary)
            }
            row("Recording events", "\(meter.recordingEventCount)")
        }
    }

    /// Log lines about CoreBluetooth state restoration (relaunch after the
    /// system suspended the app while connected).
    private var restoreSection: some View {
        Section("State restoration") {
            let lines = meter.log.filter { $0.message.localizedCaseInsensitiveContains("restor") }
            if lines.isEmpty {
                Text("No restoration events this launch").foregroundStyle(.secondary)
            }
            ForEach(lines.suffix(10)) { entry in
                logLine(entry)
            }
        }
    }

    private var gattSection: some View {
        Section("GATT") {
            if meter.discoveredGATT.isEmpty {
                Text("Nothing discovered yet").foregroundStyle(.secondary)
            }
            ForEach(meter.discoveredGATT, id: \.self) { line in
                Text(line).font(.system(.caption, design: .monospaced))
            }
        }
    }

    private var logSection: some View {
        Section("Log (newest first)") {
            if meter.log.isEmpty {
                Text("Log is empty").foregroundStyle(.secondary)
            }
            ForEach(meter.log.reversed()) { entry in
                logLine(entry)
            }
        }
    }

    // MARK: Rows

    private func logLine(_ entry: LogEntry) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(Self.timeFormat.string(from: entry.time))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(entry.message).font(.caption)
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        LabeledContent(title) {
            Text(value)
                .multilineTextAlignment(.trailing)
                .tableValueStyle()
                .textSelection(.enabled)
        }
    }
}

#Preview {
    NavigationStack { DiagnosticsView() }
        .environment(MeterManager())
}
