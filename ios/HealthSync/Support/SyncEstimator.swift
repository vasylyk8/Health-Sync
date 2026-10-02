import Foundation

/// A rough time left for the first sync, shown in coarse steps so small changes in speed never
/// make it jump. The number only goes down (a slowdown that lasts two minutes is allowed through).
struct SyncEstimate: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case estimating
        case minutes(Int)
        case almostDone
        case overAnHour
        case finished
    }

    var kind: Kind = .estimating

    var text: String {
        switch kind {
        case .estimating: return Copy.Home.estimating
        case .minutes(let m): return Copy.Home.minutesLeft(m)
        case .almostDone: return Copy.Home.almostDone
        case .overAnHour: return Copy.Home.overAnHour
        case .finished: return Copy.Home.upToDate
        }
    }
}

struct SyncEstimator {
    /// The minute values the estimate can show.
    static let buckets = [1, 2, 3, 5, 8, 10, 15, 20, 30, 45, 60]
    /// How long a higher estimate must hold before it replaces a lower one.
    static let riseDelay: TimeInterval = 120
    /// Speed is measured over this long a window.
    static let window: TimeInterval = 180
    /// And needs at least this much time of measurements.
    static let minimumSpan: TimeInterval = 10

    private var samples: [(time: TimeInterval, done: Int)] = []
    private var lowest: Int?
    private var risingSince: TimeInterval?
    private(set) var estimate = SyncEstimate()

    /// Feed every progress update. `now` is any steadily increasing clock, in seconds.
    mutating func record(detailsDone: Int, detailsTotal: Int, historyComplete: Bool, now: TimeInterval) {
        if historyComplete {
            self = SyncEstimator()
            estimate = SyncEstimate(kind: .finished)
            return
        }
        guard detailsTotal > 0 else { return }
        if samples.last?.done != detailsDone { samples.append((now, detailsDone)) }
        samples.removeAll { now - $0.time > Self.window }

        let remaining = max(0, detailsTotal - detailsDone)
        if remaining == 0 {
            estimate = SyncEstimate(kind: .almostDone)
            return
        }
        guard let first = samples.first, let last = samples.last, last.done > first.done, last.time - first.time >= Self.minimumSpan else { return }
        let perSecond = Double(last.done - first.done) / (last.time - first.time)
        let minutes = Double(remaining) / perSecond / 60

        var index = Self.index(forMinutes: minutes)
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

    /// -1: almost done, 0..<buckets.count: that bucket, buckets.count: over an hour.
    static func index(forMinutes minutes: Double) -> Int {
        if minutes <= 0.5 { return -1 }
        return buckets.firstIndex { Double($0) >= minutes } ?? buckets.count
    }

    static func estimate(forIndex index: Int) -> SyncEstimate {
        if index < 0 { return SyncEstimate(kind: .almostDone) }
        if index >= buckets.count { return SyncEstimate(kind: .overAnHour) }
        return SyncEstimate(kind: .minutes(buckets[index]))
    }
}
