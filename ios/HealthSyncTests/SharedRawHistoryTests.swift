import XCTest
@testable import HealthSync

final class SharedRawHistoryTests: XCTestCase {
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

    func testNewSessionsSeeUpdatedReadingsAndChildTasksShare() async throws {
        let key = key, value = value
        let first = try await SharedRawHistory.withFreshCache {
            let cache = try XCTUnwrap(SharedRawHistory.cache)
            async let a = cache.value(key) { value }
            async let b = cache.value(key) { value }
            _ = try await (a, b)
            let builds = await cache.builds
            XCTAssertEqual(builds, 1)
            return cache
        }
        XCTAssertNil(SharedRawHistory.cache)
        let newer = RawHistorySummary(daily: ["sum": [("1970-01-01", 456)]], hourly: [])
        try await SharedRawHistory.withFreshCache {
            let cache = try XCTUnwrap(SharedRawHistory.cache)
            XCTAssertFalse(cache === first)
            let result = try await cache.value(key) { newer }
            XCTAssertEqual(result.daily["sum"]?.first?.1, 456)
        }
        XCTAssertNil(SharedRawHistory.cache)
    }

    func testCancellationStopsSharedBuildAndLeavesNextSessionFresh() async throws {
        let key = key
        let task = Task {
            try await SharedRawHistory.withFreshCache {
                let cache = try XCTUnwrap(SharedRawHistory.cache)
                return try await cache.value(key) {
                    try await Task.sleep(for: .seconds(30))
                    return RawHistorySummary(daily: [:], hourly: [])
                }
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        do { _ = try await task.value; XCTFail("cancelled shared build must stop") } catch is CancellationError {}
        try await SharedRawHistory.withFreshCache {
            let cache = try XCTUnwrap(SharedRawHistory.cache)
            let result = try await cache.value(key) { RawHistorySummary(daily: ["sum": [("day", 789)]], hourly: []) }
            XCTAssertEqual(result.daily["sum"]?.first?.1, 789)
        }
    }
}
