#if DEBUG
import Foundation
import CoreFoundation

/// Investigation only. Release builds keep the established monthly reader.
enum RawHistoryExperiment: String, CaseIterable, Sendable {
    case baseline, shared, larger, parallel
}

struct RawHistoryWindow: Sendable {
    let from: Date
    let to: Date

    static func months(from: Date, to: Date, calendar: Calendar) -> [Self] {
        var cursor = from.addingTimeInterval(-SampleAggregator.nearWatch)
        let end = to.addingTimeInterval(SampleAggregator.nearWatch)
        var windows: [Self] = []
        while cursor < end {
            let next = min(calendar.date(byAdding: .month, value: 1, to: cursor) ?? end, end)
            guard next > cursor else { break }
            windows.append(Self(from: cursor, to: next))
            cursor = next
        }
        return windows
    }

    /// Queries may complete out of order; ingestion stays in month order on one lane.
    /// At most `width` months are fetched or buffered. Indexed values cannot lose a result slot.
    static func parallel(_ windows: [Self], width: Int,
                         fetch: @escaping @Sendable (Self) async throws -> [RawReading],
                         consume: ([RawReading], Int) -> Void) async throws {
        guard !windows.isEmpty else { return }
        try await withThrowingTaskGroup(of: (Int, [RawReading]).self) { group in
            var launched = 0
            var ready: [Int: [RawReading]] = [:]
            func launch() {
                let index = launched, window = windows[launched]
                launched += 1
                group.addTask { (index, try await fetch(window)) }
            }
            for _ in 0..<min(max(1, width), windows.count) { launch() }
            for index in windows.indices {
                try Task.checkCancellation()
                while ready[index] == nil {
                    guard let (slot, values) = try await group.next() else { throw MissingWindow() }
                    ready[slot] = values
                }
                guard let values = ready.removeValue(forKey: index) else { throw MissingWindow() }
                consume(values, index)
                if launched < windows.count { launch() }
            }
        }
    }
    struct MissingWindow: Error {}
}

struct RawHistoryKey: Hashable, Sendable {
    let type: String
    let unit: String
    let scale: Double
    let from: Date
    let to: Date
    let calendar: String
    let timeZone: String
}

struct RawHistorySummary: Sendable {
    let daily: [String: [(String, Double)]]
    let hourly: [HourBucket]
    var cost: Int { daily.values.reduce(hourly.count) { $0 + $1.count } }
}

/// Single-flight computation; retains bounded aggregate output, never whole raw histories.
/// Failed reads are removed so the existing retry can execute a fresh query.
actor RawHistoryCache {
    private var running: [RawHistoryKey: Task<RawHistorySummary, Error>] = [:]
    private var completed: [RawHistoryKey: RawHistorySummary] = [:]
    private var order: [RawHistoryKey] = []
    private let rowLimit: Int
    private var rows = 0
    private(set) var hits = 0
    private(set) var builds = 0
    private(set) var peakRows = 0
    init(rowLimit: Int = 100_000) { self.rowLimit = rowLimit }

    func value(_ key: RawHistoryKey, build: @escaping @Sendable () async throws -> RawHistorySummary) async throws -> RawHistorySummary {
        if let value = completed[key] { hits += 1; return value }
        if let task = running[key] { hits += 1; return try await task.value }
        builds += 1
        let task = Task { try await build() }
        running[key] = task
        do {
            let value = try await task.value
            running[key] = nil
            if value.cost <= rowLimit {
                while rows + value.cost > rowLimit || completed.count >= 32 {
                    guard !order.isEmpty else { break }
                    if let removed = completed.removeValue(forKey: order.removeFirst()) { rows -= removed.cost }
                }
                completed[key] = value
                order.append(key)
                rows += value.cost
                peakRows = max(peakRows, rows)
            }
            return value
        } catch {
            running[key] = nil
            throw error
        }
    }

    var summary: String { "cacheBuilds=\(builds) cacheHits=\(hits) cachedRowsPeak=\(peakRows)" }
}

