import XCTest
@testable import HealthSync

final class SeriesRecordsTests: XCTestCase {
    private func column(_ r: Record, _ key: String, count: Int) -> [Double?]? {
        guard let c = r[key] else { return nil }
        return CompactColumns.decode(c, count: count)
    }

    func testHourlyChunkDropsEmptyHoursAndRoundTrips() throws {
        let hours = [
            HourBucket(t: 7_200_000, v: 61.5, lo: 55, hi: 70),
            HourBucket(t: 3_600_000, v: 59, lo: 52, hi: 66),
            HourBucket(t: 10_800_000, v: nil, lo: nil, hi: nil),
        ]
        let chunks = SeriesRecords.hourlyChunks(name: "HeartRate", unit: "count/min", hours: hours)
        XCTAssertEqual(chunks.count, 1)
        let r = try XCTUnwrap(chunks.first)
        XCTAssertEqual(r["k"], "hs")
        XCTAssertEqual(r["st"], "HeartRate")
        XCTAssertEqual(r["n"], 2)
        XCTAssertEqual(CompactColumns.decode(try XCTUnwrap(r["t"]), count: 2), [3_600_000, 7_200_000], "sorted by time, the empty hour is gone")
        XCTAssertEqual(column(r, "v", count: 2), [59, 61.5])
        XCTAssertEqual(column(r, "lo", count: 2), [52, 55])
        XCTAssertEqual(column(r, "hi", count: 2), [66, 70])
    }

    func testSumSeriesHasNoMinMaxColumns() throws {
        let chunks = SeriesRecords.hourlyChunks(name: "StepCount", unit: "count", hours: [HourBucket(t: 0, v: 420, lo: nil, hi: nil)])
        let r = try XCTUnwrap(chunks.first)
        XCTAssertNotNil(r["v"])
        XCTAssertNil(r["lo"])
        XCTAssertNil(r["hi"])
    }

    func testLongSeriesIsSplitIntoChunks() {
        let hours = (0..<(SeriesRecords.chunkPoints + 10)).map { HourBucket(t: Int64($0) * 3_600_000, v: 60, lo: nil, hi: nil) }
        XCTAssertEqual(SeriesRecords.hourlyChunks(name: "HeartRate", unit: "count/min", hours: hours).count, 2)
    }

    func testDenseEventsCarryNoIdsAndNoMeta() throws {
        let points = (0..<4).map { EventPoint(start: Int64($0) * 300_000, end: Int64($0) * 300_000, v: 100 + Double($0)) }
        let r = try XCTUnwrap(SeriesRecords.eventChunks(type: "BloodGlucose", unit: "mg/dL", source: "Dexcom", bundle: "com.dexcom", points: points).first)
        XCTAssertEqual(r["ty"], "BloodGlucose")
        XCTAssertEqual(r["src"], "Dexcom")
        XCTAssertNil(r["ids"])
        XCTAssertNil(r["meta"])
        XCTAssertNil(r["e"], "point events have no end column")
        XCTAssertEqual(column(r, "v", count: 4), [100, 101, 102, 103])
    }

    func testEventsWithIdsAndDurations() throws {
        let points = [
            EventPoint(start: 2_000, end: 5_000, v: nil, v2: nil, c: 3, id: "B", meta: ["note": "x"]),
            EventPoint(start: 1_000, end: 1_000, v: nil, v2: nil, c: 2, id: "A", meta: nil),
        ]
        let r = try XCTUnwrap(SeriesRecords.eventChunks(type: "Headache", unit: nil, source: nil, bundle: nil, points: points).first)
        XCTAssertEqual(r["ids"], .array(["A", "B"]))
        XCTAssertEqual(column(r, "c", count: 2), [2, 3])
        XCTAssertEqual(column(r, "e", count: 2), [1_000, 5_000])
        XCTAssertEqual(r["meta"], .array([.null, .object(["note": "x"])]))
    }
}

final class ConsentStoreTests: XCTestCase {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "consent-\(UUID().uuidString)")! }

    func testCoreIsAlwaysOnAndChoicesPersist() {
        let d = defaults()
        let store = ConsentStore(defaults: d)
        XCTAssertEqual(store.enabled, ["core"])
        XCTAssertFalse(store.hasChoice)
        store.set(["devices"])
        XCTAssertEqual(store.enabled, ["core", "devices"])
        XCTAssertTrue(store.hasChoice)
        XCTAssertEqual(ConsentStore(defaults: d).enabled, ["core", "devices"], "survives a relaunch")
        store.set([])
        XCTAssertEqual(store.enabled, ["core"], "core cannot be switched off")
    }
}
