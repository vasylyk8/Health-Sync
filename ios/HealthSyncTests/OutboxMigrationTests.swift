import XCTest
@testable import HealthSync

final class OutboxMigrationTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("batches"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("pending"), withIntermediateDirectories: true)
    }

    /// State file written by the previous app version, which synced every Health type.
    private let legacy = """
    {"anchors":{"HKWorkoutTypeIdentifier":"QQ=="},"seq":{"HKWorkoutTypeIdentifier":41,"HKQuantityTypeIdentifierHeartRate":900},
     "recentDone":["HKWorkoutTypeIdentifier"],"caughtUp":["HKWorkoutTypeIdentifier"],"statsFullAt":{},"earliest":{},
     "reconcile":{},"activityInitialDone":true,"correlationInitialDone":[],"profileHash":"abc"}
    """

    func testLegacyStateIsUpgradedKeepingSequenceNumbers() throws {
        try Data(legacy.utf8).write(to: root.appendingPathComponent("state.json"))
        try Data("old".utf8).write(to: root.appendingPathComponent("batches/old.ndjson.gz"))
        try Data("{}".utf8).write(to: root.appendingPathComponent("pending/0001-x.json"))
        let box = Outbox(root: root)
        XCTAssertEqual(box.state.schemaVersion, Outbox.State.currentSchema)
        XCTAssertNil(box.state.anchors["HKWorkoutTypeIdentifier"], "workouts are re-read from the start with full detail")
        XCTAssertTrue(box.state.caughtUp.isEmpty)
        XCTAssertTrue(box.state.recentDone.isEmpty)
        XCTAssertTrue(box.state.detailsDone.isEmpty)
        XCTAssertEqual(box.state.seq["HKWorkoutTypeIdentifier"], 41, "the server keeps the highest seq per record, so numbering must continue")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("batches").path).count, 0)
        XCTAssertTrue(box.pending().isEmpty)
        // The upgrade is persisted: opening again does not upgrade twice.
        try box.update { $0.detailsDone.insert("W1") }
        XCTAssertEqual(Outbox(root: root).state.detailsDone, ["W1"])
        XCTAssertEqual(Outbox(root: root).state.seq["HKWorkoutTypeIdentifier"], 41)
    }

    func testCurrentStateRoundTrips() throws {
        let box = Outbox(root: root)
        try box.update {
            $0.anchors["w"] = Data("A".utf8)
            $0.detailsDone = ["a", "b"]
            $0.workoutTotal = 5
            $0.dailyFullAt = Date(timeIntervalSince1970: 100)
        }
        let again = Outbox(root: root).state
        XCTAssertEqual(again.anchors["w"], Data("A".utf8))
        XCTAssertEqual(again.detailsDone, ["a", "b"])
        XCTAssertEqual(again.workoutTotal, 5)
        XCTAssertEqual(again.dailyFullAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(again.schemaVersion, Outbox.State.currentSchema)
    }

    func testCompletionsUpdateState() throws {
        let box = Outbox(root: root)
        let b = Batch(id: UUID().uuidString.lowercased(), gz: Data("x".utf8))
        var e = try box.enqueue(typeId: HealthTypes.streamId, batches: [b], anchor: nil, completes: .detailDone("W9"))
        try box.markUploaded(&e, batchId: b.id)
        try box.complete(e)
        XCTAssertEqual(box.state.detailsDone, ["W9"])
        let d = try box.enqueue(typeId: HealthTypes.dailyId, batches: [], anchor: nil, completes: .dailyFull(Date(timeIntervalSince1970: 7)))
        try box.complete(d)
        XCTAssertEqual(box.state.dailyFullAt, Date(timeIntervalSince1970: 7))
    }
}
