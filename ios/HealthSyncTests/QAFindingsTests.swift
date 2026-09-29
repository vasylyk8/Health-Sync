import XCTest
@testable import HealthSync

/// QA findings (2026-09-29). Each test asserts the CORRECT behaviour inside `XCTExpectFailure`
/// because the current code gets it wrong. When a bug is fixed the expected failure stops
/// happening and the test fails: then remove the `XCTExpectFailure` wrapper. IDs match QA_REPORT.md.
final class QAFindingsTests: XCTestCase {
    var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    private func sample(_ id: String) -> Record { ["k": "s", "id": .string(id), "s": 1, "e": 1, "v": 60.0, "u": "count/min"] }

    /// I-4: one data type whose HealthKit query keeps failing must not block every type after it.
    func testOneFailingTypeDoesNotBlockTheOthers() async throws {
        let types = (0..<6).map { SyncType(id: "T\($0)", kind: .category, sampleType: nil, unit: nil) }
        let inner = ScriptedSource()
        for t in types { inner.pages[t.id] = [AnchoredPage(records: [sample("\(t.id)-a")], newAnchor: Data(t.id.utf8), objectCount: 1)] }
        let source = FailingSource(inner: inner, failing: "T0")
        let outbox = Outbox(root: root)
        let engine = SyncEngine(source: source, uploader: RecordingUploader(), outbox: outbox, types: types, config: .init(pageLimit: 5, parallelTypes: 1))
        _ = try? await engine.run()
        XCTExpectFailure("I-4: the whole sync aborts at the first failing type; T1…T5 never reach caughtUp")
        XCTAssertEqual(outbox.state.caughtUp, Set(types.dropFirst().map(\.id)))
    }

    /// I-3: "Delete All My Data" while an upload is in flight must not leave an anchor behind,
    /// otherwise the next account (after re-onboarding) silently skips that type's history.
    func testResetDuringUploadLeavesNoAnchor() async throws {
        let hr = SyncType(id: "HKQuantityTypeIdentifierHeartRate", kind: .quantity(cumulative: false), sampleType: nil, unit: .count())
        let source = ScriptedSource()
        source.pages[hr.id] = [AnchoredPage(records: [sample("a1")], newAnchor: Data("A1".utf8), objectCount: 1)]
        let outbox = Outbox(root: root)
        let uploader = ResettingUploader(outbox: outbox, resetOnType: hr.id)
        let engine = SyncEngine(source: source, uploader: uploader, outbox: outbox, types: [hr], config: .init(pageLimit: 5))
        _ = try? await engine.run()
        XCTExpectFailure("I-3: complete() re-writes the anchor into the freshly reset state")
        XCTAssertNil(outbox.state.anchors[hr.id])
        XCTAssertNil(Outbox(root: root).state.anchors[hr.id], "persisted state.json too")
    }

    /// I-6: older data added later (e.g. an import from another app) must reach the weekly full
    /// statistics recompute; today the first-ever `earliest` date is cached forever.
    func testFullStatsRecomputeStartsAtNewEarliestSample() async throws {
        let steps = SyncType(id: "HKQuantityTypeIdentifierStepCount", kind: .quantity(cumulative: true), sampleType: nil, unit: .count())
        let source = ScriptedSource()
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        source.earliest = t0.addingTimeInterval(-30 * 86_400)
        let outbox = Outbox(root: root)
        let up = RecordingUploader()
        let clock = Clock(t0)
        let engine = SyncEngine(source: source, uploader: up, outbox: outbox, types: [steps], config: .init(pageLimit: 5), now: { clock.now })
        _ = try await engine.run()
        // Two years of older steps get imported, then the weekly full recompute is due.
        let imported = t0.addingTimeInterval(-730 * 86_400)
        source.earliest = imported
        clock.now = t0.addingTimeInterval(8 * 86_400)
        let before = up.uploaded.count
        _ = try await engine.run()
        let firstStats = up.uploaded[before...].first { $0.header["mode"] as? String == "stats" }
        let windowStart = ((firstStats?.header["window"] as? [String: Any])?["start"] as? Int) ?? .max
        XCTExpectFailure("I-6: stats start at the cached earliest date; the imported history never gets merged totals")
        XCTAssertLessThanOrEqual(windowStart, Int(imported.timeIntervalSince1970 * 1000))
    }
}

final class Clock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}

/// Delegates to a scripted source but throws for one type, like a HealthKit query that errors.
final class FailingSource: HealthSource, @unchecked Sendable {
    struct QueryFailed: Error {}
    let inner: ScriptedSource
    let failing: String
    init(inner: ScriptedSource, failing: String) { self.inner = inner; self.failing = failing }
    var isAvailable: Bool { true }
    func requestAuthorization(types: [SyncType]) async throws {}
    func samples(_ type: SyncType, from: Date, to: Date) async throws -> [Record] {
        if type.id == failing { throw QueryFailed() }
        return try await inner.samples(type, from: from, to: to)
    }
    func anchoredPage(_ type: SyncType, anchor: Data?, limit: Int) async throws -> AnchoredPage {
        if type.id == failing { throw QueryFailed() }
        return try await inner.anchoredPage(type, anchor: anchor, limit: limit)
    }
    func hourlyStats(_ type: SyncType, from: Date, to: Date) async throws -> [Record] { [] }
    func earliestSampleDate(_ type: SyncType) async throws -> Date? { nil }
    func activitySummaries(from: Date, to: Date) async throws -> [Record] { [] }
    func correlations(_ type: SyncType, from: Date, to: Date) async throws -> [Record] { [] }
    func profile() -> Record? { nil }
    func observeChanges(types: [SyncType], onChange: @escaping @Sendable (SyncType, @escaping @Sendable () -> Void) -> Void) {}
}

/// Simulates the user tapping "Delete All My Data" while this batch is uploading.
final class ResettingUploader: Uploader, @unchecked Sendable {
    let outbox: Outbox
    let resetOnType: String
    init(outbox: Outbox, resetOnType: String) { self.outbox = outbox; self.resetOnType = resetOnType }
    func upload(batchId: String, gz: Data, sha256: String, typeId: String) async throws {
        if typeId == resetOnType { outbox.reset() }
    }
}
