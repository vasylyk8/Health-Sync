import CryptoKit
import Foundation

/// A JSON value for batch records (see docs/DATA_CONTRACT.md).
enum RecordValue: Codable, Equatable, Sendable {
    case string(String), int(Int64), double(Double), bool(Bool), array([RecordValue]), object([String: RecordValue]), null

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v.isFinite ? v : 0)
        case .bool(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int64.self) { self = .int(v) }
        else if let v = try? c.decode(Double.self) { self = .double(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([RecordValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: RecordValue].self)) }
    }
}

extension RecordValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int64) { self = .int(value) }
    init(floatLiteral value: Double) { self = .double(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
}

typealias Record = [String: RecordValue]

extension Date {
    /// Epoch milliseconds, the time format used everywhere in batches.
    var ms: RecordValue { .int(Int64((timeIntervalSince1970 * 1000).rounded())) }
    var msValue: Int64 { Int64((timeIntervalSince1970 * 1000).rounded()) }
}

extension Optional where Wrapped == String {
    var value: RecordValue { map { .string($0) } ?? .null }
}

enum BatchMode: String, Codable, Sendable {
    /// `status`: one batch reporting types that had nothing new (type "_status").
    /// `workoutdata`: raw streams of workouts (type "_wstream"). `stats`: daily context (type "_daily").
    case anchored, recent, stats, reconcile, status, workoutdata
}

struct BatchHeader: Sendable {
    var type: String
    var mode: BatchMode
    var seq: Int64
    var window: (start: Date, end: Date)?
    var caughtUp: Bool?
    var checkedAt: Date
    var reconcileId: String?
    var reconcileDone: Bool?
    /// Timings sent to the server so slow syncs can be diagnosed (never health data).
    var readMs: Int?
    var uploadMs: Int?
    /// A short diagnostic line (metric counts, error codes, never health values) the server writes to its log, so a sync
    /// that loses data on a real iPhone can be understood without asking the owner to run tests.
    var note: String?

    func record(batchId: String, now: Date, tz: String, device: String, appVersion: String) -> Record {
        var r: Record = [
            "kind": "header", "schema": 2, "batchId": .string(batchId), "type": .string(type), "seq": .int(seq),
            "device": .string(device), "appVersion": .string(appVersion), "tz": .string(tz),
            "createdAt": now.ms, "mode": .string(mode.rawValue), "checkedAt": checkedAt.ms,
        ]
        if let window { r["window"] = .object(["start": window.start.ms, "end": window.end.ms]) }
        if let caughtUp { r["caughtUp"] = .bool(caughtUp) }
        if let reconcileId {
            r["reconcileId"] = .string(reconcileId)
            r["reconcileDone"] = .bool(reconcileDone ?? false)
        }
        var perf: [String: RecordValue] = [:]
        if let readMs { perf["readMs"] = .int(Int64(min(max(readMs, 0), 3_600_000))) }
        if let uploadMs { perf["uploadMs"] = .int(Int64(min(max(uploadMs, 0), 3_600_000))) }
        if let note, !note.isEmpty { perf["note"] = .string(BatchHeader.cleanNote(note)) }
        if !perf.isEmpty { r["perf"] = .object(perf) }
        return r
    }
}

extension BatchHeader {
    /// Only the characters the server accepts in a note, at most 700 of them.
    static func cleanNote(_ text: String) -> String {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 ,.:;()_/|=<>+*-")
        return String(text.map { allowed.contains($0) ? $0 : "_" }.prefix(700))
    }
}

/// A finished, compressed batch ready for upload.
struct Batch: Sendable {
    let id: String
    let gz: Data
    var sha256: String { SHA256.hash(data: gz).map { String(format: "%02x", $0) }.joined() }
}

enum BatchWriter {
    static let maxCompressedBytes = 4_500_000
    static let maxRecords = 150_000
    static let maxUncompressedBytes = 60_000_000

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    /// Encodes records into one or more gzip NDJSON batches that each respect the server limits.
    /// Only the last batch carries `caughtUp`/`reconcileDone`, so the server never marks a type
    /// complete before every part has arrived.
    static func make(header: BatchHeader, records: [Record], nextSeq: () -> Int64, now: Date = Date(), tz: String, device: String, appVersion: String) throws -> [Batch] {
        try make(header: header, lines: encodeLines(records), nextSeq: nextSeq, now: now, tz: tz, device: device, appVersion: appVersion)
    }

    /// One JSON line per record. Can run off the sync actor (several workouts at once).
    static func encodeLines(_ records: [Record]) throws -> [Data] {
        try records.map { try encoder.encode($0) }
    }

    /// Same as `make(header:records:)` for records that were already encoded with `encodeLines`.
    static func make(header: BatchHeader, lines: [Data], nextSeq: () -> Int64, now: Date = Date(), tz: String, device: String, appVersion: String) throws -> [Batch] {
        var chunks: [[Data]] = [[]]
        var bytes = 0
        for line in lines {
            if chunks[chunks.count - 1].count >= maxRecords || bytes + line.count > maxUncompressedBytes {
                chunks.append([])
                bytes = 0
            }
            chunks[chunks.count - 1].append(line)
            bytes += line.count + 1
        }
        var out: [Batch] = []
        for (i, chunk) in chunks.enumerated() {
            let last = i == chunks.count - 1
            out.append(contentsOf: try encode(chunk, header: header, last: last, first: i == 0, nextSeq: nextSeq, now: now, tz: tz, device: device, appVersion: appVersion))
        }
        return out
    }

    private static func encode(_ lines: [Data], header: BatchHeader, last: Bool, first: Bool, nextSeq: () -> Int64, now: Date, tz: String, device: String, appVersion: String) throws -> [Batch] {
        var h = header
        h.seq = first ? header.seq : nextSeq()
        if !last {
            h.caughtUp = header.caughtUp == nil ? nil : false
            h.reconcileDone = header.reconcileDone == nil ? nil : false
            // Coverage windows are only claimed once all parts of a result have been sent.
            h.window = nil
        }
        let id = UUID().uuidString.lowercased()
        var body = try encoder.encode(h.record(batchId: id, now: now, tz: tz, device: device, appVersion: appVersion))
        for line in lines {
            body.append(0x0A)
            body.append(line)
        }
        let gz = Gzip.compress(body)
        if gz.count > maxCompressedBytes && lines.count > 1 {
            let mid = lines.count / 2
            var firstHalf = header
            firstHalf.seq = h.seq
            return try encode(Array(lines[..<mid]), header: firstHalf, last: false, first: true, nextSeq: nextSeq, now: now, tz: tz, device: device, appVersion: appVersion)
                + encode(Array(lines[mid...]), header: header, last: last, first: false, nextSeq: nextSeq, now: now, tz: tz, device: device, appVersion: appVersion)
        }
        return [Batch(id: id, gz: gz)]
    }
}
