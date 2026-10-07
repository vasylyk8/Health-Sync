import HealthKit
import XCTest
@testable import HealthSync

/// Scriptable in-memory HealthKit stand-in.
final class ScriptedSource: HealthSource, @unchecked Sendable {
    var recent: [Record] = []
    var pages: [AnchoredPage] = []
    var index: [WorkoutRef] = []
    /// Raw data records by workout id. A missing id means the workout no longer exists.
    var details: [String: [Record]] = [:]
    var daily: [Record] = []
    var eventPages: [AnchoredPage] = []
    var hourly: [Record] = []
    var hourlyNote: String?
    private(set) var hourlyRanges: [(from: Date, to: Date)] = []
    var earliestDaily: Date?
    /// Steps that throw: "recent", "anchored", "index", "daily", "detail".
    var failing: Set<String> = []
    struct HealthKitFailure: Error {}
    private(set) var anchorsSeen: [Data?] = []
    private(set) var detailReads: [String] = []
    private(set) var dailyRanges: [(from: Date, to: Date)] = []
    private let lock = NSLock()

    var isAvailable: Bool { true }
    func requestAuthorization(scope: SyncScope) async throws {}

    func workouts(from: Date, to: Date) async throws -> [Record] {
        if failing.contains("recent") { throw HealthKitFailure() }
        return recent
    }

    func anchoredPage(_ type: SyncType, anchor: Data?, limit: Int) async throws -> AnchoredPage {
        lock.lock(); defer { lock.unlock() }
        if failing.contains("anchored") { throw HealthKitFailure() }
        anchorsSeen.append(anchor)
        if type.kind == .events {
            guard !eventPages.isEmpty else { return AnchoredPage(records: [], newAnchor: anchor, objectCount: 0) }
            return eventPages.removeFirst()
        }
        guard !pages.isEmpty else { return AnchoredPage(records: [], newAnchor: anchor, objectCount: 0) }
        return pages.removeFirst()
    }

    func workoutIndex() async throws -> [WorkoutRef] {
        if failing.contains("index") { throw HealthKitFailure() }
        return index
    }

    func workoutDetail(id: String, gen: Int64) async throws -> [Record]? {
        lock.lock(); defer { lock.unlock() }
        if failing.contains("detail") { throw HealthKitFailure() }
        detailReads.append(id)
        return details[id]
    }

    func dailyContext(from: Date, to: Date) async throws -> [Record] {
        lock.lock(); defer { lock.unlock() }
        if failing.contains("daily") { throw HealthKitFailure() }
        dailyRanges.append((from, to))
        return daily
    }

    func hourlySeries(from: Date, to: Date) async throws -> [Record] {
        lock.lock(); defer { lock.unlock() }
        hourlyRanges.append((from, to))
        return hourly
    }

    func hourlyDiagnosticNote() -> String? { hourlyNote }

    func earliestDailyDate() async throws -> Date? { earliestDaily }
    func observeWorkouts(onChange: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void) {}
}

final class RecordingUploader: Uploader, @unchecked Sendable {
    var uploaded: [(id: String, type: String, header: [String: Any], records: Int)] = []
    var failAfter: Int?
    private let lock = NSLock()
    struct Offline: Error {}

    func upload(batchId: String, gz: Data, sha256: String, typeId: String) async throws {
        try locked { if let n = failAfter, uploaded.count >= n { throw Offline() } }
        let lines = String(data: Gzip.decompress(gz)!, encoding: .utf8)!.split(separator: "\n")
        let header = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as! [String: Any]
        locked { uploaded.append((batchId, typeId, header, lines.count - 1)) }
    }

    var modes: [String] { uploaded.map { $0.header["mode"] as! String } }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }
}

final class SyncEngineTests: XCTestCase {
    let workoutType = SyncType(id: HealthTypes.workoutId, kind: .workout, sampleType: nil)
    var scope: SyncScope { SyncScope(types: [workoutType], workoutQuantities: [], dailyMetrics: [DailyMetric(key: "rings", kind: .rings)]) }
    var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    private func workout(_ id: String) -> Record { ["k": "w", "id": .string(id), "s": 1, "e": 2, "act": 37, "actName": "Running"] }

    private func detail(_ id: String) -> [Record] {
        [["k": "ws", "wid": .string(id), "st": "HeartRate", "gen": 5, "t": .array([1, 2]), "v": .array([140, 141])],
         WorkoutRecords.mark(wid: id, gen: 5, expected: ["HeartRate": 2])]
    }

    private func makeEngine(_ source: ScriptedSource, _ up: RecordingUploader, outbox: Outbox? = nil, config: SyncEngine.Config = .init()) -> (SyncEngine, Outbox) {
        let box = outbox ?? Outbox(root: root)
        return (SyncEngine(source: source, uploader: up, outbox: box, scope: scope, config: config), box)
    }

