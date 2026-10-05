import CryptoKit
import HealthKit
import XCTest
@testable import HealthSync

final class PhoneSyncComparisonTests: XCTestCase {
    private var root: URL!
    override func setUp() { root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func index(_ name: String, rows: [[String: Any]], type: String = "daily", header: String = "{\"seq\":1}") async throws -> DiagnosticRecordIndex {
        let sink = try DiagnosticBatchSink(root: root.appendingPathComponent(name), delay: 0)
        var raw = Data((header + "\n").utf8)
        for row in rows { raw += try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]); raw += Data([10]) }
        let gz = Gzip.compress(raw)
        try await sink.upload(batchId: name, gz: gz, sha256: SHA256.hash(data: gz).map { String(format: "%02x", $0) }.joined(), typeId: type)
        return try DiagnosticRecordIndex(sink: sink)
    }
    private func day(_ date: String = "2020-01-01", _ value: Double = 72) -> [String: Any] {
        ["k": "day", "day": date, "m": ["hrAvg": value]]
    }

    func testDiskComparisonKeepsDuplicatesAndIgnoresHeadersAndOrder() async throws {
        let rows = [day(), day(), day("2020-01-02", 80)]
        let a = try await index("a", rows: rows)
        let b = try await index("b", rows: Array(rows.reversed()), header: "{\"seq\":99,\"ms\":123}")
        let result = try b.compare(to: a)
        XCTAssertTrue(result.exact); XCTAssertTrue(result.equivalent)
        XCTAssertEqual(a.count, 3)
        let missing = try await index("missing", rows: Array(rows.dropFirst()))
        XCTAssertFalse(try missing.compare(to: a).equivalent)
    }
    func testComparisonDetectsChangedValuesDatesTypesAndStreamShape() async throws {
        let reference = try await index("a", rows: [day()])
        let changed = try await index("value", rows: [day("2020-01-01", 73)])
        XCTAssertFalse(try changed.compare(to: reference).equivalent)
        XCTAssertEqual(try changed.compare(to: reference).maximumDelta, 1)
        let date = try await index("date", rows: [day("2020-01-02")])
        XCTAssertFalse(try date.compare(to: reference).equivalent)
        let type = try await index("type", rows: [day()], type: "hourly")
        XCTAssertFalse(try type.compare(to: reference).equivalent)
        let a = try await index("stream-a", rows: [["k": "ws", "w": "W", "v": [70, 80]]])
        let b = try await index("stream-b", rows: [["k": "ws", "w": "W", "v": [70]]])
        XCTAssertFalse(try b.compare(to: a).equivalent)
    }
    func testTinyFloatingNoiseIsReportedWithoutChangingStoredValues() async throws {
        let a = try await index("a", rows: [day(), day()])
        let b = try await index("b", rows: [day(), day("2020-01-01", 72 + 1e-12)])
        let result = try b.compare(to: a)
        XCTAssertFalse(result.exact); XCTAssertTrue(result.equivalent)
        XCTAssertEqual(result.changedRecords, 1)
        XCTAssertGreaterThan(result.maximumDelta, 0)
    }
    func testInvalidBatchHashIsRejected() async throws {
        let sink = try DiagnosticBatchSink(root: root, delay: 0)
        do { try await sink.upload(batchId: "bad", gz: Data([1]), sha256: "wrong", typeId: "daily"); XCTFail() }
        catch is DiagnosticBatchSink.InvalidBatch {} catch { XCTFail("unexpected error") }
        XCTAssertTrue(sink.batches.isEmpty)
    }
    func testOverridesAndTimingAreConfinedToDiagnosticTaskTree() async throws {
        let normal = SyncTiming.shared
        let privateTiming = SyncTiming()
        for width in [1, 2, 4] {
            try await PhoneSyncComparisonContext.$width.withValue(width) {
                try await PhoneSyncComparisonContext.$cutoff.withValue(Date(timeIntervalSince1970: 1_700_000_000)) {
                    try await SyncTiming.$diagnostic.withValue(privateTiming) {
                        let observed = await Task { (DailyMetricConcurrency.width, SyncTiming.shared === privateTiming, PhoneSyncComparisonContext.samplePredicate != nil) }.value
                        XCTAssertEqual(observed.0, width); XCTAssertTrue(observed.1); XCTAssertTrue(observed.2)
                        try Task.checkCancellation()
                    }
                }
            }
        }
        XCTAssertEqual(DailyMetricConcurrency.width, 2)
        XCTAssertTrue(SyncTiming.shared === normal)
        XCTAssertNil(PhoneSyncComparisonContext.samplePredicate)
    }

    private var scope: SyncScope { HealthTypes.scope(HealthTypes.loadCoverage()) }
    private func source(cutoff: Date) -> ScriptedSource {
        let source = ScriptedSource()
        source.index = [WorkoutRef(id: "W", start: cutoff.addingTimeInterval(-86400))]
        source.details = ["W": [["k": "ws", "w": "W", "ty": "HeartRate", "v": .array([70, 80])], ["k": "wd", "w": "W", "gen": 1]]]
        source.earliestDaily = cutoff.addingTimeInterval(-86400)
        return source
    }
    func testSixRunsStartFreshAndKeepProductionOutboxUntouched() async throws {
        let cutoff = Calendar.current.startOfDay(for: Date())
        let sourceScope = scope
        let production = Outbox(root: root.appendingPathComponent("production"))
        try production.update { $0.detailsDone.insert("already-synced") }
        var options = PhoneSyncComparison.Options()
        options.order = [1, 2, 4, 4, 2, 1]; options.cutoff = cutoff; options.uploadDelay = 0; options.coolingTimeout = 0
        let result = try await PhoneSyncComparison.run(scope: sourceScope, categories: ["core"], options: options,
            sourceFactory: { self.source(cutoff: cutoff) }, onUpdate: { _ in })
        XCTAssertEqual(result.runs.map(\.width), options.order)
        XCTAssertTrue(result.passed, result.report)
        XCTAssertTrue(result.runs.allSatisfy { $0.records == 2 })
        XCTAssertEqual(production.state.detailsDone, ["already-synced"])
        XCTAssertTrue(production.pending().isEmpty)
    }
    func testPausedEngineSkipsMainAndObserverRunsThenResumes() async throws {
        let cutoff = Calendar.current.startOfDay(for: Date())
        let source = source(cutoff: cutoff)
        let box = Outbox(root: root.appendingPathComponent("production"))
        try box.update { $0.caughtUp.insert(HealthTypes.workoutId) }
        let engine = SyncEngine(source: source, uploader: RecordingUploader(), outbox: box, scope: scope, now: { cutoff })
        try await engine.pauseForDiagnostic()
        let blocked = try await engine.run()
        XCTAssertEqual(blocked, .alreadyRunning)
        try await engine.runWorkoutChanges(deadline: Date().addingTimeInterval(10))
        XCTAssertTrue(source.detailReads.isEmpty)
        await engine.resumeAfterDiagnostic()
        let resumed = try await engine.run()
        XCTAssertEqual(resumed, .finished)
        XCTAssertEqual(source.detailReads, ["W"])
    }
    func testCancelledDiagnosticRemovesPrivateScratchBatches() async throws {
        let cutoff = Calendar.current.startOfDay(for: Date())
        var options = PhoneSyncComparison.Options()
        options.order = [1, 2, 4]; options.cutoff = cutoff; options.uploadDelay = 30; options.coolingTimeout = 0
        let sourceScope = scope
        let task = Task {
            try await PhoneSyncComparison.run(scope: sourceScope, categories: ["core"], options: options,
                sourceFactory: { self.source(cutoff: cutoff) }, onUpdate: { _ in })
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do { _ = try await task.value; XCTFail("cancelled runs cannot be reported successful") }
        catch is CancellationError {} catch { XCTFail("unexpected cancellation result") }
        let parent = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("PhoneSyncComparison")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty)
    }
}
