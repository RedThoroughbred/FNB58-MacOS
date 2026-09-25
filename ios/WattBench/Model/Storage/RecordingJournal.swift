import Foundation

/// Append-only binary sample file (`samples.wbj`).
///
/// Header (16 bytes, little endian): magic `"WBJ1"`, `UInt32 version = 1`,
/// `Float64 startEpoch` (wall-clock seconds since 1970 at the start of the
/// recording). Records (16 bytes each): `UInt32 t_ms` milliseconds since the
/// recording's MONOTONIC start, then `Float v`, `Float i`, `Float w`. The time
/// base is monotonic so a wall-clock jump mid-recording can never reorder or
/// wrap the offsets; on read `timestamp = startEpoch + t_ms/1000` and
/// `monotonic = t_ms/1000`. A trailing partial record is ignored.
///
/// Foundation ships the format and a main-thread implementation with write
/// buffering (every `flushInterval` seconds or `flushEvery` records); WS-A
/// adds the utility queue, checkpointing and the recorder wiring.
final class RecordingJournal {
    static let magic: [UInt8] = Array("WBJ1".utf8)
    static let version: UInt32 = 1
    static let headerSize = 16
    static let recordSize = 16

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
    private(set) var bytesWritten = 0
    private(set) var lastFlush: Date
    private(set) var lastError: String?

    private let handle: FileHandle
    private let flushInterval: TimeInterval
    private let flushEvery: Int
    private var buffer = Data()
    private var pending = 0
    private var isClosed = false

    /// Creates the file (replacing any existing one) with
    /// `.completeUntilFirstUserAuthentication` protection so background
    /// recording keeps writing while the phone is locked, and writes the
    /// header. `monotonicStart` defaults to now; pass the value captured at
    /// the same instant as `startEpoch` when they were taken separately.
    init(url: URL, startEpoch: Date, flushInterval: TimeInterval = 1, flushEvery: Int = 64,
         monotonicStart: TimeInterval? = nil) throws {
        self.url = url
        self.startEpoch = startEpoch
        self.monotonicStart = monotonicStart ?? MonotonicClock.now
        self.flushInterval = flushInterval
        self.flushEvery = flushEvery
        self.lastFlush = Date()

        var header = Data(capacity: Self.headerSize)
        header.append(contentsOf: Self.magic)
        header.append(le: Self.version)
        header.append(le: startEpoch.timeIntervalSince1970.bitPattern)

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
        do {
            handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
        } catch {
            throw JournalError.io(error.localizedDescription)
        }
        bytesWritten = Self.headerSize
    }

    deinit {
        if !isClosed {
            flushBuffer()
            try? handle.close()
        }
    }

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
        let ms = UInt32(clamping: Int64((max(0, seconds) * 1000).rounded()))
        buffer.append(le: ms)
        buffer.append(le: Float(r.voltage).bitPattern)
        buffer.append(le: Float(r.current).bitPattern)
        buffer.append(le: Float(r.power).bitPattern)
        recordCount += 1
        pending += 1
        if pending >= flushEvery || Date().timeIntervalSince(lastFlush) >= flushInterval {
            flush()
        }
    }

    /// Writes buffered records to the file (no fsync).
    func flush() {
        guard !isClosed else { return }
        flushBuffer()
    }

    /// Flushes and asks the OS to commit the file to storage.
    func synchronize() {
        guard !isClosed else { return }
        flushBuffer()
        do { try handle.synchronize() } catch { lastError = error.localizedDescription }
    }

    /// Flushes, synchronizes and closes the file. Further appends are ignored.
    func close() {
        guard !isClosed else { return }
        synchronize()
        isClosed = true
        do { try handle.close() } catch { lastError = error.localizedDescription }
    }

    private func flushBuffer() {
        guard !buffer.isEmpty else { return }
        do {
            try handle.write(contentsOf: buffer)
            bytesWritten += buffer.count
            buffer.removeAll(keepingCapacity: true)
            pending = 0
            lastFlush = Date()
        } catch {
            lastError = error.localizedDescription
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
        guard data.count >= headerSize,
              Array(data[data.startIndex..<data.startIndex + 4]) == magic,
              data.readLE(UInt32.self, at: 4) == version else {
            throw JournalError.badHeader
        }
        let start = Date(timeIntervalSince1970: Double(bitPattern: data.readLE(UInt64.self, at: 8)))
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
                                    voltage: Double(v), current: Double(i), power: Double(w),
                                    monotonic: seconds))
        }
        return (start, readings)
    }

    /// Number of complete records in the file, from its size alone.
    static func count(url: URL) -> Int {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int, size >= headerSize else { return 0 }
        return (size - headerSize) / recordSize
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
