import Foundation

/// One Apple Health reading reduced to what the daily and hourly aggregation needs. HealthKit-free, so the rules are unit-tested.
struct RawReading: Equatable, Sendable {
    var start: Date
    var end: Date
    /// Cumulative types: the amount. Discrete types: the average of the reading (a series reading holds `count` values).
    var value: Double
    var min: Double
    var max: Double
    /// Discrete types: the most recent value inside the reading.
    var last: Double
    var count: Int
    /// Bundle identifier of the app or device that wrote the reading.
    var source: String

    /// A single value (count 1).
    init(start: Date, end: Date, value: Double, source: String) {
        self.init(start: start, end: end, value: value, min: value, max: value, last: value, count: 1, source: source)
    }

    init(start: Date, end: Date, value: Double, min: Double, max: Double, last: Double, count: Int, source: String) {
        self.start = start
        self.end = end
        self.value = value
        self.min = min
        self.max = max
        self.last = last
        self.count = Swift.max(1, count)
        self.source = source
    }
}

/// Daily and hourly values computed from raw readings, for the days and hours Apple Health's own statistics leave out
/// (a restored iOS 27 iPhone returned empty statistics for every year that ended in the past, while the readings were there).
/// It follows HealthKit's statistics: a discrete reading counts in every bucket its time span touches, a series reading
/// weighs as many values as it holds, a cumulative reading is spread over its span by time. Cumulative readings from
/// several sources are never added together: per hour the largest source wins, like Apple Health's per-interval source
/// priority, so a Watch and an iPhone that both counted the same walk count it once.
struct SampleAggregator {
    enum Granularity { case day, hour }

    let calendar: Calendar
    let from: Date
    let to: Date
    let cumulative: Bool
    let granularity: Granularity

    private struct Discrete {
        var sum = 0.0
        var weight = 0
        var min = Double.infinity
        var max = -Double.infinity
        var lastAt = Date.distantPast
        var last = 0.0
    }

    private var discrete: [Date: Discrete] = [:]
    /// Cumulative amount per hour start, per source.
    private var hours: [Date: [String: Double]] = [:]

    init(calendar: Calendar, from: Date, to: Date, cumulative: Bool, granularity: Granularity) {
        self.calendar = calendar
        self.from = from
        self.to = to
        self.cumulative = cumulative
        self.granularity = granularity
    }

    mutating func add(_ r: RawReading) {
        guard r.value.isFinite, r.end >= r.start else { return }
        if cumulative { addCumulative(r) } else { addDiscrete(r) }
    }

    private mutating func addDiscrete(_ r: RawReading) {
        guard r.min.isFinite, r.max.isFinite, r.last.isFinite else { return }
        let component: Calendar.Component = granularity == .day ? .day : .hour
        for bucket in buckets(component, start: r.start, end: r.end) {
            var acc = discrete[bucket] ?? Discrete()
            acc.sum += r.value * Double(r.count)
            acc.weight += r.count
            acc.min = Swift.min(acc.min, r.min)
            acc.max = Swift.max(acc.max, r.max)
            if r.end >= acc.lastAt {
                acc.lastAt = r.end
                acc.last = r.last
            }
            discrete[bucket] = acc
        }
    }

    private mutating func addCumulative(_ r: RawReading) {
        let span = r.end.timeIntervalSince(r.start)
        if span <= 0 {
            guard r.start >= from, r.start < to, let hour = calendar.dateInterval(of: .hour, for: r.start)?.start else { return }
            hours[hour, default: [:]][r.source, default: 0] += r.value
            return
        }
        for hour in buckets(.hour, start: r.start, end: r.end) {
            guard let interval = calendar.dateInterval(of: .hour, for: hour) else { continue }
            let lo = Swift.max(interval.start, r.start, from)
            let hi = Swift.min(interval.end, r.end, to)
            guard hi > lo else { continue }
            hours[hour, default: [:]][r.source, default: 0] += r.value * hi.timeIntervalSince(lo) / span
        }
    }