    func testOrderRecentDailyHistoryDetailsThenStatus() async throws {
        let source = ScriptedSource()
        source.recent = [workout("W2")]
        source.earliestDaily = Date(timeIntervalSinceNow: -3 * 86_400)
        source.daily = [["k": "day", "day": "2024-06-20", "m": .object(["restingHr": 51])]]
        source.pages = [AnchoredPage(records: [workout("W2"), workout("W1")], newAnchor: Data("A1".utf8), objectCount: 2)]
        source.index = [WorkoutRef(id: "W2", start: Date()), WorkoutRef(id: "W1", start: Date(timeIntervalSinceNow: -100))]
        source.details = ["W2": detail("W2"), "W1": detail("W1")]
        let up = RecordingUploader()
        var config = SyncEngine.Config()
        config.workoutPageLimit = 2
        let (engine, box) = makeEngine(source, up, config: config)
        let outcome = try await engine.run()
        XCTAssertEqual(outcome, .finished)
        // Daily history runs alongside the workout steps, so it may land anywhere between recent and status;
        // the workout uploads keep their order.
        // Daily history and the workout summaries run alongside the raw data, so they may land anywhere
        // between the recent workouts (first) and the status batch (last).
        XCTAssertEqual(up.modes.first, "recent")
        XCTAssertEqual(up.modes.last, "status")
        XCTAssertEqual(up.modes.sorted(), ["anchored", "recent", "stats", "status", "workoutdata"], "both workouts' raw data go in one upload")
        XCTAssertEqual(up.uploaded.filter { $0.type == HealthTypes.workoutId }.map { $0.header["mode"] as? String }, ["recent", "anchored"])
        // The first page was full (2 of limit 2), so not caught up; the second was empty and is
        // reported in the status batch instead of its own upload.
        XCTAssertEqual(up.uploaded.first { $0.header["mode"] as? String == "anchored" }?.header["caughtUp"] as? Bool, false)
        XCTAssertEqual(up.uploaded[0].header["schema"] as? Int, 2)
        XCTAssertEqual(box.state.anchors[workoutType.id], Data("A1".utf8))
        XCTAssertTrue(box.state.caughtUp.contains(workoutType.id))
        XCTAssertTrue(box.state.recentDone.contains(workoutType.id))
        XCTAssertNotNil(box.state.dailyFullAt)
        XCTAssertEqual(box.state.detailsDone, ["W1", "W2"])
        XCTAssertEqual(box.state.workoutTotal, 2)
        XCTAssertTrue(box.pending().isEmpty)
        let seqs = up.uploaded.filter { $0.type == workoutType.id }.map { $0.header["seq"] as! Int }
        XCTAssertEqual(seqs, seqs.sorted())
        XCTAssertEqual(Set(seqs).count, seqs.count)
        let p = await engine.progress
        XCTAssertTrue(p.historyComplete)
        XCTAssertEqual(p.fraction, 1)
        XCTAssertEqual(Set(source.detailReads), ["W2", "W1"])
        XCTAssertEqual(up.uploaded.first { $0.type == HealthTypes.streamId }?.records, 4, "two streams and two markers")
    }

    func testDetailBatchesCarryStreamsAndTheMarker() async throws {
        let source = ScriptedSource()
        source.index = [WorkoutRef(id: "W1", start: Date())]
        source.details = ["W1": detail("W1")]
        let up = RecordingUploader()
        let (engine, _) = makeEngine(source, up)
        _ = try await engine.run()
        let d = try XCTUnwrap(up.uploaded.first { $0.type == HealthTypes.streamId })
        XCTAssertEqual(d.header["mode"] as? String, "workoutdata")
        XCTAssertEqual(d.records, 2, "one stream chunk and the closing marker")
    }

    private func manyWorkouts(_ n: Int) -> ScriptedSource {
        let source = ScriptedSource()
        for i in 0..<n {
            let id = "W\(String(format: "%04d", i))"
            source.index.append(WorkoutRef(id: id, start: Date(timeIntervalSinceNow: -Double(i) * 60)))
            source.details[id] = detail(id)
        }
        return source
    }

    func testManyWorkoutsShareUploadsInOrder() async throws {
        let source = manyWorkouts(60)
        let up = RecordingUploader()
        var config = SyncEngine.Config()
        config.detailGroupSize = 24
        let (engine, box) = makeEngine(source, up, config: config)
        _ = try await engine.run()
        let streams = up.uploaded.filter { $0.type == HealthTypes.streamId }
        XCTAssertEqual(streams.count, 3, "60 workouts in groups of 24")
        XCTAssertEqual(streams.map { $0.records }, [48, 48, 24])
        XCTAssertEqual(box.state.detailsDone.count, 60)
        XCTAssertEqual(Set(source.detailReads).count, 60)
        // Groups upload at the same time, so they may arrive in any order; each has its own sequence number.
        let seqs = streams.map { $0.header["seq"] as! Int }
        XCTAssertEqual(Set(seqs).count, seqs.count)
        XCTAssertTrue(box.pending().isEmpty)
    }

    func testOneGroupAtATimeStillWorks() async throws {
        let source = manyWorkouts(60)
        let up = RecordingUploader()
        var config = SyncEngine.Config()
        config.detailGroupSize = 24
        config.detailGroupsUploading = 1
        let (engine, box) = makeEngine(source, up, config: config)
        _ = try await engine.run()
        let streams = up.uploaded.filter { $0.type == HealthTypes.streamId }
        XCTAssertEqual(streams.map { $0.records }, [48, 48, 24])
        let seqs = streams.map { $0.header["seq"] as! Int }
        XCTAssertEqual(seqs, seqs.sorted())
        XCTAssertEqual(box.state.detailsDone.count, 60)
        XCTAssertTrue(box.pending().isEmpty)
    }

    func testBigGroupsAreSentAsSeveralPartsAndRecordedOnce() async throws {
        let source = manyWorkouts(60)
        let up = RecordingUploader()
        var config = SyncEngine.Config()
        config.detailGroupSize = 24
        config.detailPartBytes = 1 // one line per part
        let (engine, box) = makeEngine(source, up, config: config)
        _ = try await engine.run()
        let streams = up.uploaded.filter { $0.type == HealthTypes.streamId }
        XCTAssertGreaterThan(streams.count, 3, "groups split into parts")
        XCTAssertEqual(streams.reduce(0) { $0 + $1.records }, 120, "every line sent once")
        XCTAssertEqual(Set(streams.map(\.id)).count, streams.count)
        let seqs = streams.map { $0.header["seq"] as! Int }
        XCTAssertEqual(Set(seqs).count, seqs.count, "no sequence number used twice")
        XCTAssertEqual(box.state.detailsDone.count, 60)
        XCTAssertTrue(box.pending().isEmpty)

        // A second run sends nothing again.
        let before = up.uploaded.count
        _ = try await engine.run()
        XCTAssertEqual(up.uploaded.filter { $0.type == HealthTypes.streamId }.count, streams.count)
        XCTAssertGreaterThanOrEqual(up.uploaded.count, before)
    }

