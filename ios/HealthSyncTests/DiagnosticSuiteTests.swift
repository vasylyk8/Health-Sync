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
