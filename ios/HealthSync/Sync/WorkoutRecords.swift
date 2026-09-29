import Foundation

struct SeriesPoint: Equatable, Sendable {
    var t: Int64
    var v: Double
}

struct RoutePoint: Equatable, Sendable {
    var t: Int64
    var lat: Double
    var lon: Double
    var alt: Double?
    var spd: Double?
    var crs: Double?
    var ha: Double?
    var va: Double?
}

/// Builds the `ws` / `wd` records of a workout's raw data (docs/DATA_CONTRACT.md §1).
/// Points are sorted and de-duplicated by time here, so the count promised in the `wd` marker
/// is exactly what the server ends up storing.
enum WorkoutRecords {
    /// Points per chunk record: keeps every record line small.
    static let chunkPoints = 5_000

    static func dedupe(_ points: [SeriesPoint]) -> [SeriesPoint] {
        let valid = points.filter { $0.v.isFinite && $0.t >= 0 }
        let byTime = Dictionary(valid.map { ($0.t, $0) }, uniquingKeysWith: { _, new in new })
        return byTime.values.sorted { $0.t < $1.t }
    }

    static func dedupe(_ points: [RoutePoint]) -> [RoutePoint] {
        let valid = points.filter { $0.lat.isFinite && $0.lon.isFinite && abs($0.lat) <= 90 && abs($0.lon) <= 180 && $0.t >= 0 }
        let byTime = Dictionary(valid.map { ($0.t, $0) }, uniquingKeysWith: { _, new in new })
        return byTime.values.sorted { $0.t < $1.t }
    }

    /// Chunks of one stream with a single value column `v`.
    static func series(wid: String, name: String, gen: Int64, unit: String?, points: [SeriesPoint]) -> (records: [Record], count: Int) {
        let pts = dedupe(points)
        let records = chunks(wid: wid, name: name, gen: gen, unit: unit, t: pts.map(\.t), columns: ["v": pts.map { Optional($0.v) }])
        return (records, pts.count)
    }

    /// Chunks of the GPS route with columns lat, lon, alt, spd, crs, ha, va (unused ones are omitted).
    static func route(wid: String, gen: Int64, points: [RoutePoint]) -> (records: [Record], count: Int) {
        let pts = dedupe(points)
        let columns: [String: [Double?]] = [
            "lat": pts.map { Optional($0.lat) }, "lon": pts.map { Optional($0.lon) },
            "alt": pts.map(\.alt), "spd": pts.map(\.spd), "crs": pts.map(\.crs), "ha": pts.map(\.ha), "va": pts.map(\.va),
        ]
        return (chunks(wid: wid, name: "route", gen: gen, unit: nil, t: pts.map(\.t), columns: columns), pts.count)
    }

    /// "Raw data of this generation consists of these streams with these point counts."
    static func mark(wid: String, gen: Int64, expected: [String: Int]) -> Record {
        ["k": "wd", "wid": .string(wid), "gen": .int(gen), "expected": .object(expected.mapValues { .int(Int64($0)) })]
    }

    private static func chunks(wid: String, name: String, gen: Int64, unit: String?, t: [Int64], columns: [String: [Double?]]) -> [Record] {
        // A column with no value at all is left out; a chunk must carry at least one column.
        let used = columns.filter { $0.value.contains { $0 != nil } }
        guard !used.isEmpty else { return [] }
        var out: [Record] = []
        var i = 0
        while i < t.count {
            let j = min(i + chunkPoints, t.count)
            var r: Record = ["k": "ws", "wid": .string(wid), "st": .string(name), "gen": .int(gen), "t": .array(t[i..<j].map { RecordValue.int($0) })]
            if let unit { r["u"] = .string(unit) }
            for (col, values) in used {
                r[col] = .array(values[i..<j].map { value -> RecordValue in
                    if let value, value.isFinite { return .double(value) }
                    return .null
                })
            }
            out.append(r)
            i = j
        }
        return out
    }
}
