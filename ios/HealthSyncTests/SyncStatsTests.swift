import SwiftUI
import XCTest
@testable import HealthSync

final class SyncStatsTests: XCTestCase {
    private let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func store(url: URL? = nil) -> SyncStatsStore { SyncStatsStore(url: url, calendar: utc) }

    private func workout(_ id: String, startMs: Int64 = 1_700_000_000_000, seconds: Double = 600, type: String = "Running",
                         hrAvg: Double? = nil, metadata: [String: RecordValue]? = nil) -> Record {
        var r: Record = ["k": "w", "id": .string(id), "s": .int(startMs), "e": .int(startMs + 1000), "actName": .string(type), "dur": .double(seconds)]
        if let hrAvg { r["hrAvg"] = .double(hrAvg) }
        if let metadata { r["md"] = .object(metadata) }
        return r
    }

    private func day(_ key: String, _ metrics: [String: RecordValue]) -> Record {
        ["k": "day", "day": .string(key), "m": .object(metrics)]
    }

    // MARK: Store

    func testWorkoutSummariesAreCountedOnceEvenWhenReadTwice() {
        let s = store()
        s.addWorkoutSummaries([workout("A"), workout("B", type: "Cycling")])
        s.addWorkoutSummaries([workout("A")])
        let snap = s.snapshot()
        XCTAssertEqual(snap.workouts, 2)
        XCTAssertEqual(snap.trainingSeconds, 1200, accuracy: 0.001)
        XCTAssertEqual(snap.workoutTypes, 2)
    }

    func testElevationBeatsAndActiveDays() {
        let s = store()
        let day1: Int64 = 1_700_000_000_000
        let day2: Int64 = day1 + 86_400_000
        s.addWorkoutSummaries([
            workout("A", startMs: day1, seconds: 1800, hrAvg: 140, metadata: ["HKElevationAscended": .string("1500 cm")]),
            workout("B", startMs: day1 + 3_600_000, seconds: 600),
            workout("C", startMs: day2, seconds: 600, metadata: ["HKElevationAscended": .string("12 m")]),
        ])
        let snap = s.snapshot()
        XCTAssertEqual(snap.climbedMeters, 27, accuracy: 0.001)
        XCTAssertEqual(snap.workoutBeats, 140 * 1800 / 60, accuracy: 0.001)
        XCTAssertEqual(snap.workoutDays, 2)
    }

    func testDeletedWorkoutsAreRemovedWithTheirRawDataCounts() {
        let s = store()
        s.addWorkoutSummaries([workout("A"), workout("B")])
        s.setDetail(workoutId: "A", heartRate: 500, gpsPoints: 100)
        s.setDetail(workoutId: "B", heartRate: 300, gpsPoints: 0)
        XCTAssertEqual(s.snapshot().hrReadings, 800)
        s.addWorkoutSummaries([["k": "d", "id": "A"]])
        let snap = s.snapshot()
        XCTAssertEqual(snap.workouts, 1)
        XCTAssertEqual(snap.hrReadings, 300)
        XCTAssertEqual(snap.gpsPoints, 0)
    }

    func testDetailCountsReplaceInsteadOfAdding() {
        let s = store()
        s.setDetail(workoutId: "A", heartRate: 500, gpsPoints: 10)
        s.setDetail(workoutId: "A", heartRate: 520, gpsPoints: 12)
        XCTAssertEqual(s.snapshot().hrReadings, 520)
        XCTAssertEqual(s.snapshot().gpsPoints, 12)
    }

    func testDailyRowsAddUpAndAreReplacedWhenReadAgain() {
        let s = store()
        s.addDays([
            day("2024-01-01", ["steps": 8000, "walkRunDistanceM": 6000, "sleepAsleepMin": 420, "activeKcal": 500, "hrv": 40]),
            day("2024-01-02", ["steps": 10000, "cyclingDistanceM": 20000, "swimDistanceM": 1000, "activeKcal": 600]),
        ])
        var snap = s.snapshot()
        XCTAssertEqual(snap.steps, 18000)
        XCTAssertEqual(snap.walkRunMeters, 6000)
        XCTAssertEqual(snap.cyclingMeters, 20000)
        XCTAssertEqual(snap.swimMeters, 1000)
        XCTAssertEqual(snap.sleepMinutes, 420)
        XCTAssertEqual(snap.activeKcal, 1100)
        XCTAssertEqual(snap.hrvDays, 1)
        // The weekly full pass reads the same day again: it replaces, never adds.
        s.addDays([day("2024-01-01", ["steps": 9000])])
        snap = s.snapshot()
        XCTAssertEqual(snap.steps, 19000)
        XCTAssertEqual(snap.hrvDays, 0)
    }

