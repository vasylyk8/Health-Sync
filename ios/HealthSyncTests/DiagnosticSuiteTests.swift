import XCTest
@testable import HealthSync

final class DiagnosticSuiteTests: XCTestCase {
    func testTimelineUnionDoesNotAddOverlappingWork() {
        let events = [(0.0, 5.0), (2.0, 6.0), (10.0, 12.0)].map { SyncProbeRecorder.Event(name: "read", metric: "m", window: "", start: $0.0, end: $0.1, error: false, count: 0) }
        XCTAssertEqual(SyncProbeRecorder.unionDuration(events), 8)
    }
    func testMetricWindowCountsAndErrorsAreSeparate() {
        let r = SyncProbeRecorder()
        let a = r.begin("query", metric: "hr", window: "old"), b = r.begin("query", metric: "steps", window: "new")
        r.end(a, error: true, count: 17); r.end(b, count: 2); r.end(a)
        XCTAssertEqual(r.snapshot().stats["hr|old|query"]?.errors, 1)
        XCTAssertEqual(r.snapshot().stats["hr|old|query"]?.items, 17)
        XCTAssertEqual(r.snapshot().active, 0)
    }
    func testPlanHasIndependentBaselinesAndReplay() {
        for deep in [false, true] {
            let p = DiagnosticVariant.plan(deep: deep)
            XCTAssertEqual(p.first?.id, "baseline-start"); XCTAssertEqual(p.last?.id, "baseline-end")
            XCTAssertEqual(Set(p.map(\.id)).count, p.count); XCTAssertTrue(p.contains(where: \.replay))
        }
    }
    func testScratchBudgetStopsBeforeWritingMoreData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let s = try DiagnosticScratch(root: root, limit: 3)
        try s.write(Data([1, 2]), name: "a")
        XCTAssertThrowsError(try s.write(Data([3, 4]), name: "b"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("b").path))
    }
    func testCaptureRoundTripsWithoutHealthKitAndMissingReplayFails() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let s = SourceReplayStore(scratch: try DiagnosticScratch(root: root))
        let record: Record = ["k": "day", "day": "2024-01-01", "m": .object(["steps": 1000])]
        try s.capture("daily", reply: .init(records: [record, record]))
        XCTAssertEqual(try s.read("daily").records, [record, record])
        XCTAssertThrowsError(try s.read("missing"))
    }
    func testRawReplayPreservesWatchSelectionAndUnifiedTotals() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RawReplayStore(scratch: try DiagnosticScratch(root: root))
        let start = Date(timeIntervalSince1970: 1_700_000_000), end = start.addingTimeInterval(7200)
        let writer = try store.writer(type: "Steps", from: start, to: end, style: .cumulative)
        try writer.append(RawReading(start: start, end: start.addingTimeInterval(600), value: 100, source: "com.apple.health.watch", watch: true), id: "a")
        try writer.append(RawReading(start: start, end: start.addingTimeInterval(600), value: 200, source: "com.apple.health.phone"), id: "b")
        try writer.finish()
        let f = try XCTUnwrap(store.inventory.first)
        XCTAssertEqual(f.count, 2)
        XCTAssertTrue(DiagnosticSuite.rawEqual(try store.replay(f, unified: false), try store.replay(f, unified: true)))
        XCTAssertEqual(try store.replay(f, unified: false).daily["sum"]?.reduce(0) { $0 + $1.1 } ?? 0, 100, accuracy: 1e-9)
    }
    func testSavedReportHasNoCaptureValuesAndCanBeReloaded() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DiagnosticReportStore(root: root)
        var r = DiagnosticRunReport(); r.status = "paused"; r.preset = "Deep investigation"; r.text = "Counts and timings only"
        try store.save(r)
        XCTAssertEqual(store.reports().first?.id, r.id)
        for file in store.files(r.id) { XCTAssertTrue(FileManager.default.fileExists(atPath: file.path)) }
    }
}

extension DiagnosticSuiteTests {
    func testKnownAnswerLibraryIsReadOnlyAndCoversDSTSourcesAndMeans() {
        let lines = DiagnosticFixtures.run()
        XCTAssertGreaterThanOrEqual(lines.count, 14)
        XCTAssertEqual(lines.filter { $0.hasPrefix("FAIL") }, [])
        XCTAssertFalse(DiagnosticFixtures.notExercised.isEmpty)
    }
    func testWholeSuiteCapturesAndReplaysAnEmptyHistoryWithoutInventingData() async throws {
        var options = DiagnosticSuite.Options(); options.delay = 0
        options.variants = [DiagnosticVariant(id: "baseline-start"), DiagnosticVariant(id: "replay", replay: true), DiagnosticVariant(id: "baseline-end")]
        let result = try await DiagnosticSuite.run(scope: .empty, categories: ["core"], options: options, sourceFactory: { _ in FakeHealthSource() }, onUpdate: { _ in })
        XCTAssertEqual(result.status, "complete"); XCTAssertEqual(result.cases.count, 3)
        XCTAssertTrue(result.cases.allSatisfy { $0.complete && $0.records == 0 })
        let store = DiagnosticReportStore(); for file in store.files(result.id) { try? FileManager.default.removeItem(at: file) }
    }
}

