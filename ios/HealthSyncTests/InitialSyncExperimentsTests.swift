import XCTest
@testable import HealthSync

final class InitialSyncExperimentsTests: XCTestCase {
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "America/Toronto")!; return c }
    private func date(_ text: String) -> Date {
        let f = DateFormatter(); f.calendar = calendar; f.timeZone = calendar.timeZone; f.dateFormat = "yyyy-MM-dd"
        return f.date(from: text)!
    }
    func testSelectiveWindowsKeepDSTDaysAndMergeAdjacentGaps() throws {
        let from = date("2026-03-01"), to = date("2026-04-01")
        var present = Set<String>()
        for i in 0..<31 {
            let d = calendar.date(byAdding: .day, value: i, to: from)!
            let key = SleepNights.dayKey(d, calendar: calendar)
            if key != "2026-03-08" && key != "2026-03-09" { present.insert(key) }
        }
        let gaps = try XCTUnwrap(InitialSyncExperiments.missingWindows(present: present, from: from, to: to, calendar: calendar))
        XCTAssertEqual(gaps.count, 1)
        XCTAssertEqual(gaps[0].start, date("2026-03-08"))
        XCTAssertEqual(gaps[0].end, date("2026-03-10"))
        XCTAssertEqual(gaps[0].duration, 47 * 3600)
        XCTAssertNil(InitialSyncExperiments.missingWindows(present: [], from: from, to: to, calendar: calendar))
        XCTAssertNil(InitialSyncExperiments.missingWindows(present: Set((1...31).map { String(format: "2026-03-%02d", $0) }), from: from, to: to, calendar: calendar))
    }
    func testNormalWindowUnchangedAndWiderPairsAnnualConsumers() async {
        let start = date("2020-07-14"), end = date("2026-10-05"), from = date("2021-07-14"), to = date("2022-07-14")
        XCTAssertEqual(InitialSyncExperiments.statisticsWindow(from: from, to: to, calendar: calendar).0, from)
        await InitialSyncExperiments.$strategy.withValue(.widerStatistics) {
            await InitialSyncExperiments.$historyStart.withValue(start) {
                await InitialSyncExperiments.$historyEnd.withValue(end) {
                    let range = InitialSyncExperiments.statisticsWindow(from: from, to: to, calendar: calendar)
                    XCTAssertEqual(range.0, start); XCTAssertEqual(range.1, to)
                    let tail = InitialSyncExperiments.statisticsWindow(from: self.date("2026-07-14"), to: end, calendar: calendar)
                    XCTAssertEqual(tail.0, self.date("2026-07-14")); XCTAssertEqual(tail.1, end)
                }
            }
        }
        XCTAssertNil(InitialSyncExperiments.strategy)
    }
    func testStatisticsCacheSingleFlightAndRetryAfterFailure() async throws {
        struct Failed: Error {}
        let cache = DailyStatisticsCache()
        let key = DailyStatisticsKey(type: "hr", unit: "bpm", from: date("2020-01-01"), to: date("2021-01-01"), zone: "UTC", explicitSources: false)
        do { _ = try await cache.value(key) { throw Failed() }; XCTFail() } catch is Failed {}
        let snapshot = DailyStatisticsSnapshot(values: ["avg": [("2020-01-01", 72)], "min": [("2020-01-01", 60)]])
        async let a = cache.value(key) { try await Task.sleep(for: .milliseconds(40)); return snapshot }
        async let b = cache.value(key) { try await Task.sleep(for: .milliseconds(40)); return snapshot }
        let result = try await (a, b)
        XCTAssertEqual(result.0.values["avg"]?.first?.1, 72)
        XCTAssertEqual(result.1.values["min"]?.first?.1, 60)
        let builds = await cache.builds
        XCTAssertEqual(builds, 2)
        let hits = await cache.hits
        XCTAssertEqual(hits, 1)
    }
    func testUnifiedCumulativeKeepsWatchPriorityBoundariesAndHourlyValues() throws {
        let from = date("2026-03-08"), to = date("2026-03-10")
        let samples = [
            RawReading(start: from.addingTimeInterval(-120), end: from.addingTimeInterval(1800), value: 1000, source: "com.apple.health.watch", watch: true),
            RawReading(start: from, end: from.addingTimeInterval(1800), value: 1100, source: "com.apple.health.phone"),
            RawReading(start: from.addingTimeInterval(7200), end: from.addingTimeInterval(8400), value: 300, source: "com.apple.health.phone"),
            RawReading(start: from.addingTimeInterval(7200), end: from.addingTimeInterval(8400), value: 5000, source: "thirdparty"),
            RawReading(start: to.addingTimeInterval(-1200), end: to.addingTimeInterval(1200), value: 600, source: "com.apple.health.watch", watch: true)
        ]
        var day = SampleAggregator(calendar: calendar, from: from, to: to, style: .cumulative, granularity: .day)
        var hour = SampleAggregator(calendar: calendar, from: from, to: to, style: .cumulative, granularity: .hour)
        for sample in samples { day.add(sample); hour.add(sample) }
        let unified = day.cumulativeDailyHourly(includeHourly: true)
        let expected = day.daily(.sum), actual = try XCTUnwrap(unified.daily[DailyAgg.sum.rawValue])
        XCTAssertEqual(actual.map(\.0), expected.map(\.0))
        for (a, b) in zip(actual, expected) { XCTAssertEqual(a.1, b.1, accuracy: 1e-9) }
        let hourly = hour.hourly(avg: true, min: true, max: true)
        XCTAssertEqual(unified.hourly.map(\.t), hourly.map(\.t))
        for (a, b) in zip(unified.hourly, hourly) { XCTAssertEqual(a.v!, b.v!, accuracy: 1e-9) }
        XCTAssertTrue(day.cumulativeDailyHourly(includeHourly: false).hourly.isEmpty)
    }
    func testAggregateCachePrefersSharedTypesWithinItsRowBound() async throws {
        let cache = RawHistoryCache(rowLimit: 2, entryLimit: 2)
        func key(_ name: String) -> RawHistoryKey { RawHistoryKey(type: name, unit: "count", scale: 1, from: date("2020-01-01"), to: date("2021-01-01"), calendar: "gregorian", timeZone: "UTC") }
        let value = RawHistorySummary(daily: ["sum": [("2020-01-01", 12)]], hourly: [])
        _ = try await cache.value(key("shared"), retentionPriority: true) { value }
        _ = try await cache.value(key("other")) { value }
        _ = try await cache.value(key("new")) { value }
        _ = try await cache.value(key("shared"), retentionPriority: true) { XCTFail("shared summary was evicted"); return value }
        let builds = await cache.builds, peak = await cache.peakRows
        XCTAssertEqual(builds, 3); XCTAssertEqual(peak, 2)
    }
    /// Investigation evidence: these existing rules are order-sensitive. Do not claim a phone root cause from this fixture.
    func testExistingWorkoutCollisionRuleDependsOnInputOrder() {
        let a = SeriesPoint(t: 1000, v: 70), b = SeriesPoint(t: 1000, v: 80)
        XCTAssertEqual(WorkoutRecords.dedupe([a, b]), [b])
        XCTAssertEqual(WorkoutRecords.dedupe([b, a]), [a])
    }
    func testExistingWeightedFallbackCanChangeWithEqualTimeSpans() {
        let from = date("2026-03-01"), to = date("2026-03-02")
        func value(_ values: [Double]) -> Double? {
            var a = SampleAggregator(calendar: calendar, from: from, to: to, style: .timeWeighted, granularity: .day)
            for v in values { a.add(RawReading(start: from.addingTimeInterval(3600), end: from.addingTimeInterval(3660), value: v, source: "fixture")) }
            return a.daily(.avg).first?.1
        }
        XCTAssertNotEqual(value([60, 80, 100]), value([60, 100, 80]))
    }
    func testFieldDiagnosticsIdentifyMetricWithoutIgnoringValues() {
        let a: [String: Any] = ["k": "day", "day": "2020-01-01", "m": ["hrAvg": 72, "steps": 100]]
        let b: [String: Any] = ["k": "day", "day": "2020-01-01", "m": ["hrAvg": 73, "steps": 100]]
        let diff = HistoryRecordComparison.differingFields(a, b)
        XCTAssertEqual(diff.count, 1); XCTAssertEqual(diff[0].0, "m.hrAvg")
        XCTAssertEqual(diff[0].1, 72); XCTAssertEqual(diff[0].2, 73)
        XCTAssertTrue(HistoryRecordComparison.differingFields(a, a).isEmpty)
    }
}