    func testVersionOnlyChangesWhenTotalsChange() {
        let s = store()
        s.addDays([day("2024-01-01", ["steps": 100])])
        let v = s.version
        s.addDays([day("2024-01-01", ["steps": 100])])
        XCTAssertEqual(s.version, v)
        s.addDays([day("2024-01-01", ["steps": 101])])
        XCTAssertGreaterThan(s.version, v)
    }

    func testTotalsSurviveARelaunchAndResetClearsThem() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stats-\(UUID().uuidString).json")
        let first = store(url: url)
        first.addWorkoutSummaries([workout("A")])
        first.setDetail(workoutId: "A", heartRate: 42, gpsPoints: 7)
        first.flush()
        let second = store(url: url)
        XCTAssertEqual(second.snapshot().workouts, 1)
        XCTAssertEqual(second.snapshot().hrReadings, 42)
        XCTAssertEqual(second.snapshot().gpsPoints, 7)
        second.reset()
        XCTAssertEqual(second.snapshot().workouts, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(store(url: url).snapshot().workouts, 0)
    }

    func testMetadataQuantitiesAreParsedToMetres() {
        XCTAssertEqual(SyncStatsStore.meters(from: "1500 cm"), 15)
        XCTAssertEqual(SyncStatsStore.meters(from: "12.5 m"), 12.5)
        XCTAssertEqual(SyncStatsStore.meters(from: "1 km"), 1000)
        XCTAssertEqual(SyncStatsStore.meters(from: "100 ft") ?? 0, 30.48, accuracy: 0.001)
        XCTAssertNil(SyncStatsStore.meters(from: "5 degC"))
        XCTAssertNil(SyncStatsStore.meters(from: "abc"))
    }

    func testTotalsAreCompleteOnlyWhenCountingStartedWithTheFirstSync() throws {
        XCTAssertFalse(store().snapshot().partial)
        XCTAssertFalse(SyncStatsStore(url: nil, calendar: utc, historyExists: false).snapshot().partial)
        let late = SyncStatsStore(url: nil, calendar: utc, historyExists: true)
        XCTAssertTrue(late.snapshot().partial)
        XCTAssertTrue(late.needsDailyBackfill)
        late.markDailyBackfilled()
        XCTAssertFalse(late.needsDailyBackfill)
        XCTAssertTrue(late.snapshot().partial, "still partial: workout details are not read again")
        XCTAssertFalse(store().needsDailyBackfill)

        // A stats file from a build that did not record this is treated as partial.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stats-\(UUID().uuidString).json")
        try Data(#"{"days":{},"workouts":{},"heartRate":{},"gps":{}}"#.utf8).write(to: url)
        let legacy = SyncStatsStore(url: url, calendar: utc)
        XCTAssertTrue(legacy.snapshot().partial)

        // The flags survive a relaunch, and Delete All My Data starts a complete count again.
        late.markDailyBackfilled()
        let saved = FileManager.default.temporaryDirectory.appendingPathComponent("stats-\(UUID().uuidString).json")
        let first = SyncStatsStore(url: saved, calendar: utc, historyExists: true)
        first.markDailyBackfilled()
        first.flush()
        let second = SyncStatsStore(url: saved, calendar: utc)
        XCTAssertTrue(second.snapshot().partial)
        XCTAssertFalse(second.needsDailyBackfill)
        second.reset()
        XCTAssertFalse(second.snapshot().partial)
    }

    // MARK: Engine

    func testEngineFillsTheTotalsFromWhatItReadsAndUploads() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let workoutType = SyncType(id: HealthTypes.workoutId, kind: .workout, sampleType: nil)
        let scope = SyncScope(types: [workoutType], workoutQuantities: [], dailyMetrics: [DailyMetric(key: "rings", kind: .rings)])
        let source = ScriptedSource()
        source.recent = [workout("W2")]
        source.earliestDaily = Date(timeIntervalSinceNow: -3 * 86_400)
        source.daily = [day("2024-06-20", ["steps": 5000])]
        source.pages = [AnchoredPage(records: [workout("W2"), workout("W1", seconds: 1200)], newAnchor: Data("A".utf8), objectCount: 2)]
        source.index = [WorkoutRef(id: "W2", start: Date()), WorkoutRef(id: "W1", start: Date(timeIntervalSinceNow: -100))]
        func detail(_ id: String, hr: Int, gps: Int) -> [Record] {
            [WorkoutRecords.mark(wid: id, gen: 1, expected: ["HeartRate": hr, "route": gps])]
        }
        // A stream record is needed besides the marker, or the workout counts as "no raw data".
        func withStream(_ id: String, hr: Int, gps: Int) -> [Record] {
            [["k": "ws", "wid": .string(id), "st": "HeartRate", "gen": 1, "t": .array([1, 2]), "v": .array([140, 141])]] + detail(id, hr: hr, gps: gps)
        }
        source.details = ["W2": withStream("W2", hr: 500, gps: 120), "W1": withStream("W1", hr: 300, gps: 0)]
        let engine = SyncEngine(source: source, uploader: RecordingUploader(), outbox: Outbox(root: root), scope: scope)
        _ = try await engine.run()
        let stats = await engine.progress.stats
        XCTAssertEqual(stats.workouts, 2)
        XCTAssertEqual(stats.hrReadings, 800)
        XCTAssertEqual(stats.gpsPoints, 120)
        XCTAssertEqual(stats.steps, 5000)
        XCTAssertEqual(stats.trainingSeconds, 1800, accuracy: 0.001)

        // A new engine over the same folder starts from the saved totals.
        await engine.flushStats()
        let again = SyncEngine(source: ScriptedSource(), uploader: RecordingUploader(), outbox: Outbox(root: root), scope: scope)
        let restored = await again.progress.stats
        XCTAssertEqual(restored.hrReadings, 800)
        await again.resetStats()
        let cleared = await again.progress.stats
        XCTAssertEqual(cleared.hrReadings, 0)
    }
}

