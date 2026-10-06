import CryptoKit
import Foundation

/// The diagnostic's only destination. It has no network client, account identifier or backend.
final class DiagnosticBatchSink: Uploader, @unchecked Sendable {
    let root: URL
    private let delay: TimeInterval
    private let lock = NSLock()
    private var files: [(String, URL)] = []
    private var bytes = 0, peak = 0, active = 0
    private var elapsed = 0.0
    private var failOnce: Bool
    init(root: URL, delay: TimeInterval, failOnce: Bool = false) throws {
        self.root = root; self.delay = delay; self.failOnce = failOnce
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: root.appendingPathComponent("manifest.json")), let saved = try? JSONDecoder().decode([SavedBatch].self, from: data) { files = saved.map { ($0.type, root.appendingPathComponent($0.file)) } }
    }
    func upload(batchId: String, gz: Data, sha256: String, typeId: String) async throws {
        try Task.checkCancellation()
        if lock.withLock({ let fail = failOnce; failOnce = false; return fail }) { throw URLError(.networkConnectionLost) }
        let digest = SHA256.hash(data: gz).map { String(format: "%02x", $0) }.joined()
        guard digest == sha256 else { throw InvalidBatch() }
        let url = root.appendingPathComponent(UUID().uuidString).appendingPathExtension("gz")
        let start = ProcessInfo.processInfo.systemUptime
        lock.withLock { active += 1; peak = max(peak, active) }
        defer { lock.withLock { active -= 1; elapsed += ProcessInfo.processInfo.systemUptime - start } }
        try gz.write(to: url, options: [.atomic, .completeFileProtection])
        try await Task.sleep(for: .seconds(max(0, delay)))
        try Task.checkCancellation()
        try lock.withLock { files.append((typeId, url)); bytes += gz.count
            let saved = files.map { SavedBatch(type: $0.0, file: $0.1.lastPathComponent) }; try JSONEncoder().encode(saved).write(to: root.appendingPathComponent("manifest.json"), options: [.atomic, .completeFileProtection])
        }
    }
    var batches: [(String, URL)] { lock.withLock { files } }
    func summary() -> String {
        lock.withLock { String(format: "Simulated uploads: %d batches · %.2f MB · %.2fs total request time (overlaps) · peak %d", files.count, Double(bytes) / 1_000_000, elapsed, peak) }
    }
    private struct SavedBatch: Codable { let type: String, file: String }
    struct InvalidBatch: Error {}
}

