import HealthKit
import XCTest
@testable import HealthSync

private final class SchedulingSource: HealthSource, @unchecked Sendable {
    let base = ScriptedSource()
    private let lock = NSLock()
    private var historyActive = 0
    private var detailActive = 0
    private var maximumHistory = 0
    private var maximumDetails = 0
    private var queryLimit = 80
    private var limits: [Int] = []
    var failDaily = false
    var isAvailable: Bool { true }
    func requestAuthorization(scope: SyncScope) async throws {}
    func observeWorkouts(onChange: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void) {}
    func workouts(from: Date, to: Date) async throws -> [Record] { try await base.workouts(from: from, to: to) }
    func anchoredPage(_ type: SyncType, anchor: Data?, limit: Int) async throws -> AnchoredPage { try await base.anchoredPage(type, anchor: anchor, limit: limit) }
    func workoutIndex() async throws -> [WorkoutRef] { try await base.workoutIndex() }
    func earliestDailyDate() async throws -> Date? { Date().addingTimeInterval(-2 * 86_400) }
    func dailyContext(from: Date, to: Date) async throws -> [Record] {
        try await historyRead()
        if failDaily { throw ScriptedSource.HealthKitFailure() }
        return try await base.dailyContext(from: from, to: to)
    }
    func hourlySeries(from: Date, to: Date) async throws -> [Record] {
        try await historyRead()
        return try await base.hourlySeries(from: from, to: to)
    }
    private func historyRead() async throws {
        lock.withLock { historyActive += 1; maximumHistory = max(maximumHistory, historyActive) }
        defer { lock.withLock { historyActive -= 1 } }
        try await Task.sleep(for: .milliseconds(30))
    }
    func workoutDetail(id: String, gen: Int64) async throws -> [Record]? {
        lock.withLock { detailActive += 1; maximumDetails = max(maximumDetails, detailActive) }
        defer { lock.withLock { detailActive -= 1 } }
        try await Task.sleep(for: .milliseconds(10))
        return try await base.workoutDetail(id: id, gen: gen)
    }
    var queryConcurrency: Int { lock.withLock { queryLimit } }
    func setQueryConcurrency(_ n: Int) { lock.withLock { queryLimit = n; limits.append(n) } }
    var snapshot: (history: Int, details: Int, limits: [Int], active: Int) { lock.withLock { (maximumHistory, maximumDetails, limits, detailActive) } }
}

final class SyncSchedulingTests: XCTestCase {
    private var scope: SyncScope {
        SyncScope(types: [SyncType(id: HealthTypes.workoutId, kind: .workout, sampleType: nil)], workoutQuantities: [],
                  dailyMetrics: [DailyMetric(key: "rings", kind: .rings)],
                  hourly: [HourlyMetric(name: "StepCount", type: HKQuantityType(.stepCount), unit: .count(), unitLabel: "count", cumulative: true, cols: ["v"])])
    }
    private func fixture() -> SchedulingSource {
        let s = SchedulingSource()
        s.base.daily = [["k": "day", "day": "2026-10-03", "m": .object(["steps": 10000])]]
        s.base.hourly = [["k": "hs", "st": "StepCount", "t": .array([1]), "v": .array([10])]]
        for i in 0..<60 {
            let id = "w\(i)"
            s.base.index.append(WorkoutRef(id: id, start: Date()))
            s.base.details[id] = [["k": "ws", "wid": .string(id), "st": "HeartRate", "gen": 1, "t": .array([1]), "v": .array([140])], WorkoutRecords.mark(wid: id, gen: 1, expected: ["HeartRate": 1])]
        }
        return s
    }
    func testHistoryReadsDoNotOverlapAndAllWorkoutsComplete() async throws {
        let s = fixture(), up = RecordingUploader()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let box = Outbox(root: root)
        var config = SyncEngine.Config()
        config.detailReadConcurrency = 4
        config.serializeHistoryReads = true
        config.detailQueryMaxConcurrency = 32
        let engine = SyncEngine(source: s, uploader: up, outbox: box, scope: scope, config: config)
        let outcome = try await engine.run()
        XCTAssertEqual(outcome, .finished)
        XCTAssertEqual(s.snapshot.history, 1)
        XCTAssertLessThanOrEqual(s.snapshot.details, 4)
        XCTAssertEqual(Set(s.base.detailReads), Set(s.base.index.map(\.id)))
        XCTAssertEqual(box.state.detailsDone.count, 60)
        XCTAssertNotNil(box.state.dailyFullAt)
        XCTAssertNotNil(box.state.hourlyAt)
        XCTAssertEqual(s.queryConcurrency, 80, "restore the source's query limit after detail reading")
        XCTAssertTrue(s.snapshot.limits.dropLast().allSatisfy { $0 <= 32 })
    }
    func testFailedDetailUploadDrainsPrefetchAndCanResume() async throws {
        let s = fixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let box = Outbox(root: root)
        var config = SyncEngine.Config()
        config.detailGroupSize = 4
        let engine = SyncEngine(source: s, uploader: DetailFailUploader(), outbox: box, scope: scope, config: config)
        do { _ = try await engine.run(); XCTFail("offline upload must fail") } catch is DetailFailUploader.Offline {}
        XCTAssertEqual(s.snapshot.active, 0, "prefetched HealthKit reads must stop before the run returns")
        XCTAssertEqual(s.queryConcurrency, 80)
        XCTAssertFalse(box.pending().isEmpty)
        let resumed = SyncEngine(source: s, uploader: RecordingUploader(), outbox: box, scope: scope, config: config)
        let outcome = try await resumed.run()
        XCTAssertEqual(outcome, .finished)
        XCTAssertEqual(box.state.detailsDone.count, 60)
        XCTAssertTrue(box.pending().isEmpty)
    }

    func testDailyFailureStillUploadsHourlyHistoryAndWorkoutDetails() async throws {
        let s = fixture(), up = RecordingUploader()
        s.failDaily = true
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let box = Outbox(root: root)
        let engine = SyncEngine(source: s, uploader: up, outbox: box, scope: scope)
        do { _ = try await engine.run(); XCTFail("daily failure must be reported") } catch is ScriptedSource.HealthKitFailure {}
        XCTAssertNil(box.state.dailyFullAt)
        XCTAssertNotNil(box.state.hourlyAt)
        XCTAssertEqual(box.state.detailsDone.count, 60)
    }
}

private struct DetailFailUploader: Uploader {
    struct Offline: Error {}
    func upload(batchId: String, gz: Data, sha256: String, typeId: String) async throws {
        if typeId == HealthTypes.streamId { throw Offline() }
    }
}