final class HeroMetricsTests: XCTestCase {
    private func digits(_ s: String) -> String { s.filter(\.isNumber) }

    func testPartialTotalsLeaveOutTheMetricsBuiltFromWorkoutDetails() {
        var s = SyncStatsSnapshot()
        s.partial = true
        s.workouts = 5
        s.hrReadings = 1000
        s.gpsPoints = 500
        s.trainingSeconds = 36_000
        s.steps = 20_000
        let metrics = HeroMetrics.make(stats: s, workoutsUploaded: 5, historyStart: nil)
        XCTAssertEqual(metrics.map(\.kind), [.workouts, .steps])
    }

    func testBeforeAnythingIsReadThereIsOneZeroWorkoutsMetric() {
        let metrics = HeroMetrics.make(stats: SyncStatsSnapshot(), workoutsUploaded: 0, historyStart: nil)
        XCTAssertEqual(metrics.map(\.kind), [.workouts])
        XCTAssertEqual(metrics.first?.value, 0)
    }

    func testOnlyMetricsWithDataAreIncludedInRotationOrder() {
        var s = SyncStatsSnapshot()
        s.workouts = 3337
        s.hrReadings = 8_200_000
        s.steps = 38_700_000
        s.gpsPoints = 1_900_000
        let metrics = HeroMetrics.make(stats: s, workoutsUploaded: 10, historyStart: nil)
        XCTAssertEqual(metrics.map(\.kind), [.heartRate, .workouts, .steps, .gps])
        XCTAssertEqual(metrics[1].value, 3337, "the larger of known and uploaded workouts")
    }

    func testUploadedWorkoutsCanExceedTheKnownCount() {
        var s = SyncStatsSnapshot()
        s.workouts = 2
        let metrics = HeroMetrics.make(stats: s, workoutsUploaded: 5, historyStart: nil)
        XCTAssertEqual(metrics.first?.value, 5)
    }

    func testCaptionsCompareWhenBigEnoughAndFallBackWhenNot() {
        var s = SyncStatsSnapshot()
        s.steps = 111_000
        s.sleepMinutes = 60
        let metrics = HeroMetrics.make(stats: s, workoutsUploaded: 0, historyStart: nil)
        let steps = metrics.first { $0.kind == .steps }
        XCTAssertEqual(steps?.caption, "≈ 2 marathons on foot")
        let sleep = metrics.first { $0.kind == .sleep }
        XCTAssertEqual(sleep?.caption, Copy.Metric.sleepFallback)
    }