/// One disk-backed canonical record stream and a compact index. Only changed groups are
/// loaded for numeric comparison, so an entire personal workout history is never kept in RAM.
struct DiagnosticRecordIndex: Sendable {
    struct Location: Sendable {
        let offset: UInt64, length: Int, digest: String
    }
    let file: URL
    let groups: [String: [Location]]
    let count: Int
    init(sink: DiagnosticBatchSink) throws {
        file = sink.root.appendingPathComponent("records.ndjson")
        FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.protectionKey: FileProtectionType.complete])
        let writer = try FileHandle(forWritingTo: file)
        defer { try? writer.close() }
        var found: [String: [Location]] = [:]
        var offset: UInt64 = 0
        var count = 0
        for (type, url) in sink.batches {
            try Task.checkCancellation()
            guard let raw = Gzip.decompress(try Data(contentsOf: url)) else { throw BadRecord() }
            for line in raw.split(separator: 10).dropFirst() {
                try Task.checkCancellation()
                let body = try JSONSerialization.jsonObject(with: Data(line))
                guard let object = body as? [String: Any] else { throw BadRecord() }
                if object["k"] as? String == "c" { continue } // sync status, not a health reading
                let canonical = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
                let shape = try JSONSerialization.data(withJSONObject: HistoryRecordComparison.signature(body), options: [.sortedKeys])
                let key = Self.digest(Data(type.utf8) + Data([0]) + shape)
                found[key, default: []].append(Location(offset: offset, length: canonical.count, digest: Self.digest(canonical)))
                try writer.write(contentsOf: canonical)
                offset += UInt64(canonical.count)
                count += 1
            }
        }
        groups = found; self.count = count
    }
    /// `currentDay` (a "YYYY-MM-DD" key) names the day that is still being written while a run proceeds (the cutoff day: last night's
    /// sleep, today's rings). Differences on it are counted and reported but never make the comparison fail; every other day is held
    /// to `tolerance`. Records are matched as a multiset of exact digests first, so duplicate multiplicity is compared exactly.
    func compare(to reference: Self, tolerance: Double = 1e-9, currentDay: String? = nil) throws -> HistoryRecordComparison {
        let a = try FileHandle(forReadingFrom: reference.file), b = try FileHandle(forReadingFrom: file)
        defer { try? a.close(); try? b.close() }
        var result = HistoryRecordComparison(exact: true, equivalent: true, maximumDelta: 0, changedRecords: 0)
        func describe(_ object: Any) -> (kind: String, keys: String, day: String?) {
            let o = object as? [String: Any] ?? [:]
            return (o["k"] as? String ?? "record", (o["m"] as? [String: Any])?.keys.sorted().joined(separator: ",") ?? (o["ty"] as? String ?? ""), o["day"] as? String)
        }
        // A record present on only one side.
        func unpaired(_ object: Any, _ side: String) {
            let d = describe(object)
            result.changedRecords += 1; result.exact = false
            if let day = d.day, day == currentDay { result.currentDayChanged += 1; result.changedFields["currentDay.\(d.kind).\(d.keys).\(side)", default: 0] += 1; return }
            result.beyondTolerance += 1; result.equivalent = false
            result.changedFields["\(d.kind).\(d.keys).\(d.day ?? "").\(side)", default: 0] += 1
            if let day = d.day { result.changedDays[day, default: 0] += 1 }
        }
        for key in Set(groups.keys).union(reference.groups.keys).sorted() {
            try Task.checkCancellation()
            let originals = reference.groups[key] ?? [], candidates = groups[key] ?? []
            var pool: [String: Int] = [:]
            for c in candidates { pool[c.digest, default: 0] += 1 }
            var unmatchedOriginals: [Location] = []
            for o in originals { if let n = pool[o.digest], n > 0 { pool[o.digest] = n - 1 } else { unmatchedOriginals.append(o) } }
            var free: [Location] = []
            for c in candidates { if let n = pool[c.digest], n > 0 { pool[c.digest] = n - 1; free.append(c) } }
            if unmatchedOriginals.isEmpty && free.isEmpty { continue }
            result.exact = false
            for location in unmatchedOriginals {
                try Task.checkCancellation()
                let original = try Self.read(a, location)
                var best: (Int, Double)?
                for (i, candidateLocation) in free.enumerated() {
                    if let delta = HistoryRecordComparison.distance(original, try Self.read(b, candidateLocation)), best == nil || delta < best!.1 { best = (i, delta) }
                }
                guard let best else { unpaired(original, "missing"); continue }
                let candidate = try Self.read(b, free[best.0]); free.remove(at: best.0)
                let d = describe(original)
                let differences = HistoryRecordComparison.differingFields(original, candidate, tolerance: tolerance)
                result.changedRecords += 1
                if let day = d.day, day == currentDay {
                    result.currentDayMaximumDelta = max(result.currentDayMaximumDelta, best.1)
                    if differences.isEmpty { result.noiseRecords += 1; continue }
                    result.currentDayChanged += 1
                    for field in Set(differences.map { "currentDay." + d.kind + "." + $0.0 }) { result.changedFields[field, default: 0] += 1 }
                    continue
                }
                result.maximumDelta = max(result.maximumDelta, best.1)
                if differences.isEmpty { result.noiseRecords += 1; continue }
                result.beyondTolerance += 1; result.equivalent = false
                if let day = d.day { result.changedDays[day, default: 0] += 1 }
                for field in Set(differences.map { d.kind + "." + $0.0 }) { result.changedFields[field, default: 0] += 1 }
                if result.examples.count < 8, let first = differences.first {
                    let date = d.day.map { " day=" + $0 } ?? ""
                    let values = first.1.flatMap { x in first.2.map { y in " reference=\(x) candidate=\(y)" } } ?? " shape/value changed"
                    result.examples.append("Difference \(d.kind)\(date) field=\(first.0)\(values)")
                }
            }
            for location in free { unpaired(try Self.read(b, location), "extra") }
        }
        return result
    }
    private static func read(_ handle: FileHandle, _ location: Location) throws -> Any {
        try handle.seek(toOffset: location.offset)
        guard let data = try handle.read(upToCount: location.length), data.count == location.length else { throw BadRecord() }
        return try JSONSerialization.jsonObject(with: data)
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    struct BadRecord: Error {}
}
