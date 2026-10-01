import XCTest
@testable import HealthSync

final class WorkoutRecordsTests: XCTestCase {
    /// Chunks are compact (`enc: 1`): `n` points and one object per column. These read them back like the server does.
    private func count(_ r: Record) -> Int {
        if case .int(let n)? = r["n"] { return Int(n) }
        return -1
    }

    private func ints(_ v: RecordValue?, of r: Record) -> [Int64] {
        guard let v, let values = CompactColumns.decode(v, count: count(r)) else { return [] }
        return values.compactMap { $0.map { Int64($0) } }
    }

    private func doubles(_ v: RecordValue?, of r: Record) -> [Double?] {
        guard let v else { return [] }
        return CompactColumns.decode(v, count: count(r)) ?? []
    }

    func testSeriesIsSortedDeduplicatedAndCounted() {
        let points = [SeriesPoint(t: 3000, v: 143), SeriesPoint(t: 1000, v: 141), SeriesPoint(t: 2000, v: 142), SeriesPoint(t: 2000, v: 999), SeriesPoint(t: 4000, v: .nan)]
        let built = WorkoutRecords.series(wid: "W1", name: "HeartRate", gen: 42, unit: "count/min", points: points)
        XCTAssertEqual(built.count, 3, "duplicates by time and non-finite values are removed, so the promised count matches what the server stores")
        XCTAssertEqual(built.records.count, 1)
        let r = built.records[0]
        XCTAssertEqual(r["k"], .string("ws"))
        XCTAssertEqual(r["st"], .string("HeartRate"))
        XCTAssertEqual(r["gen"], .int(42))
        XCTAssertEqual(r["enc"], .int(1))
        XCTAssertEqual(r["n"], .int(3))
        XCTAssertEqual(r["u"], .string("count/min"))
        XCTAssertEqual(ints(r["t"], of: r), [1000, 2000, 3000])
        XCTAssertEqual(doubles(r["v"], of: r), [141, 999, 143], "the later duplicate wins")
    }

    func testLongSeriesIsChunked() {
        let n = WorkoutRecords.chunkPoints * 2 + 7
        let points = (0..<n).map { SeriesPoint(t: Int64($0) * 1000, v: Double($0)) }
        let built = WorkoutRecords.series(wid: "W1", name: "ActiveEnergyBurned", gen: 1, unit: "kcal", points: points)
        XCTAssertEqual(built.count, n)
        XCTAssertEqual(built.records.count, 3)
        XCTAssertEqual(built.records.map { count($0) }, [WorkoutRecords.chunkPoints, WorkoutRecords.chunkPoints, 7])
        XCTAssertEqual(built.records.flatMap { ints($0["t"], of: $0) }, (0..<n).map { Int64($0) * 1000 })
    }

    func testRouteHasColumnsAndDropsInvalidCoordinates() {
        let pts = [
            RoutePoint(t: 1000, lat: 50.0, lon: 30.0, alt: 100, spd: 3, crs: 90, ha: 5, va: 3),
            RoutePoint(t: 2000, lat: 50.001, lon: 30.0, alt: nil, spd: nil, crs: nil, ha: 5, va: nil),
            RoutePoint(t: 3000, lat: 200, lon: 30, alt: 1, spd: 1, crs: 1, ha: 1, va: 1),
        ]
        let built = WorkoutRecords.route(wid: "W1", gen: 5, points: pts)
        XCTAssertEqual(built.count, 2)
        let r = built.records[0]
        XCTAssertEqual(r["st"], .string("route"))
        XCTAssertEqual(doubles(r["lat"], of: r), [50.0, 50.001])
        XCTAssertEqual(doubles(r["alt"], of: r), [100, nil])
        XCTAssertNil(r["v"])
        XCTAssertNotNil(r["crs"])
    }

    func testRouteIsRoundedToAboutAMetreAndKeepsEveryPoint() {
        var pts: [RoutePoint] = []
        for i in 0..<2000 {
            let step = Double(i)
            let lat: Double = 50.123456789 + step * 0.0000271
            let lon: Double = 30.987654321 + step * 0.0000193
            let alt: Double = 180.234 + Double(i % 17) * 0.37
            let spd: Double = 3.14159 + Double(i % 5) * 0.0123
            let crs: Double = 87.654 + Double(i % 9)
            pts.append(RoutePoint(t: Int64(i) * 1000, lat: lat, lon: lon, alt: alt, spd: spd, crs: crs, ha: 3.79, va: 2.1))
        }
        let built = WorkoutRecords.route(wid: "W", gen: 1, points: pts)
        XCTAssertEqual(built.count, 2000, "no point is dropped")
        var back: [Double?] = []
        for r in built.records { back += doubles(r["lat"], of: r) }
        XCTAssertEqual(back.count, 2000)
        for (original, decoded) in zip(pts, back) {
            XCTAssertEqual(decoded!, original.lat, accuracy: 0.5e-5 + 1e-12, "within half of 0.00001 degrees (about 0.6 m)")
        }
        // Much smaller than the older form.
        func size(_ records: [Record]) -> Int {
            var total = 0
            for record in records {
                let lines: [Data] = (try? BatchWriter.encodeLines([record])) ?? []
                total += lines.first?.count ?? 0
            }
            return total
        }
        let plain = WorkoutRecords.route(wid: "W", gen: 1, points: pts, format: .plain).records
        XCTAssertLessThan(size(built.records), size(plain) / 3)
    }

    func testQuantityValuesAreExactEvenWhenNotShortDecimals() {
        let values: [Double] = [0, 0.1, 0.30000000000000004, 1.0 / 3.0, 117, 12.5, 98.6, 0.0234567890123]
        let points = values.enumerated().map { SeriesPoint(t: Int64($0.offset) * 1000, v: $0.element) }
        let r = WorkoutRecords.series(wid: "W", name: "X", gen: 1, unit: nil, points: points).records[0]
        XCTAssertEqual(doubles(r["v"], of: r), values.map { Optional($0) }, "every value comes back bit for bit")
    }

    func testEmptyColumnsAreOmittedAndEmptyInputMakesNoRecords() {
        let pts = [RoutePoint(t: 1, lat: 1, lon: 1, alt: nil, spd: nil, crs: nil, ha: nil, va: nil)]
        let r = WorkoutRecords.route(wid: "W", gen: 1, points: pts).records[0]
        XCTAssertNil(r["alt"])
        XCTAssertNil(r["spd"])
        XCTAssertTrue(WorkoutRecords.series(wid: "W", name: "X", gen: 1, unit: nil, points: []).records.isEmpty)
    }

    func testMarkListsExpectedCounts() {
        let m = WorkoutRecords.mark(wid: "W1", gen: 9, expected: ["HeartRate": 361, "route": 200])
        XCTAssertEqual(m["k"], .string("wd"))
        XCTAssertEqual(m["gen"], .int(9))
        XCTAssertEqual(m["expected"], .object(["HeartRate": .int(361), "route": .int(200)]))
    }

    /// The records must be valid for the server's parser: parallel arrays of equal length.
    func testEveryChunkHasEqualLengthArrays() {
        let pts = (0..<(WorkoutRecords.chunkPoints + 3)).map { RoutePoint(t: Int64($0), lat: 50, lon: 30, alt: Double($0), spd: nil, crs: nil, ha: 5, va: nil) }
        for r in WorkoutRecords.route(wid: "W", gen: 1, points: pts).records {
            let n = count(r)
            XCTAssertEqual(ints(r["t"], of: r).count, n)
            for key in ["lat", "lon", "alt", "ha"] { XCTAssertEqual(doubles(r[key], of: r).count, n, key) }
        }
    }
}
