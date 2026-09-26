import Foundation

/// Moves 1.0 session files (`Documents/sessions/<uuid>.json`, every sample
/// inline) into the per-session folder layout (`<uuid>/manifest.json` plus
/// `samples.wbj`). Pure functions with no shared state, so `SessionStore`
/// can run them synchronously for a handful of files or from a detached task
/// when there are many.
///
/// Losing user data is the one unrecoverable mistake here, so a legacy file
/// is deleted only after the new folder has been read back and verified
/// (record count and manifest identity). Anything that fails verification is
/// kept where it was and still listed from the JSON.
enum LegacyMigration {
    /// More legacy files than this migrate in the background with a progress
    /// row instead of delaying launch.
    static let synchronousLimit = 5

    struct Outcome: Equatable {
        enum Status: Equatable {
            /// Folder written and verified; the legacy file is gone.
            case migrated
            /// The file decodes but could not be migrated; it stays in place
            /// and is served from the JSON.
            case kept(reason: String)
            /// The file is not a session at all; it stays in place, unlisted.
            case unreadable(reason: String)
        }

        let file: URL
        let status: Status
        /// Summary of the decoded session when the file could be read.
        let summary: SessionSummary?

        var isListed: Bool { summary != nil }
    }

    /// Root `<uuid>.json` files inside `directory`, oldest name first
    /// (deterministic order; the store sorts by `startTime` afterwards).
    static func legacyFiles(in directory: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return items
            .filter { $0.pathExtension.lowercased() == "json" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Migrates one legacy file into `directory/<id>/`.
    static func migrate(_ file: URL, in directory: URL) -> Outcome {
        let session: Session
        do {
            let data = try Data(contentsOf: file)
            session = try SessionFolder.decoder().decode(Session.self, from: data)
        } catch {
            return Outcome(file: file, status: .unreadable(reason: error.localizedDescription), summary: nil)
        }
        var summary = session.summary()
        summary.schemaVersion = Session.currentSchema
        summary.sampleCount = session.readings.count
        summary.state = .complete

        let folder = SessionFolder.url(for: session.id, in: directory)
        let fm = FileManager.default
        // Only a folder this call created is ever cleaned up on failure;
        // anything else at that path is not ours to delete.
        var createdFolder = false
        do {
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue {
                // A previous, interrupted attempt: start over from the JSON.
                try fm.removeItem(at: folder)
            }
            try fm.createDirectory(at: folder, withIntermediateDirectories: false)
            createdFolder = true
            try SessionFolder.writeManifest(summary, in: folder)
            try SessionFolder.writeSamples(session.readings, startEpoch: session.startTime, in: folder)
        } catch {
            if createdFolder { try? fm.removeItem(at: folder) }
            return Outcome(file: file, status: .kept(reason: error.localizedDescription), summary: summary)
        }

        // Verify before deleting the original.
        let written = RecordingJournal.count(url: SessionFolder.samplesURL(in: folder))
        guard written == session.readings.count else {
            try? fm.removeItem(at: folder)
            return Outcome(file: file,
                           status: .kept(reason: "wrote \(written) of \(session.readings.count) samples"),
                           summary: summary)
        }
        guard let back = try? SessionFolder.readManifest(in: folder), back.id == session.id,
              back.sampleCount == summary.sampleCount else {
            try? fm.removeItem(at: folder)
            return Outcome(file: file, status: .kept(reason: "manifest did not read back"), summary: summary)
        }
        do {
            try fm.removeItem(at: file)
        } catch {
            // The folder is good; the stale JSON just lingers until it can be
            // removed. Report it so it is not silently ignored.
            return Outcome(file: file, status: .kept(reason: "could not delete legacy file: \(error.localizedDescription)"),
                           summary: back)
        }
        return Outcome(file: file, status: .migrated, summary: back)
    }
}
