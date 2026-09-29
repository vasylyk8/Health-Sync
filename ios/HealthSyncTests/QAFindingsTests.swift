import XCTest
@testable import HealthSync

/// Regression tests for problems found in the QA audit (2026-09-29), adapted to the workouts sync.
final class QAFindingsTests: XCTestCase {
    var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    /// I-3: "Delete All My Data" while an upload is in flight must not leave an anchor behind,
    /// otherwise the next account (after re-onboarding) silently skips that type's history.
    func testResetDuringUploadLeavesNoAnchor() async throws {
        let wt = SyncType(id: HealthTypes.workoutId, kind: .workout, sampleType: nil)
        let source = ScriptedSource()
        source.pages = [AnchoredPage(records: [["k": "w", "id": "W1", "s": 1, "e": 2, "act": 37]], newAnchor: Data("A1".utf8), objectCount: 1)]
        let outbox = Outbox(root: root)
        let uploader = ResettingUploader(outbox: outbox, resetOnType: wt.id)
        let engine = SyncEngine(source: source, uploader: uploader, outbox: outbox, scope: SyncScope(types: [wt], workoutQuantities: [], dailyMetrics: []))
        _ = try? await engine.run()
        XCTAssertNil(outbox.state.anchors[wt.id])
        XCTAssertNil(Outbox(root: root).state.anchors[wt.id], "persisted state.json too")
    }
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
