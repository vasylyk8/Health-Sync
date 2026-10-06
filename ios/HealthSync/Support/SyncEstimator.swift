import Foundation

/// A rough time left for the first sync, shown in steps coarse enough that small changes in speed never make it jump.
/// The number only goes down (a slowdown that lasts half a minute is allowed through).
struct SyncEstimate: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case estimating
        /// The time left as the top of the step it falls in, in seconds (see `SyncEstimator.steps`).
        case left(Int)
        case almostDone
        case overAnHour
        case finished
    }

    var kind: Kind = .estimating

    var text: String {
        switch kind {
        case .estimating: return Copy.Home.estimating
        case .left(let seconds): return Copy.Home.timeLeft(seconds: seconds)
        case .almostDone: return Copy.Home.almostDone
        case .overAnHour: return Copy.Home.overAnHour
        case .finished: return Copy.Home.upToDate
        }
    }
}

/// The first sync runs three jobs side by side: the daily history, the hourly history and the workouts. It ends when the
/// slowest one does, so the estimate is the latest finish among the jobs that are still running. While one of them has not
/// shown any progress yet there is nothing to base a number on, and the estimate stays "estimating".
struct SyncEstimator {
    /// The times the estimate can show, in seconds (the top of each step). Short syncs get steps of 30 seconds.
    static let steps = [60, 90, 120, 150, 180, 240, 300, 360, 420, 480, 540, 600, 900, 1200, 1500, 1800, 2400, 3000, 3600]
    /// At or under this the estimate says "almost done".
    static let almostDoneBelow: TimeInterval = 30
    /// How long a higher estimate must hold before it replaces a lower one.
    static let riseDelay: TimeInterval = 30
    /// Workout speed is measured over this long a window.
    static let window: TimeInterval = 90
    /// And needs at least this much time of measurements.
    static let minimumSpan: TimeInterval = 8
    /// Time for what follows the three jobs (the closing status batch).
    static let finishing: TimeInterval = 5
    /// A job that should have finished by now but has not counts as this much time left, so a stall never reads "almost done".
    static let overdue: TimeInterval = 45

    /// A job that advances in chunks (a year of history at a time): its end is predicted from how fast it went so far.
    private struct Job {
        var done = false
        var startedAt: TimeInterval?
        var startFraction = 0.0
        var lastFraction = 0.0
        var finishAt: TimeInterval?
    }

    private var samples: [(time: TimeInterval, done: Int)] = []
    private var workoutsDone = false
    private var workoutsFinishAt: TimeInterval?
    private var daily = Job()
    private var hourly = Job()
    private var lowest: Int?
    private var risingSince: TimeInterval?
    private(set) var estimate = SyncEstimate()

    /// Feed every progress update. `now` is any steadily increasing clock, in seconds.
    mutating func record(_ p: SyncProgress, now: TimeInterval) {
        if p.historyComplete {
            self = SyncEstimator()
            estimate = SyncEstimate(kind: .finished)
            return
        }
        guard p.isSyncing else { return }

        updateWorkouts(done: p.detailsDone, total: p.detailsTotal, finished: p.indexingDone && p.detailsDone >= p.detailsTotal, now: now)
        Self.update(&daily, fraction: p.dailyFraction, done: p.dailyDone, now: now)
        Self.update(&hourly, fraction: p.hourlyFraction, done: p.hourlyDone, now: now)

        // Every job still running needs a prediction; otherwise there is nothing to say yet.
        var finishes: [TimeInterval] = []
        if !workoutsDone {
            guard let at = workoutsFinishAt else { return }
            finishes.append(at)
        }
        for job in [daily, hourly] where !job.done {
            guard let at = job.finishAt else { return }
            finishes.append(at)
        }
        let left = finishes.map { $0 > now ? $0 - now : Self.overdue }.max() ?? 0
        var index = Self.index(forSeconds: left + Self.finishing)
        if let low = lowest, index > low {
            let since = risingSince ?? now
            risingSince = since
            if now - since < Self.riseDelay { index = low } else { risingSince = nil }
        } else {
            risingSince = nil
        }
        lowest = index
        estimate = Self.estimate(forIndex: index)
    }

    /// Workouts go steadily, so their speed is taken from the last stretch of time.
    private mutating func updateWorkouts(done: Int, total: Int, finished: Bool, now: TimeInterval) {
        workoutsDone = finished
        if finished {
            workoutsFinishAt = nil
            samples = []
            return
        }
        guard total > 0 else { return }
        if samples.last?.done != done { samples.append((now, done)) }
        samples.removeAll { now - $0.time > Self.window }
        guard let first = samples.first, let last = samples.last, last.done > first.done, last.time - first.time >= Self.minimumSpan else { return }
        let perSecond = Double(last.done - first.done) / (last.time - first.time)
        workoutsFinishAt = now + Double(max(0, total - done)) / perSecond
    }

    /// The prediction is renewed whenever the job moves on, and stands in between (a year of history takes a while to read).
    private static func update(_ job: inout Job, fraction: Double, done: Bool, now: TimeInterval) {
        job.done = done
        if done {
            job.finishAt = nil
            return
        }
        guard let startedAt = job.startedAt else {
            job.startedAt = now
            job.startFraction = fraction
            job.lastFraction = fraction
            return
        }
        guard fraction > job.lastFraction, now - startedAt >= 1 else { return }
        job.lastFraction = fraction
        let perSecond = (fraction - job.startFraction) / (now - startedAt)
        job.finishAt = now + (1 - fraction) / perSecond
    }

    /// -1: almost done, 0..<steps.count: that step, steps.count: over an hour.
    static func index(forSeconds seconds: Double) -> Int {
        if seconds <= almostDoneBelow { return -1 }
        return steps.firstIndex { Double($0) >= seconds } ?? steps.count
    }

    static func estimate(forIndex index: Int) -> SyncEstimate {
        if index < 0 { return SyncEstimate(kind: .almostDone) }
        if index >= steps.count { return SyncEstimate(kind: .overAnHour) }
        return SyncEstimate(kind: .left(steps[index]))
    }
}

