import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// What `ShareLink` shares for a session: a CSV file (samples loaded on
/// demand through `loader`, so the list never preloads samples) with a
/// one-line text summary as the lightweight representation.
struct SessionExport: Transferable, Sendable {
    let summary: SessionSummary
    let loader: @Sendable (UUID) async throws -> Session
    var formatter: MetricFormatter

    init(summary: SessionSummary,
         formatter: MetricFormatter = MetricFormatter(),
         loader: @escaping @Sendable (UUID) async throws -> Session) {
        self.summary = summary
        self.formatter = formatter
        self.loader = loader
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .commaSeparatedText) { export in
            SentTransferredFile(try await export.writeCSV())
        }
        ProxyRepresentation(exporting: \.summaryText)
    }

    /// "Anker 65W · 27.4 Wh · 1h 42m · peak 61.3 W"
    var summaryText: String {
        Self.summaryText(for: summary, formatter: formatter)
    }

    static func summaryText(for s: SessionSummary, formatter: MetricFormatter) -> String {
        [s.name,
         formatter.energy(s.stats.energyWh).text,
         formatter.compactDuration(s.stats.durationS),
         "peak " + formatter.format(s.stats.maxPower, .power).text]
            .joined(separator: " · ")
    }

    /// Temporary folder for shared files; never inside Documents.
    static var exportsDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("exports", isDirectory: true)
    }

    /// Loads the full session and writes its CSV into `directory`.
    func writeCSV(to directory: URL = SessionExport.exportsDirectory) async throws -> URL {
        let session = try await loader(summary.id)
        return try Self.writeCSV(session, to: directory)
    }

    /// Writes `session.csv()` as `<name>_<id>.csv` in `directory`.
    static func writeCSV(_ session: Session, to directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(fileName(name: session.name, id: session.id))
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try session.csv().write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw SessionStore.StoreError.io(error.localizedDescription)
        }
        return url
    }

    static func fileName(name: String, id: UUID) -> String {
        let safe = name.replacingOccurrences(of: "[^A-Za-z0-9_-]+", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        let base = safe.isEmpty ? "session" : safe
        return "\(base)_\(id.uuidString.prefix(8)).csv"
    }
}

extension MetricFormatter {
    /// "1h 42m" style duration for summaries and share previews (hours and
    /// minutes above a minute, seconds below).
    func compactDuration(_ s: TimeInterval) -> String {
        guard s.isFinite, s >= 0 else { return Self.placeholder }
        let d = Duration.seconds(s.rounded(.down))
        if s < 60 {
            return d.formatted(.units(allowed: [.seconds], width: .narrow).locale(locale))
        }
        return d.formatted(.units(allowed: [.hours, .minutes], width: .narrow, maximumUnitCount: 2).locale(locale))
    }
}