    /// Starts of the buckets that the span [start, end) touches, inside [from, to). A reading without duration touches the
    /// bucket it is in.
    private func buckets(_ component: Calendar.Component, start: Date, end: Date) -> [Date] {
        let lo = Swift.max(start, from)
        let hi = end > start ? Swift.min(end, to) : start.addingTimeInterval(0.001)
        guard lo < to, hi > lo, var cursor = calendar.dateInterval(of: component, for: lo)?.start else { return [] }
        var out: [Date] = []
        while cursor < hi {
            out.append(cursor)
            guard let next = calendar.date(byAdding: component, value: 1, to: cursor), next > cursor else { break }
            cursor = next
        }
        return out
    }

    /// One value per local day that has readings ("YYYY-MM-DD", value).
    func daily(_ agg: DailyAgg) -> [(String, Double)] {
        if cumulative {
            var days: [String: Double] = [:]
            for (hour, sources) in hours {
                days[SleepNights.dayKey(hour, calendar: calendar), default: 0] += sources.values.max() ?? 0
            }
            return days.keys.sorted().map { ($0, days[$0]!) }
        }
        var days: [String: Discrete] = [:]
        for (bucket, acc) in discrete {
            let key = SleepNights.dayKey(bucket, calendar: calendar)
            guard var merged = days[key] else { days[key] = acc; continue }
            merged.sum += acc.sum
            merged.weight += acc.weight
            merged.min = Swift.min(merged.min, acc.min)
            merged.max = Swift.max(merged.max, acc.max)
            if acc.lastAt >= merged.lastAt { merged.lastAt = acc.lastAt; merged.last = acc.last }
            days[key] = merged
        }
        return days.keys.sorted().compactMap { day in
            guard let acc = days[day], acc.weight > 0 else { return nil }
            switch agg {
            case .sum: return nil
            case .avg: return (day, acc.sum / Double(acc.weight))
            case .min: return (day, acc.min)
            case .max: return (day, acc.max)
            case .last: return (day, acc.last)
            }
        }
    }

    /// One bucket per local hour that has readings: cumulative types fill `v` with the amount, discrete types the
    /// average (`v`), minimum (`lo`) and maximum (`hi`), each only when asked for.
    func hourly(avg: Bool, min: Bool, max: Bool) -> [HourBucket] {
        if cumulative {
            return hours.keys.sorted().map { HourBucket(t: $0.msValue, v: hours[$0]!.values.max() ?? 0, lo: nil, hi: nil) }
        }
        return discrete.keys.sorted().compactMap { hour in
            guard let acc = discrete[hour], acc.weight > 0 else { return nil }
            return HourBucket(t: hour.msValue, v: avg ? acc.sum / Double(acc.weight) : nil, lo: min ? acc.min : nil, hi: max ? acc.max : nil)
        }
    }

    /// Local calendar days from the day of `from` up to `to` (a day that has started counts).
    static func localDays(from: Date, to: Date, calendar: Calendar) -> Int {
        guard to > from else { return 0 }
        let first = calendar.startOfDay(for: from)
        let last = calendar.startOfDay(for: to.addingTimeInterval(-0.001))
        return (calendar.dateComponents([.day], from: first, to: last).day ?? 0) + 1
    }

    /// Relative difference of `other` from `reference` on the days both have, as (median, largest) absolute percentages.
    /// Used to measure the raw aggregation against Apple's own statistics where those work.
    static func difference(reference: [(String, Double)], other: [(String, Double)]) -> (median: Double, max: Double, days: Int)? {
        let ref = Dictionary(reference, uniquingKeysWith: { a, _ in a })
        let diffs = other.compactMap { day, v -> Double? in
            guard let r = ref[day], r != 0 else { return nil }
            return abs(v - r) / abs(r) * 100
        }.sorted()
        guard !diffs.isEmpty else { return nil }
        return (diffs[diffs.count / 2], diffs.last!, diffs.count)
    }
}
