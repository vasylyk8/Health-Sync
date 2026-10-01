import Foundation

/// One hour of a quantity (average/min/max, or the sum for cumulative types).
struct HourBucket: Equatable, Sendable {
    var t: Int64
    var v: Double?
    var lo: Double?
    var hi: Double?
}

/// One event or timed entry (a symptom, a glucose reading, a nutrient...), before it is turned into an `ev` chunk.
struct EventPoint: Equatable, Sendable {
    var start: Int64
    var end: Int64
    var v: Double?
    var v2: Double?
    var c: Int?
    var id: String?
    var meta: [String: RecordValue]?
}

/// Builds the `hs` (hourly buckets) and `ev` (events) records of docs/DATA_CONTRACT.md. Columns are compact
/// (`enc: 1`): integer differences, so a year of hourly values or a CGM's readings stay a few KB.
enum SeriesRecords {
    /// Points per chunk record.
    static let chunkPoints = 5_000

    /// Chunks of one hourly series. Buckets without any value are left out; `lo`/`hi` are omitted when never set.
    static func hourlyChunks(name: String, unit: String, hours: [HourBucket]) -> [Record] {
        let sorted = Dictionary(hours.filter { $0.v != nil || $0.lo != nil || $0.hi != nil }.map { ($0.t, $0) }, uniquingKeysWith: { _, new in new })
            .values.sorted { $0.t < $1.t }
        var out: [Record] = []
        var i = 0
        while i < sorted.count {
            let j = min(i + chunkPoints, sorted.count)
            let slice = Array(sorted[i ..< j])
            var r: Record = [
                "k": "hs", "st": .string(name), "u": .string(unit), "enc": .int(1), "n": .int(Int64(slice.count)),
                "t": CompactColumns.encodeTimes(slice.map(\.t)),
            ]
            if slice.contains(where: { $0.v != nil }) { r["v"] = CompactColumns.encode(slice.map(\.v), plan: WorkoutRecords.quantityPlan) }
            if slice.contains(where: { $0.lo != nil }) { r["lo"] = CompactColumns.encode(slice.map(\.lo), plan: WorkoutRecords.quantityPlan) }
            if slice.contains(where: { $0.hi != nil }) { r["hi"] = CompactColumns.encode(slice.map(\.hi), plan: WorkoutRecords.quantityPlan) }
            out.append(r)
            i = j
        }
        return out
    }

    /// Chunks of events of one type from one source. `ids` and `meta` are only sent when the points carry them
    /// (dense series such as glucose readings do not, to stay small).
    static func eventChunks(type: String, unit: String?, source: String?, bundle: String?, points: [EventPoint]) -> [Record] {
        let sorted = points.sorted { $0.start != $1.start ? $0.start < $1.start : ($0.id ?? "") < ($1.id ?? "") }
        var out: [Record] = []
        var i = 0
        while i < sorted.count {
            let j = min(i + chunkPoints, sorted.count)
            let slice = Array(sorted[i ..< j])
            var r: Record = ["k": "ev", "ty": .string(type), "enc": .int(1), "n": .int(Int64(slice.count)), "s": CompactColumns.encodeTimes(slice.map(\.start))]
            if let unit { r["u"] = .string(unit) }
            if let source { r["src"] = .string(String(source.prefix(200))) }
            if let bundle { r["bid"] = .string(String(bundle.prefix(200))) }
            if slice.contains(where: { $0.end != $0.start }) { r["e"] = CompactColumns.encodeTimes(slice.map(\.end)) }
            if slice.contains(where: { $0.v != nil }) { r["v"] = CompactColumns.encode(slice.map(\.v), plan: WorkoutRecords.quantityPlan) }
            if slice.contains(where: { $0.v2 != nil }) { r["v2"] = CompactColumns.encode(slice.map(\.v2), plan: WorkoutRecords.quantityPlan) }
            if slice.contains(where: { $0.c != nil }) { r["c"] = CompactColumns.encode(slice.map { $0.c.map(Double.init) }, plan: .exact) }
            if slice.allSatisfy({ $0.id != nil }) { r["ids"] = .array(slice.map { .string($0.id ?? "") }) }
            if slice.contains(where: { $0.meta != nil }) { r["meta"] = .array(slice.map { $0.meta.map { .object($0) } ?? .null }) }
            out.append(r)
            i = j
        }
        return out
    }

    /// Metadata keys that only identify the writing app's own bookkeeping: not worth uploading.
    static let ignoredMetadataKeys: Set<String> = ["HKExternalUUID", "HKMetadataKeySyncIdentifier", "HKMetadataKeySyncVersion", "HKTimeZone", "HKSyncIdentifier", "HKSyncVersion"]
}