extension DiagnosticSuiteTests {
    func testSourceCaptureChecksumsSurviveReopenAndDetectReplacement() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scratch = try DiagnosticScratch(root: root), store = SourceReplayStore(scratch: scratch)
        try store.capture("a", reply: .init(count: 7))
        XCTAssertEqual(try SourceReplayStore(scratch: scratch).read("a").count, 7)
        try Gzip.compress(JSONEncoder().encode(SourceReplayStore.Reply(count: 8))).write(to: root.appendingPathComponent(DiagnosticScratch.digest(Data("a".utf8)) + ".source.gz"))
        XCTAssertThrowsError(try store.read("a"))
    }
    func testRawCaptureChecksumsDetectAlteredReadings() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scratch = try DiagnosticScratch(root: root), store = RawReplayStore(scratch: scratch), start = Date(timeIntervalSince1970: 1_700_000_000)
        let writer = try store.writer(type: "Steps", from: start, to: start.addingTimeInterval(3600), style: .cumulative)
        try writer.append(RawReading(start: start, end: start.addingTimeInterval(600), value: 100, source: "watch"), id: "a"); try writer.finish()
        let fixture = try XCTUnwrap(store.inventory.first)
        XCTAssertEqual(RawReplayStore(scratch: scratch).inventory.count, 1)
        let file = root.appendingPathComponent(fixture.name)
        let text = try String(contentsOf: file, encoding: .utf8).replacingOccurrences(of: "100", with: "101")
        try Data(text.utf8).write(to: file)
        XCTAssertThrowsError(try store.replay(fixture, unified: false))
    }
}


private final class FlakyUploader: Uploader, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var sent: [String] = []
    private var failAfter: Int?
    init(failAfter: Int? = nil) { self.failAfter = failAfter }
    func upload(batchId: String, gz: Data, sha256: String, typeId: String) async throws {
        try lock.withLock { if let limit = failAfter, sent.count >= limit { throw CancellationError() }; sent.append(typeId) }
    }
}

