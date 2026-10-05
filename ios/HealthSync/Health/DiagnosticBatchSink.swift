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
    init(root: URL, delay: TimeInterval) throws {
        self.root = root; self.delay = delay
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func upload(batchId: String, gz: Data, sha256: String, typeId: String) async throws {
        try Task.checkCancellation()
        let digest = SHA256.hash(data: gz).map { String(format: "%02x", $0) }.joined()
        guard digest == sha256 else { throw InvalidBatch() }
        let url = root.appendingPathComponent(UUID().uuidString).appendingPathExtension("gz")
        let start = ProcessInfo.processInfo.systemUptime
        lock.withLock { active += 1; peak = max(peak, active) }
        defer { lock.withLock { active -= 1; elapsed += ProcessInfo.processInfo.systemUptime - start } }
        try gz.write(to: url, options: [.atomic, .completeFileProtection])
        try await Task.sleep(for: .seconds(max(0, delay)))
        try Task.checkCancellation()
        lock.withLock { files.append((typeId, url)); bytes += gz.count }
    }
    var batches: [(String, URL)] { lock.withLock { files } }
    func summary() -> String {
        lock.withLock { String(format: "Simulated uploads: %d batches · %.2f MB · %.2fs total request time (overlaps) · peak %d", files.count, Double(bytes) / 1_000_000, elapsed, peak) }
    }
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
    func compare(to reference: Self, tolerance: Double = 1e-9) throws -> HistoryRecordComparison {
        let a = try FileHandle(forReadingFrom: reference.file), b = try FileHandle(forReadingFrom: file)
        defer { try? a.close(); try? b.close() }
        var result = HistoryRecordComparison(exact: count == reference.count && Set(groups.keys) == Set(reference.groups.keys), equivalent: count == reference.count && Set(groups.keys) == Set(reference.groups.keys), maximumDelta: 0, changedRecords: 0)
        for key in Set(groups.keys).union(reference.groups.keys).sorted() {
            try Task.checkCancellation()
            let originals = reference.groups[key] ?? [], candidates = groups[key] ?? []
            guard originals.count == candidates.count else {
                result.exact = false; result.equivalent = false
                result.changedRecords += max(originals.count, candidates.count)
                result.changedFields["record shape/count", default: 0] += max(originals.count, candidates.count)
                continue
            }
            func frequencies(_ locations: [Location]) -> [String: Int] {
                locations.reduce(into: [:]) { $0[$1.digest, default: 0] += 1 }
            }
            if frequencies(originals) == frequencies(candidates) { continue }
            result.exact = false
            var remaining = candidates
            var unmatched: [Location] = []
            // Reserve every exact occurrence before pairing changed numeric records.
            for location in originals {
                if let exact = remaining.firstIndex(where: { $0.digest == location.digest }) { remaining.remove(at: exact) }
                else { unmatched.append(location) }
            }
            for location in unmatched {
                try Task.checkCancellation()
                let original = try Self.read(a, location)
                var best: (Int, Double)?
                for (i, location) in remaining.enumerated() {
                    if let delta = HistoryRecordComparison.distance(original, try Self.read(b, location)), best == nil || delta < best!.1 { best = (i, delta) }
                }
                result.changedRecords += 1
                guard let best else { result.equivalent = false; continue }
                let candidate = try Self.read(b, remaining[best.0])
                let differences = HistoryRecordComparison.differingFields(original, candidate, tolerance: tolerance)
                let label = (original as? [String: Any])?["k"] as? String ?? "record"
                for field in Set(differences.map { label + "." + $0.0 }) { result.changedFields[field, default: 0] += 1 }
                if result.examples.count < 8, let first = differences.first {
                    let day = (original as? [String: Any])?["day"] as? String
                    let date = day.map { " day=" + $0 } ?? ""
                    let values = first.1.flatMap { a in first.2.map { b in " reference=\(a) candidate=\(b)" } } ?? " shape/value changed"
                    result.examples.append("Difference \(label)\(date) field=\(first.0)\(values)")
                }
                remaining.remove(at: best.0)
                result.maximumDelta = max(result.maximumDelta, best.1)
                if !best.1.isFinite || best.1 > tolerance { result.equivalent = false }
            }
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
