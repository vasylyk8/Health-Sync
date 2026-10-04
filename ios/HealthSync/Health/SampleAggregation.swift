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
    /// Written by an Apple Watch (used only to measure alternative merge rules against HealthKit's).
    var watch = false

    /// A single value (count 1).
    init(start: Date, end: Date, value: Double, source: String, watch: Bool = false) {
        self.init(start: start, end: end, value: value, min: value, max: value, last: value, count: 1, source: source, watch: watch)
    }

    init(start: Date, end: Date, value: Double, min: Double, max: Double, last: Double, count: Int, source: String, watch: Bool = false) {
        self.start = start
        self.end = end
        self.value = value
        self.min = min
        self.max = max
        self.last = last
        self.count = Swift.max(1, count)
        self.source = source
        self.watch = watch
    }

    /// Apple's own devices (Watch, iPhone) write as com.apple.health.<id>.
    var apple: Bool { source.hasPrefix("com.apple.health") }
}

/// Daily and hourly values computed from raw readings, for the days and hours Apple Health's own statistics leave out
/// (a restored iOS 27 iPhone returned empty statistics for every year that ended in the past, while the readings were there).
/// The rules follow what HealthKit's statistics do, measured against them in the simulator by the daily check:
/// - arithmetic types (respiratory rate, SpO2...) weigh every value alike (a series reading as many values as it holds) and
///   count a reading only in the bucket it starts in, however far it reaches into the next one;
/// - time-weighted types (heart rate, resting heart rate) weigh each reading by its time span widened by 22.5 s on each
///   side, overlaps split in the middle, and count it in every bucket its span touches (the Watch's resting heart rate
///   written 23:55-23:50 counts on both days);
/// - sound levels average as energy (10^(dB/10)) weighted by duration, an equivalent continuous level;
/// - a cumulative reading is spread over its span by time, and readings from several sources are never added together:
///   per hour, if Apple's own devices recorded anything, the larger of them counts (a Watch and an iPhone that both
///   counted the same walk count it once) and other apps are left out, as Apple Health does by default (a scale app's
///   whole-day resting energy written at a weigh-in is not added to the Watch's); an hour only other apps recorded counts
///   their largest.
struct SampleAggregator {
    enum Granularity { case day, hour }
    enum Style { case cumulative, arithmetic, timeWeighted, equivalentLevel }

    /// Half the time HealthKit's time-weighted average gives an instantaneous reading (measured: 45 s in all). Sound levels
    /// are weighted by duration alone.
    static let halfWindow: TimeInterval = 22.5
    private var widen: TimeInterval { style == .timeWeighted ? Self.halfWindow : 0 }

    let calendar: Calendar
    let from: Date
    let to: Date
    let style: Style
    let granularity: Granularity

    private struct Span {
        var start: Double
        var end: Double
        var value: Double
        /// Most time the reading can weigh: a series reading of n values, spaced evenly, weighs each value until the next
        /// one, at most 45 s (measured), and 45 s for the last.
        var cap = Double.infinity
    }

    private struct Discrete {
        var sum = 0.0
        var weight = 0.0
        var spans: [Span] = []
        var min = Double.infinity
        var max = -Double.infinity
        var lastAt = Date.distantPast
        var last = 0.0
    }

    private var discrete: [Date: Discrete] = [:]
    /// Cumulative amount per hour start, per source.
    private var hours: [Date: [String: Double]] = [:]
    /// Cumulative amount per 5-minute slot, per source, and which sources are Apple Watches: only when `measureVariants`.
    private var slots: [Date: [String: Double]] = [:]
    private var watches: Set<String> = []
    let measureVariants: Bool

    init(calendar: Calendar, from: Date, to: Date, style: Style, granularity: Granularity, measureVariants: Bool = false) {
        self.calendar = calendar
        self.from = from
        self.to = to
        self.style = style
        self.granularity = granularity
        self.measureVariants = measureVariants
    }

