import Foundation

/// One of the four lines under the big number while the first sync runs.
struct SyncLine: Equatable, Identifiable, Sendable {
    enum State: Equatable, Sendable {
        /// Not started: an empty line.
        case waiting
        /// Being read: a short bar moves back and forth (it says "working", not "this much is done").
        case running
        /// Finished: a solid line.
        case done
    }

    let id: Int
    let name: String
    /// What has been read so far, under the name.
    let detail: String
    let state: State
}

extension SyncProgress {
    /// Indexing, every day, every hour, every workout: the four kinds of data being read from Apple Health, each with its own count.
    var lines: [SyncLine] {
        let historyKnown = daysTotal > 0
        let workoutsDone = indexingDone && detailsDone >= detailsTotal
        let pending: String = isSyncing ? Copy.Home.Line.reading : Copy.Home.Line.waiting
        let indexingDetail: String = indexingDone ? Copy.Home.Line.workouts(detailsTotal) : Copy.Home.Line.reading
        let daysDetail: String = historyKnown ? Copy.Home.Line.days(daysRead) : (dailyDone ? "" : pending)
        let hoursDetail: String = historyKnown ? Copy.Home.Line.hours(hoursRead) : (hourlyDone ? "" : pending)
        let workoutsDetail: String = indexingDone ? Copy.Home.Line.progress(detailsDone, of: detailsTotal) : Copy.Home.Line.waiting
        // Only a line that is being read moves; while nothing runs (offline, between runs) the lines stand still.
        func lineState(done: Bool, started: Bool) -> SyncLine.State {
            if done { return .done }
            return started && isSyncing ? .running : .waiting
        }
        return [
            SyncLine(id: 0, name: Copy.Home.Line.indexing, detail: indexingDetail, state: indexingDone ? .done : .running),
            SyncLine(id: 1, name: Copy.Home.Line.everyDay, detail: daysDetail, state: lineState(done: dailyDone, started: true)),
            SyncLine(id: 2, name: Copy.Home.Line.everyHour, detail: hoursDetail, state: lineState(done: hourlyDone, started: true)),
            SyncLine(id: 3, name: Copy.Home.Line.everyWorkout, detail: workoutsDetail, state: lineState(done: workoutsDone, started: indexingDone)),
        ]
    }

    /// The sentence above the time left. It names the finest-grained thing still being read (hours, then days, then workouts),
    /// which is also what is left last.
    var headline: String {
        guard indexingDone else { return Copy.Home.Line.gettingReady }
        let hours = !hourlyDone, days = !dailyDone, workouts = detailsDone < detailsTotal
        let remaining = [hours, days, workouts].filter { $0 }.count
        if remaining == 0 { return Copy.Home.Line.finishingUp }
        let noun = hours ? "hour" : (days ? "day" : "workout")
        let since = (hours || days) ? (historySinceYear.map { Copy.Home.Line.since($0) } ?? "") : ""
        return remaining == 1 ? Copy.Home.Line.finishingEvery(noun, since: since) : Copy.Home.Line.indexingEvery(noun, since: since)
    }
}