extension DiagnosticSuiteTests {
    private func caseReport(_ name: String, kind: String, changed: Int = 0, replay: Bool = false, input: String? = nil, raw: String? = nil) -> DiagnosticCaseReport {
        DiagnosticCaseReport(name: name, transfer: replay ? "local simulated (fixed-input replay)" : "local simulated (live Apple Health)", elapsed: 1, records: 1, complete: kind != "incomplete", verdict: "", changed: changed, snapshot: SyncProbeRecorder().snapshot(), kind: kind, inputDigest: input, rawDigest: raw)
    }
    func testVariantValidationRejectsTyposUnboundedValuesAndUnreplayablePlans() {
        XCTAssertTrue(DiagnosticVariant.validate(DiagnosticVariant.plan(deep: false)))
        XCTAssertTrue(DiagnosticVariant.validate(DiagnosticVariant.plan(deep: true)))
        func plan(_ edit: (inout [DiagnosticVariant]) -> Void) -> Bool { var p = DiagnosticVariant.plan(deep: false); edit(&p); return DiagnosticVariant.validate(p) }
        XCTAssertFalse(plan { $0[1].strategy = "selectiveFalback" })
        XCTAssertFalse(plan { $0[1].family = "dailly" })
        XCTAssertFalse(plan { $0[1].fault = "explode" })
        XCTAssertFalse(plan { $0[1].routeWidth = 500 })
        XCTAssertFalse(plan { $0[1].cacheRows = 50_000_000 })
        XCTAssertFalse(plan { $0[1].historyCapacity = 99 })
        XCTAssertFalse(plan { $0[1].id = "../escape" })
        XCTAssertFalse(plan { $0[2].id = $0[1].id })
        XCTAssertFalse(plan { $0[0].fault = "error" })
        XCTAssertFalse(plan { $0[0].family = "daily" })
        XCTAssertFalse(plan { $0[3].chunkMonths = 6 })
        XCTAssertFalse(plan { $0.removeFirst() })
        XCTAssertFalse(plan { $0 += (0..<80).map { DiagnosticVariant(id: "extra-\($0)") } })
    }
    func testBaselineMatchIsNotLabelledAsComparedAndSourceChangeIsAttributed() {
        let reference = DiagnosticVariant(id: "baseline-start")
        let differs = HistoryRecordComparison(exact: false, equivalent: false, maximumDelta: 3, changedRecords: 5)
        let matches = HistoryRecordComparison(exact: true, equivalent: true, maximumDelta: 0, changedRecords: 0)
        let ref = caseReport("baseline-start", kind: "reference", input: "A", raw: "R")
        func kind(_ v: DiagnosticVariant, _ c: HistoryRecordComparison?, input: String? = "A", raw: String? = "R") -> String {
            DiagnosticSuite.classify(variant: v, reference: reference, complete: true, comparison: c, referenceCase: ref, liveInput: input, liveRaw: raw)
        }
        XCTAssertEqual(kind(reference, nil), "reference")
        XCTAssertTrue(DiagnosticSuite.verdictText("reference").hasPrefix("REFERENCE CAPTURED"))
        XCTAssertEqual(kind(DiagnosticVariant(id: "four", width: 4), matches), "matched")
        XCTAssertEqual(kind(DiagnosticVariant(id: "four", width: 4), differs, input: "B", raw: "Q"), "sourceChanged")
        XCTAssertEqual(kind(DiagnosticVariant(id: "four", width: 4), differs, input: "B", raw: "R"), "readerDifference")
        XCTAssertEqual(kind(DiagnosticVariant(id: "four", width: 4), differs, input: "A", raw: "Q"), "engineDifference")
        XCTAssertEqual(kind(DiagnosticVariant(id: "replay", replay: true), differs), "replayRegression")
        XCTAssertEqual(kind(DiagnosticVariant(id: "x-known-regression", strategy: "widerStatistics"), differs), "knownRegression")
        XCTAssertEqual(kind(DiagnosticVariant(id: "sel", strategy: "selectiveFallback"), differs), "candidateDifference")
        XCTAssertEqual(kind(DiagnosticVariant(id: "err", fault: "error"), differs), "recoveryDifference")
        XCTAssertEqual(kind(DiagnosticVariant(id: "noroutes", includeRoutes: false), differs), "costProbe")
        XCTAssertEqual(DiagnosticSuite.classify(variant: reference, reference: reference, complete: false, comparison: nil, referenceCase: nil, liveInput: nil, liveRaw: nil), "incomplete")
    }
    func testAccuracyGateSeparatesFailureInstabilityIncompleteAndCandidateDifferences() {
        func gate(_ cases: [DiagnosticCaseReport], known: Int = 0, differ: Int = 0) -> String {
            DiagnosticSuite.accuracyGate(cases: cases, knownAnswerFailures: known, rawDiffer: differ, orderSensitive: 0, realTransfer: "off").verdict
        }
        let ref = caseReport("baseline-start", kind: "reference"), end = caseReport("baseline-end", kind: "matched")
        XCTAssertTrue(gate([ref, caseReport("replay", kind: "matched", replay: true), end]).hasPrefix("NO REGRESSION DETECTED"))
        XCTAssertTrue(gate([ref, caseReport("replay", kind: "replayRegression", changed: 2, replay: true), end]).hasPrefix("FAILED"))
        XCTAssertTrue(gate([ref, end], known: 1).hasPrefix("FAILED"))
        XCTAssertTrue(gate([ref, end], differ: 1).hasPrefix("FAILED"))
        XCTAssertTrue(gate([ref, caseReport("baseline-end", kind: "sourceChanged", changed: 9)]).hasPrefix("INCONCLUSIVE"))
        XCTAssertTrue(gate([ref, caseReport("x", kind: "incomplete"), end]).hasPrefix("INCOMPLETE"))
        XCTAssertTrue(gate([ref, caseReport("sel", kind: "candidateDifference", changed: 7), end]).hasPrefix("CANDIDATE DIFFERENCES"))
        XCTAssertTrue(gate([ref, caseReport("w-known-regression", kind: "knownRegression", changed: 7), caseReport("probe", kind: "costProbe"), end]).hasPrefix("NO REGRESSION DETECTED"))
        XCTAssertTrue(gate([ref]).hasPrefix("NO REGRESSION DETECTED"))
    }
    func testGateReportsFloatingPointNoiseWithoutRelaxingTheTolerance() {
        var noisy = caseReport("baseline-end", kind: "matched", changed: 3); noisy.exact = false; noisy.maximumDelta = 3.6e-12
        let ok = DiagnosticSuite.accuracyGate(cases: [caseReport("baseline-start", kind: "reference"), noisy], knownAnswerFailures: 0, rawDiffer: 0, orderSensitive: 0, realTransfer: "off")
        XCTAssertTrue(ok.verdict.hasPrefix("NO REGRESSION DETECTED"))
        XCTAssertTrue(ok.lines.contains { $0.contains("not byte-identical") && $0.contains("1e-09") || $0.contains("not byte-identical") && $0.contains("1e-9") })
    }
    func testCoverageStatusDistinguishesFailedReadsFromEmptyReads() {
        func row(_ metric: String, records: Int = 0) -> DiagnosticCoverage { DiagnosticCoverage(family: "daily", metric: metric, category: "core", enabled: true, status: "", records: records) }
        let recorder = SyncProbeRecorder()
        recorder.end(recorder.begin("query", metric: "daily.failed", window: "w"), error: true)
        recorder.end(recorder.begin("query", metric: "daily.empty", window: "w"))
        recorder.end(recorder.begin("query", metric: "daily.good", window: "w"), count: 3)
        let snapshot = recorder.snapshot()
        XCTAssertTrue(DiagnosticSuite.coverageStatus(row("failed"), snapshot: snapshot).contains("not evidence of absent data"))
        XCTAssertTrue(DiagnosticSuite.coverageStatus(row("empty"), snapshot: snapshot).contains("does not say which"))
        XCTAssertEqual(DiagnosticSuite.coverageStatus(row("good", records: 4), snapshot: snapshot), "readable data")
        XCTAssertTrue(DiagnosticSuite.coverageStatus(row("never"), snapshot: snapshot).contains("no read recorded"))
    }
    func testRawFingerprintIgnoresDeliveryOrderButNotContent() throws {
        func digest(_ values: [Double]) throws -> String {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = RawReplayStore(scratch: try DiagnosticScratch(root: root)), start = Date(timeIntervalSince1970: 1_700_000_000)
            let writer = try store.writer(type: "Steps", from: start, to: start.addingTimeInterval(7200), style: .cumulative)
            for (i, v) in values.enumerated() { try writer.append(RawReading(start: start, end: start.addingTimeInterval(60), value: v, source: "watch"), id: "row-\(Int(v))") ; _ = i }
            try writer.finish()
            return try XCTUnwrap(store.unorderedDigest())
        }
        XCTAssertEqual(try digest([1, 2, 3]), try digest([3, 1, 2]))
        XCTAssertNotEqual(try digest([1, 2, 3]), try digest([1, 2, 4]))
        XCTAssertNotEqual(try digest([1, 2, 3]), try digest([1, 2, 3, 3]))
    }
    func testRealTransferCheckpointsAndResumesOnlyTheRemainingBatches() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sink = try DiagnosticBatchSink(root: root.appendingPathComponent("batches"), delay: 0)
        for i in 0..<5 { let data = Data("batch-\(i)".utf8); try await sink.upload(batchId: "b\(i)", gz: data, sha256: DiagnosticScratch.digest(data), typeId: "type\(i)") }
        let reports = DiagnosticReportStore(root: root.appendingPathComponent("reports"))
        var report = DiagnosticRunReport(); report.configuration["realTransfer"] = "requested"
        let first = FlakyUploader(failAfter: 2)
        do { try await DiagnosticSuite.realTransfer(sink: sink, uploader: first, report: &report, reports: reports, onUpdate: { _ in }); XCTFail("expected interruption") } catch {}
        XCTAssertEqual(report.configuration["realTransferBatches"], "2"); XCTAssertEqual(report.configuration["realTransfer"], "running")
        let second = FlakyUploader()
        try await DiagnosticSuite.realTransfer(sink: sink, uploader: second, report: &report, reports: reports, onUpdate: { _ in })
        XCTAssertEqual(second.sent, ["type2", "type3", "type4"])
        XCTAssertEqual(report.configuration["realTransfer"], "done"); XCTAssertEqual(report.configuration["realTransferBatches"], "5")
    }
    func testSuiteRefusesAnInvalidFirstCaseOrPlanBeforeTouchingHealthData() async {
        var options = DiagnosticSuite.Options(); options.delay = 0
        options.variants = [DiagnosticVariant(id: "baseline-start", strategy: "typo")]
        do { _ = try await DiagnosticSuite.run(scope: .empty, categories: ["core"], options: options, sourceFactory: { _ in XCTFail("source must not be built"); return FakeHealthSource() }, onUpdate: { _ in }); XCTFail("expected rejection") }
        catch { XCTAssertTrue(error is DiagnosticSuite.DiagnosticFailure) }
    }
}
