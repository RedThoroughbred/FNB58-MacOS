import Foundation

/// Append-only binary sample file (`samples.wbj`).
///
/// Header (16 bytes, little endian): magic `"WBJ1"`, `UInt32 version = 1`,
/// `Float64 startEpoch` (wall-clock seconds since 1970 at the start of the
/// recording). Records (16 bytes each): `UInt32 t_ms` milliseconds since the
/// recording's MONOTONIC start, then `Float v`, `Float i`, `Float w`. The time
/// base is monotonic so a wall-clock jump mid-recording can never reorder or
/// wrap the offsets; on read `timestamp = startEpoch + t_ms/1000` and
/// `monotonic = t_ms/1000`. Values are restored at the meter's native
/// 1/10000 resolution (`quantise`), which a `Float` carries exactly for
/// anything below 1000 units, so meter readings round-trip bit for bit. A
/// trailing partial record is ignored.
///
/// Threading: `append` runs on the caller's thread (the main actor) and only
/// touches an in-memory buffer. Every `flushInterval` seconds or `flushEvery`
/// records the buffer is handed to a serial utility queue that writes it with
/// `FileHandle.write`; `synchronize()` (fsync) is requested every
/// `syncInterval` seconds and by the recorder on a gap, on backgrounding and
/// on stop, so at most `syncInterval` seconds of samples are at risk in a
/// power loss and at most `flushInterval` seconds in a crash. `close()` and
/// `waitForWrites()` drain the queue synchronously.
final class RecordingJournal: @unchecked Sendable {
    static let magic: [UInt8] = Array("WBJ1".utf8)
    static let version: UInt32 = 1
    static let headerSize = 16
    static let recordSize = 16
    /// Default fsync cadence.
    static let defaultSyncInterval: TimeInterval = 10

    enum JournalError: LocalizedError {
        case cannotCreate(String)
        case badHeader
        case io(String)

        var errorDescription: String? {
            switch self {
            case .cannotCreate(let p): return "Could not create journal at \(p)"
            case .badHeader: return "Not a WattBench journal"
            case .io(let m): return m
            }
        }
    }

    let url: URL
    let startEpoch: Date
    /// Monotonic seconds (`MonotonicClock` base) that correspond to `startEpoch`.
    let monotonicStart: TimeInterval

    /// Records appended so far (buffered or written).
    private(set) var recordCount = 0

    /// Bytes on disk (header included) as of the last completed write.
    var bytesWritten: Int { writer.stats.withLock { $0.bytesWritten } }
    /// When the last write to the file completed.
    var lastFlush: Date { writer.stats.withLock { $0.lastFlush } }
    /// When the last fsync completed.
    var lastSync: Date { writer.stats.withLock { $0.lastSync } }
    /// The most recent I/O error, if any.
    var lastError: String? { writer.stats.withLock { $0.lastError } }

    fileprivate struct Stats {
        var bytesWritten: Int
        var lastFlush: Date
        var lastSync: Date
        var lastError: String?
    }

    /// Owns the file handle. Only the writer queue (and `close`, which drains
    /// it) touches the file; queued blocks capture the writer, never the
    /// journal, so the journal can never be deallocated on its own queue.
    private final class Writer: @unchecked Sendable {
        let handle: FileHandle
        let stats: Locked<Stats>

        init(handle: FileHandle, stats: Locked<Stats>) {
            self.handle = handle
            self.stats = stats
        }

        func write(_ chunk: Data) {
            do {
                try handle.write(contentsOf: chunk)
                stats.withLock {
                    $0.bytesWritten += chunk.count
                    $0.lastFlush = Date()
                }
            } catch {
                stats.withLock { $0.lastError = error.localizedDescription }
            }
        }

        func sync() {
            do {
                try handle.synchronize()
                stats.withLock { $0.lastSync = Date() }
            } catch {
                stats.withLock { $0.lastError = error.localizedDescription }
            }
        }

        func close() {
            do { try handle.close() } catch { stats.withLock { $0.lastError = error.localizedDescription } }
        }
    }

    private let writer: Writer
    private let queue = DispatchQueue(label: "wattbench.journal", qos: .utility)
    private let flushInterval: TimeInterval
    private let flushEvery: Int
    private let syncInterval: TimeInterval
    /// Clock for the flush and sync cadence (injectable for tests).
    private let now: () -> Date