final class RawHistoryCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var queries = 0, active = 0, peak = 0, samples = 0, peakSamples = 0
    func start() { lock.withLock { queries += 1; active += 1; peak = max(peak, active) } }
    func finish() { lock.withLock { active -= 1 } }
    func received(_ n: Int) { lock.withLock { samples += n; peakSamples = max(peakSamples, n) } }
    var summary: String { lock.withLock { "rawQueries=\(queries) rawSamples=\(samples) rawQueriesPeak=\(peak) querySamplesPeak=\(peakSamples)" } }
}

/// Diagnostic comparison only: production records are never rounded or rewritten.
/// Preserve strings, booleans, keys, array shapes, duplicates and record counts. Numeric differences
/// are reported, with a 1e-9 absolute ceiling far below the quantity encoder's 0.0005 precision.
struct HistoryRecordComparison {
    var exact: Bool
    var equivalent: Bool
    var maximumDelta: Double
    var changedRecords: Int

    static func compare(_ reference: [String], _ candidate: [String], tolerance: Double = 1e-9) throws -> Self {
        func groups(_ records: [String]) throws -> [String: [(String, Any)]] {
            var result: [String: [(String, Any)]] = [:]
            for record in records {
                guard let colon = record.firstIndex(of: ":") else { throw BadRecord() }
                let type = String(record[..<colon])
                let body = try JSONSerialization.jsonObject(with: Data(record[record.index(after: colon)...].utf8))
                let shape = try JSONSerialization.data(withJSONObject: signature(body), options: [.sortedKeys])
                result[type + ":" + String(decoding: shape, as: UTF8.self), default: []].append((record, body))
            }
            return result
        }
        let a = try groups(reference), b = try groups(candidate)
        var result = Self(exact: reference.sorted() == candidate.sorted(), equivalent: reference.count == candidate.count && Set(a.keys) == Set(b.keys), maximumDelta: 0, changedRecords: 0)
        for key in a.keys {
            let originals = a[key] ?? []
            var remaining = b[key] ?? []
            guard originals.count == remaining.count else { result.equivalent = false; continue }
            for (line, original) in originals {
                let matches = remaining.enumerated().compactMap { index, value -> (Int, Double)? in
                    guard let delta = distance(original, value.1) else { return nil }
                    return (index, delta)
                }
                guard let best = matches.min(by: { $0.1 < $1.1 }) else { result.equivalent = false; continue }
                result.maximumDelta = max(result.maximumDelta, best.1)
                if best.1 > tolerance { result.equivalent = false }
                if line != remaining[best.0].0 { result.changedRecords += 1 }
                remaining.remove(at: best.0)
            }
        }
        return result
    }

    private static func signature(_ value: Any) -> Any {
        if let number = value as? NSNumber {
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? value : 0
        }
        if let array = value as? [Any] { return array.map(signature) }
        if let object = value as? [String: Any] { return object.mapValues(signature) }
        return value
    }

    private static func distance(_ a: Any, _ b: Any) -> Double? {
        if let a = a as? NSNumber, let b = b as? NSNumber {
            let ab = CFGetTypeID(a) == CFBooleanGetTypeID(), bb = CFGetTypeID(b) == CFBooleanGetTypeID()
            if ab || bb { return ab == bb && a == b ? 0 : nil }
            return abs(a.doubleValue - b.doubleValue)
        }
        if let a = a as? String, let b = b as? String { return a == b ? 0 : nil }
        if a is NSNull, b is NSNull { return 0 }
        if let a = a as? [Any], let b = b as? [Any], a.count == b.count {
            var maximum = 0.0
            for (a, b) in zip(a, b) { guard let d = distance(a, b) else { return nil }; maximum = max(maximum, d) }
            return maximum
        }
        if let a = a as? [String: Any], let b = b as? [String: Any], Set(a.keys) == Set(b.keys) {
            var maximum = 0.0
            for key in a.keys { guard let d = distance(a[key]!, b[key]!) else { return nil }; maximum = max(maximum, d) }
            return maximum
        }
        return nil
    }
    private struct BadRecord: Error {}
}
#endif
