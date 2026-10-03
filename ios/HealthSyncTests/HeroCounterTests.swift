import XCTest
@testable import HealthSync

final class HeroCounterTests: XCTestCase {
    func testFirstTimeCountsFromZero() {
        var counter = HeroCounter()
        XCTAssertEqual(counter.start(.sleep, to: 200), 0)
    }

    func testUpdateCountsFromTheLastShownValue() {
        var counter = HeroCounter()
        _ = counter.start(.sleep, to: 200)
        XCTAssertEqual(counter.start(.sleep, to: 255), 200, "200 → 255, not 0 → 255")
        XCTAssertEqual(counter.start(.sleep, to: 255), 255, "showing it again without a change has nothing to count")
    }

    func testEachMetricKeepsItsOwnStart() {
        var counter = HeroCounter()
        _ = counter.start(.sleep, to: 200)
        XCTAssertEqual(counter.start(.workouts, to: 12), 0, "a metric shown for the first time starts from 0")
        XCTAssertEqual(counter.start(.sleep, to: 210), 200)
    }
}
