import XCTest
@testable import HealthSync

final class SampleAggregationTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Toronto")!
        return c
    }()

    private func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    private func aggregator(_ from: Date, _ to: Date, cumulative: Bool, _ g: SampleAggregator.Granularity = .day) -> SampleAggregator {
        SampleAggregator(calendar: cal, from: from, to: to, cumulative: cumulative, granularity: g)
    }

    private func dict(_ v: [(String, Double)]) -> [String: Double] { Dictionary(v, uniquingKeysWith: { a, _ in a }) }

    /// The known gap: a 50 bpm resting-heart-rate reading from the evening of May 11 to May 12. Apple Health shows it on
    /// May 12; HealthKit's statistics had a value for May 11 only. The fill must give May 12 its 50 and leave May 11 alone.
    func testRestingHeartRateAcrossMidnightFillsTheSecondDay() {
        var a = aggregator(at(2026, 5, 1), at(2026, 6, 1), cumulative: false)
        a.add(RawReading(start: at(2026, 5, 11, 0, 5), end: at(2026, 5, 11, 23, 50), value: 47, source: "com.apple.health.A"))
        a.add(RawReading(start: at(2026, 5, 11, 23, 55), end: at(2026, 5, 12, 23, 55), value: 50, source: "com.apple.health.A"))
        let raw = a.daily(.avg)
        XCTAssertEqual(dict(raw)["2026-05-12"], 50)
        let primary = [("2026-05-11", 47.0)]
        let filled = HealthKitSource.missingDaily(primary: primary, fallback: raw)
        XCTAssertEqual(filled.map(\.0), ["2026-05-12"])
        XCTAssertEqual(filled.first?.1, 50)
    }

    func testDiscreteReadingThatEndsAtMidnightStaysOnItsDay() {
        var a = aggregator(at(2026, 5, 1), at(2026, 6, 1), cumulative: false)
        a.add(RawReading(start: at(2026, 5, 11, 22), end: at(2026, 5, 12), value: 50, source: "s"))
        XCTAssertEqual(a.daily(.avg).map(\.0), ["2026-05-11"])
    }

    func testSeriesReadingWeighsAsManyValuesAsItHolds() {
        var a = aggregator(at(2026, 5, 1), at(2026, 6, 1), cumulative: false)
        a.add(RawReading(start: at(2026, 5, 3, 8), end: at(2026, 5, 3, 8), value: 60, source: "w"))
        a.add(RawReading(start: at(2026, 5, 3, 12), end: at(2026, 5, 3, 12, 2), value: 145, min: 100, max: 190, last: 190, count: 10, source: "w"))
        a.add(RawReading(start: at(2026, 5, 3, 20), end: at(2026, 5, 3, 20), value: 70, source: "w"))
        XCTAssertEqual(dict(a.daily(.avg))["2026-05-03"]!, (60 + 1450 + 70) / 12.0, accuracy: 1e-9)
        XCTAssertEqual(dict(a.daily(.min))["2026-05-03"], 60)
        XCTAssertEqual(dict(a.daily(.max))["2026-05-03"], 190)
        XCTAssertEqual(dict(a.daily(.last))["2026-05-03"], 70)
    }

    func testLastIsTheLatestReadingOfTheDay() {
        var a = aggregator(at(2026, 5, 1), at(2026, 6, 1), cumulative: false)
        a.add(RawReading(start: at(2026, 5, 3, 19), end: at(2026, 5, 3, 19), value: 81, source: "scale"))
        a.add(RawReading(start: at(2026, 5, 3, 7), end: at(2026, 5, 3, 7), value: 80, source: "scale"))
        XCTAssertEqual(dict(a.daily(.last))["2026-05-03"], 81)
    }

    /// Watch and iPhone both counting the same walk: counted once (the larger), never added together.
    func testOverlappingSourcesAreNotAddedTogether() {
        var a = aggregator(at(2026, 5, 1), at(2026, 6, 1), cumulative: true)
        a.add(RawReading(start: at(2026, 5, 3, 9), end: at(2026, 5, 3, 9, 30), value: 1000, source: "com.apple.health.watch"))
        a.add(RawReading(start: at(2026, 5, 3, 9, 5), end: at(2026, 5, 3, 9, 35), value: 1100, source: "com.apple.health.phone"))
        // Only the phone was carried in the afternoon: those steps count.
        a.add(RawReading(start: at(2026, 5, 3, 15), end: at(2026, 5, 3, 15, 20), value: 400, source: "com.apple.health.phone"))
        XCTAssertEqual(dict(a.daily(.sum))["2026-05-03"]!, 1100 + 400, accuracy: 1e-9)
    }

    func testOneSourceAddsUpLikeHealthKit() {
        var a = aggregator(at(2026, 5, 1), at(2026, 6, 1), cumulative: true)
        for h in [8, 12, 16] { a.add(RawReading(start: at(2026, 5, 3, h), end: at(2026, 5, 3, h, 30), value: 801, source: "app")) }
        XCTAssertEqual(dict(a.daily(.sum))["2026-05-03"]!, 2403, accuracy: 1e-9)
    }

    func testCumulativeReadingIsSpreadOverDaysAndHoursByTime() {
        var a = aggregator(at(2026, 5, 1), at(2026, 6, 1), cumulative: true)
        a.add(RawReading(start: at(2026, 5, 3, 23, 30), end: at(2026, 5, 4, 0, 30), value: 600, source: "p"))
        a.add(RawReading(start: at(2026, 5, 4, 14, 45), end: at(2026, 5, 4, 15, 15), value: 120, source: "p"))
        let days = dict(a.daily(.sum))
        XCTAssertEqual(days["2026-05-03"]!, 300, accuracy: 1e-9)
        XCTAssertEqual(days["2026-05-04"]!, 300 + 120, accuracy: 1e-9)
        var h = aggregator(at(2026, 5, 1), at(2026, 6, 1), cumulative: true, .hour)
        h.add(RawReading(start: at(2026, 5, 4, 14, 45), end: at(2026, 5, 4, 15, 15), value: 120, source: "p"))
        let hours = h.hourly(avg: true, min: false, max: false)
        XCTAssertEqual(hours.map(\.t), [at(2026, 5, 4, 14).msValue, at(2026, 5, 4, 15).msValue])
        XCTAssertEqual(hours.compactMap(\.v), [60, 60])
    }

    func testOnlyTheRangeCounts() {
        var a = aggregator(at(2026, 5, 4), at(2026, 5, 5), cumulative: true)
        a.add(RawReading(start: at(2026, 5, 3, 23, 30), end: at(2026, 5, 4, 0, 30), value: 600, source: "p"))
        a.add(RawReading(start: at(2026, 5, 5, 10), end: at(2026, 5, 5, 11), value: 999, source: "p"))
        XCTAssertEqual(a.daily(.sum).map(\.0), ["2026-05-04"])
        XCTAssertEqual(a.daily(.sum).first!.1, 300, accuracy: 1e-9)
        var d = aggregator(at(2026, 5, 4), at(2026, 5, 5), cumulative: false)
        d.add(RawReading(start: at(2026, 5, 3, 12), end: at(2026, 5, 3, 12), value: 1, source: "p"))
        d.add(RawReading(start: at(2026, 5, 5), end: at(2026, 5, 5), value: 1, source: "p"))
        XCTAssertTrue(d.daily(.avg).isEmpty)
    }

    func testHourlyDiscreteBuckets() {
        var a = aggregator(at(2026, 5, 1), at(2026, 6, 1), cumulative: false, .hour)
        a.add(RawReading(start: at(2026, 5, 3, 9, 10), end: at(2026, 5, 3, 9, 10), value: 60, source: "w"))
        a.add(RawReading(start: at(2026, 5, 3, 9, 40), end: at(2026, 5, 3, 9, 40), value: 80, source: "w"))
        let b = a.hourly(avg: true, min: true, max: true)
        XCTAssertEqual(b, [HourBucket(t: at(2026, 5, 3, 9).msValue, v: 70, lo: 60, hi: 80)])
        XCTAssertEqual(a.hourly(avg: true, min: false, max: false).first?.lo, nil)
    }

    func testLocalDaysCountsStartedDaysAcrossDaylightSaving() {
        XCTAssertEqual(SampleAggregator.localDays(from: at(2026, 3, 1), to: at(2026, 4, 1), calendar: cal), 31)
        XCTAssertEqual(SampleAggregator.localDays(from: at(2026, 10, 1), to: at(2026, 10, 3, 13), calendar: cal), 3)
        XCTAssertEqual(SampleAggregator.localDays(from: at(2026, 10, 1), to: at(2026, 10, 1), calendar: cal), 0)
    }

    func testDifferenceReportsMedianAndLargest() {
        let d = SampleAggregator.difference(reference: [("a", 100), ("b", 200), ("c", 50)], other: [("a", 101), ("b", 200), ("c", 55), ("x", 9)])
        XCTAssertEqual(d?.days, 3)
        XCTAssertEqual(d?.median ?? -1, 1, accuracy: 1e-9)
        XCTAssertEqual(d?.max ?? -1, 10, accuracy: 1e-9)
        XCTAssertNil(SampleAggregator.difference(reference: [], other: [("a", 1)]))
    }
}
