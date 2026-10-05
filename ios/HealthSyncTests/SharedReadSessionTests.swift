import HealthKit
import XCTest
@testable import HealthSync

private final class SessionSource: HealthSource, @unchecked Sendable {
    var isAvailable: Bool { true }
    var latest = 100.0
    var failAfterRead = false
    var sessions: [RawHistoryCache] = []
    var values: [Double] = []
    func requestAuthorization(scope: SyncScope) async throws {}
    func observeWorkouts(onChange: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void) {}
    func workouts(from: Date, to: Date) async throws -> [Record] { [] }
    func anchoredPage(_ type: SyncType, anchor: Data?, limit: Int) async throws -> AnchoredPage {
        AnchoredPage(records: [], newAnchor: anchor, objectCount: 0)
    }
    func workoutIndex() async throws -> [WorkoutRef] { [] }
    func workoutDetail(id: String, gen: Int64) async throws -> [Record]? { nil }
    func earliestDailyDate() async throws -> Date? { Date(timeIntervalSince1970: 1_759_536_000) }
    func dailyContext(from: Date, to: Date) async throws -> [Record] {
        let cache = try XCTUnwrap(SharedRawHistory.cache, "both engine entry points must establish a read session")
        let key = RawHistoryKey(type: "steps", unit: "count", scale: 1, from: .distantPast, to: .distantFuture, calendar: "gregorian", timeZone: "UTC")
        let latest = latest
        let result = try await cache.value(key) { RawHistorySummary(daily: ["sum": [("day", latest)]], hourly: []) }
        let value = try XCTUnwrap(result.daily["sum"]?.first?.1)
        sessions.append(cache)
        values.append(value)
        if failAfterRead { throw ScriptedSource.HealthKitFailure() }
        return [["k": "day", "day": .string(SleepNights.dayKey(from, calendar: Calendar.current)), "m": .object(["steps": .double(value)])]]
    }
}

final class SharedReadSessionTests: XCTestCase {
    func testSameEngineFullThenIncrementalReadsNewValues() async throws {
        let source = SessionSource(), box = Outbox(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let scope = SyncScope(types: [SyncType(id: HealthTypes.workoutId, kind: .workout, sampleType: nil)], workoutQuantities: [], dailyMetrics: [DailyMetric(key: "rings", kind: .rings)])
        var config = SyncEngine.Config()
        config.minRefresh = 0
        config.dailyFullEvery = 0
        let at = Date(timeIntervalSince1970: 1_759_708_800)
        let engine = SyncEngine(source: source, uploader: RecordingUploader(), outbox: box, scope: scope, config: config, now: { at })
        let outcome = try await engine.run()
        XCTAssertEqual(outcome, .finished)
        let first = try XCTUnwrap(source.sessions.first)
        source.latest = 400
        try await engine.runWorkoutChanges(deadline: at.addingTimeInterval(3600))
        let last = try XCTUnwrap(source.sessions.last)
        XCTAssertFalse(first === last)
        XCTAssertEqual(source.values.last, 400)
        XCTAssertNil(SharedRawHistory.cache)
    }

    func testFailedRunCannotPoisonRetry() async throws {
        let source = SessionSource(), box = Outbox(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let scope = SyncScope(types: [], workoutQuantities: [], dailyMetrics: [DailyMetric(key: "rings", kind: .rings)])
        let at = Date(timeIntervalSince1970: 1_759_708_800)
        let engine = SyncEngine(source: source, uploader: RecordingUploader(), outbox: box, scope: scope, now: { at })
        source.failAfterRead = true
        do { _ = try await engine.run(); XCTFail("fixture must fail after populating its cache") } catch is ScriptedSource.HealthKitFailure {}
        let first = try XCTUnwrap(source.sessions.first)
        source.latest = 500
        source.failAfterRead = false
        let outcome = try await engine.run()
        XCTAssertEqual(outcome, .finished)
        XCTAssertFalse(first === source.sessions.last)
        XCTAssertEqual(source.values.last, 500)
        XCTAssertNil(SharedRawHistory.cache)
    }
}
