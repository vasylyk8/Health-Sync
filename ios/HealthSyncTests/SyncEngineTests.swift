import HealthKit
import XCTest
@testable import HealthSync

/// Scriptable in-memory HealthKit stand-in.
final class ScriptedSource: HealthSource, @unchecked Sendable {
    var pages: [String: [AnchoredPage]] = [:]
    var recent: [String: [Record]] = [:]
    var stats: [Record] = []
    var earliest: Date?
    var failing: Set<String> = []
    struct HealthKitFailure: Error {}
    var anchorsSeen: [String: [Data?]] = [:]
    var isAvailable: Bool { true }
    func requestAuthorization(types: [SyncType]) async throws {}
    func samples(_ type: SyncType, from: Date, to: Date) async throws -> [Record] { recent[type.id] ?? [] }
    private let lock = NSLock()
    func anchoredPage(_ type: SyncType, anchor: Data?, limit: Int) async throws -> AnchoredPage {
        try nextPage(type, anchor)
    }
    private func nextPage(_ type: SyncType, _ anchor: Data?) throws -> AnchoredPage {
        lock.lock(); defer { lock.unlock() }
        if failing.contains(type.id) { throw HealthKitFailure() }
        anchorsSeen[type.id, default: []].append(anchor)
        var list = pages[type.id] ?? []
        guard !list.isEmpty else { return AnchoredPage(records: [], newAnchor: anchor, objectCount: 0) }
        let page = list.removeFirst()
        pages[type.id] = list
        return page
    }
    func hourlyStats(_ type: SyncType, from: Date, to: Date) async throws -> [Record] { stats }
    func earliestSampleDate(_ type: SyncType) async throws -> Date? { earliest }
    func activitySummaries(from: Date, to: Date) async throws -> [Record] { [] }
    func correlations(_ type: SyncType, from: Date, to: Date) async throws -> [Record] { [] }
    /// Rebuilt on every call so dictionary ordering can differ between calls, like real HealthKit reads.
    var profileFields: [String: RecordValue] = ["k": "p", "sex": "female"]
    func profile() -> Record? { Dictionary(uniqueKeysWithValues: profileFields.map { ($0.key, $0.value) }) }
    func observeChanges(types: [SyncType], onChange: @escaping @Sendable (SyncType, @escaping @Sendable () -> Void) -> Void) {}
}

final class RecordingUploader: Uploader, @unchecked Sendable {
    var uploaded: [(id: String, type: String, header: [String: Any], records: Int)] = []
    var failAfter: Int?
    /// Simulated network latency, so parallel uploads overlap.
    var delay: UInt64 = 0
    private(set) var maxInFlight = 0
    private var inFlight = 0
    private let lock = NSLock()
    struct Offline: Error {}
    func upload(batchId: String, gz: Data, sha256: String, typeId: String) async throws {
        try locked {
            if let n = failAfter, uploaded.count >= n { throw Offline() }
            inFlight += 1
            maxInFlight = max(maxInFlight, inFlight)
        }
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        let lines = String(data: Gzip.decompress(gz)!, encoding: .utf8)!.split(separator: "\n")
        let header = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as! [String: Any]
        locked {
            inFlight -= 1
            uploaded.append((batchId, typeId, header, lines.count - 1))
        }
    }
    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }
}

final class SyncEngineTests: XCTestCase {
    let hr = SyncType(id: "HKQuantityTypeIdentifierHeartRate", kind: .quantity(cumulative: false), sampleType: nil, unit: .count())
    var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    private func sample(_ id: String) -> Record { ["k": "s", "id": .string(id), "s": 1, "e": 1, "v": 60.0, "u": "count/min"] }

    func testOrderRecentThenStatsThenAnchoredAndCommitsAnchors() async throws {
        let source = ScriptedSource()
        source.recent[hr.id] = [sample("r1")]
        source.earliest = Date(timeIntervalSinceNow: -3 * 86_400)
        source.stats = [["k": "h", "s": 0, "e": 3_600_000, "agg": "avg", "v": 60.0, "u": "count/min"]]
        source.pages[hr.id] = [
            AnchoredPage(records: [sample("a1"), sample("a2")], newAnchor: Data("A1".utf8), objectCount: 2),
        ]
        let up = RecordingUploader()
        let outbox = Outbox(root: root)
        let engine = SyncEngine(source: source, uploader: up, outbox: outbox, types: [hr], config: .init(pageLimit: 2))
        let outcome = try await engine.run()
        XCTAssertEqual(outcome, .finished)
        let modes = up.uploaded.map { $0.header["mode"] as! String }
        XCTAssertEqual(modes, ["profile", "recent", "stats", "anchored", "status"])
        // First page was full (2 of limit 2) so not caught up; the second page was empty, which is
        // reported in the status batch instead of its own upload.
        XCTAssertEqual(up.uploaded[3].header["caughtUp"] as? Bool, false)
        XCTAssertEqual(up.uploaded[4].type, "_status")
        XCTAssertNotNil(up.uploaded[3].header["perf"], "timings are sent for diagnosis")
        XCTAssertEqual(outbox.state.anchors[hr.id], Data("A1".utf8))
        XCTAssertTrue(outbox.state.caughtUp.contains(hr.id))
        XCTAssertTrue(outbox.state.recentDone.contains(hr.id))
        let seqs = up.uploaded.filter { $0.type == hr.id }.map { $0.header["seq"] as! Int }
        XCTAssertEqual(seqs, seqs.sorted())
        XCTAssertEqual(Set(seqs).count, seqs.count)
        XCTAssertTrue(outbox.pending().isEmpty)
    }

