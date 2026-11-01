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

    func testTiltIsClampedToOneInEitherDirection() {
        XCTAssertEqual(TiltSource.normalized(0), 0, accuracy: 0.0001)
        XCTAssertEqual(TiltSource.normalized(TiltSource.fullDeflection / 2), 0.5, accuracy: 0.0001)
        XCTAssertEqual(TiltSource.normalized(3), 1, accuracy: 0.0001)
        XCTAssertEqual(TiltSource.normalized(-3), -1, accuracy: 0.0001)
    }

    func testQuestionFeedScrollsUpOneListHeightPerLoopAndRestarts() {
        let loop = QuestionFeed.loopSeconds
        XCTAssertEqual(QuestionFeed.offset(elapsed: 0, loopHeight: 800), 0, accuracy: 0.001)
        XCTAssertEqual(QuestionFeed.offset(elapsed: loop / 2, loopHeight: 800), -400, accuracy: 0.001)
        XCTAssertEqual(QuestionFeed.offset(elapsed: loop, loopHeight: 800), 0, accuracy: 0.001)
        XCTAssertEqual(QuestionFeed.offset(elapsed: loop * 3 + loop / 4, loopHeight: 800), -200, accuracy: 0.001)
    }

    func testQuestionFeedStaysPutUntilItsHeightIsKnown() {
        XCTAssertEqual(QuestionFeed.offset(elapsed: 12, loopHeight: 0), 0)
        XCTAssertEqual(QuestionFeed.offset(elapsed: -5, loopHeight: 800), 0, accuracy: 0.001)
    }
}
