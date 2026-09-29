import XCTest
@testable import HealthSync

final class WorkoutRecordsTests: XCTestCase {
    private func ints(_ v: RecordValue?) -> [Int64] {
        guard case .array(let a)? = v else { return [] }
        return a.compactMap { if case .int(let i) = $0 { return i } else { return nil } }
    }

    private func doubles(_ v: RecordValue?) -> [Double?] {
        guard case .array(let a)? = v else { return [] }
        return a.map { if case .double(let d) = $0 { return d } else { return nil } }
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
        XCTAssertEqual(r["u"], .string("count/min"))
        XCTAssertEqual(ints(r["t"]), [1000, 2000, 3000])
        XCTAssertEqual(doubles(r["v"]), [141, 999, 143], "the later duplicate wins")
    }

    func testLongSeriesIsChunked() {
        let n = WorkoutRecords.chunkPoints * 2 + 7
        let points = (0..<n).map { SeriesPoint(t: Int64($0) * 1000, v: Double($0)) }
        let built = WorkoutRecords.series(wid: "W1", name: "ActiveEnergyBurned", gen: 1, unit: "kcal", points: points)
        XCTAssertEqual(built.count, n)
        XCTAssertEqual(built.records.count, 3)
        XCTAssertEqual(built.records.map { ints($0["t"]).count }, [WorkoutRecords.chunkPoints, WorkoutRecords.chunkPoints, 7])
        XCTAssertEqual(built.records.flatMap { ints($0["t"]) }, (0..<n).map { Int64($0) * 1000 })
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
        XCTAssertEqual(doubles(r["lat"]), [50.0, 50.001])
        XCTAssertEqual(doubles(r["alt"]), [100, nil])
        XCTAssertNil(r["v"])
        XCTAssertNotNil(r["crs"])
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
            let n = ints(r["t"]).count
            for key in ["lat", "lon", "alt", "ha"] { XCTAssertEqual(doubles(r[key]).count, n, key) }
        }
    }
}
