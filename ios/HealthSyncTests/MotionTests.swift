import XCTest
@testable import HealthSync

final class MotionTests: XCTestCase {
    func testReduceMotionTurnsAnimationOff() {
        XCTAssertNil(Motion.resolved(Motion.smooth, reduceMotion: true, uiTesting: false))
    }

    func testUITestingTurnsAnimationOff() {
        XCTAssertNil(Motion.resolved(Motion.smooth, reduceMotion: false, uiTesting: true))
    }

    func testAnimationRunsWhenAllowed() {
        XCTAssertNotNil(Motion.resolved(Motion.smooth, reduceMotion: false, uiTesting: false))
    }

    func testStaggerDelayGrowsPerItemAndNeverGoesNegative() {
        XCTAssertEqual(Motion.staggerDelay(index: 0), 0, accuracy: 0.0001)
        XCTAssertEqual(Motion.staggerDelay(index: 3), 3 * Motion.stagger, accuracy: 0.0001)
        XCTAssertEqual(Motion.staggerDelay(index: 2, base: 0.2), 0.2 + 2 * Motion.stagger, accuracy: 0.0001)
        XCTAssertEqual(Motion.staggerDelay(index: -4), 0, accuracy: 0.0001)
    }
}