    func testHistoryMetricUsesTheStartDate() throws {
        let start = Date(timeIntervalSince1970: 1_373_000_000) // July 2013
        let now = start.addingTimeInterval(100 * 86_400)
        let metrics = HeroMetrics.make(stats: SyncStatsSnapshot(), workoutsUploaded: 0, historyStart: start, now: now)
        let history = try XCTUnwrap(metrics.first { $0.kind == .history })
        XCTAssertEqual(history.value, 100, accuracy: 0.01)
        XCTAssertTrue(history.caption.hasPrefix("Back to "))
    }

    func testNumbersAreWrittenShortOrWhole() {
        let big = NumberSpec.make(for: 8_200_000, wholeNumber: false)
        XCTAssertEqual(big.unit, "M")
        XCTAssertEqual(big.text(8_200_000), "8.2")
        XCTAssertEqual(NumberSpec.make(for: 488_000_000, wholeNumber: false).text(488_000_000), "488")
        XCTAssertEqual(NumberSpec.make(for: 21_600_000, wholeNumber: false).text(21_600_000), "21.6")
        XCTAssertEqual(NumberSpec.make(for: 31_500, wholeNumber: false).unit, "K")
        XCTAssertEqual(NumberSpec.make(for: 31_500, wholeNumber: false).text(31_500), "31.5")
        XCTAssertEqual(NumberSpec.make(for: 2_100_000_000, wholeNumber: false).unit, "B")
        let small = NumberSpec.make(for: 3337, wholeNumber: false)
        XCTAssertEqual(small.unit, "")
        XCTAssertEqual(digits(small.text(3337)), "3337")
        let whole = NumberSpec.make(for: 24_300, wholeNumber: true)
        XCTAssertEqual(whole.unit, "")
        XCTAssertEqual(digits(whole.text(24_300)), "24300")
    }

    func testFontSizeShrinksAsTheTextGrows() {
        XCTAssertEqual(NumberSpec.fontSize(forTextLength: 3), 176)
        XCTAssertEqual(NumberSpec.fontSize(forTextLength: 4), 148)
        XCTAssertEqual(NumberSpec.fontSize(forTextLength: 5), 124)
        XCTAssertEqual(NumberSpec.fontSize(forTextLength: 6), 108)
        XCTAssertEqual(NumberSpec.fontSize(forTextLength: 9), 92)
    }

    func testSpecialEditionRunsUntilTheEndOfTheLastDay() {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        func date(_ d: Int, hour: Int) -> Date { c.date(from: DateComponents(year: 2026, month: 10, day: d, hour: hour))! }
        XCTAssertEqual(SpecialEdition.active(now: date(2, hour: 12), calendar: c, arguments: [])?.id, "chicago-marathon-2026")
        XCTAssertEqual(SpecialEdition.active(now: date(11, hour: 23), calendar: c, arguments: [])?.id, "chicago-marathon-2026")
        XCTAssertNotNil(SpecialEdition.active(now: date(17, hour: 23), calendar: c, arguments: []), "the medal stays a week after race day")
        XCTAssertNil(SpecialEdition.active(now: date(18, hour: 0), calendar: c, arguments: []))
        XCTAssertNil(SpecialEdition.active(now: date(2, hour: 12), calendar: c, arguments: ["-noSpecialEdition"]))
        XCTAssertNotNil(SpecialEdition.active(now: date(25, hour: 12), calendar: c, arguments: ["-specialEdition"]))
    }

    func testTheNewestEditionInItsWindowWins() {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        let next = SpecialEdition(id: "next-race", raceName: "Next Race", raceDay: DateComponents(year: 2027, month: 4, day: 18),
                                  lastDay: DateComponents(year: 2027, month: 4, day: 24), medalTop: "NEXT", medalBottom: "APR 18, 2027",
                                  caption: "GO", hours: 2...8, defaultGoal: (3, 45), art: { AnyView(EmptyView()) })
        let editions = [next, SpecialEdition.chicago2026]
        let now = c.date(from: DateComponents(year: 2027, month: 4, day: 1))!
        XCTAssertEqual(SpecialEdition.active(now: now, calendar: c, arguments: [], editions: editions)?.id, "next-race")
        XCTAssertEqual(next.raceDate, "2027-04-18")
        XCTAssertEqual(next.defaultGoalSeconds, 3 * 3600 + 45 * 60)
        XCTAssertEqual(SpecialEdition.timeText(seconds: 16_200), "4:30", "hours and minutes only")
        XCTAssertEqual(SpecialEdition.chicago2026.prompt("4:30"), "Am I in 4:30 shape for Chicago?")
    }

