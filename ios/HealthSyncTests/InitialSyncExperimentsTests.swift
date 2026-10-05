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
    func testFieldDiagnosticsIdentifyMetricWithoutIgnoringValues() {
        let a: [String: Any] = ["k": "day", "day": "2020-01-01", "m": ["hrAvg": 72, "steps": 100]]
        let b: [String: Any] = ["k": "day", "day": "2020-01-01", "m": ["hrAvg": 73, "steps": 100]]
        let diff = HistoryRecordComparison.differingFields(a, b)
        XCTAssertEqual(diff.count, 1); XCTAssertEqual(diff[0].0, "m.hrAvg")
        XCTAssertEqual(diff[0].1, 72); XCTAssertEqual(diff[0].2, 73)
        XCTAssertTrue(HistoryRecordComparison.differingFields(a, a).isEmpty)
    }
}
