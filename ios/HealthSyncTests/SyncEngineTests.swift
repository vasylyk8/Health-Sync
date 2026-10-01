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
        XCTAssertEqual(up.modes.filter { $0 != "stats" }, ["recent", "anchored", "workoutdata", "status"], "both workouts' raw data go in one upload")
        XCTAssertEqual(up.modes.filter { $0 == "stats" }.count, 1)
        XCTAssertEqual(up.modes.first, "recent")
        XCTAssertEqual(up.modes.last, "status")
        XCTAssertEqual(up.uploaded.map { $0.type }.filter { $0 != HealthTypes.dailyId }, [HealthTypes.workoutId, HealthTypes.workoutId, HealthTypes.streamId, HealthTypes.statusId])
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
        let seqs = streams.map { $0.header["seq"] as! Int }
        XCTAssertEqual(seqs, seqs.sorted())
        XCTAssertTrue(box.pending().isEmpty)
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
        let (engine, _) = makeEngine(source, up)
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
}