    // Main-actor side (touched only by the appending thread).
    private var buffer = Data()
    private var pending = 0
    private var lastFlushRequest: Date
    private var lastSyncRequest: Date
    private var isClosed = false

    /// Creates the file (replacing any existing one) with
    /// `.completeUntilFirstUserAuthentication` protection so background
    /// recording keeps writing while the phone is locked, and writes the
    /// header. `monotonicStart` defaults to now; pass the value captured at
    /// the same instant as `startEpoch` when they were taken separately.
    /// `now` is injectable so tests can drive the flush and sync timers.
    init(url: URL, startEpoch: Date, flushInterval: TimeInterval = 1, flushEvery: Int = 64,
         monotonicStart: TimeInterval? = nil, syncInterval: TimeInterval = RecordingJournal.defaultSyncInterval,
         now: @escaping () -> Date = Date.init) throws {
        self.url = url
        self.startEpoch = startEpoch
        self.monotonicStart = monotonicStart ?? MonotonicClock.now
        self.flushInterval = flushInterval
        self.flushEvery = max(1, flushEvery)
        self.syncInterval = syncInterval
        self.now = now
        let start = now()
        self.lastFlushRequest = start
        self.lastSyncRequest = start

        let header = Self.header(startEpoch: startEpoch)
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let attributes: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        if !fm.createFile(atPath: url.path, contents: header, attributes: attributes) {
            // Some file systems (the Simulator's host volume) reject the
            // protection attribute; the journal itself still matters more.
            guard fm.createFile(atPath: url.path, contents: header, attributes: nil) else {
                throw JournalError.cannotCreate(url.path)
            }
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
        } catch {
            throw JournalError.io(error.localizedDescription)
        }
        writer = Writer(handle: handle,
                        stats: Locked(Stats(bytesWritten: Self.headerSize, lastFlush: start, lastSync: start, lastError: nil)))
    }

    deinit {
        if !isClosed {
            let chunk = buffer
            let writer = self.writer
            queue.sync {
                if !chunk.isEmpty { writer.write(chunk) }
                writer.sync()
                writer.close()
            }
        }
    }

    // MARK: - Writing

    /// Buffers one record. Readings with a monotonic stamp are placed by it;
    /// readings without one (tests, replays) fall back to their wall time.
    func append(_ r: Reading) {
        guard !isClosed else { return }
        let seconds: TimeInterval
        if r.monotonic > 0 {
            seconds = r.monotonic - monotonicStart
        } else {
            seconds = r.timestamp.timeIntervalSince(startEpoch)
        }
        Self.appendRecord(&buffer, seconds: seconds, r)
        recordCount += 1
        pending += 1
        let t = now()
        if pending >= flushEvery || t.timeIntervalSince(lastFlushRequest) >= flushInterval {
            flush()
        }
        if t.timeIntervalSince(lastSyncRequest) >= syncInterval {
            synchronize()
        }
    }

    /// Hands buffered records to the writer queue (no fsync). Returns at once.
    func flush() {
        guard !isClosed else { return }
        lastFlushRequest = now()
        guard !buffer.isEmpty else { return }
        let chunk = buffer
        buffer.removeAll(keepingCapacity: true)
        pending = 0
        let writer = self.writer
        queue.async { writer.write(chunk) }
    }

    /// Flushes and asks the OS to commit the file to storage (on the queue).
    func synchronize() {
        guard !isClosed else { return }
        flush()
        lastSyncRequest = now()
        let writer = self.writer
        queue.async { writer.sync() }
    }