    func testUnchangedProfileIsUploadedOnlyOnce() async throws {
        let source = ScriptedSource()
        for i in 0..<12 { source.profileFields["f\(i)"] = .string("value\(i)") }
        let up = RecordingUploader()
        let outbox = Outbox(root: root)
        for _ in 0..<6 {
            let engine = SyncEngine(source: source, uploader: up, outbox: outbox, types: [])
            _ = try await engine.run()
        }
        XCTAssertEqual(up.uploaded.filter { $0.header["mode"] as? String == "profile" }.count, 1)
    }

    func testTypesWithNothingNewShareOneStatusUpload() async throws {
        let types = (0..<5).map { SyncType(id: "E\($0)", kind: .category, sampleType: nil, unit: nil) }
        let up = RecordingUploader()
        let outbox = Outbox(root: root)
        let engine = SyncEngine(source: ScriptedSource(), uploader: up, outbox: outbox, types: types)
        _ = try await engine.run()
        let status = up.uploaded.filter { $0.header["mode"] as? String == "status" }
        XCTAssertEqual(status.count, 1)
        XCTAssertEqual(status.first?.records, 5)
        XCTAssertFalse(up.uploaded.contains { $0.header["mode"] as? String == "anchored" })
        XCTAssertEqual(outbox.state.caughtUp, Set(types.map(\.id)))
        let p = await engine.progress
        XCTAssertTrue(p.historyComplete)

        // A later run with nothing new doesn't upload again within the hour.
        let before = up.uploaded.count
        _ = try await engine.run()
        XCTAssertEqual(up.uploaded.count, before)
    }

    func testOneFailingTypeDoesNotStopTheOthers() async throws {
        let types = (0..<4).map { SyncType(id: "F\($0)", kind: .category, sampleType: nil, unit: nil) }
        let source = ScriptedSource()
        source.failing = ["F1"]
        for t in types { source.pages[t.id] = [AnchoredPage(records: [sample("\(t.id)-a")], newAnchor: Data(t.id.utf8), objectCount: 1)] }
        let up = RecordingUploader()
        let outbox = Outbox(root: root)
        let engine = SyncEngine(source: source, uploader: up, outbox: outbox, types: types)
        do {
            _ = try await engine.run()
            XCTFail("the failing type should make the run report an error")
        } catch is ScriptedSource.HealthKitFailure {}
        XCTAssertEqual(outbox.state.caughtUp, ["F0", "F2", "F3"])
        XCTAssertNil(outbox.state.lastSyncAt, "the run is not recorded as complete, so it is retried")
    }

    func testMostAskedTypesSyncFirst() {
        let ids = ["HKQuantityTypeIdentifierDietaryWater", "HKQuantityTypeIdentifierHeartRate", "X", "HKQuantityTypeIdentifierStepCount"]
        let types = ids.map { SyncType(id: $0, kind: .quantity(cumulative: true), sampleType: nil, unit: .count()) }
        XCTAssertEqual(SyncEngine.prioritized(types).map(\.id),
                       ["HKQuantityTypeIdentifierStepCount", "HKQuantityTypeIdentifierHeartRate", "HKQuantityTypeIdentifierDietaryWater", "X"])
    }

    func testOfflineNeverAdvancesAnchorAndResumes() async throws {
        let source = ScriptedSource()
        source.pages[hr.id] = [AnchoredPage(records: [sample("a1")], newAnchor: Data("A1".utf8), objectCount: 1)]
        let up = RecordingUploader()
        up.failAfter = 1 // profile succeeds (no recent data, so no recent upload), then the network drops
        let outbox = Outbox(root: root)
        let engine = SyncEngine(source: source, uploader: up, outbox: outbox, types: [hr], config: .init(pageLimit: 5))
        do {
            _ = try await engine.run()
            XCTFail("expected offline error")
        } catch is RecordingUploader.Offline {}
        XCTAssertNil(outbox.state.anchors[hr.id], "anchor must not move before the server has the data")
        XCTAssertFalse(outbox.pending().isEmpty)

        // App restarts later with the network back: the same batches are re-sent and committed.
        up.failAfter = nil
        let engine2 = SyncEngine(source: source, uploader: up, outbox: Outbox(root: root), types: [hr], config: .init(pageLimit: 5))
        _ = try await engine2.run()
        let reloaded = Outbox(root: root)
        XCTAssertTrue(reloaded.pending().isEmpty)
        XCTAssertTrue(reloaded.state.caughtUp.contains(hr.id))
    }

