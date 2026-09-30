import XCTest
@testable import HealthSync

final class ReadGateTests: XCTestCase {
    private actor Counter {
        var current = 0
        var maxSeen = 0
        func enter() {
            current += 1
            maxSeen = max(maxSeen, current)
        }
        func leave() { current -= 1 }
    }

    func testNeverMoreThanTheLimitAtOnce() async {
        let gate = ReadGate(limit: 3)
        let counter = Counter()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<30 {
                group.addTask {
                    await gate.acquire()
                    await counter.enter()
                    try? await Task.sleep(for: .milliseconds(5))
                    await counter.leave()
                    gate.release()
                }
            }
        }
        let seen = await counter.maxSeen
        XCTAssertLessThanOrEqual(seen, 3)
        XCTAssertGreaterThan(seen, 1, "reads do overlap")
    }

    func testRaisingTheLimitWakesWaitingReads() async {
        let gate = ReadGate(limit: 1)
        await gate.acquire()
        let second = expectation(description: "second read gets a slot")
        Task {
            await gate.acquire()
            second.fulfill()
        }
        try? await Task.sleep(for: .milliseconds(50))
        gate.setLimit(2)
        await fulfillment(of: [second], timeout: 2)
        gate.release()
        gate.release()
    }

    func testTunerKeepsTheLimitInBounds() {
        let gate = ReadGate(limit: 12)
        let tuner = ReadTuner(gate: gate)
        for _ in 0..<5_000 {
            tuner.completed()
            XCTAssertGreaterThanOrEqual(gate.currentLimit, ReadTuner.minLimit)
            XCTAssertLessThanOrEqual(gate.currentLimit, ReadTuner.maxLimit)
        }
    }
}