    /// Flushes, synchronizes and closes the file, waiting for the writes to
    /// finish. Further appends are ignored.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        let chunk = buffer
        buffer.removeAll()
        pending = 0
        let writer = self.writer
        queue.sync {
            if !chunk.isEmpty { writer.write(chunk) }
            writer.sync()
            writer.close()
        }
    }

    /// Blocks until every write requested so far has reached the file
    /// (tests and diagnostics; the app never needs it).
    func waitForWrites() {
        queue.sync {}
    }

    // MARK: - Format

    private static func header(startEpoch: Date) -> Data {
        var header = Data(capacity: headerSize)
        header.append(contentsOf: magic)
        header.append(le: version)
        header.append(le: startEpoch.timeIntervalSince1970.bitPattern)
        return header
    }

    private static func appendRecord(_ data: inout Data, seconds: TimeInterval, _ r: Reading) {
        let ms = UInt32(clamping: Int64((max(0, seconds) * 1000).rounded()))
        data.append(le: ms)
        data.append(le: Float(r.voltage).bitPattern)
        data.append(le: Float(r.current).bitPattern)
        data.append(le: Float(r.power).bitPattern)
    }

    /// Writes a whole journal in one go from in-memory readings, placing each
    /// record by its wall-clock offset from `startEpoch` (imports, migration).
    static func write(_ readings: [Reading], startEpoch: Date, to url: URL) throws {
        var data = header(startEpoch: startEpoch)
        data.reserveCapacity(headerSize + readings.count * recordSize)
        for r in readings {
            appendRecord(&data, seconds: r.timestamp.timeIntervalSince(startEpoch), r)
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw JournalError.io(error.localizedDescription)
        }
    }

    // MARK: - Reading

    /// Reads a whole journal. Never throws for a truncated trailing record.
    static func read(url: URL) throws -> (start: Date, readings: [Reading]) {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw JournalError.io(error.localizedDescription)
        }
        guard let start = start(of: data) else { throw JournalError.badHeader }
        let n = (data.count - headerSize) / recordSize
        var readings: [Reading] = []
        readings.reserveCapacity(n)
        for k in 0..<n {
            let base = headerSize + k * recordSize
            let ms = data.readLE(UInt32.self, at: base)
            let v = Float(bitPattern: data.readLE(UInt32.self, at: base + 4))
            let i = Float(bitPattern: data.readLE(UInt32.self, at: base + 8))
            let w = Float(bitPattern: data.readLE(UInt32.self, at: base + 12))
            let seconds = Double(ms) / 1000
            readings.append(Reading(timestamp: start.addingTimeInterval(seconds),
                                    voltage: quantise(v), current: quantise(i), power: quantise(w),
                                    monotonic: seconds))
        }
        return (start, readings)
    }

    /// The meter reports 1/10000 units; a stored `Float` is restored to that
    /// grid so `9.0123` reads back as exactly `9.0123`.
    static func quantise(_ v: Float) -> Double {
        (Double(v) * 10_000).rounded() / 10_000
    }

    /// The header's start epoch, or nil when `data` is not a journal.
    static func start(of data: Data) -> Date? {
        guard data.count >= headerSize,
              Array(data[data.startIndex..<data.startIndex + 4]) == magic,
              data.readLE(UInt32.self, at: 4) == version else { return nil }
        return Date(timeIntervalSince1970: Double(bitPattern: data.readLE(UInt64.self, at: 8)))
    }

    /// Reads only the header (start epoch) of a journal file.
    static func startEpoch(url: URL) throws -> Date {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw JournalError.io(error.localizedDescription)
        }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: headerSize)) ?? Data()
        guard let start = start(of: head) else { throw JournalError.badHeader }
        return start
    }

    /// Number of complete records in the file, from its size alone (0 for a
    /// missing file or one shorter than the header). Uses the file offset
    /// rather than file attributes, so no timestamp API is touched.
    static func count(url: URL) -> Int {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return 0 }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size >= UInt64(headerSize) else { return 0 }
        return Int((size - UInt64(headerSize)) / UInt64(recordSize))
    }
}

// MARK: - Little-endian helpers

private extension Data {
    mutating func append<T: FixedWidthInteger>(le value: T) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }

    /// Reads a little-endian integer at `offset` relative to `startIndex`.
    func readLE<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T {
        var v: T = 0
        let lower = startIndex + offset
        Swift.withUnsafeMutableBytes(of: &v) { dst in
            _ = copyBytes(to: dst, from: lower..<lower + MemoryLayout<T>.size)
        }
        return T(littleEndian: v)
    }
}

/// A value guarded by a lock (the journal's statistics are written on the
/// writer queue and read on the main actor).
final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) {
        self.value = value
    }

    func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}
