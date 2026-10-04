#if DEBUG
import XCTest
@testable import HealthSync

final class RawHistoryExperimentTests: XCTestCase {
    private var key: RawHistoryKey { RawHistoryKey(type: "steps", unit: "count", scale: 1, from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 100), calendar: "gregorian", timeZone: "UTC") }
    private var value: RawHistorySummary { RawHistorySummary(daily: ["sum": [("1970-01-01", 123)]], hourly: []) }

    func testConcurrentConsumersShareOneBuild() async throws {
        let cache = RawHistoryCache()
        let key = key, value = value
        async let a = cache.value(key) { try await Task.sleep(for: .milliseconds(40)); return value }
        async let b = cache.value(key) { try await Task.sleep(for: .milliseconds(40)); return value }
        let results = try await (a, b)
        XCTAssertEqual(results.0.daily["sum"]?.first?.1, 123)
        XCTAssertEqual(results.1.daily["sum"]?.first?.1, 123)
        let builds = await cache.builds
        XCTAssertEqual(builds, 1)
    }

    func testFailureDoesNotPoisonRetry() async throws {
        struct Failed: Error {}
        let cache = RawHistoryCache()
        do { _ = try await cache.value(key) { throw Failed() }; XCTFail("must fail") } catch is Failed {}
        let value = value
        let recovered = try await cache.value(key) { value }
        XCTAssertEqual(recovered.daily["sum"]?.first?.1, 123)
        let builds = await cache.builds
        XCTAssertEqual(builds, 2)
    }

    func testCacheBoundEvictsAndRebuilds() async throws {
        let cache = RawHistoryCache(rowLimit: 1)
        let value = value
        _ = try await cache.value(key) { value }
        let other = RawHistoryKey(type: "hr", unit: "bpm", scale: 1, from: key.from, to: key.to, calendar: key.calendar, timeZone: key.timeZone)
        _ = try await cache.value(other) { value }
        _ = try await cache.value(key) { value }
        let builds = await cache.builds, peak = await cache.peakRows
        XCTAssertEqual(builds, 3)
        XCTAssertEqual(peak, 1)
    }

    func testParallelCompletionKeepsOrderAndBound() async throws {
        let state = WindowProbe()
        let windows = (0..<9).map { RawHistoryWindow(from: Date(timeIntervalSince1970: Double($0)), to: Date(timeIntervalSince1970: Double($0 + 1))) }
        var consumed: [Int] = []
        try await RawHistoryWindow.parallel(windows, width: 3, fetch: { window in
            let index = Int(window.from.timeIntervalSince1970)
            state.begin()
            defer { state.end() }
            try await Task.sleep(for: .milliseconds(index % 3 == 0 ? 30 : 1))
            return [RawReading(start: window.from, end: window.to, value: Double(index), source: "watch", watch: true)]
        }, consume: { values, index in
            XCTAssertEqual(values.first?.value, Double(index))
            consumed.append(index)
        })
        XCTAssertEqual(consumed, Array(0..<9))
        XCTAssertEqual(state.active, 0)
        XCTAssertLessThanOrEqual(state.peak, 3)
        XCTAssertGreaterThan(state.peak, 1)
    }

    func testWindowFailureDrainsOtherReadsBeforeReturn() async throws {
        struct Failed: Error {}
        let state = WindowProbe()
        let windows = (0..<9).map { RawHistoryWindow(from: Date(timeIntervalSince1970: Double($0)), to: Date(timeIntervalSince1970: Double($0 + 1))) }
        do {
            try await RawHistoryWindow.parallel(windows, width: 3, fetch: { window in
                state.begin()
                defer { state.end() }
                if window.from.timeIntervalSince1970 == 1 { throw Failed() }
                try await Task.sleep(for: .milliseconds(100))
                return []
            }, consume: { _, _ in })
            XCTFail("failure must propagate")
        } catch is Failed {}
        XCTAssertEqual(state.active, 0)
    }

    func testMonthlyBoundariesIncludeMarginsAcrossDST() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Toronto")!
        let from = calendar.date(from: DateComponents(year: 2024, month: 2, day: 28))!
        let to = calendar.date(from: DateComponents(year: 2024, month: 12, day: 1))!
        let windows = RawHistoryWindow.months(from: from, to: to, calendar: calendar)
        XCTAssertEqual(windows.first?.from, from.addingTimeInterval(-300))
        XCTAssertEqual(windows.last?.to, to.addingTimeInterval(300))
        for i in 1..<windows.count { XCTAssertEqual(windows[i - 1].to, windows[i].from) }
        XCTAssertTrue(windows.allSatisfy { $0.to > $0.from })
    }
}

private final class WindowProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0, maximum = 0
    func begin() { lock.withLock { count += 1; maximum = max(maximum, count) } }
    func end() { lock.withLock { count -= 1 } }
    var active: Int { lock.withLock { count } }
    var peak: Int { lock.withLock { maximum } }
}
#endif
