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

    /// How chunks are written: `compact` is what the app sends (docs/DATA_CONTRACT.md); `plain` (one array per
    /// column) is the older form, kept so the speed test can show how much smaller compact is.
    enum Format: Sendable { case compact, plain }

    /// GPS route precision: about a metre in position (GPS itself is good to 3-5 m), 0.1 m altitude (what the
    /// elevation tools report), 0.1 m/s speed; course and the two accuracy figures to a whole unit (no tool reads them).
    /// Every point is kept. Quantity streams are always exact.
    static let routePlans: [String: CompactColumns.Plan] = [
        "lat": .step(100_000), "lon": .step(100_000), "alt": .step(10), "spd": .step(10), "crs": .step(1), "ha": .step(1), "va": .step(1),
    ]
    /// Finer variant for the speed test's size comparison only.
    static let fineRoutePlans: [String: CompactColumns.Plan] = [
        "lat": .step(100_000), "lon": .step(100_000), "alt": .step(10), "spd": .step(100), "crs": .step(10), "ha": .step(10), "va": .step(10),
    ]

    /// Chunks of one stream with a single value column `v`.
    static func series(wid: String, name: String, gen: Int64, unit: String?, points: [SeriesPoint], format: Format = .compact) -> (records: [Record], count: Int) {
        let pts = dedupe(points)
        let records = chunks(wid: wid, name: name, gen: gen, unit: unit, t: pts.map(\.t), columns: ["v": pts.map { Optional($0.v) }], plans: [:], format: format)
        return (records, pts.count)
    }

    /// Chunks of the GPS route with columns lat, lon, alt, spd, crs, ha, va (unused ones are omitted).
    static func route(wid: String, gen: Int64, points: [RoutePoint], format: Format = .compact, plans: [String: CompactColumns.Plan] = routePlans) -> (records: [Record], count: Int) {
        let pts = dedupe(points)
        let columns: [String: [Double?]] = [
            "lat": pts.map { Optional($0.lat) }, "lon": pts.map { Optional($0.lon) },
            "alt": pts.map(\.alt), "spd": pts.map(\.spd), "crs": pts.map(\.crs), "ha": pts.map(\.ha), "va": pts.map(\.va),
        ]
        return (chunks(wid: wid, name: "route", gen: gen, unit: nil, t: pts.map(\.t), columns: columns, plans: plans, format: format), pts.count)
    }

    /// "Raw data of this generation consists of these streams with these point counts."
    static func mark(wid: String, gen: Int64, expected: [String: Int]) -> Record {
        ["k": "wd", "wid": .string(wid), "gen": .int(gen), "expected": .object(expected.mapValues { .int(Int64($0)) })]
    }

    private static func chunks(wid: String, name: String, gen: Int64, unit: String?, t: [Int64], columns: [String: [Double?]], plans: [String: CompactColumns.Plan], format: Format) -> [Record] {
        // A column with no value at all is left out; a chunk must carry at least one column.
        let used = columns.filter { $0.value.contains { $0 != nil } }
        guard !used.isEmpty else { return [] }
        var out: [Record] = []
        var i = 0
        while i < t.count {
            let j = min(i + chunkPoints, t.count)
            var r: Record = ["k": "ws", "wid": .string(wid), "st": .string(name), "gen": .int(gen)]
            if let unit { r["u"] = .string(unit) }
            switch format {
            case .compact:
                r["enc"] = .int(1)
                r["n"] = .int(Int64(j - i))
                r["t"] = CompactColumns.encodeTimes(Array(t[i..<j]))
                for (col, values) in used { r[col] = CompactColumns.encode(Array(values[i..<j]), plan: plans[col] ?? .exact) }
            case .plain:
                r["t"] = .array(t[i..<j].map { RecordValue.int($0) })
                for (col, values) in used {
                    r[col] = .array(values[i..<j].map { value -> RecordValue in
                        if let value, value.isFinite { return .double(value) }
                        return .null
                    })
                }
            }
            out.append(r)
            i = j
        }
        return out
    }
}