    /// One hour's (or slot's) amount from the per-source amounts: Apple's devices first, the largest of them.
    static func merged(_ sources: [String: Double]) -> Double {
        let apple = sources.filter { $0.key.hasPrefix("com.apple.health") }
        return (apple.isEmpty ? sources : apple).values.max() ?? 0
    }

    mutating func add(_ r: RawReading) {
        guard r.value.isFinite, r.end >= r.start else { return }
        if style == .cumulative { addCumulative(r) } else { addDiscrete(r) }
    }

    private mutating func addDiscrete(_ r: RawReading) {
        guard r.min.isFinite, r.max.isFinite, r.last.isFinite else { return }
        for bucket in discreteBuckets(r) {
            var acc = discrete[bucket] ?? Discrete()
            switch style {
            case .arithmetic, .cumulative:
                acc.sum += r.value * Double(r.count)
                acc.weight += Double(r.count)
            case .timeWeighted, .equivalentLevel:
                acc.spans.append(span(r, value: style == .equivalentLevel ? pow(10, r.value / 10) : r.value))
            }
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
        // Copies, so the closures and the in-out bucket maps do not access `self` at the same time.
        let cal = calendar, lower = from, upper = to
        Self.spread(r, into: &hours, from: lower, to: upper) { cal.dateInterval(of: .hour, for: $0) }
        guard measureVariants else { return }
        if r.watch { watches.insert(r.source) }
        Self.spread(r, into: &slots, from: lower, to: upper) { date in
            let start = Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 300).rounded(.down) * 300)
            return DateInterval(start: start, duration: 300)
        }
    }

    /// Adds a cumulative reading to `buckets`, spread over the buckets its span covers by time.
    private static func spread(_ r: RawReading, into buckets: inout [Date: [String: Double]], from: Date, to: Date,
                               bucket: (Date) -> DateInterval?) {
        let span = r.end.timeIntervalSince(r.start)
        if span <= 0 {
            guard r.start >= from, r.start < to, let b = bucket(r.start)?.start else { return }
            buckets[b, default: [:]][r.source, default: 0] += r.value
            return
        }
        var cursor = r.start
        while cursor < r.end, let interval = bucket(cursor) {
            let lo = Swift.max(interval.start, r.start, from)
            let hi = Swift.min(interval.end, r.end, to)
            if hi > lo { buckets[interval.start, default: [:]][r.source, default: 0] += r.value * hi.timeIntervalSince(lo) / span }
            cursor = interval.end
        }
    }

    /// Daily totals by two other merge rules, to measure against HealthKit's statistics where those work: "a5" Apple's
    /// devices first, largest per 5 minutes; "w5" the Watch first, then the rest by the same rule, per 5 minutes.
    func dailyVariants() -> [String: [(String, Double)]] {
        var a5: [String: Double] = [:]
        var w5: [String: Double] = [:]
        for (slot, sources) in slots {
            let day = SleepNights.dayKey(slot, calendar: calendar)
            a5[day, default: 0] += Self.merged(sources)
            let watch = sources.filter { watches.contains($0.key) }
            w5[day, default: 0] += watch.isEmpty ? Self.merged(sources) : (watch.values.max() ?? 0)
        }
        return ["a5": a5.keys.sorted().map { ($0, a5[$0]!) }, "w5": w5.keys.sorted().map { ($0, w5[$0]!) }]
    }

    private var component: Calendar.Component { granularity == .day ? .day : .hour }

    /// The buckets a discrete reading counts in: the one it starts in, and for time-weighted types and sound levels also
    /// every later one its span reaches into. Only buckets inside [from, to).
    private func discreteBuckets(_ r: RawReading) -> [Date] {
        guard let first = calendar.dateInterval(of: component, for: r.start) else { return [] }
        var out = [first.start]
        if style != .arithmetic {
            var cursor = first.end
            while cursor < r.end, let next = calendar.dateInterval(of: component, for: cursor) {
                out.append(next.start)
                cursor = next.end
            }
        }
        let lower = calendar.dateInterval(of: component, for: from)?.start ?? from
        return out.filter { $0 >= lower && $0 < to }
    }

    private func span(_ r: RawReading, value: Double) -> Span {
        let start = r.start.timeIntervalSince1970
        let end = r.end.timeIntervalSince1970
        guard r.count > 1, style == .timeWeighted else { return Span(start: start, end: end, value: value) }
        let gap = (end - start) / Double(r.count)
        return Span(start: start, end: end - gap, value: value, cap: Double(r.count - 1) * Swift.min(gap, 2 * widen) + 2 * widen)
    }

    /// Average of one bucket's readings by the type's style.
    private func average(_ acc: Discrete, bucket: Date) -> Double? {
        switch style {
        case .arithmetic, .cumulative:
            return acc.weight > 0 ? acc.sum / acc.weight : nil
        case .timeWeighted:
            return timeWeightedMean(acc.spans, bucket: bucket)
        case .equivalentLevel:
            return timeWeightedMean(acc.spans, bucket: bucket).map { 10 * log10($0) }
        }
    }

    /// Each reading weighs its span widened by `widen` on each side, inside the bucket (widened the same way); where two
    /// neighbours' spans overlap, the overlap is split in the middle. Readings without any weight count alike.
    private func timeWeightedMean(_ spans: [Span], bucket: Date) -> Double? {
        guard !spans.isEmpty, let interval = calendar.dateInterval(of: component, for: bucket) else { return nil }
        let s = spans.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        let lo = s.map { $0.start - widen }
        let hi = s.map { $0.end + widen }
        let bucketStart = interval.start.timeIntervalSince1970 - widen
        let bucketEnd = interval.end.timeIntervalSince1970 + widen
        var sum = 0.0
        var weight = 0.0
        for i in s.indices {
            var a = Swift.max(lo[i], bucketStart)
            var b = Swift.min(hi[i], bucketEnd)
            if i > 0, lo[i] < hi[i - 1] { a = Swift.max(a, (lo[i] + hi[i - 1]) / 2) }
            if i + 1 < s.count, lo[i + 1] < hi[i] { b = Swift.min(b, (lo[i + 1] + hi[i]) / 2) }
            let w = Swift.min(s[i].cap, Swift.max(0, b - a))
            sum += s[i].value * w
            weight += w
        }
        if weight > 0 { return sum / weight }
        return s.map(\.value).reduce(0, +) / Double(s.count)
    }

    /// One value per local day that has readings ("YYYY-MM-DD", value).
    func daily(_ agg: DailyAgg) -> [(String, Double)] {
        if style == .cumulative {
            var days: [String: Double] = [:]
            for (hour, sources) in hours {
                days[SleepNights.dayKey(hour, calendar: calendar), default: 0] += Self.merged(sources)
            }
            return days.keys.sorted().map { ($0, days[$0]!) }
        }
        // Day buckets map one to one onto days; hour buckets (not used for daily values) would be merged per day.
        return discrete.keys.sorted().compactMap { bucket in
            guard let acc = discrete[bucket] else { return nil }
            let day = SleepNights.dayKey(bucket, calendar: calendar)
            switch agg {
            case .sum: return nil
            case .avg: return average(acc, bucket: bucket).map { (day, $0) }
            case .min: return (day, acc.min)
            case .max: return (day, acc.max)
            case .last: return (day, acc.last)
            }
        }
    }

    /// One bucket per local hour that has readings: cumulative types fill `v` with the amount, discrete types the
    /// average (`v`), minimum (`lo`) and maximum (`hi`), each only when asked for.
    func hourly(avg: Bool, min: Bool, max: Bool) -> [HourBucket] {
        if style == .cumulative {
            return hours.keys.sorted().map { HourBucket(t: $0.msValue, v: Self.merged(hours[$0]!), lo: nil, hi: nil) }
        }
        return discrete.keys.sorted().compactMap { hour in
            guard let acc = discrete[hour] else { return nil }
            return HourBucket(t: hour.msValue, v: avg ? average(acc, bucket: hour) : nil, lo: min ? acc.min : nil, hi: max ? acc.max : nil)
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