    func testRaceGoalIsKeptUntilTheServerHasIt() {
        let defaults = UserDefaults(suiteName: "goal-\(UUID().uuidString)")!
        let store = RaceGoalStore(defaults: defaults)
        XCTAssertNil(store.goal(for: "r"))
        store.save(16_200, for: "r")
        XCTAssertEqual(store.goal(for: "r"), 16_200)
        XCTAssertTrue(store.isPending("r"))
        store.markSent("r")
        XCTAssertFalse(store.isPending("r"))
        store.clear(editions: [SpecialEdition(id: "r", raceName: "R", raceDay: DateComponents(year: 2026, month: 1, day: 1),
                                              lastDay: DateComponents(year: 2026, month: 1, day: 2), medalTop: "", medalBottom: "", caption: "",
                                              hours: 2...8, defaultGoal: (4, 30), art: { AnyView(EmptyView()) })])
        XCTAssertNil(store.goal(for: "r"))
    }
}

final class SyncEstimatorTests: XCTestCase {
    /// Progress of a first sync. By default the daily and hourly history are finished, so only the workouts count.
    private func firstSync(done: Int = 0, total: Int = 1000, daily: Double = 1, hourly: Double = 1,
                          dailyDone: Bool = true, hourlyDone: Bool = true, syncing: Bool = true) -> SyncProgress {
        var p = SyncProgress(detailsDone: done, detailsTotal: total, isSyncing: syncing)
        p.indexingDone = true
        p.dailyDone = dailyDone
        p.hourlyDone = hourlyDone
        p.dailyFraction = daily
        p.hourlyFraction = hourly
        return p
    }

    /// Seconds shown, with "almost done" as 0 and "over an hour" as 100000.
    private func seconds(_ e: SyncEstimator) -> Int {
        switch e.estimate.kind {
        case .left(let s): return s
        case .almostDone: return 0
        case .overAnHour: return 100_000
        default: return -1
        }
    }

    func testStaysEstimatingUntilThereIsEnoughToMeasure() {
        var e = SyncEstimator()
        e.record(firstSync(done: 0), now: 0)
        XCTAssertEqual(e.estimate.kind, .estimating)
        e.record(firstSync(done: 3), now: 4)
        XCTAssertEqual(e.estimate.kind, .estimating, "less than eight seconds of measurements")
    }

    func testNothingChangesWhileTheSyncIsNotRunning() {
        var e = SyncEstimator()
        for t in [0.0, 5, 10] { e.record(firstSync(done: Int(t), syncing: false), now: t) }
        XCTAssertEqual(e.estimate.kind, .estimating)
    }

    func testEstimateIsRoundedUpToAStep() {
        var e = SyncEstimator()
        // 1 workout per second, 990 left after ten seconds: 16.5 minutes, shown as the 15 to 20 step.
        for t in [0.0, 5, 10] { e.record(firstSync(done: Int(t)), now: t) }
        XCTAssertEqual(e.estimate.kind, .left(1_200))
        XCTAssertEqual(e.estimate.text, "About 15–20 min left")
    }

    func testShortSyncsCountInHalfMinutes() {
        var e = SyncEstimator()
        // 10 workouts per second, 900 left after ten seconds: 90 seconds, plus the closing batch.
        for t in [0.0, 5, 10] { e.record(firstSync(done: Int(10 * t)), now: t) }
        XCTAssertEqual(e.estimate.kind, .left(120))
        XCTAssertEqual(e.estimate.text, "About 2 min left")
    }

    func testTheSlowestJobSetsTheTime() {
        var e = SyncEstimator()
        // Workouts would be done in 90 seconds, but the hourly history has read 5% in ten seconds: 190 seconds left.
        e.record(firstSync(done: 0, hourly: 0, hourlyDone: false), now: 0)
        e.record(firstSync(done: 50, hourly: 0.025, hourlyDone: false), now: 5)
        e.record(firstSync(done: 100, hourly: 0.05, hourlyDone: false), now: 10)
        XCTAssertEqual(e.estimate.kind, .left(240))
        XCTAssertEqual(e.estimate.text, "About 4 min left")
    }

    func testStaysEstimatingWhileAJobHasNotMovedYet() {
        var e = SyncEstimator()
        for t in [0.0, 5, 10] { e.record(firstSync(done: Int(10 * t), daily: 0, dailyDone: false), now: t) }
        XCTAssertEqual(e.estimate.kind, .estimating, "the daily history has not finished a year yet, so nothing is known about it")
    }