    func testInterruptedGroupedUploadResumesWithoutLosingWorkouts() async throws {
        let source = manyWorkouts(60)
        source.earliestDaily = Date() // today only: the daily context is a single batch
        let up = RecordingUploader()
        up.failAfter = 2 // the daily batch and the first group get through, then the network drops
        var config = SyncEngine.Config()
        config.detailGroupSize = 24
        let (engine, box) = makeEngine(source, up, config: config)
        do {
            _ = try await engine.run()
            XCTFail("expected offline error")
        } catch is RecordingUploader.Offline {}
        let done = box.state.detailsDone.count
        XCTAssertGreaterThan(done, 0)
        XCTAssertLessThan(done, 60)
        XCTAssertEqual(done % 24, 0, "a group is recorded only after its whole upload was accepted")
        XCTAssertFalse(box.pending().isEmpty, "the group that failed stays queued")

        up.failAfter = nil
        let (engine2, _) = makeEngine(source, up, outbox: Outbox(root: root), config: config)
        _ = try await engine2.run()
        let reloaded = Outbox(root: root)
        XCTAssertEqual(reloaded.state.detailsDone.count, 60)
        XCTAssertTrue(reloaded.pending().isEmpty)
    }

    /// A queued raw-data entry with several parts, as a big group of workouts produces.
    private func enqueueParts(_ outbox: Outbox, count: Int, workoutId: String) throws -> [String] {
        let batches = (0..<count).map { i in
            Batch(id: "part-\(i)-\(UUID().uuidString.lowercased())", gz: Gzip.compress(Data(#"{"kind":"header","mode":"workoutdata"}"#.utf8)))
        }
        _ = try outbox.enqueue(typeId: HealthTypes.streamId, batches: batches, anchor: nil, completes: .detailsDone([workoutId]))
        return batches.map(\.id)
    }

    func testPartsOfARawDataUploadAreAllSentAndRecordedOnce() async throws {
        let up = RecordingUploader()
        let (engine, box) = makeEngine(ScriptedSource(), up)
        let ids = try enqueueParts(box, count: 7, workoutId: "W1")
        try await engine.flush()
        XCTAssertEqual(Set(up.uploaded.map(\.id)), Set(ids))
        XCTAssertEqual(up.uploaded.count, 7, "each part exactly once")
        XCTAssertEqual(box.state.detailsDone, ["W1"])
        XCTAssertTrue(box.pending().isEmpty)
    }

    func testFailedPartIsRetriedWithoutResendingTheOthers() async throws {
        let up = RecordingUploader()
        up.failAfter = 3
        let (engine, box) = makeEngine(ScriptedSource(), up)
        let ids = try enqueueParts(box, count: 7, workoutId: "W1")
        do {
            try await engine.flush()
            XCTFail("expected offline error")
        } catch is RecordingUploader.Offline {}
        XCTAssertTrue(box.state.detailsDone.isEmpty, "the group is not recorded until every part is accepted")
        XCTAssertFalse(box.pending().isEmpty)

        up.failAfter = nil
        try await engine.flush()
        XCTAssertEqual(Set(up.uploaded.map(\.id)), Set(ids))
        XCTAssertEqual(up.uploaded.count, 7, "parts accepted before the failure are not sent again")
        XCTAssertEqual(box.state.detailsDone, ["W1"])
        XCTAssertTrue(box.pending().isEmpty)
    }

    func testGroupsAreSmallWhenThereIsADeadline() async throws {
        let source = manyWorkouts(10)
        let up = RecordingUploader()
        let (engine, box) = makeEngine(source, up)
        _ = try await engine.run(deadline: Date(timeIntervalSinceNow: 60))
        XCTAssertEqual(box.state.detailsDone.count, 10)
        XCTAssertEqual(up.uploaded.filter { $0.type == HealthTypes.streamId }.count, 3, "groups of 4")
    }

    func testDetailsAreUploadedOnlyOnce() async throws {
        let source = ScriptedSource()
        source.index = [WorkoutRef(id: "W1", start: Date())]
        source.details = ["W1": detail("W1")]
        let up = RecordingUploader()
        let (engine, _) = makeEngine(source, up)
        _ = try await engine.run()
        _ = try await engine.run()
        XCTAssertEqual(source.detailReads, ["W1"])
        XCTAssertEqual(up.uploaded.filter { $0.type == HealthTypes.streamId }.count, 1)
    }

    func testWorkoutDetailsAreReadAgainAfterExtractionLogicChanges() async throws {
        let source = ScriptedSource()
        source.index = [WorkoutRef(id: "W1", start: Date())]
        source.details = ["W1": detail("W1")]
        let box = Outbox(root: root)
        try box.update {
            $0.detailsDone = ["W1"]
            $0.detailVersion = 0
        }
        let (engine, _) = makeEngine(source, RecordingUploader(), outbox: box)
        _ = try await engine.run()
        XCTAssertEqual(source.detailReads, ["W1"])
        XCTAssertEqual(box.state.detailVersion, SyncEngine.detailVersion)
        XCTAssertEqual(box.state.detailsDone, ["W1"])
    }

    func testWorkoutsWithoutRawDataOrThatVanishedAreMarkedDoneWithoutUpload() async throws {
        let source = ScriptedSource()
        source.index = [WorkoutRef(id: "MANUAL", start: Date()), WorkoutRef(id: "GONE", start: Date())]
        source.details = ["MANUAL": [WorkoutRecords.mark(wid: "MANUAL", gen: 1, expected: [:])]]
        let up = RecordingUploader()
        let (engine, box) = makeEngine(source, up)
        _ = try await engine.run()
        XCTAssertEqual(box.state.detailsDone, ["MANUAL", "GONE"])
        XCTAssertFalse(up.uploaded.contains { $0.type == HealthTypes.streamId })
    }

    func testOfflineNeverAdvancesAnchorAndResumes() async throws {
        let source = ScriptedSource()
        source.pages = [AnchoredPage(records: [workout("W1")], newAnchor: Data("A1".utf8), objectCount: 1)]
        source.index = [WorkoutRef(id: "W1", start: Date())]
        source.details = ["W1": detail("W1")]
        let up = RecordingUploader()
        up.failAfter = 0 // the network is down from the start
        let (engine, box) = makeEngine(source, up)
        do {
            _ = try await engine.run()
            XCTFail("expected offline error")
        } catch is RecordingUploader.Offline {}
        XCTAssertNil(box.state.anchors[workoutType.id], "anchor must not move before the server has the data")
        XCTAssertFalse(box.pending().isEmpty)

        // The app restarts later with the network back: the queued batches are re-sent and committed.
        up.failAfter = nil
        source.pages = [AnchoredPage(records: [workout("W1")], newAnchor: Data("A1".utf8), objectCount: 1)]
        let (engine2, _) = makeEngine(source, up, outbox: Outbox(root: root))
        _ = try await engine2.run()
        let reloaded = Outbox(root: root)
        XCTAssertTrue(reloaded.pending().isEmpty)
        XCTAssertTrue(reloaded.state.caughtUp.contains(workoutType.id))
        XCTAssertEqual(reloaded.state.detailsDone, ["W1"])
    }

    func testOneFailingPhaseDoesNotStopTheOthers() async throws {
        let source = ScriptedSource()
        source.failing = ["daily"]
        source.pages = [AnchoredPage(records: [workout("W1")], newAnchor: Data("A1".utf8), objectCount: 1)]
        source.index = [WorkoutRef(id: "W1", start: Date())]
        source.details = ["W1": detail("W1")]
        let up = RecordingUploader()
        let (engine, box) = makeEngine(source, up)
        do {
            _ = try await engine.run()
            XCTFail("the failing phase should make the run report an error")
        } catch is ScriptedSource.HealthKitFailure {}
        XCTAssertNil(box.state.lastSyncAt, "the run is not recorded as complete, so it is retried")
        XCTAssertEqual(box.state.detailsDone, ["W1"], "workouts still synced")
        XCTAssertTrue(box.state.caughtUp.contains(workoutType.id))
        XCTAssertNil(box.state.dailyFullAt)
    }

    func testDailyContextIsFullOnceThenOnlyRecentDays() async throws {
        let source = ScriptedSource()
        source.earliestDaily = Date(timeIntervalSinceNow: -400 * 86_400)
        source.daily = [["k": "day", "day": "2024-06-20", "m": .object(["steps": 1])]]
        let up = RecordingUploader()
        var config = SyncEngine.Config()
        config.minRefresh = 0
        let (engine, _) = makeEngine(source, up, config: config)
        _ = try await engine.run()
        XCTAssertEqual(source.dailyRanges.count, 2, "400 days are read a year at a time")
        let first = try XCTUnwrap(source.dailyRanges.first)
        XCTAssertLessThan(first.from.timeIntervalSinceNow, -399 * 86_400)
        _ = try await engine.run()
        XCTAssertEqual(source.dailyRanges.count, 3)
        let last = try XCTUnwrap(source.dailyRanges.last)
        XCTAssertGreaterThan(last.from.timeIntervalSinceNow, -4 * 86_400 - 1, "later runs only recompute the last few days")
        let statsHeaders = up.uploaded.filter { $0.type == HealthTypes.dailyId }.map { $0.header }
        XCTAssertTrue(statsHeaders.allSatisfy { $0["mode"] as? String == "stats" && $0["window"] != nil })
    }

    func testUnchangedDailyRowsAreNotSentAgain() async throws {
        let source = ScriptedSource()
        source.earliestDaily = Date(timeIntervalSinceNow: -3 * 86_400)
        source.daily = [["k": "day", "day": "2024-06-20", "m": .object(["steps": 1])]]
        let up = RecordingUploader()
        var config = SyncEngine.Config()
        config.minRefresh = 0
        let (engine, _) = makeEngine(source, up, config: config)
        _ = try await engine.run()
        _ = try await engine.run()
        let sent = up.uploaded.filter { $0.type == HealthTypes.dailyId }.count
        _ = try await engine.run()
        XCTAssertEqual(up.uploaded.filter { $0.type == HealthTypes.dailyId }.count, sent, "the same rows are not uploaded a third time")
        source.daily = [["k": "day", "day": "2024-06-20", "m": .object(["steps": 2])]]
        _ = try await engine.run()
        XCTAssertEqual(up.uploaded.filter { $0.type == HealthTypes.dailyId }.count, sent + 1, "changed rows are sent")
    }

    func testDailyRowsAreNotReadAgainWithinTheRefreshInterval() async throws {
        let source = ScriptedSource()
        source.earliestDaily = Date(timeIntervalSinceNow: -3 * 86_400)
        let up = RecordingUploader()
        let (engine, _) = makeEngine(source, up)
        _ = try await engine.run()
        let reads = source.dailyRanges.count
        _ = try await engine.run()
        XCTAssertEqual(source.dailyRanges.count, reads)
    }

    private var hourlyScope: SyncScope {
        var s = scope
        s.hourly = [HourlyMetric(name: "HeartRate", type: HKQuantityType(.heartRate), unit: HKUnit.count().unitDivided(by: .minute()), unitLabel: "count/min", cumulative: false, cols: ["avg", "min", "max"])]
        return s
    }

    func testHourlySeriesUploadOnceThenAboutHourly() async throws {
        let source = ScriptedSource()
        source.earliestDaily = Date(timeIntervalSinceNow: -3 * 86_400)
        source.hourly = SeriesRecords.hourlyChunks(name: "HeartRate", unit: "count/min", hours: [HourBucket(t: 3_600_000, v: 60, lo: 50, hi: 70)])
        source.hourlyNote = "hourly fallback=HeartRate:sources"
        let up = RecordingUploader()
        let box = Outbox(root: root)
        let engine = SyncEngine(source: source, uploader: up, outbox: box, scope: hourlyScope)
        _ = try await engine.run()
        XCTAssertEqual(source.hourlyRanges.count, 1)
        XCTAssertEqual(up.uploaded.filter { $0.type == HealthTypes.hourlyId }.count, 1)
        let header = try XCTUnwrap(up.uploaded.first { $0.type == HealthTypes.hourlyId }?.header)
        XCTAssertEqual((header["perf"] as? [String: Any])?["note"] as? String, source.hourlyNote)
        XCTAssertNotNil(box.state.hourlyThrough)
        XCTAssertNotNil(box.state.hourlyAt)
        _ = try await engine.run()
        XCTAssertEqual(source.hourlyRanges.count, 1, "not read again within the hour")
    }

    func testHourlyHistoryIsReadAgainAfterAnAppUpdate() async throws {
        let source = ScriptedSource()
        source.earliestDaily = Date(timeIntervalSinceNow: -400 * 86_400)
        source.hourly = SeriesRecords.hourlyChunks(name: "HeartRate", unit: "count/min", hours: [HourBucket(t: 3_600_000, v: 60, lo: 50, hi: 70)])
        let box = Outbox(root: root)
        // An older app marked the history as uploaded (possibly with series missing).
        try box.update { $0.hourlyThrough = Date(); $0.hourlyAt = Date(); $0.hourlyVersion = 0 }
        let engine = SyncEngine(source: source, uploader: RecordingUploader(), outbox: box, scope: hourlyScope)
        _ = try await engine.run()
        let first = try XCTUnwrap(source.hourlyRanges.first)
        XCTAssertLessThan(first.from.timeIntervalSinceNow, -399 * 86_400, "the whole history is read again, not just the last days")
        XCTAssertEqual(box.state.hourlyVersion, SyncEngine.hourlyVersion)
    }

    private var glucose: EventType {
        EventType(name: "BloodGlucose", category: "devices", kind: .quantity, sampleType: HKQuantityType(.bloodGlucose),
                  unit: HKUnit.gramUnit(with: .milli).unitDivided(by: .literUnit(with: .deci)), unitLabel: "mg/dL", dense: true)
    }

    func testEventsAreOnlyReadForSwitchedOnCategories() async throws {
        var scope = self.scope
        scope.events = [glucose]
        let page = AnchoredPage(records: SeriesRecords.eventChunks(type: "BloodGlucose", unit: "mg/dL", source: "Dexcom", bundle: "com.dexcom", points: [EventPoint(start: 1_000, end: 1_000, v: 100)]), newAnchor: Data("G1".utf8), objectCount: 1)
        // Off: nothing is read or uploaded.
        let off = ScriptedSource()
        off.eventPages = [page]
        let up1 = RecordingUploader()
        let box1 = Outbox(root: root)
        _ = try await SyncEngine(source: off, uploader: up1, outbox: box1, scope: scope).run()
        XCTAssertTrue(up1.uploaded.filter { $0.type == "_events_devices" }.isEmpty)
        XCTAssertNil(box1.state.anchors["ev:BloodGlucose"])
        // On: uploaded under the category's batch type and the anchor is kept.
        let on = ScriptedSource()
        on.eventPages = [page]
        let up2 = RecordingUploader()
        let box2 = Outbox(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let engine = SyncEngine(source: on, uploader: up2, outbox: box2, scope: scope, categories: { ["core", "devices"] })
        _ = try await engine.run()
        XCTAssertEqual(up2.uploaded.filter { $0.type == "ev:BloodGlucose" }.count, 1)
        XCTAssertEqual(up2.uploaded.first { $0.type == "ev:BloodGlucose" }?.header["type"] as? String, "_events_devices")
        XCTAssertEqual(box2.state.anchors["ev:BloodGlucose"], Data("G1".utf8))
        // Switched off again: the position is forgotten so a later switch-on starts from the beginning.
        try await engine.categoryDisabled("devices")
        XCTAssertNil(box2.state.anchors["ev:BloodGlucose"])
        XCTAssertFalse(box2.state.caughtUp.contains("ev:BloodGlucose"))
    }

    func testAWakeForNewReadingsAlsoSendsEventsAndHourlyData() async throws {
        var scope = hourlyScope
        scope.events = [glucose]
        let source = ScriptedSource()
        source.earliestDaily = Date(timeIntervalSinceNow: -3 * 86_400)
        let up = RecordingUploader()
        let box = Outbox(root: root)
        let engine = SyncEngine(source: source, uploader: up, outbox: box, scope: scope, categories: { ["core", "devices"] })
        _ = try await engine.run()
        XCTAssertTrue(box.state.caughtUp.contains(workoutType.id))
        // A new glucose reading arrives and iOS wakes the app.
        source.eventPages = [AnchoredPage(records: SeriesRecords.eventChunks(type: "BloodGlucose", unit: "mg/dL", source: "Dexcom", bundle: "com.dexcom", points: [EventPoint(start: 9_000, end: 9_000, v: 110)]), newAnchor: Data("G2".utf8), objectCount: 1)]
        let before = up.uploaded.filter { $0.type == "ev:BloodGlucose" }.count
        try await engine.runWorkoutChanges(deadline: Date().addingTimeInterval(5))
        XCTAssertEqual(up.uploaded.filter { $0.type == "ev:BloodGlucose" }.count, before + 1, "the reading is sent without opening the app")
        XCTAssertEqual(box.state.anchors["ev:BloodGlucose"], Data("G2".utf8))
    }

    func testDailyHistoryIsReadAgainAfterAnAppUpdate() async throws {
        let source = ScriptedSource()
        source.earliestDaily = Date(timeIntervalSinceNow: -400 * 86_400)
        source.daily = [["k": "day", "day": "2024-06-20", "m": .object(["steps": 1])]]
        let box = Outbox(root: root)
        // An older app finished a (possibly incomplete) full pass a moment ago.
        try box.update { $0.dailyFullAt = Date(); $0.dailyVersion = 0 }
        let (engine, _) = makeEngine(source, RecordingUploader(), outbox: box)
        _ = try await engine.run()
        let first = try XCTUnwrap(source.dailyRanges.first)
        XCTAssertLessThan(first.from.timeIntervalSinceNow, -399 * 86_400, "the whole history is read again, not just the last days")
        XCTAssertEqual(box.state.dailyVersion, SyncEngine.dailyVersion)
    }

    func testEmptyRecentPassSkipsTheUpload() async throws {
        let up = RecordingUploader()
        let (engine, box) = makeEngine(ScriptedSource(), up)
        _ = try await engine.run()
        XCTAssertFalse(up.modes.contains("recent"))
        XCTAssertTrue(box.state.recentDone.contains(workoutType.id))
        // Nothing new is reported in one status batch, and not again within the hour.
        XCTAssertEqual(up.modes.filter { $0 == "status" }.count, 1)
        _ = try await engine.run()
        XCTAssertEqual(up.modes.filter { $0 == "status" }.count, 1)
        XCTAssertFalse(up.modes.contains("recent"))
    }

    func testObserverWakeIgnoredUntilHistoryIsIn() async throws {
        let source = ScriptedSource()
        source.pages = [AnchoredPage(records: [workout("N1")], newAnchor: Data("N".utf8), objectCount: 1)]
        let up = RecordingUploader()
        let (engine, box) = makeEngine(source, up)
        // HealthKit fires every observer at launch, before the first sync has covered the type.
        try await engine.runWorkoutChanges(deadline: Date().addingTimeInterval(5))
        XCTAssertTrue(up.uploaded.isEmpty)
        XCTAssertNil(box.state.anchors[workoutType.id])
        // The main run is not blocked and picks the workout up.
        let outcome = try await engine.run()
        XCTAssertEqual(outcome, .finished)
        XCTAssertTrue(box.state.caughtUp.contains(workoutType.id))
    }

    func testObserverWakeSyncsANewWorkoutAndItsDetail() async throws {
        let source = ScriptedSource()
        let up = RecordingUploader()
        let (engine, box) = makeEngine(source, up)
        _ = try await engine.run()
        XCTAssertTrue(box.state.caughtUp.contains(workoutType.id))
        source.pages = [AnchoredPage(records: [workout("N1")], newAnchor: Data("N".utf8), objectCount: 1)]
        source.index = [WorkoutRef(id: "N1", start: Date())]
        source.details = ["N1": detail("N1")]
        let before = up.uploaded.count
        try await engine.runWorkoutChanges(deadline: Date().addingTimeInterval(5))
        XCTAssertEqual(box.state.anchors[workoutType.id], Data("N".utf8))
        XCTAssertEqual(box.state.detailsDone, ["N1"])
        XCTAssertGreaterThanOrEqual(up.uploaded.count, before + 2, "the summary and the raw data")
        XCTAssertTrue(up.uploaded[before...].contains { $0.type == HealthTypes.streamId })
    }

    func testLostBatchFileDoesNotAdvanceTheAnchor() async throws {
        let outbox = Outbox(root: root)
        let batch = Batch(id: "lost-batch", gz: Gzip.compress(Data("{}".utf8)))
        _ = try outbox.enqueue(typeId: workoutType.id, batches: [batch], anchor: Data("A1".utf8), completes: .caughtUp)
        try FileManager.default.removeItem(at: root.appendingPathComponent("batches/lost-batch.ndjson.gz"))
        let up = RecordingUploader()
        let (engine, _) = makeEngine(ScriptedSource(), up, outbox: outbox)
        try await engine.flush()
        XCTAssertNil(outbox.state.anchors[workoutType.id], "data that never reached the server must be read again")
        XCTAssertFalse(outbox.state.caughtUp.contains(workoutType.id))
        XCTAssertTrue(outbox.pending().isEmpty)
        XCTAssertTrue(up.uploaded.isEmpty)
    }

    func testDeadlineStopsCleanly() async throws {
        let source = ScriptedSource()
        source.pages = [AnchoredPage(records: [workout("W1")], newAnchor: Data("A".utf8), objectCount: 1)]
        source.index = [WorkoutRef(id: "W1", start: Date())]
        source.details = ["W1": detail("W1")]
        let up = RecordingUploader()
        let (engine, box) = makeEngine(source, up)
        let outcome = try await engine.run(deadline: Date(timeIntervalSinceNow: -1))
        XCTAssertEqual(outcome, .outOfTime)
        XCTAssertTrue(box.state.detailsDone.isEmpty)
    }

    func testReconcileAfterLongAbsence() async throws {
        let source = ScriptedSource()
        let outbox = Outbox(root: root)
        try outbox.update { s in
            s.lastSyncAt = Date(timeIntervalSinceNow: -40 * 86_400)
            s.anchors[HealthTypes.workoutId] = Data("OLD".utf8)
            s.caughtUp.insert(HealthTypes.workoutId)
            s.recentDone.insert(HealthTypes.workoutId)
        }
        source.pages = [AnchoredPage(records: [workout("W1")], newAnchor: Data("NEW".utf8), objectCount: 1)]
        source.index = [WorkoutRef(id: "W1", start: Date())]
        source.details = ["W1": detail("W1")]
        let up = RecordingUploader()
        let (engine, _) = makeEngine(source, up, outbox: outbox)
        _ = try await engine.run()
        XCTAssertNil(source.anchorsSeen.first ?? Data("x".utf8), "reconcile restarts from the beginning")
        let rec = try XCTUnwrap(up.uploaded.first { $0.header["mode"] as? String == "reconcile" })
        XCTAssertEqual(rec.header["reconcileDone"] as? Bool, true)
        XCTAssertNotNil(rec.header["reconcileId"])
        XCTAssertNil(outbox.state.reconcile[HealthTypes.workoutId])
        XCTAssertEqual(outbox.state.anchors[HealthTypes.workoutId], Data("NEW".utf8))
    }

    func testProgressTitlesAndFraction() {
        var p = SyncProgress(detailsDone: 3, detailsTotal: 10, isSyncing: true)
        p.stepsDone = 5
        p.stepsTotal = 13
        p.phase = 4
        XCTAssertEqual(p.stepTitle, "Step 4 of 4: workout details (3 of 10)")
        XCTAssertEqual(p.fraction, 5.0 / 13.0, accuracy: 0.0001)
        XCTAssertFalse(p.historyComplete)
        p.stepsDone = 13
        XCTAssertTrue(p.historyComplete)
    }

    // MARK: Lines on Home

    func testProgressReachesTheEndWithDaysHoursAndWorkouts() async throws {
        let source = ScriptedSource()
        let from = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -30, to: Date()))
        source.earliestDaily = from
        source.recent = [workout("W1")]
        source.daily = [["k": "day", "day": "2024-06-20", "m": .object(["restingHr": 51])]]
        source.pages = [AnchoredPage(records: [workout("W1")], newAnchor: Data("A1".utf8), objectCount: 1)]
        source.index = [WorkoutRef(id: "W1", start: Date())]
        source.details = ["W1": detail("W1")]
        let box = Outbox(root: root)
        let engine = SyncEngine(source: source, uploader: RecordingUploader(), outbox: box, scope: hourlyScope)
        let log = ProgressLog()
        await engine.onProgress { log.add($0) }
        _ = try await engine.run()
        let p = await engine.progress
        XCTAssertTrue(p.historyComplete)
        XCTAssertEqual(p.stepsTotal, 5, "recent workouts, workout list, daily history, hourly history and one workout")
        XCTAssertTrue(p.indexingDone)
        XCTAssertTrue(p.dailyDone)
        XCTAssertTrue(p.hourlyDone)
        XCTAssertEqual(p.daysTotal, 30)
        XCTAssertEqual(p.daysRead, 30)
        XCTAssertEqual(p.hoursRead, 30 * 24)
        XCTAssertEqual(p.historySinceYear, Calendar.current.component(.year, from: from))
        XCTAssertEqual(p.dailyFraction, 1)
        XCTAssertEqual(p.hourlyFraction, 1)
        XCTAssertEqual(box.state.historyFrom, Calendar.current.startOfDay(for: from))
        let seen = log.items
        XCTAssertEqual(seen.first?.indexingDone, false, "the first report is made before anything is read")
        XCTAssertEqual(seen.last?.historyComplete, true)
    }

    func testHistoryIsNotCompleteUntilTheHourlyHistoryIs() async throws {
        let box = Outbox(root: root)
        try box.update { s in
            s.recentDone.insert(HealthTypes.workoutId)
            s.caughtUp.insert(HealthTypes.workoutId)
            s.dailyFullAt = Date()
            s.workoutTotal = 1
            s.detailsDone = ["W1"]
        }
        let engine = SyncEngine(source: ScriptedSource(), uploader: RecordingUploader(), outbox: box, scope: hourlyScope)
        var p = await engine.progress
        XCTAssertTrue(p.indexingDone)
        XCTAssertTrue(p.dailyDone)
        XCTAssertFalse(p.hourlyDone)
        XCTAssertFalse(p.historyComplete)
        XCTAssertEqual(p.stepsTotal, 5)
        XCTAssertEqual(p.stepsDone, 4)
        try box.update { $0.hourlyAt = Date() }
        p = await engine.progress
        XCTAssertTrue(p.hourlyDone)
        XCTAssertTrue(p.historyComplete)
    }

    func testAScopeWithoutHourlyMetricsDoesNotWaitForThem() async throws {
        let box = Outbox(root: root)
        try box.update { s in
            s.recentDone.insert(HealthTypes.workoutId)
            s.caughtUp.insert(HealthTypes.workoutId)
            s.dailyFullAt = Date()
        }
        let engine = SyncEngine(source: ScriptedSource(), uploader: RecordingUploader(), outbox: box, scope: scope)
        let p = await engine.progress
        XCTAssertTrue(p.hourlyDone)
        XCTAssertTrue(p.historyComplete)
    }

    func testIndexingIsDoneOnlyOnceTheWorkoutListIsKnown() async throws {
        let box = Outbox(root: root)
        try box.update { s in
            s.recentDone.insert(HealthTypes.workoutId)
            s.caughtUp.insert(HealthTypes.workoutId)
        }
        let engine = SyncEngine(source: ScriptedSource(), uploader: RecordingUploader(), outbox: box, scope: scope)
        var p = await engine.progress
        XCTAssertFalse(p.indexingDone, "the number of workouts is not known yet")
        try box.update { $0.workoutTotal = 12 }
        p = await engine.progress
        XCTAssertTrue(p.indexingDone)
        XCTAssertEqual(p.detailsTotal, 12)
    }

    func testTheHourCounterFollowsTheSavedPosition() async throws {
        let cal = Calendar.current
        let box = Outbox(root: root)
        try box.update { s in
            s.historyFrom = cal.date(byAdding: .day, value: -10, to: Date())
            s.hourlyThrough = cal.date(byAdding: .day, value: -4, to: Date())
        }
        let engine = SyncEngine(source: ScriptedSource(), uploader: RecordingUploader(), outbox: box, scope: hourlyScope)
        let p = await engine.progress
        XCTAssertEqual(p.daysTotal, 10)
        XCTAssertEqual(p.hoursRead, 6 * 24, "the hourly pass is resumable, so its position comes from the saved state")
        XCTAssertEqual(p.hourlyFraction, 0.6, accuracy: 0.0001)
        XCTAssertEqual(p.daysRead, 0, "the daily pass has not read anything in this run")
        XCTAssertEqual(p.dailyFraction, 0)
    }

    func testNoCountersUntilTheHistoryStartIsKnown() async throws {
        let engine = SyncEngine(source: ScriptedSource(), uploader: RecordingUploader(), outbox: Outbox(root: root), scope: hourlyScope)
        let p = await engine.progress
        XCTAssertEqual(p.daysTotal, 0)
        XCTAssertEqual(p.daysRead, 0)
        XCTAssertEqual(p.hoursRead, 0)
        XCTAssertNil(p.historySinceYear)
    }

    // MARK: Last checked

    func testAFinishedRunRecordsWhenItChecked() async throws {
        let source = ScriptedSource()
        let box = Outbox(root: root)
        let engine = SyncEngine(source: source, uploader: RecordingUploader(), outbox: box, scope: scope)
        var p = await engine.progress
        XCTAssertNil(p.lastCheckedAt, "never checked")
        let before = Date()
        _ = try await engine.run()
        p = await engine.progress
        let checked = try XCTUnwrap(p.lastCheckedAt)
        XCTAssertGreaterThanOrEqual(checked, before.addingTimeInterval(-1))
        XCTAssertEqual(box.state.lastCheckedAt, box.state.lastSyncAt)
    }

    func testARunThatDoesNotFinishDoesNotCountAsAChecked() async throws {
        let source = ScriptedSource()
        source.failing = ["index"]
        let box = Outbox(root: root)
        let engine = SyncEngine(source: source, uploader: RecordingUploader(), outbox: box, scope: scope)
        _ = try? await engine.run()
        XCTAssertNil(box.state.lastCheckedAt, "a failed step is retried, so it is not a clean check")
        let source2 = ScriptedSource()
        source2.index = [WorkoutRef(id: "W1", start: Date())]
        source2.details = ["W1": detail("W1")]
        let box2 = Outbox(root: URL(fileURLWithPath: root.path + "-2"))
        let engine2 = SyncEngine(source: source2, uploader: RecordingUploader(), outbox: box2, scope: scope)
        let outcome = try await engine2.run(deadline: Date(timeIntervalSinceNow: -1))
        XCTAssertEqual(outcome, .outOfTime)
        XCTAssertNil(box2.state.lastCheckedAt, "out of time: not everything was checked")
    }

    func testAWakeForNewDataRecordsTheCheckAndReportsIt() async throws {
        let source = ScriptedSource()
        let box = Outbox(root: root)
        let engine = SyncEngine(source: source, uploader: RecordingUploader(), outbox: box, scope: scope)
        _ = try await engine.run()
        let first = try XCTUnwrap(box.state.lastCheckedAt)
        let log = ProgressLog()
        await engine.onProgress { log.add($0) }
        try await Task.sleep(for: .milliseconds(1_100))
        try await engine.runWorkoutChanges(deadline: Date().addingTimeInterval(5))
        let second = try XCTUnwrap(box.state.lastCheckedAt)
        XCTAssertGreaterThan(second, first, "a wake that finishes is a check too")
        XCTAssertEqual(log.items.last?.lastCheckedAt, second, "Home hears about it")
        XCTAssertEqual(log.items.last?.isSyncing, false)
    }

    func testAWakeThatRunsOutOfTimeIsNotACheck() async throws {
        let source = ScriptedSource()
        let box = Outbox(root: root)
        let engine = SyncEngine(source: source, uploader: RecordingUploader(), outbox: box, scope: scope)
        _ = try await engine.run()
        let first = try XCTUnwrap(box.state.lastCheckedAt)
        source.index = [WorkoutRef(id: "N1", start: Date())]
        source.details = ["N1": detail("N1")]
        try await Task.sleep(for: .milliseconds(1_100))
        try await engine.runWorkoutChanges(deadline: Date(timeIntervalSinceNow: -1))
        XCTAssertEqual(box.state.lastCheckedAt, first)
    }

    func testTheLastCheckSurvivesARestart() throws {
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        try Outbox(root: root).update { $0.lastCheckedAt = when }
        XCTAssertEqual(Outbox(root: root).state.lastCheckedAt, when)
    }

    func testTheHistoryStartSurvivesARestartAndKeepsTheEarliestDate() throws {
        let early = Date(timeIntervalSince1970: 1_500_000_000)
        let later = Date(timeIntervalSince1970: 1_600_000_000)
        try Outbox(root: root).update { $0.historyFrom = later }
        XCTAssertEqual(Outbox(root: root).state.historyFrom, later)
        try Outbox(root: root).update { $0.historyFrom = early }
        XCTAssertEqual(Outbox(root: root).state.historyFrom, early)
    }
}

/// Collects what the engine reports.
final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [SyncProgress] = []
    func add(_ p: SyncProgress) { lock.lock(); all.append(p); lock.unlock() }
    var items: [SyncProgress] { lock.lock(); defer { lock.unlock() }; return all }
}

