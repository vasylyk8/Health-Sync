import XCTest
@testable import HealthSync

final class UploadAttemptsTests: XCTestCase {
    private func makeAttempts() -> UploadAttempts {
        UploadAttempts(defaults: UserDefaults(suiteName: "attempts-\(UUID().uuidString)")!)
    }

    func testFirstAttemptIsNotARetry() {
        XCTAssertFalse(makeAttempts().begin("a"))
    }

    func testInterruptedAttemptIsARetryNextTime() {
        let attempts = makeAttempts()
        XCTAssertFalse(attempts.begin("a"))
        XCTAssertTrue(attempts.begin("a"), "no definite outcome yet, so the next attempt may find the object already uploaded")
    }

    func testDefiniteOutcomeForgetsTheBatch() {
        let attempts = makeAttempts()
        _ = attempts.begin("a")
        attempts.finish("a")
        XCTAssertFalse(attempts.begin("a"), "a definite rejection must never turn a later attempt into a silent success")
    }

    func testOtherBatchesAreIndependent() {
        let attempts = makeAttempts()
        _ = attempts.begin("a")
        XCTAssertFalse(attempts.begin("b"))
    }

    func testHistoryIsBounded() {
        let attempts = makeAttempts()
        for i in 0..<600 { _ = attempts.begin("id\(i)") }
        XCTAssertFalse(attempts.begin("id0"), "the oldest entries are dropped")
        XCTAssertTrue(attempts.begin("id599"))
    }
}