    func testAJobThatIsOverdueIsNeverAlmostDone() {
        var e = SyncEstimator()
        e.record(firstSync(done: 0, hourly: 0, hourlyDone: false), now: 0)
        e.record(firstSync(done: 50, hourly: 0.5, hourlyDone: false), now: 5)
        // The hourly history predicted itself done at 10 s and still is not; the workouts finished long ago.
        e.record(firstSync(done: 1000, hourly: 0.5, hourlyDone: false), now: 60)
        XCTAssertEqual(e.estimate.kind, .left(60))
        XCTAssertEqual(e.estimate.text, "Less than a minute left")
    }

    func testEstimateNeverRisesForShortSlowdowns() {
        var e = SyncEstimator()
        for t in [0.0, 5, 10] { e.record(firstSync(done: Int(t)), now: t) }
        XCTAssertEqual(e.estimate.kind, .left(1_200))
        // Speed drops to a fifth: the raw estimate rises, the display holds for half a minute.
        var done = 10
        for t in stride(from: 15.0, through: 40.0, by: 5.0) {
            done += 1
            e.record(firstSync(done: done), now: t)
            XCTAssertLessThanOrEqual(seconds(e), 1_200, "at \(t)s")
        }
    }

    func testALastingSlowdownIsEventuallyShown() {
        var e = SyncEstimator()
        for t in [0.0, 5, 10] { e.record(firstSync(done: Int(t)), now: t) }
        var done = 10
        for t in stride(from: 15.0, through: 400.0, by: 5.0) {
            done += 1
            e.record(firstSync(done: done), now: t)
        }
        XCTAssertGreaterThan(seconds(e), 1_200)
    }

    func testEstimateFallsAsWorkIsDone() {
        var e = SyncEstimator()
        for t in [0.0, 5, 10] { e.record(firstSync(done: Int(10 * t)), now: t) }
        let first = seconds(e)
        for t in [15.0, 20, 60] { e.record(firstSync(done: Int(10 * t)), now: t) }
        XCTAssertLessThan(seconds(e), first)
    }

    func testAlmostDoneWhenEveryJobIsFinished() {
        var e = SyncEstimator()
        e.record(firstSync(done: 0), now: 0)
        e.record(firstSync(done: 1000), now: 20)
        XCTAssertEqual(e.estimate.kind, .almostDone)
    }

    func testFinishedWhenTheHistoryIsComplete() {
        var e = SyncEstimator()
        var p = firstSync(done: 10, total: 10)
        p.stepsTotal = 14
        p.stepsDone = 14
        e.record(p, now: 20)
        XCTAssertEqual(e.estimate.kind, .finished)
    }

    func testStepsAreOrderedAndCoverTheRange() {
        XCTAssertEqual(SyncEstimator.steps, SyncEstimator.steps.sorted())
        XCTAssertEqual(SyncEstimator.index(forSeconds: 20), -1)
        XCTAssertEqual(SyncEstimator.estimate(forIndex: SyncEstimator.index(forSeconds: 20)).kind, .almostDone)
        XCTAssertEqual(SyncEstimator.estimate(forIndex: SyncEstimator.index(forSeconds: 31)).kind, .left(60))
        XCTAssertEqual(SyncEstimator.estimate(forIndex: SyncEstimator.index(forSeconds: 100)).kind, .left(120))
        XCTAssertEqual(SyncEstimator.estimate(forIndex: SyncEstimator.index(forSeconds: 1_900)).kind, .left(2_400))
        XCTAssertEqual(SyncEstimator.estimate(forIndex: SyncEstimator.index(forSeconds: 3_600)).kind, .left(3_600))
        XCTAssertEqual(SyncEstimator.estimate(forIndex: SyncEstimator.index(forSeconds: 3_601)).kind, .overAnHour)
    }

    func testTimeLeftText() {
        let expected: [Int: String] = [
            60: "Less than a minute left", 90: "About 1½ min left", 120: "About 2 min left", 150: "About 2½ min left",
            180: "About 3 min left", 240: "About 4 min left", 600: "About 10 min left", 900: "About 10–15 min left",
            1_800: "About 25–30 min left", 2_400: "About 30–40 min left", 3_600: "About 50–60 min left",
        ]
        for (seconds, text) in expected { XCTAssertEqual(Copy.Home.timeLeft(seconds: seconds), text, "\(seconds) s") }
        for step in SyncEstimator.steps { XCTAssertTrue(Copy.Home.timeLeft(seconds: step).hasSuffix(" left"), "\(step) s") }
    }
}

