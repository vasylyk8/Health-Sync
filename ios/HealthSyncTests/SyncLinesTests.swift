import XCTest
@testable import HealthSync

final class SyncLinesTests: XCTestCase {
    /// A first sync partway through: 3,300 workouts found, 1,787 uploaded; 1,642 of 3,285 days and 29,981 of 78,840 hours read.
    private func midSync() -> SyncProgress {
        var p = SyncProgress(detailsDone: 1_787, detailsTotal: 3_300, isSyncing: true)
        p.indexingDone = true
        p.daysTotal = 3_285
        p.daysRead = 1_642
        p.hoursRead = 29_981
        p.historySinceYear = 2017
        return p
    }

    private func states(_ p: SyncProgress) -> [SyncLine.State] { p.lines.map(\.state) }

    func testBeforeAnythingHasStartedOnlyTheFirstLineIsLoading() {
        let p = SyncProgress(detailsDone: 0, detailsTotal: 0, isSyncing: false)
        XCTAssertEqual(p.lines.map(\.name), ["Indexing", "Every day", "Every hour", "Every workout"])
        XCTAssertEqual(states(p), [.running, .waiting, .waiting, .waiting])
        XCTAssertEqual(p.headline, "Getting your workouts ready…")
    }

    func testWhileIndexingEveryLineIsLoadingExceptTheWorkouts() {
        var p = SyncProgress(detailsDone: 0, detailsTotal: 0, isSyncing: true)
        p.recentDone = true
        XCTAssertEqual(states(p), [.running, .running, .running, .waiting])
        XCTAssertEqual(p.lines[0].detail, "Reading…")
        XCTAssertEqual(p.lines[3].detail, "Waiting")
    }

    func testMidSyncShowsWhatHasBeenRead() {
        let p = midSync()
        XCTAssertEqual(states(p), [.done, .running, .running, .running])
        XCTAssertEqual(p.lines.map(\.detail), [
            "\(3_300.formatted()) workouts", "\(1_642.formatted()) days", "\(29_981.formatted()) hours", "\(1_787.formatted()) / \(3_300.formatted())",
        ])
    }

    func testFinishedLinesAreSolid() {
        var p = midSync()
        p.dailyDone = true
        p.hourlyDone = true
        p.detailsDone = 3_300
        XCTAssertEqual(states(p), [.done, .done, .done, .done])
    }

    func testLinesStopMovingWhenTheSyncIsNotRunning() {
        var p = midSync()
        p.isSyncing = false
        XCTAssertEqual(states(p), [.done, .waiting, .waiting, .waiting])
    }

    func testTheHeadlineNamesTheFinestThingStillBeingRead() {
        var p = midSync()
        XCTAssertEqual(p.headline, "Indexing every hour since 2017…")
        p.hourlyDone = true
        XCTAssertEqual(p.headline, "Indexing every day since 2017…")
        p.dailyDone = true
        XCTAssertEqual(p.headline, "Finishing every workout")
        p.detailsDone = 3_300
        XCTAssertEqual(p.headline, "Finishing up…")
    }

    func testTheHeadlineNarrowsWhenOneJobIsLeft() {
        var p = midSync()
        p.detailsDone = 3_300
        p.dailyDone = true
        XCTAssertEqual(p.headline, "Finishing every hour since 2017")
        p.hourlyDone = true
        p.dailyDone = false
        XCTAssertEqual(p.headline, "Finishing every day since 2017")
    }

    func testTheHeadlineWithoutAKnownStartYear() {
        var p = midSync()
        p.historySinceYear = nil
        XCTAssertEqual(p.headline, "Indexing every hour…")
    }

    func testSingularCounts() {
        XCTAssertEqual(Copy.Home.Line.workouts(1), "1 workout")
        XCTAssertEqual(Copy.Home.Line.days(1), "1 day")
        XCTAssertEqual(Copy.Home.Line.hours(1), "1 hour")
    }
}
