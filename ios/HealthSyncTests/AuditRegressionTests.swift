import XCTest
import HealthKit
@testable import HealthSync

final class AuditRegressionTests: XCTestCase {
    func testMissingQueuedFileMustNotAdvanceAnchor() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let box = Outbox(root: root)
        let id = UUID().uuidString.lowercased()
        let type = SyncType(id: "HKQuantityTypeIdentifierHeartRate", kind: .quantity(cumulative: false), sampleType: nil, unit: .count())
        _ = try box.enqueue(typeId: type.id, batches: [Batch(id: id, gz: Data("pending".utf8))], anchor: Data("UNUPLOADED".utf8), completes: .caughtUp)
        try FileManager.default.removeItem(at: root.appendingPathComponent("batches/\(id).ndjson.gz"))
        let uploader = RecordingUploader()
        let engine = SyncEngine(source: ScriptedSource(), uploader: uploader, outbox: box, types: [type])
        do { try await engine.flush() } catch { /* Failing closed is acceptable. */ }
        XCTAssertEqual(uploader.uploaded.count, 0)
        XCTAssertNil(box.state.anchors[type.id], "Unuploaded records must not be skipped permanently")
        XCTAssertFalse(box.state.caughtUp.contains(type.id))
    }

    func testDeadlineResumePreservesReconcileSessionAndAnchor() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let box = Outbox(root: root)
        let type = SyncType(id: "HKQuantityTypeIdentifierHeartRate", kind: .quantity(cumulative: false), sampleType: nil, unit: .count())
        let rid = UUID().uuidString.lowercased()
        let anchor = Data("PARTIAL-PASS".utf8)
        try box.update { s in
            s.lastSyncAt = Date(timeIntervalSinceNow: -40 * 86400)
            s.reconcile[type.id] = rid
            s.anchors[type.id] = anchor
            s.recentDone.insert(type.id)
            s.statsFullAt[type.id] = Date()
        }
        let engine = SyncEngine(source: ScriptedSource(), uploader: RecordingUploader(), outbox: box, types: [type])
        _ = try await engine.run(deadline: Date(timeIntervalSinceNow: -1))
        XCTAssertEqual(box.state.reconcile[type.id], rid, "Resuming must not restart an in-progress reconciliation")
        XCTAssertEqual(box.state.anchors[type.id], anchor)
    }
}
