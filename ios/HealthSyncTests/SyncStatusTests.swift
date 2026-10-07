import XCTest
@testable import HealthSync

final class SyncStatusTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }
    private func lines(lastChecked: Date?, checking: Bool = false, failed: Bool = false) -> SyncStatus.Lines {
        SyncStatus.lines(lastChecked: lastChecked, checking: checking, failed: failed, now: now)
    }

    func testAgeIsCoarseAndGrows() {
        XCTAssertEqual(SyncStatus.ago(ago(0), now: now), "just now")
        XCTAssertEqual(SyncStatus.ago(ago(59), now: now), "just now")
        XCTAssertEqual(SyncStatus.ago(ago(60), now: now), "1 min ago")
        XCTAssertEqual(SyncStatus.ago(ago(5 * 60 + 40), now: now), "5 min ago")
        XCTAssertEqual(SyncStatus.ago(ago(59 * 60), now: now), "59 min ago")
        XCTAssertEqual(SyncStatus.ago(ago(3_600), now: now), "1 hr ago")
        XCTAssertEqual(SyncStatus.ago(ago(47 * 3_600), now: now), "47 hr ago")
        XCTAssertEqual(SyncStatus.ago(ago(72 * 3_600), now: now), "3 days ago")
        XCTAssertEqual(SyncStatus.ago(ago(-30), now: now), "just now", "a clock that moved back never shows a negative age")
    }

    func testUpToDateAfterACheck() {
        XCTAssertEqual(lines(lastChecked: ago(5)), .init(title: "Up to date", detail: "Checked just now"))
        XCTAssertEqual(lines(lastChecked: ago(7 * 60)), .init(title: "Up to date", detail: "Checked 7 min ago"))
        XCTAssertEqual(lines(lastChecked: ago(3 * 3_600)), .init(title: "Up to date", detail: "Checked 3 hr ago"))
    }

    func testAFreshCheckStaysUpToDateWhileTheNextOneRuns() {
        XCTAssertEqual(lines(lastChecked: ago(30), checking: true), .init(title: "Up to date", detail: "Checking…"))
        XCTAssertEqual(lines(lastChecked: ago(119), checking: true), .init(title: "Up to date", detail: "Checking…"))
    }

    func testAnOldCheckIsNotClaimedWhileTheNextOneRuns() {
        XCTAssertEqual(lines(lastChecked: ago(120), checking: true), .init(title: "Checking for new data…", detail: "Last checked 2 min ago"))
        XCTAssertEqual(lines(lastChecked: ago(3_600), checking: true), .init(title: "Checking for new data…", detail: "Last checked 1 hr ago"))
        XCTAssertEqual(lines(lastChecked: nil, checking: true), .init(title: "Checking for new data…", detail: "Keep the app open."))
    }

    func testAFailedCheckPromisesNothing() {
        XCTAssertEqual(lines(lastChecked: ago(2 * 3_600), failed: true), .init(title: "Waiting to sync", detail: "Last checked 2 hr ago"))
        XCTAssertEqual(lines(lastChecked: nil, failed: true), .init(title: "Waiting to sync", detail: "Not checked yet"))
    }

    func testARetryAfterAFailureShowsThatItIsChecking() {
        XCTAssertEqual(lines(lastChecked: ago(2 * 3_600), checking: true, failed: true), .init(title: "Checking for new data…", detail: "Last checked 2 hr ago"))
    }

    func testBeforeTheFirstCheckOfThisVersion() {
        XCTAssertEqual(lines(lastChecked: nil), .init(title: "Checking for new data…", detail: "Keep the app open."))
    }
}
