import HealthKit
import XCTest
@testable import HealthSync

private final class HistorySchedulingSource: HealthSource, @unchecked Sendable {
    let base = ScriptedSource()
    private let lock = NSLock()
    private var finished = 0
    private var activeDetails = 0
    private var historyDetails = 0
    private var boostedDetails = 0
    var failDaily = false
    var isAvailable: Bool { true }
    func requestAuthorization(scope: SyncScope) async throws {}
    func observeWorkouts(onChange: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void) {}
    func workouts(from: Date, to: Date) async throws -> [Record] { try await base.workouts(from: from, to: to) }
    func anchoredPage(_ type: SyncType, anchor: Data?, limit: Int) async throws -> AnchoredPage { try await base.anchoredPage(type, anchor: anchor, limit: limit) }
    func workoutIndex() async throws -> [WorkoutRef] { try await base.workoutIndex() }
    func earliestDailyDate() async throws -> Date? { Date().addingTimeInterval(-86400) }
    func dailyContext(from: Date, to: Date) async throws -> [Record] {
        defer { lock.withLock { finished += 1 } }
        try await Task.sleep(for: .milliseconds(60))
        if failDaily { throw ScriptedSource.HealthKitFailure() }
        return try await base.dailyContext(from: from, to: to)
    }
    func hourlySeries(from: Date, to: Date) async throws -> [Record] {
        defer { lock.withLock { finished += 1 } }
        try await Task.sleep(for: .milliseconds(100))
        return try await base.hourlySeries(from: from, to: to)
    }
    func workoutDetail(id: String, gen: Int64) async throws -> [Record]? {
        lock.withLock {
            activeDetails += 1
            if finished < 2 { historyDetails = max(historyDetails, activeDetails) }
            else { boostedDetails = max(boostedDetails, activeDetails) }
        }
        defer { lock.withLock { activeDetails -= 1 } }
        try await Task.sleep(for: .milliseconds(12))
        return try await base.workoutDetail(id: id, gen: gen)
    }
    var peaks: (during: Int, after: Int) { lock.withLock { (historyDetails, boostedDetails) } }
}

final class HistorySchedulingTests: XCTestCase {
    private var scope: SyncScope {
        SyncScope(types: [SyncType(id: HealthTypes.workoutId, kind: .workout, sampleType: nil)], workoutQuantities: [],
                  dailyMetrics: [DailyMetric(key: "rings", kind: .rings)],
                  hourly: [HourlyMetric(name: "StepCount", type: HKQuantityType(.stepCount), unit: .count(), unitLabel: "count", cumulative: true, cols: ["sum"])])
    }
    private func fixture() -> HistorySchedulingSource {
        let source = HistorySchedulingSource()
        source.base.daily = [["k": "day", "day": "2026-10-04", "m": .object(["steps": 10000])]]
        source.base.hourly = [["k": "hs", "st": "StepCount", "t": .array([1]), "v": .array([10])]]
        for i in 0..<144 {
            let id = "w\(i)"
            source.base.index.append(WorkoutRef(id: id, start: Date()))
            source.base.details[id] = [["k": "ws", "wid": .string(id), "st": "HeartRate", "gen": 1, "t": .array([1]), "v": .array([140])], WorkoutRecords.mark(wid: id, gen: 1, expected: ["HeartRate": 1])]
        }
        return source
    }
    func testCapsIncreaseOnlyAfterBothHistoryLanesFinish() async throws {
        for cap in [4, 8] {
            let schedule = HistoryReadSchedule(normalLimit: 24, historyLimit: cap)
            XCTAssertEqual(schedule.gate.currentLimit, cap)
            schedule.finishedHistoryLane()
            XCTAssertEqual(schedule.gate.currentLimit, cap)
            schedule.finishedHistoryLane()
            XCTAssertEqual(schedule.gate.currentLimit, 24)
            let source = fixture()
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let box = Outbox(root: root)
            var config = SyncEngine.Config()
            config.historyWorkoutReadLimit = cap
            let engine = SyncEngine(source: source, uploader: RecordingUploader(), outbox: box, scope: scope, config: config)
            let outcome = try await engine.run()
            XCTAssertEqual(outcome, .finished)
            XCTAssertGreaterThan(source.peaks.during, 0)
            XCTAssertLessThanOrEqual(source.peaks.during, cap)
            XCTAssertGreaterThan(source.peaks.after, cap)
            XCTAssertEqual(box.state.detailsDone.count, 144)
            XCTAssertTrue(box.pending().isEmpty)
            XCTAssertNotNil(box.state.dailyFullAt)
            XCTAssertNotNil(box.state.hourlyAt)
        }
    }
    func testHistoryFirstPreventsDetailOverlapAndCompletesAllRecords() async throws {
        let source = fixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let box = Outbox(root: root)
        var config = SyncEngine.Config()
        config.historyBeforeDetails = true
        let engine = SyncEngine(source: source, uploader: RecordingUploader(), outbox: box, scope: scope, config: config)
        let outcome = try await engine.run()
        XCTAssertEqual(outcome, .finished)
        XCTAssertEqual(source.peaks.during, 0)
        XCTAssertGreaterThan(source.peaks.after, 8)
        XCTAssertEqual(box.state.detailsDone.count, 144)
        XCTAssertTrue(box.pending().isEmpty)
    }
    func testFailedDailyLaneDoesNotPreventOtherWorkOrLeaveCapStuck() async throws {
        let source = fixture()
        source.failDaily = true
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let box = Outbox(root: root)
        var config = SyncEngine.Config()
        config.historyWorkoutReadLimit = 4
        let engine = SyncEngine(source: source, uploader: RecordingUploader(), outbox: box, scope: scope, config: config)
        do { _ = try await engine.run(); XCTFail("daily failure must be reported") } catch is ScriptedSource.HealthKitFailure {}
        XCTAssertNil(box.state.dailyFullAt)
        XCTAssertNotNil(box.state.hourlyAt)
        XCTAssertEqual(box.state.detailsDone.count, 144)
        XCTAssertGreaterThan(source.peaks.after, 4)
    }

    func testCancellationDuringHistoryFirstStopsBeforeDetailReads() async throws {
        let source = fixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let box = Outbox(root: root)
        var config = SyncEngine.Config()
        config.historyBeforeDetails = true
        let engine = SyncEngine(source: source, uploader: RecordingUploader(), outbox: box, scope: scope, config: config)
        let task = Task { try await engine.run() }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        do { _ = try await task.value; XCTFail("cancellation must propagate") } catch is CancellationError {}
        XCTAssertEqual(source.peaks.during, 0)
        XCTAssertEqual(source.peaks.after, 0)
        XCTAssertTrue(box.state.detailsDone.isEmpty)
    }
}
