import XCTest
@testable import HealthSync

final class DailyMetricReadsTests: XCTestCase {
    private enum Expected: Error { case failed }
    private actor Activity {
        var active = 0, peak = 0, started = 0
        func begin() { active += 1; started += 1; peak = max(peak, active) }
        func end() { active -= 1 }
        func counts() -> (Int, Int, Int) { (active, peak, started) }
    }

    func testOutOfOrderResultsKeepEveryDestinationAndBound() async throws {
        for width in [2, 4] {
            let activity = Activity()
            let results = try await DailyMetricReads.collect(Array(0..<65), width: width) { index in
                await activity.begin()
                try await Task.sleep(for: .milliseconds(index % 2 == 0 ? 5 : 1))
                await activity.end()
                return index * 10
            }
            XCTAssertEqual(try results.map { try $0.get() }, (0..<65).map { $0 * 10 })
            let counts = await activity.counts()
            XCTAssertEqual(counts.0, 0)
            XCTAssertLessThanOrEqual(counts.1, width)
            XCTAssertGreaterThan(counts.1, 1)
            XCTAssertEqual(counts.2, 65)
        }
    }

    func testFailureRetainsItsIndexAndAllOtherResults() async throws {
        let results = try await DailyMetricReads.collect(Array(0..<65), width: 4) { index in
            if index == 0 || index == 33 { throw Expected.failed }
            return index
        }
        XCTAssertEqual(results.count, 65)
        for (index, result) in results.enumerated() {
            if index == 0 || index == 33 { XCTAssertThrowsError(try result.get()) }
            else { XCTAssertEqual(try result.get(), index) }
        }
    }

    func testSlotsRejectDuplicateMissingAndInvalidIndices() throws {
        var slots = DailyMetricSlots<Int>(count: 2)
        XCTAssertThrowsError(try slots.record(index: -1, result: .success(1)))
        XCTAssertThrowsError(try slots.record(index: 2, result: .success(1)))
        try slots.record(index: 0, result: .success(10))
        XCTAssertThrowsError(try slots.record(index: 0, result: .success(99)))
        XCTAssertThrowsError(try slots.complete())
        try slots.record(index: 1, result: .failure(Expected.failed))
        let completed = try slots.complete()
        XCTAssertEqual(try completed[0].get(), 10)
        XCTAssertThrowsError(try completed[1].get())
    }

    func testEmptyAndSmallInputs() async throws {
        let empty = try await DailyMetricReads.collect([Int](), width: 4) { $0 }
        XCTAssertTrue(empty.isEmpty)
        let small = try await DailyMetricReads.collect([7], width: 4) { $0 }
        XCTAssertEqual(try small[0].get(), 7)
    }

    func testCancellationDoesNotBecomeAnOrdinaryMetricFailure() async throws {
        let activity = Activity()
        let task = Task {
            try await DailyMetricReads.collect(Array(0..<65), width: 2) { index in
                await activity.begin()
                try await Task.sleep(for: .seconds(30))
                return index
            }
        }
        let deadline = Date().addingTimeInterval(5)
        while await activity.counts().2 < 2, Date() < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("cancelled collection must throw") }
        catch is CancellationError {} catch { XCTFail("unexpected error: \(error)") }
        let counts = await activity.counts()
        XCTAssertEqual(counts.2, 2)
    }

    func testRepeatedCollectionDoesNotReuseResults() async throws {
        for width in [2, 4] {
            for run in 0..<10 {
                let values = try await DailyMetricReads.collect(Array(0..<65), width: width) { index in
                    await Task.yield()
                    return run * 100 + index
                }
                XCTAssertEqual(try values.map { try $0.get() }, (0..<65).map { run * 100 + $0 })
            }
        }
    }
}