    func testSyncsTypesInParallelSkipsEmptyRecentAndReportsAllPhases() async throws {
        let types = (0..<6).map { SyncType(id: "T\($0)", kind: .quantity(cumulative: false), sampleType: nil, unit: .count()) }
        let source = ScriptedSource()
        source.recent["T0"] = [sample("r0")]
        for t in types {
            source.pages[t.id] = [AnchoredPage(records: [sample("\(t.id)-a")], newAnchor: Data("\(t.id)".utf8), objectCount: 1)]
        }
        let up = RecordingUploader()
        up.delay = 20_000_000
        let outbox = Outbox(root: root)
        let engine = SyncEngine(source: source, uploader: up, outbox: outbox, types: types, config: .init(pageLimit: 5, parallelTypes: 4))
        let outcome = try await engine.run()
        XCTAssertEqual(outcome, .finished)
        XCTAssertGreaterThan(up.maxInFlight, 1, "different types upload at the same time")
        XCTAssertLessThanOrEqual(up.maxInFlight, 4)
        let recentTypes = up.uploaded.filter { $0.header["mode"] as? String == "recent" }.map(\.type)
        XCTAssertEqual(recentTypes, ["T0"], "types without recent data skip the recent upload")
        for t in types {
            let seqs = up.uploaded.filter { $0.type == t.id }.map { $0.header["seq"] as! Int }
            XCTAssertEqual(seqs, seqs.sorted(), "each type's batches stay in order")
            XCTAssertEqual(outbox.state.anchors[t.id], Data("\(t.id)".utf8))
        }
        let progress = await engine.progress
        XCTAssertEqual(progress.stepsTotal, 6 * 3 + 6)
        XCTAssertEqual(progress.fraction, 1)
        XCTAssertTrue(progress.historyComplete)
        XCTAssertTrue(outbox.pending().isEmpty)
    }

    func testProgressMovesBeforeFullHistoryStarts() {
        var p = SyncProgress(typesDone: 0, typesTotal: 10, isSyncing: true)
        p.stepsDone = 10
        p.stepsTotal = 40
        p.phase = 2
        XCTAssertEqual(p.fraction, 0.25)
        XCTAssertFalse(p.historyComplete)
        XCTAssertEqual(p.stepTitle, "Step 2 of 3: long-term totals")
    }

    func testDeadlineStopsCleanly() async throws {
        let source = ScriptedSource()
        source.pages[hr.id] = (0..<10).map { AnchoredPage(records: [sample("a\($0)")], newAnchor: Data("A\($0)".utf8), objectCount: 1) }
        let up = RecordingUploader()
        let engine = SyncEngine(source: source, uploader: up, outbox: Outbox(root: root), types: [hr], config: .init(pageLimit: 1))
        let outcome = try await engine.run(deadline: Date(timeIntervalSinceNow: -1))
        XCTAssertEqual(outcome, .outOfTime)
    }

    func testReconcileAfterLongAbsence() async throws {
        let source = ScriptedSource()
        let outbox = Outbox(root: root)
        try outbox.update { s in
            s.lastSyncAt = Date(timeIntervalSinceNow: -40 * 86_400)
            s.anchors[self.hr.id] = Data("OLD".utf8)
            s.caughtUp.insert(self.hr.id)
            s.recentDone.insert(self.hr.id)
            s.statsFullAt[self.hr.id] = Date()
        }
        source.pages[hr.id] = [AnchoredPage(records: [sample("a1")], newAnchor: Data("NEW".utf8), objectCount: 1)]
        let up = RecordingUploader()
        let engine = SyncEngine(source: source, uploader: up, outbox: outbox, types: [hr], config: .init(pageLimit: 5))
        _ = try await engine.run()
        XCTAssertNil(source.anchorsSeen[hr.id]?.first ?? Data("x".utf8), "reconcile restarts from the beginning")
        let rec = up.uploaded.first { $0.header["mode"] as? String == "reconcile" }!
        XCTAssertEqual(rec.header["reconcileDone"] as? Bool, true)
        XCTAssertNotNil(rec.header["reconcileId"])
        XCTAssertNil(outbox.state.reconcile[hr.id])
        XCTAssertEqual(outbox.state.anchors[hr.id], Data("NEW".utf8))
    }
}
